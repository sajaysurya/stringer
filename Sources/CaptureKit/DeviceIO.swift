import CoreAudio
import Foundation
import StringerCore

/// Runs a call that can block inside the HAL on its own thread and waits at
/// most `seconds`. A hung call is abandoned, never waited on forever.
func withDeadline(_ seconds: Double, _ work: @escaping @Sendable () -> OSStatus) -> OSStatus? {
    let sem = DispatchSemaphore(value: 0)
    let box = StatusBox()
    Thread.detachNewThread {
        box.value = work()
        sem.signal()
    }
    return sem.wait(timeout: .now() + seconds) == .success ? box.value : nil
}

private final class StatusBox: @unchecked Sendable { var value: OSStatus = noErr }

public struct CaptureError: Error, CustomStringConvertible {
    public var description: String
    init(_ d: String) { description = d }
}

/// An IOProc on one device, delivering its input to a source.
final class DeviceInput: @unchecked Sendable {
    let device: AudioObjectID
    let name: String
    private var proc: AudioDeviceIOProcID?
    private let queue: DispatchQueue

    init(device: AudioObjectID, name: String) {
        self.device = device
        self.name = name
        queue = DispatchQueue(label: "stringer.io.\(device)", qos: .userInteractive)
    }

    func create(deliver: @escaping (UnsafePointer<AudioBufferList>, UInt64) -> Void) -> OSStatus {
        var proc: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, input, inputTime, _, _ in
            let t = inputTime.pointee
            let host = (t.mFlags.contains(.hostTimeValid) && t.mHostTime != 0) ? t.mHostTime : AudioGetCurrentHostTime()
            deliver(input, host)
        }
        self.proc = proc
        return err
    }

    /// Starts within `timeout` seconds or gives up. A hung start is left behind.
    func start(timeout: Double) -> OSStatus? {
        guard let proc else { return kAudioHardwareNotRunningError }
        let device = self.device
        if ProcessInfo.processInfo.environment["STRINGER_TEST_HANG_MIC"] == name {
            // Test hook (C-7): simulate a device whose start never returns.
            return withDeadline(timeout) { Thread.sleep(forTimeInterval: 3600); return noErr }
        }
        return withDeadline(timeout) { AudioDeviceStart(device, proc) }
    }

    func stop() {
        guard let proc else { return }
        let device = self.device
        _ = withDeadline(2) { AudioDeviceStop(device, proc) }
        AudioDeviceDestroyIOProcID(device, proc)
        self.proc = nil
    }
}

/// System audio: one global process tap of every process but this one, in a
/// private aggregate device clocked by the built-in speakers. The tap's
/// content is global; the clock device only supplies a clock.
public final class SystemTap: @unchecked Sendable {
    private let log: FileLog
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var input: DeviceInput?
    public private(set) var clockName = ""
    public private(set) var rate: Double = 48_000

    public init(log: FileLog) { self.log = log }

    public func start(bus: Bus, clock: TimelineClock) throws -> Source {
        let own = CA.processObject(pid: getpid())
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
        desc.name = "Stringer"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var err = AudioHardwareCreateProcessTap(desc, &tapID)
        guard err == noErr else { throw CaptureError("could not create the process tap (\(err))") }

        guard let clockDevice = CA.clockDevice() else { throw CaptureError("no real output device to clock the tap") }
        clockName = clockDevice.description
        log("tap clock: \(clockDevice)")

        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Stringer Tap",
            kAudioAggregateDeviceUIDKey: "org.sajay.stringer.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: clockDevice.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockDevice.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        err = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID)
        guard err == noErr else { throw CaptureError("could not create the tap's aggregate device (\(err))") }

        // Trust the aggregate's nominal rate, not the tap's format: the format
        // claims 48 kHz even when the clock runs at 24 kHz.
        rate = CA.nominalRate(aggregateID) ?? clockDevice.nominalRate
        if let fmt = CA.get(tapID, CA.address(kAudioTapPropertyFormat), AudioStreamBasicDescription()) {
            log("tap format claims \(Int(fmt.mSampleRate)) Hz × \(fmt.mChannelsPerFrame); aggregate nominal \(Int(rate)) Hz")
        }
        let source = Source(name: "system", rate: rate, bus: bus, clock: clock, log: log)
        let input = DeviceInput(device: aggregateID, name: "Stringer Tap")
        err = input.create { list, host in source.push(list, hostTime: host) }
        guard err == noErr else { throw CaptureError("could not create the tap IOProc (\(err))") }
        guard let started = input.start(timeout: 3) else { throw CaptureError("macOS did not start the tap within 3 s") }
        guard started == noErr else { throw CaptureError("could not start the tap (\(started))") }
        self.input = input
        log("system tap started")
        return source
    }

    public func stop() {
        input?.stop()
        input = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

public enum MicMode: String, Sendable {
    case `default`, all, none

    public init(setting: String) {
        switch setting.lowercased() {
        case "all": self = .all
        case "none", "off": self = .none
        default: self = .default  // includes the old name "aec"
        }
    }
}

/// The microphone track. In `default` mode it follows the system default
/// input (AirPods connecting, a pick in System Settings, the lid closing); in
/// `all` mode it mixes every real input and attaches or releases devices as
/// they come and go. Virtual loopback inputs are never used.
public final class Microphones: @unchecked Sendable {
    private let mode: MicMode
    private let bus: Bus
    private let clock: TimelineClock
    private let log: FileLog
    private let control = DispatchQueue(label: "stringer.mics")
    private let lock = NSLock()
    private var active: [AudioObjectID: (DeviceInput, Source)] = [:]
    /// Devices whose start is in flight. Never hold `lock` across a start: a
    /// hung start must not deadlock the device listeners.
    private var starting: Set<AudioObjectID> = []
    /// Devices whose start hung or failed: not retried on every device-list
    /// change (a hung start leaves a thread stuck in the HAL).
    private var gaveUp: Set<AudioObjectID> = []
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var stopped = false
    public private(set) var used: [String] = []

    public init(mode: MicMode, bus: Bus, clock: TimelineClock, log: FileLog) {
        self.mode = mode
        self.bus = bus
        self.clock = clock
        self.log = log
    }

    /// Attaches the initial devices synchronously, then follows changes.
    public func start() {
        guard mode != .none else { return }
        control.sync { reconcile() }
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var addr = CA.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.control.async { self?.reconcile() }
            }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, control, block)
            listeners.append((addr, block))
        }
    }

    public func stop() {
        control.sync {
            stopped = true
            for (addr, block) in listeners {
                var a = addr
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, control, block)
            }
            listeners.removeAll()
        }
        lock.lock()
        let all = active
        active.removeAll()
        lock.unlock()
        for (_, (input, source)) in all {
            input.stop()
            source.drain()
        }
    }

    public func drain() {
        lock.lock()
        let sources = active.values.map(\.1)
        lock.unlock()
        sources.forEach { $0.drain() }
    }

    private func wanted() -> [CA.Device] {
        switch mode {
        case .none: return []
        case .all: return CA.realInputs()
        case .default:
            if let id = CA.defaultInput(), let d = CA.device(id), d.inputChannels > 0 {
                if !d.isVirtual { return [d] }
                log("default input \(d) is a virtual loopback device — using a real mic instead")
            }
            let real = CA.realInputs()
            return Array((real.first { $0.isBuiltIn } ?? real.first).map { [$0] } ?? [])
        }
    }

    private func reconcile() {
        guard !stopped else { return }
        let want = wanted()
        let wantIDs = Set(want.map(\.id))
        lock.lock()
        let remove = active.filter { !wantIDs.contains($0.key) }
        for id in remove.keys { active.removeValue(forKey: id) }
        let add = want.filter { active[$0.id] == nil && !starting.contains($0.id) && !gaveUp.contains($0.id) }
        for d in add { starting.insert(d.id) }
        lock.unlock()

        for (_, (input, source)) in remove {
            log("mic released: \(input.name)")
            input.stop()
            source.drain()
        }
        for d in add {
            attach(d)
        }
    }

    private func attach(_ d: CA.Device) {
        defer {
            lock.lock()
            starting.remove(d.id)
            lock.unlock()
        }
        let rate = d.nominalRate > 0 ? d.nominalRate : 48_000
        let source = Source(name: "mic \(d.name)", rate: rate, bus: bus, clock: clock, log: log)
        let input = DeviceInput(device: d.id, name: d.name)
        let err = input.create { list, host in source.push(list, hostTime: host) }
        guard err == noErr else {
            log("mic \(d): could not create IOProc (\(err)) — skipped, recording continues")
            return
        }
        guard let status = input.start(timeout: 3) else {
            log("mic \(d): macOS did not start it within 3 s — skipped, recording continues")
            lock.lock(); gaveUp.insert(d.id); lock.unlock()
            return
        }
        guard status == noErr else {
            log("mic \(d): start failed (\(status)) — skipped, recording continues")
            lock.lock(); gaveUp.insert(d.id); lock.unlock()
            input.stop()
            return
        }
        lock.lock()
        active[d.id] = (input, source)
        if !used.contains(d.name) { used.append(d.name) }
        lock.unlock()
        log("mic attached: \(d)")
    }
}
