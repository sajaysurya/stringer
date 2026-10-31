import CoreAudio
import Foundation

/// Read-only Core Audio queries shared by the recorder, `doctor` and the
/// menu-bar app's meeting detection.
public enum CA {
    public static func address(_ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                               _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress
    {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    public static func get<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var addr = addr
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return err == noErr ? value : nil
    }

    public static func getArray<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ zero: T) -> [T] {
        var addr = addr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var out = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &out) == noErr else { return [] }
        return Array(out.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    public static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String?
    {
        var addr = address(selector, scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // MARK: devices

    public struct Device: Equatable, CustomStringConvertible {
        public var id: AudioObjectID
        public var name: String
        public var uid: String
        public var transport: UInt32
        public var inputChannels: Int
        public var outputChannels: Int
        public var nominalRate: Double

        public var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
        /// Loopback drivers (ZoomAudioDevice, Microsoft Teams Audio, …) and
        /// aggregates. Their input is a meeting's far end and an idle one
        /// does not clock, so they are never a mic nor the tap's clock.
        public var isVirtual: Bool {
            if transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate
                || transport == kAudioDeviceTransportTypeAutoAggregate { return true }
            let n = name.lowercased()
            return CA.virtualNameHints.contains { n.contains($0) }
        }
        public var description: String {
            "\(name) [\(transportName)\(nominalRate > 0 ? ", \(Int(nominalRate)) Hz" : "")]"
        }
        public var transportName: String {
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn: return "built-in"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
            case kAudioDeviceTransportTypeUSB: return "usb"
            case kAudioDeviceTransportTypeVirtual: return "virtual"
            case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return "aggregate"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
            case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
            case kAudioDeviceTransportTypeAirPlay: return "airplay"
            case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return "continuity"
            default: return "other"
            }
        }
    }

    public static let virtualNameHints = ["zoomaudiodevice", "microsoft teams audio", "blackhole", "loopback",
                                          "soundflower", "stringer tap", "webex", "krisp", "cadefaultdeviceaggregate"]

    public static func deviceIDs() -> [AudioObjectID] {
        getArray(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices), AudioObjectID(0))
    }

    public static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func device(_ id: AudioObjectID) -> Device? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return Device(
            id: id,
            name: string(id, kAudioObjectPropertyName) ?? "device \(id)",
            uid: uid,
            transport: get(id, address(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0,
            inputChannels: channels(id, kAudioObjectPropertyScopeInput),
            outputChannels: channels(id, kAudioObjectPropertyScopeOutput),
            nominalRate: nominalRate(id) ?? 0
        )
    }

    public static func devices() -> [Device] { deviceIDs().compactMap(device) }

    public static func nominalRate(_ id: AudioObjectID) -> Double? {
        get(id, address(kAudioDevicePropertyNominalSampleRate), Float64(0))
    }

    public static func defaultInput() -> AudioObjectID? {
        let id = get(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultInputDevice), AudioObjectID(0))
        return id == 0 ? nil : id
    }

    public static func defaultOutput() -> AudioObjectID? {
        let id = get(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0))
        return id == 0 ? nil : id
    }

    /// The tap's clock: the built-in speakers (always present, always 48 kHz),
    /// else the default output if it is real, else any real output.
    public static func clockDevice() -> Device? {
        let all = devices()
        if let d = all.first(where: { $0.isBuiltIn && $0.outputChannels > 0 }) { return d }
        if let id = defaultOutput(), let d = device(id), !d.isVirtual, d.outputChannels > 0 { return d }
        return all.first { !$0.isVirtual && $0.outputChannels > 0 }
    }

    /// Real (non-virtual) input devices.
    public static func realInputs() -> [Device] {
        devices().filter { $0.inputChannels > 0 && !$0.isVirtual }
    }

    // MARK: processes

    public struct AudioProcess {
        public var object: AudioObjectID
        public var pid: Int32
        public var bundleID: String
        public var isRunningInput: Bool
        public var isRunningOutput: Bool
    }

    /// Every process Core Audio knows, with whether it is using an input
    /// right now. Needs no permission.
    public static func audioProcesses() -> [AudioProcess] {
        let ids = getArray(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyProcessObjectList), AudioObjectID(0))
        return ids.map { obj in
            AudioProcess(
                object: obj,
                pid: get(obj, address(kAudioProcessPropertyPID), pid_t(0)) ?? 0,
                bundleID: string(obj, kAudioProcessPropertyBundleID) ?? "",
                isRunningInput: (get(obj, address(kAudioProcessPropertyIsRunningInput), UInt32(0)) ?? 0) != 0,
                isRunningOutput: (get(obj, address(kAudioProcessPropertyIsRunningOutput), UInt32(0)) ?? 0) != 0
            )
        }
    }

    public static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var obj = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                             UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return err == noErr && obj != 0 ? obj : nil
    }
}
