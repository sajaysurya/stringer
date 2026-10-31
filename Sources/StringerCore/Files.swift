import Darwin
import Foundation

/// The meeting folder's files. Files are the protocol between processes:
/// each file has one writer, and every write is atomic.
public enum MeetingFile {
    /// Stable identity: `{id, created, started_at, auto_title, title, …}`. Survives cleanup.
    public static let meeting = "meeting.json"
    /// The owner's live status. Written only by the owner, atomically.
    public static let state = "state.json"
    /// Settings snapshot for this meeting.
    public static let settings = "settings.json"
    public static let mic = "mic.wav"
    public static let system = "system.wav"
    /// Written by the recorder as soon as it is up.
    public static let captureLog = "capture.log"
    /// Written by the recorder last, after a clean stop.
    public static let captureJSON = "capture.json"
    /// Touched by whoever wants the recording stopped.
    public static let stop = "STOP"
    public static let live = "live.txt"
    public static let transcript = "transcript.txt"
    /// Output of a background owner.
    public static let workerLog = "worker.log"
    /// Intermediate output of the final pass (debug only).
    public static let finalJSON = "final.json"
    public static let liveJSON = "live.json"
    public static let title = "title.json"

    /// Everything the program may write. Cleanup removes only names from this
    /// list, never a glob and never anything unknown.
    public static let working: [String] = [
        state, settings, mic, system, captureLog, captureJSON, stop,
        workerLog, finalJSON, liveJSON, title,
    ]
    /// What a cleaned-up meeting keeps.
    public static let kept: [String] = [meeting, live, transcript]
}

public enum AtomicFile {
    /// Writes to a temporary file in the same folder, then renames over the target.
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
        try data.write(to: tmp)
        if rename(tmp.path, url.path) != 0 {
            let err = errno
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
    }

    public static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    public static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try write(JSON.encode(value), to: url)
    }
}

public enum JSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try enc.encode(value)
        data.append(0x0A)
        return data
    }

    /// Readers tolerate partial or missing files: any failure is nil.
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

public extension URL {
    func appending(_ name: String) -> URL { appendingPathComponent(name) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// Touches a file (creates it empty if missing).
public func touch(_ url: URL) {
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    } else {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
}

public func processIsAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

/// Path of the running executable, symlinks resolved.
public func executableURL() -> URL {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size) + 1)
    _NSGetExecutablePath(&buf, &size)
    return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath()
}

public enum Clock {
    public static func iso(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    public static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// `mm:ss`, or `h:mm:ss` from an hour.
    public static func stamp(_ seconds: Double) -> String {
        let t = max(0, Int(seconds))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

/// Appends timestamped lines to a log file. Thread-safe.
public final class FileLog: @unchecked Sendable {
    private let handle: FileHandle?
    private let lock = NSLock()
    private let echo: Bool

    public init(_ url: URL, echo: Bool = false) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        self.echo = echo
    }

    public func callAsFunction(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        let line = "\(f.string(from: Date())) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        handle?.write(Data(line.utf8))
        if echo { FileHandle.standardError.write(Data(line.utf8)) }
    }
}

public let stringerVersion = "0.1.0"
