import CoreAudio
import Foundation
import StringerCore

/// The capture engine. Writes `mic.wav` and `system.wav` on one timeline,
/// applies AEC3 to the mic in-process, watches for `STOP`, and writes
/// `capture.json` last.
///
/// Order matters: mics start before the tap (starting the built-in mic while
/// a tap ran on the built-in speakers hung inside the HAL).
public final class Recorder: @unchecked Sendable {
    public struct Options {
        public var dir: URL
        public var mic: MicMode
        public var maxSeconds: Double = 4 * 3600
        public var aec = true
        /// Replay two files instead of capturing (tests; no permissions needed).
        public var replayMic: URL?
        public var replaySystem: URL?
        public var replaySpeed: Double = 1

        public init(dir: URL, mic: MicMode) {
            self.dir = dir
            self.mic = mic
        }
    }

    /// Flush audio at least this old, so late buffers from any source have landed.
    static let holdBack = 2 * timelineRate
    static let flushInterval = 0.25

    private let opt: Options
    private let log: FileLog
    private let clock: TimelineClock
    private let systemBus = Bus()
    private let micBus = Bus()
    private var systemWriter: WavWriter!
    private var micWriter: WavWriter?
    private var aec: EchoCanceller?
    private var tap: SystemTap?
    private var mics: Microphones?
    private var systemSource: Source?
    private var replay: Replay?
    private var flushed = 0
    private var lastPatch = Date()
    private let work = DispatchQueue(label: "stringer.recorder")
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private var stopping = false
    private var errors: [String] = []
    private let done = DispatchSemaphore(value: 0)
    public private(set) var exitCode: Int32 = 0

    public init(_ options: Options) {
        opt = options
        log = FileLog(options.dir.appending(MeetingFile.captureLog))
        if options.replaySystem != nil {
            clock = ReplayClock(speed: options.replaySpeed)
        } else {
            clock = HostClock()
        }
    }

    /// Runs until stopped. Returns the process exit code.
    public func run() -> Int32 {
        log(RecorderHello.line(pid: getpid(), t0: clock.startDate, mic: opt.mic.rawValue))
        do {
            systemWriter = try WavWriter(url: opt.dir.appending(MeetingFile.system))
            if opt.mic != .none {
                micWriter = try WavWriter(url: opt.dir.appending(MeetingFile.mic))
                if opt.aec {
                    aec = EchoCanceller()
                    log(aec == nil ? "AEC3 unavailable — mic track not echo-cancelled" : "AEC3 on the mic track")
                }
            }
        } catch {
            log("cannot write audio files: \(error)")
            return 1
        }

        if let sys = opt.replaySystem {
            replay = Replay(system: sys, mic: opt.mic == .none ? nil : opt.replayMic,
                            systemBus: systemBus, micBus: micBus, clock: clock as! ReplayClock, log: log)
            replay?.start()
            log("replaying \(sys.lastPathComponent)\(opt.replayMic.map { " + \($0.lastPathComponent)" } ?? "")")
        } else {
            // Mics first, then the tap.
            if opt.mic != .none {
                let m = Microphones(mode: opt.mic, bus: micBus, clock: clock, log: log)
                m.start()
                mics = m
            }
            let t = SystemTap(log: log)
            do {
                systemSource = try t.start(bus: systemBus, clock: clock)
                tap = t
            } catch {
                log("system audio: \(error)")
                errors.append("system audio: \(error)")
                t.stop()
                mics?.stop()
                finish(reason: "error")
                return 1
            }
        }

        installSignals()
        let timer = DispatchSource.makeTimerSource(queue: work)
        timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        log("recording")
        done.wait()
        return exitCode
    }

    private func installSignals() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: work)
            s.setEventHandler { [weak self] in self?.stop(reason: sig == SIGINT ? "SIGINT" : "SIGTERM") }
            s.resume()
            signals.append(s)
        }
    }

    private func tick() {
        guard !stopping else { return }
        let stopFile = opt.dir.appending(MeetingFile.stop)
        if stopFile.exists {
            stop(reason: "STOP")
            return
        }
        if Double(clock.nowPosition()) / Double(timelineRate) >= opt.maxSeconds {
            stop(reason: "ceiling")
            return
        }
        if let replay, replay.finished, Double(clock.nowPosition()) > Double(replay.length + Self.holdBack) {
            stop(reason: "replay-end")
            return
        }
        flush(upTo: clock.nowPosition() - Self.holdBack)
    }

    /// Writes `[flushed, end)` of both tracks, end aligned to whole AEC frames.
    private func flush(upTo rawEnd: Int) {
        let frame = aec?.frameSize ?? 160
        let end = rawEnd - rawEnd % frame
        guard end > flushed else { return }
        let system = systemBus.take(upTo: end)
        systemWriter.write(system)
        if let micWriter {
            var mic = micBus.take(upTo: end)
            aec?.process(mic: &mic, system: system)
            micWriter.write(mic)
        }
        flushed = end
        if Date().timeIntervalSince(lastPatch) > 5 {
            systemWriter.patchHeader()
            micWriter?.patchHeader()
            lastPatch = Date()
        }
    }

    /// Stops on STOP, a signal, or the ceiling. Runs on `work`.
    public func stop(reason: String) {
        guard !stopping else { return }
        stopping = true
        log("stopping: \(reason)")
        timer?.cancel()
        mics?.stop()
        tap?.stop()
        systemSource?.drain()
        replay?.stop()
        finish(reason: reason)
    }

    private func finish(reason: String) {
        // Everything that has landed, padded to a whole frame.
        let frame = aec?.frameSize ?? 160
        var end = max(systemBus.highWater, micBus.highWater, flushed)
        if end % frame != 0 { end += frame - end % frame }
        if systemWriter != nil { flush(upTo: end) }
        systemWriter?.close()
        micWriter?.close()
        try? FileManager.default.removeItem(at: opt.dir.appending(MeetingFile.stop))

        let report = CaptureReport(
            version: stringerVersion,
            startedAt: Clock.iso(clock.startDate),
            endedAt: Clock.iso(),
            stopReason: reason,
            system: .init(seconds: systemWriter?.seconds ?? 0, peak: systemWriter?.peak ?? 0),
            mic: micWriter.map { .init(seconds: $0.seconds, peak: $0.peak) },
            micMode: opt.mic.rawValue,
            mics: mics?.used ?? [],
            clock: tap?.clockName ?? (replay != nil ? "replay" : ""),
            tapRate: tap?.rate ?? 0,
            aec: aec != nil,
            errors: errors
        )
        if report.system.silent { log("system track is exact zeros (silent)") }
        if report.mic?.silent == true { log("mic track is exact zeros (silent)") }
        do {
            try AtomicFile.writeJSON(report, to: opt.dir.appending(MeetingFile.captureJSON))
        } catch {
            log("could not write capture.json: \(error)")
        }
        log(String(format: "stopped (%@): system %.2fs peak %.3f%@", reason, report.system.seconds, report.system.peak,
                   report.mic.map { String(format: ", mic %.2fs peak %.3f", $0.seconds, $0.peak) } ?? ""))
        exitCode = reason == "error" ? 1 : 0
        done.signal()
    }
}

/// A clock for replay: advances with the wall clock times a speed factor.
final class ReplayClock: TimelineClock, @unchecked Sendable {
    let startDate = Date()
    let speed: Double
    init(speed: Double) { self.speed = max(speed, 0.01) }
    func position(hostTime: UInt64) -> Int { nowPosition() }
    func nowPosition() -> Int { Int(Date().timeIntervalSince(startDate) * speed * Double(timelineRate)) }
}

/// Feeds files onto the buses at the replay clock's pace, through the same
/// resampling path as live capture.
final class Replay: @unchecked Sendable {
    private let systemSource: Source
    private let micSource: Source?
    private let system: [Float]
    private let mic: [Float]
    private let clock: ReplayClock
    private var position = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "stringer.replay")
    var length: Int { max(system.count, mic.count) }
    private(set) var finished = false

    init(system: URL, mic: URL?, systemBus: Bus, micBus: Bus, clock: ReplayClock, log: FileLog) {
        let sys = Self.load(system)
        let m = mic.map(Self.load)
        self.system = sys.samples
        self.mic = m?.samples ?? []
        self.clock = clock
        systemSource = Source(name: "system", rate: sys.rate, bus: systemBus, clock: clock, log: log)
        micSource = m.map { Source(name: "mic replay", rate: $0.rate, bus: micBus, clock: clock, log: log) }
    }

    /// Any 16-bit WAV, converted to 16 kHz up front so positions are exact.
    static func load(_ url: URL) -> (samples: [Float], rate: Double) {
        let rate = Double(WavReader.info(url)?.sampleRate ?? timelineRate)
        let samples = WavReader.read(url)
        return (rate == Double(timelineRate) ? samples : Resampler(inputRate: rate).process(samples), Double(timelineRate))
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 0.05)
        t.setEventHandler { [weak self] in self?.feed() }
        t.resume()
        timer = t
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
        systemSource.drain()
        micSource?.drain()
    }

    private func feed() {
        let target = clock.nowPosition()
        guard target > position else { return }
        let from = position, to = min(target, length)
        if from >= length {
            finished = true
            return
        }
        push(system, source: systemSource, from: from, to: to)
        if let micSource { push(mic, source: micSource, from: from, to: to) }
        position = to
    }

    private func push(_ x: [Float], source: Source, from: Int, to: Int) {
        let a = min(from, x.count), b = min(to, x.count)
        guard b > a else { return }
        source.push(mono: Array(x[a..<b]), position: from)
    }
}
