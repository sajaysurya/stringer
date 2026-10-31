import Darwin
import Foundation
import StringerCore

public enum MeetingState: String, Codable, Sendable {
    case starting, recording, stopping, transcribing, done, failed, interrupted

    public var isTerminal: Bool { self == .done || self == .failed || self == .interrupted }
    /// Holding the single recording slot.
    public var isCapturing: Bool { self == .starting || self == .recording || self == .stopping }
}

/// `meeting.json`: the stable identity. Never deleted by cleanup.
public struct MeetingInfo: Codable, Sendable, Equatable {
    public var id: String
    public var created: String
    public var startedAt: String?
    public var title: String
    public var autoTitle: Bool
    /// The meeting app detected on the mic, when started from the card.
    public var source: String?
    public var endedAt: String?
    public var duration: Double?
    public var speakers: [String]?
    /// `done` or `failed` once the owner has finished.
    public var outcome: String?
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case id, created, title, source, duration, speakers, outcome, error
        case startedAt = "started_at", autoTitle = "auto_title", endedAt = "ended_at"
    }

    public init(id: String, created: String, title: String, autoTitle: Bool, source: String?) {
        self.id = id
        self.created = created
        self.title = title
        self.autoTitle = autoTitle
        self.source = source
    }
}

/// `state.json`: the owner's live status, written only by the owner.
public struct OwnerState: Codable, Sendable, Equatable {
    public struct Levels: Codable, Sendable, Equatable {
        public var mic: Float
        public var system: Float
        public init(mic: Float = 0, system: Float = 0) {
            self.mic = mic
            self.system = system
        }
    }

    public var state: MeetingState
    public var pid: Int32
    public var recorderPid: Int32?
    public var elapsed: Double
    public var levels: Levels
    public var error: String?
    public var updated: String

    enum CodingKeys: String, CodingKey {
        case state, pid, elapsed, levels, error, updated
        case recorderPid = "recorder_pid"
    }

    public init(state: MeetingState, pid: Int32, recorderPid: Int32? = nil, elapsed: Double = 0,
                levels: Levels = .init(), error: String? = nil)
    {
        self.state = state
        self.pid = pid
        self.recorderPid = recorderPid
        self.elapsed = elapsed
        self.levels = levels
        self.error = error
        updated = Clock.iso()
    }
}

/// A meeting folder, read fresh from disk.
public struct Meeting: Sendable {
    public var dir: URL
    public var info: MeetingInfo
    public var owner: OwnerState?

    public var id: String { info.id }
    public var title: String { info.title }
    public func file(_ name: String) -> URL { dir.appending(name) }

    public init?(dir: URL) {
        guard let info = JSON.read(MeetingInfo.self, from: dir.appending(MeetingFile.meeting)) else { return nil }
        self.dir = dir
        self.info = info
        owner = JSON.read(OwnerState.self, from: dir.appending(MeetingFile.state))
    }

    public var ownerAlive: Bool { owner.map { processIsAlive($0.pid) } ?? false }
    public var recorderAlive: Bool { owner?.recorderPid.map(processIsAlive) ?? false }

    /// The state, corrected for a dead owner: with no recorder left it is
    /// `interrupted`; with the recorder still running it stays capturing
    /// (and `stop` will take over).
    public var state: MeetingState {
        if let owner {
            if owner.state.isTerminal || ownerAlive { return owner.state }
            if owner.state == .starting && owner.pid == 0 {
                // Created, owner not spawned yet: give it a moment.
                let age = Clock.parse(owner.updated).map { Date().timeIntervalSince($0) } ?? 999
                return age < 15 ? .starting : .interrupted
            }
            return recorderAlive ? owner.state : .interrupted
        }
        if let o = info.outcome, let s = MeetingState(rawValue: o) { return s }
        if file(MeetingFile.transcript).exists { return .done }
        return .interrupted
    }

    public var startedAt: Date? { Clock.parse(info.startedAt) }
    public var created: Date { Clock.parse(info.created) ?? Date.distantPast }

    /// Seconds since `started_at`, or the final duration once finished.
    public var elapsed: Double {
        if let d = info.duration, state.isTerminal { return d }
        guard let s = startedAt else { return 0 }
        return max(0, Date().timeIntervalSince(s))
    }
}

/// Folders, IDs and lookups. Meetings are always found by ID: folders get
/// renamed (by Apple Intelligence and by people), and two meetings can start
/// in the same minute.
public struct MeetingStore: Sendable {
    public var home: URL

    public init(home: URL) { self.home = home }
    public init(settings: Settings = .current()) { home = settings.homeURL }

    /// Every meeting in the current home and in earlier homes, so a meeting
    /// still finishing (or kept) where it started is found by ID after the
    /// home setting changes.
    public func all() -> [Meeting] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [Meeting] = []
        for dir in [home] + Self.earlierHomes().filter({ $0.standardizedFileURL.path != home.standardizedFileURL.path }) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for m in names.filter({ !$0.hasPrefix(".") }).compactMap({ Meeting(dir: dir.appending($0)) }) where seen.insert(m.id).inserted {
                out.append(m)
            }
        }
        return out.sorted { $0.created < $1.created }
    }

    /// Homes meetings were created in (`homes.json` in the support folder).
    static var homesFile: URL { Paths.support.appending("homes.json") }

    static func earlierHomes() -> [URL] {
        (JSON.read([String].self, from: homesFile) ?? []).map { URL(fileURLWithPath: $0) }
    }

    static func remember(_ home: URL) {
        var homes = JSON.read([String].self, from: homesFile) ?? []
        let p = home.standardizedFileURL.path
        guard !homes.contains(p) else { return }
        homes.append(p)
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        try? AtomicFile.writeJSON(homes, to: homesFile)
    }

    public func find(id: String) -> Meeting? {
        all().first { $0.id == id }
    }

    /// Accepts an ID, an ID prefix (≥ 6), a folder path or a folder name.
    public func resolve(_ ref: String) -> Meeting? {
        let path = Paths.expand(ref)
        if path.hasPrefix("/"), let m = Meeting(dir: URL(fileURLWithPath: path)) { return m }
        let meetings = all()
        if let m = meetings.first(where: { $0.id == ref || $0.dir.lastPathComponent == ref }) { return m }
        if ref.count >= 6 {
            let hits = meetings.filter { $0.id.hasPrefix(ref.lowercased()) }
            if hits.count == 1 { return hits[0] }
        }
        return nil
    }

    public func latest() -> Meeting? { all().last }

    /// The meeting holding the recording slot, if any.
    public func capturing() -> Meeting? { all().last { $0.state.isCapturing } }

    public func active() -> [Meeting] { all().filter { !$0.state.isTerminal } }

    // MARK: creating and naming

    public static func folderName(title: String, created: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        return "\(f.string(from: created)) - \(safe(title))"
    }

    /// A folder-safe title: no slashes or colons, no leading dots.
    public static func safe(_ title: String) -> String {
        var t = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        while t.hasPrefix(".") { t.removeFirst() }
        if t.isEmpty { t = "Meeting" }
        return String(t.prefix(120))
    }

    /// `name`, or `name (2)`, `name (3)`… in `parent` — the first one not
    /// taken (ignoring `except`).
    static func unique(_ name: String, in parent: URL, except: URL? = nil) -> URL {
        var candidate = parent.appending(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path), candidate.standardizedFileURL.path != except?.standardizedFileURL.path {
            candidate = parent.appending("\(name) (\(n))")
            n += 1
        }
        return candidate
    }

    public func create(title: String?, source: String?, settings: Settings) throws -> Meeting {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let now = Date()
        let typed = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let name = typed ?? source.map { "\($0) meeting" } ?? "Meeting"
        let id = UUID().uuidString.lowercased()
        let dir = Self.unique(Self.folderName(title: name, created: now), in: home)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let info = MeetingInfo(id: id, created: Clock.iso(now), title: name, autoTitle: typed == nil, source: source)
        try AtomicFile.writeJSON(info, to: dir.appending(MeetingFile.meeting))
        try AtomicFile.writeJSON(settings, to: dir.appending(MeetingFile.settings))
        try AtomicFile.writeJSON(OwnerState(state: .starting, pid: 0), to: dir.appending(MeetingFile.state))
        guard let m = Meeting(dir: dir) else { throw StoreError("could not read back \(dir.path)") }
        Self.remember(home)
        return m
    }

    /// Renames the folder to match the meeting's title, where it is: a
    /// meeting never moves to another home (S-3). Returns the new location.
    @discardableResult
    public func syncFolder(_ m: Meeting) throws -> Meeting {
        let want = Self.folderName(title: m.title, created: m.created)
        let current = m.dir.lastPathComponent
        if current == want || current.hasPrefix(want + " (") { return m }
        let target = Self.unique(want, in: m.dir.deletingLastPathComponent(), except: m.dir)
        try FileManager.default.moveItem(at: m.dir, to: target)
        return Meeting(dir: target) ?? m
    }

    public func update(_ m: Meeting, _ change: (inout MeetingInfo) -> Void) throws -> Meeting {
        var info = JSON.read(MeetingInfo.self, from: m.file(MeetingFile.meeting)) ?? m.info
        change(&info)
        try AtomicFile.writeJSON(info, to: m.file(MeetingFile.meeting))
        var out = m
        out.info = info
        return out
    }
}

public struct StoreError: Error, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// A per-meeting lock, keyed by ID so it survives folder renames. Serialises
/// title changes between `rename` and the owner.
public final class MeetingLock {
    private let fd: Int32

    public init(id: String) throws {
        let dir = Paths.support.appending("locks")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fd = open(dir.appending("\(id).lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw StoreError("cannot open lock for \(id)") }
        flock(fd, LOCK_EX)
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }

    public static func with<T>(_ id: String, _ body: () throws -> T) throws -> T {
        let lock = try MeetingLock(id: id)
        defer { withExtendedLifetime(lock) {} }
        return try body()
    }
}
