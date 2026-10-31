import Darwin
import Foundation
import StringerCore

/// The transcript file: front matter (title, date, duration, speakers, id)
/// then the lines. After cleanup the meeting is described by this alone.
public struct TranscriptDoc: Equatable, Sendable {
    public var title: String
    public var date: Date
    public var duration: Double
    public var speakers: [String]
    public var id: String
    public var body: String

    public init(title: String, date: Date, duration: Double, speakers: [String], id: String, body: String) {
        self.title = title
        self.date = date
        self.duration = duration
        self.speakers = speakers
        self.id = id
        self.body = body
    }

    public func render() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return """
        ---
        title: \(title)
        date: \(f.string(from: date))
        duration: \(Clock.stamp(duration))
        speakers: \(speakers.joined(separator: ", "))
        id: \(id)
        ---

        \(body.trimmingCharacters(in: .newlines))

        """
    }

    public static func parse(_ text: String) -> TranscriptDoc? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let c = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<c])] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return TranscriptDoc(
            title: fields["title"] ?? "",
            date: fields["date"].flatMap(f.date(from:)) ?? .distantPast,
            duration: parseStamp(fields["duration"] ?? ""),
            speakers: (fields["speakers"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            id: fields["id"] ?? "",
            body: lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)
        )
    }

    static func parseStamp(_ s: String) -> Double {
        s.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
    }

    public static func read(_ url: URL) -> TranscriptDoc? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap(parse)
    }
}

public enum Lifecycle {
    /// Renames a meeting. While it is still being recorded or transcribed only
    /// the title changes (the owner renames the folder when it finishes); a
    /// finished meeting is renamed at once and its transcript edited in place.
    public static func rename(_ ref: Meeting, to title: String, store: MeetingStore, vault: URL?) throws -> Meeting {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw StoreError("the title cannot be empty") }
        return try MeetingLock.with(ref.id) {
            var m = store.find(id: ref.id) ?? ref
            m = try store.update(m) {
                $0.title = clean
                $0.autoTitle = false
            }
            if m.state.isTerminal { m = try applyName(m, store: store, vault: vault) }
            return m
        }
    }

    /// Makes the folder name, transcript header and vault copy match the
    /// title. Call with the meeting's lock held.
    @discardableResult
    public static func applyName(_ m: Meeting, store: MeetingStore, vault: URL?) throws -> Meeting {
        let oldName = m.dir.lastPathComponent
        let moved = try store.syncFolder(m)
        let tURL = moved.file(MeetingFile.transcript)
        if var doc = TranscriptDoc.read(tURL), doc.title != moved.title {
            doc.title = moved.title
            try AtomicFile.write(doc.render(), to: tURL)
        }
        if let vault, tURL.exists {
            let old = vault.appending(oldName + ".md")
            let new = vault.appending(moved.dir.lastPathComponent + ".md")
            if old != new { try? FileManager.default.removeItem(at: old) }
            try? copyToVault(tURL, vault: vault, name: moved.dir.lastPathComponent)
        }
        return moved
    }

    public static func copyToVault(_ transcript: URL, vault: URL, name: String) throws {
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let data = try Data(contentsOf: transcript)
        try AtomicFile.write(data, to: vault.appending(name + ".md"))
    }

    /// Removes the program's working files, by name. Anything not on the list
    /// (including files people put in the folder) is left alone.
    public static func cleanup(_ m: Meeting) {
        for name in MeetingFile.working {
            try? FileManager.default.removeItem(at: m.file(name))
        }
    }
}

// MARK: - status

public struct MeetingSummary: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var dir: String
    public var state: MeetingState
    public var autoTitle: Bool
    public var source: String?
    public var startedAt: String?
    public var elapsed: Double
    public var levels: OwnerState.Levels
    public var error: String?
    public var transcript: String?
    public var live: String?

    enum CodingKeys: String, CodingKey {
        case id, title, dir, state, source, elapsed, levels, error, transcript, live
        case autoTitle = "auto_title", startedAt = "started_at"
    }

    public init(_ m: Meeting) {
        id = m.id
        title = m.title
        dir = m.dir.path
        state = m.state
        autoTitle = m.info.autoTitle
        source = m.info.source
        startedAt = m.info.startedAt
        elapsed = m.elapsed
        levels = m.owner?.levels ?? .init()
        error = m.owner?.error ?? m.info.error
        transcript = m.file(MeetingFile.transcript).exists ? m.file(MeetingFile.transcript).path : nil
        live = m.file(MeetingFile.live).exists ? m.file(MeetingFile.live).path : nil
    }
}

public struct Snapshot: Codable, Sendable {
    public var version: String
    public var home: String
    public var settings: Settings
    public var models: ModelStatus
    /// Every meeting that isn't done, failed or interrupted.
    public var active: [MeetingSummary]
    /// The most recent finished meeting.
    public var last: MeetingSummary?

    /// One read of the meeting folders, for `status` and the menu-bar app.
    public static func take(settings: Settings = .current()) -> Snapshot {
        let store = MeetingStore(settings: settings)
        let all = store.all()
        return Snapshot(
            version: stringerVersion,
            home: store.home.path,
            settings: settings,
            models: ModelStatus.check(),
            active: all.filter { !$0.state.isTerminal }.map(MeetingSummary.init),
            last: all.last { $0.state.isTerminal }.map(MeetingSummary.init)
        )
    }
}

/// Whether the speech models are on disk. `stringer setup` writes the marker
/// after verifying them; the folders must still be there.
public struct ModelStatus: Codable, Sendable, Equatable {
    public var ready: Bool
    public var downloading: Bool
    public var missing: [String]

    public static var fluidModels: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending("FluidAudio/Models")
    }

    public static let required = ["parakeet-tdt-0.6b-v3", "speaker-diarization"]
    public static var marker: URL { Paths.support.appending("models-ready") }
    public static var setupLock: URL { Paths.support.appending("setup.lock") }

    public static func check() -> ModelStatus {
        let missing = required.filter { !fluidModels.appending($0).exists }
        let ready = missing.isEmpty && marker.exists
        return ModelStatus(ready: ready, downloading: setupRunning(), missing: ready ? [] : (missing.isEmpty ? ["verification (run stringer setup)"] : missing))
    }

    /// `stringer setup` holds a lock file with its pid while downloading.
    public static func setupRunning() -> Bool {
        guard let text = try? String(contentsOf: setupLock, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return processIsAlive(pid)
    }
}

// MARK: - helper binaries

/// Finds the CLI, the recorder and the title helper. They sit side by side:
/// `bin/` in a dev build, `Stringer.app/Contents/Helpers/` when packaged.
/// `STRINGER_BIN` and `STRINGER_RECORDER` override.
public enum Binaries {
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    public static var helpersDir: URL {
        let exe = executableURL()
        // Inside an app bundle: Contents/MacOS/<exe> → Contents/Helpers.
        let contents = exe.deletingLastPathComponent().deletingLastPathComponent()
        if exe.deletingLastPathComponent().lastPathComponent == "MacOS", contents.lastPathComponent == "Contents" {
            let helpers = contents.appending("Helpers")
            if helpers.appending("stringer").exists { return helpers }
        }
        return exe.deletingLastPathComponent()
    }

    public static var cli: URL {
        if let p = env["STRINGER_BIN"] { return URL(fileURLWithPath: Paths.expand(p)) }
        return helpersDir.appending("stringer")
    }

    public static var recorder: URL {
        if let p = env["STRINGER_RECORDER"] { return URL(fileURLWithPath: Paths.expand(p)) }
        return cli.deletingLastPathComponent().appending("Stringer Recorder.app")
    }

    public static var title: URL {
        if let p = env["STRINGER_TITLE"] { return URL(fileURLWithPath: Paths.expand(p)) }
        return cli.deletingLastPathComponent().appending("stringer-title")
    }
}

/// Starts a process in its own session, detached from the terminal or app
/// that started it, with output appended to `log`.
public func spawnDetached(_ exe: URL, _ args: [String], log: URL?, env extra: [String: String] = [:]) throws -> pid_t {
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    let out = log?.path ?? "/dev/null"
    posix_spawn_file_actions_addopen(&actions, 1, out, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)

    var environment = ProcessInfo.processInfo.environment
    for (k, v) in extra { environment[k] = v }
    let argv = ([exe.path] + args).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
    }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, exe.path, &actions, &attr, argv, envp)
    guard rc == 0 else { throw StoreError("could not start \(exe.lastPathComponent): \(String(cString: strerror(rc)))") }
    return pid
}
