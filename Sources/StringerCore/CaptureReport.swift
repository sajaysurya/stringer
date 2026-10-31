import Foundation

/// `capture.json`, written by the recorder last, after a clean stop.
public struct CaptureReport: Codable, Sendable {
    public struct Track: Codable, Sendable {
        public var seconds: Double
        public var peak: Float
        /// Exact zeros for the whole recording. On the system track while
        /// audio was known to play, this is the classic permission failure.
        public var silent: Bool

        public init(seconds: Double, peak: Float) {
            self.seconds = seconds
            self.peak = peak
            silent = peak == 0
        }
    }

    public var version: String
    public var startedAt: String
    public var endedAt: String
    public var stopReason: String
    public var system: Track
    public var mic: Track?
    public var micMode: String
    public var mics: [String]
    public var clock: String
    public var tapRate: Double
    public var aec: Bool
    public var errors: [String]

    enum CodingKeys: String, CodingKey {
        case version, system, mic, mics, clock, aec, errors
        case startedAt = "started_at", endedAt = "ended_at", stopReason = "stop_reason"
        case micMode = "mic_mode", tapRate = "tap_rate"
    }

    public init(version: String, startedAt: String, endedAt: String, stopReason: String, system: Track, mic: Track?,
                micMode: String, mics: [String], clock: String, tapRate: Double, aec: Bool, errors: [String])
    {
        self.version = version
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.stopReason = stopReason
        self.system = system
        self.mic = mic
        self.micMode = micMode
        self.mics = mics
        self.clock = clock
        self.tapRate = tapRate
        self.aec = aec
        self.errors = errors
    }
}

/// The first line of `capture.log`: `recorder pid=123 t0=<iso> mic=default`.
/// `t0` is the timeline's origin, i.e. the meeting's `started_at`.
public struct RecorderHello: Sendable {
    public var pid: Int32
    public var t0: Date

    public static func line(pid: Int32, t0: Date, mic: String) -> String {
        "recorder pid=\(pid) t0=\(Clock.iso(t0)) mic=\(mic) version=\(stringerVersion)"
    }

    public static func parse(_ log: URL) -> RecorderHello? {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.contains("recorder pid=") {
            var pid: Int32?
            var t0: Date?
            for field in line.split(separator: " ") {
                if field.hasPrefix("pid=") { pid = Int32(field.dropFirst(4)) }
                if field.hasPrefix("t0=") { t0 = Clock.parse(String(field.dropFirst(3))) }
            }
            if let pid, let t0 { return RecorderHello(pid: pid, t0: t0) }
        }
        return nil
    }
}
