import Foundation
import StringerCore
import StringerKit

/// The app is a UI only: it never owns a recording. It reads meeting folders
/// directly (`Snapshot`) and changes things through the CLI, so the CLI and
/// the app always agree and quitting the app never loses a recording.
enum Backend {
    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Runs `stringer <args>` off the main thread; the completion runs on main.
    static func run(_ args: [String], completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = runSync(args)
            DispatchQueue.main.async { completion(r) }
        }
    }

    static func runSync(_ args: [String]) -> Result {
        let p = Process()
        p.executableURL = Binaries.cli
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            return Result(status: -1, stdout: "", stderr: "cannot run \(Binaries.cli.path): \(error)")
        }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, stdout: String(data: o, encoding: .utf8) ?? "",
                      stderr: String(data: e, encoding: .utf8) ?? "")
    }

    /// `stringer setup --progress`, reporting `(fraction, label)` on main.
    static func setup(progress: @escaping (Double, String) -> Void, done: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = Binaries.cli
            p.arguments = ["setup", "--progress"]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch {
                DispatchQueue.main.async { done(false, "\(error)") }
                return
            }
            var buffer = Data()
            let h = out.fileHandleForReading
            while true {
                let chunk = h.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = String(data: buffer[..<nl], encoding: .utf8) ?? ""
                    buffer.removeSubrange(...nl)
                    let parts = line.split(separator: " ", maxSplits: 2)
                    if parts.count >= 2, parts[0] == "progress", let f = Double(parts[1]) {
                        let label = parts.count > 2 ? String(parts[2]) : ""
                        DispatchQueue.main.async { progress(f, label) }
                    }
                }
            }
            p.waitUntilExit()
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async { done(p.terminationStatus == 0, e) }
        }
    }
}

/// Watches the meetings folder (recursively) and calls back, coalesced.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let callback: () -> Void

    init(callback: @escaping () -> Void) { self.callback = callback }

    func watch(_ url: URL) {
        stop()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().callback()
        }
        stream = FSEventStreamCreate(nil, cb, &ctx, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

/// Meeting detection: every 2 s, which processes are using a microphone,
/// via Core Audio's per-process `IsRunningInput` (no permission needed). A
/// meeting app keeps the mic open while muted, so muting is not "ended".
final class MeetingDetector {
    struct App { var name: String; var prefixes: [String] }

    static let apps: [App] = [
        App(name: "Zoom", prefixes: ["us.zoom."]),
        App(name: "Teams", prefixes: ["com.microsoft.teams"]),
        App(name: "Slack", prefixes: ["com.tinyspeck.slackmacgap"]),
        App(name: "FaceTime", prefixes: ["com.apple.FaceTime", "com.apple.avconferenced"]),
        App(name: "Webex", prefixes: ["com.webex.", "com.cisco.webex", "Cisco-Systems.Spark"]),
        App(name: "Chrome", prefixes: ["com.google.Chrome"]),
        // Safari captures in its WebKit GPU process.
        App(name: "Safari", prefixes: ["com.apple.Safari", "com.apple.WebKit.GPU"]),
        App(name: "Arc", prefixes: ["company.thebrowser."]),
        App(name: "Edge", prefixes: ["com.microsoft.edgemac"]),
        App(name: "Brave", prefixes: ["com.brave.Browser"]),
        App(name: "Firefox", prefixes: ["org.mozilla.firefox"]),
    ]

    /// Matches by prefix so helper processes count; ignores Stringer itself.
    static func appName(bundleID: String) -> String? {
        if bundleID.hasPrefix("org.sajay.stringer") { return nil }
        return apps.first { $0.prefixes.contains { bundleID.hasPrefix($0) } }?.name
    }

    /// Meeting apps using a mic right now.
    static func current() -> [String] {
        var names: [String] = []
        for p in CA.audioProcesses() where p.isRunningInput {
            if let n = appName(bundleID: p.bundleID), !names.contains(n) { names.append(n) }
        }
        return names
    }

    var onStart: (String) -> Void = { _ in }
    var onEnd: () -> Void = {}
    private var timer: Timer?
    private(set) var active: [String] = []
    private(set) var lastSeen: Date?
    /// How long no meeting app may use the mic before the meeting has ended.
    static let grace: TimeInterval = 30

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func poll() {
        let now = Self.current()
        if !now.isEmpty { lastSeen = Date() }
        if active.isEmpty, let first = now.first { onStart(first) }
        active = now
    }

    /// No meeting app has used the mic for the grace period.
    var ended: Bool {
        guard active.isEmpty else { return false }
        return lastSeen.map { Date().timeIntervalSince($0) >= Self.grace } ?? true
    }
}
