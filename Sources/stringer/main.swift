import Darwin
import Foundation
import StringerCore
import StringerKit
import StringerPipeline

let usage = """
stringer \(stringerVersion) — record a meeting's mic and system audio, transcribe on-device

usage:
  stringer rec [--title T]          record in this terminal; Ctrl-C stops and transcribes
  stringer start [--title T]        record in the background
  stringer stop [MEETING]           stop the current recording and wait for the transcript
  stringer status [--json]          what is recording or transcribing
  stringer tail [MEETING]           follow the live transcript
  stringer ls [--json]              list meetings
  stringer note [MEETING]           re-transcribe a meeting from its audio (recovers interrupted ones)
  stringer rename [MEETING] TITLE   rename a meeting (the current or latest one by default)
  stringer config                   show settings and where each comes from
  stringer config set KEY VALUE     change a setting in ~/.config/stringer/config.toml
  stringer setup                    download the speech models once (then fully offline)
  stringer doctor [--json]          check binaries, signing, permissions, models, Apple Intelligence

settings flags (any command): --home DIR --vault DIR --mic default|all|none --asr parakeet|apple
  --speakers N --cluster-threshold X --chunk SECONDS --vocab FILE
  --[no-]diarize --[no-]live --[no-]debug --[no-]ai-title
MEETING is an id, id prefix, folder name or path.
"""

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var settingFlags: [String: String] = [:]
    var flags: Set<String> = []

    static let valued: Set<String> = ["title", "source"]

    init(_ raw: [String]) throws {
        var i = 0
        let boolKeys: Set<String> = ["diarize", "live", "debug", "ai_title", "detect"]
        while i < raw.count {
            let a = raw[i]
            i += 1
            guard a.hasPrefix("--"), a.count > 2 else {
                positional.append(a)
                continue
            }
            var name = String(a.dropFirst(2))
            var inline: String?
            if let eq = name.firstIndex(of: "=") {
                inline = String(name[name.index(after: eq)...])
                name = String(name[..<eq])
            }
            let key = name.replacingOccurrences(of: "-", with: "_")
            if Self.valued.contains(key) {
                guard let v = inline ?? (i < raw.count ? raw[i] : nil) else { throw Fail("--\(name) needs a value") }
                if inline == nil { i += 1 }
                options[key] = v
            } else if key.hasPrefix("no_"), boolKeys.contains(String(key.dropFirst(3))) {
                settingFlags[String(key.dropFirst(3))] = "false"
            } else if boolKeys.contains(key) {
                settingFlags[key] = inline ?? "true"
            } else if Settings.keys.contains(key) {
                guard let v = inline ?? (i < raw.count ? raw[i] : nil) else { throw Fail("--\(name) needs a value") }
                if inline == nil { i += 1 }
                settingFlags[key] = v
            } else {
                flags.insert(key)
            }
        }
    }
}

struct Fail: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

func out(_ s: String) { print(s) }
func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func printJSON<T: Encodable>(_ v: T) throws {
    FileHandle.standardOutput.write(try JSON.encode(v))
}

// MARK: - commands

func settings(_ a: Args) throws -> Settings {
    let r = try Settings.resolve(flags: a.settingFlags)
    for p in r.problems { err("warning: \(p)") }
    return r.settings
}

func meeting(_ store: MeetingStore, _ ref: String?, fallback: () -> Meeting?) throws -> Meeting {
    if let ref {
        guard let m = store.resolve(ref) else { throw Fail("no meeting matches '\(ref)' in \(store.home.path)") }
        return m
    }
    guard let m = fallback() else { throw Fail("no meetings in \(store.home.path)") }
    return m
}

func refuseIfCapturing(_ store: MeetingStore) async throws {
    // A recording that has been asked to stop frees the slot within a second
    // or two (the recorder finalises its files); wait rather than refuse.
    let deadline = Date().addingTimeInterval(8)
    while let busy = store.capturing() {
        let stopping = busy.state == .stopping || busy.file(MeetingFile.stop).exists
            || busy.file(MeetingFile.captureJSON).exists || !busy.recorderAlive && busy.state == .recording
        if !stopping || Date() > deadline {
            throw Fail("already recording '\(busy.title)' (\(busy.id.prefix(8))) — stop it first with `stringer stop`")
        }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
}

func cmdRec(_ a: Args) async throws -> Int32 {
    let s = try settings(a)
    let store = MeetingStore(settings: s)
    try await refuseIfCapturing(store)
    let m = try store.create(title: a.options["title"], source: a.options["source"], settings: s)
    err("recording '\(m.title)' → \(m.dir.path)\nCtrl-C to stop and transcribe")
    return await Owner(meeting: m, store: store, printLive: true).run()
}

func cmdStart(_ a: Args) async throws -> Int32 {
    let s = try settings(a)
    let store = MeetingStore(settings: s)
    try await refuseIfCapturing(store)
    let m = try store.create(title: a.options["title"], source: a.options["source"], settings: s)
    let pid = try spawnDetached(Binaries.cli, ["_run", m.id], log: m.file(MeetingFile.workerLog))
    // Wait until it is recording (or has failed).
    let deadline = Date().addingTimeInterval(25)
    var cur = m
    while Date() < deadline {
        cur = store.find(id: m.id) ?? cur
        if cur.state == .recording || cur.state.isTerminal { break }
        if !processIsAlive(pid), cur.owner?.pid == 0 { break }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    if a.flags.contains("json") {
        try printJSON(MeetingSummary(cur))
    } else if cur.state == .recording {
        out("recording '\(cur.title)' (\(cur.id.prefix(8))) → \(cur.dir.path)")
    } else {
        err("recording did not start (\(cur.state.rawValue))\(cur.owner?.error.map { ": \($0)" } ?? "") — see \(cur.file(MeetingFile.workerLog).path)")
        return 1
    }
    return cur.state.isTerminal ? 1 : 0
}

/// Waits for a terminal state, following the meeting by ID through renames.
func waitTerminal(_ store: MeetingStore, id: String, quiet: Bool) async -> Meeting? {
    var last: MeetingState?
    while true {
        guard let m = store.find(id: id) else { return nil }
        let s = m.state
        if s != last, !quiet, !s.isTerminal { err("\(s.rawValue)…") }
        last = s
        if s.isTerminal { return m }
        if !m.ownerAlive, m.owner?.pid ?? 0 != 0 { return m }  // owner died while we waited
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
}

/// A non-blocking lock so two `stop`s never both take over a dead owner.
func takeoverLock(_ id: String) -> Int32? {
    let dir = Paths.support.appending("locks")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fd = open(dir.appending("\(id).takeover").path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return nil }
    return fd
}

func cmdStop(_ a: Args) async throws -> Int32 {
    let s = try settings(a)
    let store = MeetingStore(settings: s)
    let m: Meeting
    if let ref = a.positional.first {
        guard let r = store.resolve(ref) else { throw Fail("no meeting matches '\(ref)'") }
        m = r
    } else {
        guard let r = store.capturing() ?? store.active().last else {
            err("nothing is recording")
            return 1
        }
        m = r
    }
    if m.state.isTerminal {
        out("'\(m.title)' already \(m.state.rawValue)")
        return 0
    }
    touch(m.file(MeetingFile.stop))
    let json = a.flags.contains("json")
    if a.flags.contains("no_wait") {
        if json { try printJSON(MeetingSummary(m)) } else { out("stopping '\(m.title)'") }
        return 0
    }
    while true {
        guard let cur = store.find(id: m.id) else { throw Fail("meeting \(m.id) disappeared") }
        if cur.state.isTerminal {
            return report(cur, json: json)
        }
        if cur.ownerAlive || (cur.owner?.pid ?? 0) == 0 && cur.state == .starting {
            if let done = await waitTerminal(store, id: m.id, quiet: json), done.state.isTerminal {
                return report(done, json: json)
            }
            continue  // the owner died while we waited: take over below
        }
        // The owner is gone. Take over, unless another `stop` already is.
        guard let fd = takeoverLock(m.id) else {
            if let done = await waitTerminal(store, id: m.id, quiet: json) { return report(done, json: json) }
            continue
        }
        defer { close(fd) }
        guard let fresh = store.find(id: m.id), !fresh.ownerAlive, !fresh.state.isTerminal else { continue }
        if !json { err("the recording's owner process is gone — finishing it here") }
        let code = await Owner(meeting: fresh, store: store).takeOver()
        if let done = store.find(id: m.id) { _ = report(done, json: json) }
        return code
    }
}

@discardableResult
func report(_ m: Meeting, json: Bool) -> Int32 {
    if json {
        try? printJSON(MeetingSummary(m))
    } else if m.state == .done {
        out("'\(m.title)' done\n\(m.file(MeetingFile.transcript).path)")
    } else {
        out("'\(m.title)' \(m.state.rawValue)\((m.owner?.error ?? m.info.error).map { ": \($0)" } ?? "")")
    }
    return m.state == .done ? 0 : 1
}

func cmdStatus(_ a: Args) throws -> Int32 {
    let s = try settings(a)
    let snap = Snapshot.take(settings: s)
    if a.flags.contains("json") {
        try printJSON(snap)
        return 0
    }
    if snap.active.isEmpty { out("idle") }
    for m in snap.active {
        var line = "\(m.state.rawValue)  \(m.title)  \(m.state == .recording ? Clock.stamp(m.elapsed) : "")"
        if m.state == .recording {
            line += String(format: "  mic %.0f dBFS  system %.0f dBFS", Signal.dbfs(max(m.levels.mic, 1e-6)), Signal.dbfs(max(m.levels.system, 1e-6)))
        }
        out(line)
        out("  \(m.dir)")
    }
    if let l = snap.last { out("last: \(l.title) (\(l.state.rawValue))\(l.transcript.map { "\n  \($0)" } ?? "")") }
    if !snap.models.ready { out("models: missing — run `stringer setup`\(snap.models.downloading ? " (downloading)" : "")") }
    return 0
}

func cmdTail(_ a: Args) async throws -> Int32 {
    let store = MeetingStore(settings: try settings(a))
    let m = try meeting(store, a.positional.first) { store.capturing() ?? store.active().last ?? store.latest() }
    var printed = 0
    while true {
        guard let cur = store.find(id: m.id) else { return 1 }
        if let text = try? String(contentsOf: cur.file(MeetingFile.live), encoding: .utf8), text.utf8.count > printed {
            let data = Data(text.utf8)
            FileHandle.standardOutput.write(data.subdata(in: printed..<data.count))
            printed = data.count
        }
        if cur.state.isTerminal || cur.state == .transcribing && !cur.ownerAlive { break }
        if cur.state == .transcribing {
            // The live transcript is complete once transcription starts.
            try await Task.sleep(nanoseconds: 1_500_000_000)
            if let t = try? String(contentsOf: cur.file(MeetingFile.live), encoding: .utf8), t.utf8.count == printed { break }
            continue
        }
        try await Task.sleep(nanoseconds: 500_000_000)
    }
    return 0
}

struct ListRow: Codable {
    var id: String
    var title: String
    var date: String
    var duration: Double
    var state: MeetingState
    var speakers: [String]
    var dir: String
}

func cmdLs(_ a: Args) throws -> Int32 {
    let store = MeetingStore(settings: try settings(a))
    let rows: [ListRow] = store.all().map { m in
        let doc = TranscriptDoc.read(m.file(MeetingFile.transcript))
        return ListRow(id: m.id, title: m.title, date: m.info.startedAt ?? m.info.created,
                       duration: m.info.duration ?? doc?.duration ?? m.elapsed, state: m.state,
                       speakers: m.info.speakers ?? doc?.speakers ?? [], dir: m.dir.path)
    }
    if a.flags.contains("json") {
        try printJSON(rows)
        return 0
    }
    if rows.isEmpty { out("no meetings in \(store.home.path)") }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    for r in rows {
        let date = Clock.parse(r.date).map(f.string(from:)) ?? r.date
        let state = r.state == .done ? "" : "  [\(r.state.rawValue)]"
        out("\(date)  \(Clock.stamp(r.duration).padding(toLength: 8, withPad: " ", startingAt: 0))  \(r.id.prefix(8))  \(r.title)\(state)")
    }
    return 0
}

func cmdNote(_ a: Args) async throws -> Int32 {
    let store = MeetingStore(settings: try settings(a))
    let m = try meeting(store, a.positional.first) { store.all().last { $0.state == .interrupted } ?? store.latest() }
    guard !m.ownerAlive || m.state.isTerminal else { throw Fail("'\(m.title)' is still being handled by pid \(m.owner!.pid)") }
    guard !m.state.isCapturing || !m.recorderAlive else { throw Fail("'\(m.title)' is still recording — use `stringer stop`") }
    // New flags apply on top of the meeting's snapshot.
    if !a.settingFlags.isEmpty {
        let fallback = try settings(a)
        var snap = JSON.read(Settings.self, from: m.file(MeetingFile.settings)) ?? fallback
        for (k, v) in a.settingFlags { try snap.set(k, v) }
        try AtomicFile.writeJSON(snap, to: m.file(MeetingFile.settings))
    } else if !m.file(MeetingFile.settings).exists {
        try AtomicFile.writeJSON(try settings(a), to: m.file(MeetingFile.settings))
    }
    // A finished meeting gets a fresh outcome.
    _ = try store.update(m) { $0.outcome = nil; $0.error = nil }
    err("transcribing '\(m.title)'…")
    let code = await Owner(meeting: store.find(id: m.id) ?? m, store: store, echoLog: !a.flags.contains("quiet")).recover()
    if let done = store.find(id: m.id) { report(done, json: a.flags.contains("json")) }
    return code
}

func cmdRename(_ a: Args) throws -> Int32 {
    let s = try settings(a)
    let store = MeetingStore(settings: s)
    var pos = a.positional
    guard !pos.isEmpty else { throw Fail("usage: stringer rename [MEETING] TITLE") }
    let title = pos.removeLast()
    let m = try meeting(store, pos.first) { store.capturing() ?? store.active().last ?? store.latest() }
    let r = try Lifecycle.rename(m, to: title, store: store, vault: s.vaultURL)
    if a.flags.contains("json") { try printJSON(MeetingSummary(r)) } else {
        out(r.state.isTerminal ? "renamed → \(r.dir.path)" : "renamed '\(r.title)' (the folder follows when it finishes)")
    }
    return 0
}

func cmdConfig(_ a: Args) throws -> Int32 {
    let pos = a.positional
    if pos.first == "set" {
        guard pos.count >= 3 else { throw Fail("usage: stringer config set KEY VALUE") }
        let key = pos[1].replacingOccurrences(of: "-", with: "_")
        let value = pos[2...].joined(separator: " ")
        var probe = Settings()
        try probe.set(key, value)  // validate
        try ConfigFile.set(key, key == "mic" ? probe.mic : value, in: Paths.configURL)
        out("\(key) = \(probe.value(key))")
        return 0
    }
    let r = try Settings.resolve(flags: a.settingFlags)
    if pos.first == "get", pos.count >= 2 {
        out(r.settings.value(pos[1].replacingOccurrences(of: "-", with: "_")))
        return 0
    }
    if a.flags.contains("json") {
        try printJSON(r.settings)
        return 0
    }
    out("# \(Paths.configURL.path)")
    for k in Settings.keys {
        out("\(k.padding(toLength: 18, withPad: " ", startingAt: 0)) \(r.settings.value(k).isEmpty ? "(none)" : r.settings.value(k))  [\(r.origins[k]!.rawValue)]")
    }
    for p in r.problems { out("warning: \(p)") }
    return 0
}

func cmdSetup(_ a: Args) async throws -> Int32 {
    let machine = a.flags.contains("progress")
    final class Last: @unchecked Sendable { var pct = -1 }
    let last = Last()
    do {
        try await Models.setup(force: a.flags.contains("force")) { frac, label in
            let pct = Int(frac * 100)
            if machine {
                print("progress \(String(format: "%.3f", frac)) \(label)")
                fflush(stdout)
            } else if pct != last.pct {
                last.pct = pct
                FileHandle.standardError.write(Data("\r\(String(format: "%3d", pct))%  \(label)\u{1B}[K".utf8))
            }
        }
    } catch {
        if !machine { err("") }
        throw error
    }
    if !machine { err("\nmodels ready — transcription now works offline") }
    return 0
}

// MARK: - main

setvbuf(stdout, nil, _IOLBF, 0)
var argv = Array(CommandLine.arguments.dropFirst())
let command = argv.isEmpty ? "help" : argv.removeFirst()

let code: Int32
do {
    let a = try Args(argv)
    switch command {
    case "rec": code = try await cmdRec(a)
    case "start": code = try await cmdStart(a)
    case "stop": code = try await cmdStop(a)
    case "status": code = try cmdStatus(a)
    case "tail": code = try await cmdTail(a)
    case "ls", "list": code = try cmdLs(a)
    case "note": code = try await cmdNote(a)
    case "rename": code = try cmdRename(a)
    case "config": code = try cmdConfig(a)
    case "setup": code = try await cmdSetup(a)
    case "doctor": code = await Doctor.run(json: a.flags.contains("json"))
    case "devices":
        // Diagnostic: audio devices, the tap's clock, and which apps use a mic.
        let clock = CA.clockDevice()
        for d in CA.devices() {
            var tags: [String] = []
            if d.inputChannels > 0 { tags.append("in \(d.inputChannels)") }
            if d.outputChannels > 0 { tags.append("out \(d.outputChannels)") }
            if d.isVirtual { tags.append("virtual — never used") }
            if d.id == CA.defaultInput() { tags.append("default input") }
            if d.id == clock?.id { tags.append("tap clock") }
            out("\(d)  \(tags.joined(separator: ", "))")
        }
        out("apps using a microphone now:")
        for p in CA.audioProcesses() where p.isRunningInput { out("  \(p.bundleID.isEmpty ? "pid \(p.pid)" : p.bundleID)") }
        code = 0
    case "transcribe":
        // Diagnostic: one file through the recogniser, plain text out.
        guard let f = a.positional.first else { throw Fail("usage: stringer transcribe FILE.wav") }
        Models.forbidDownloads()
        let s = try settings(a)
        let r: Recognizer = s.asr == "apple" ? try await AppleSpeech.load() : try await ParakeetRecognizer.load(vocabulary: s.vocabURL) { err($0) }
        let url = URL(fileURLWithPath: Paths.expand(f))
        let tokens = try await r.tokens(file: url)
        var words = Transcript.words(tokens)
        if s.vocabURL != nil { words = await FinalPass.rescore(words, tokens: tokens, url: url, recognizer: r) }
        for sentence in Transcript.sentences(words) { out("[\(Clock.stamp(sentence[0].start))] \(Text.join(sentence.map(\.text)))") }
        code = 0
    case "_run":
        let store = MeetingStore(settings: try settings(a))
        guard let id = a.positional.first, let m = store.find(id: id) else { throw Fail("_run: no meeting \(a.positional.first ?? "")") }
        code = await Owner(meeting: m, store: store).run()
    case "version", "--version", "-v": out("stringer \(stringerVersion)"); code = 0
    case "help", "--help", "-h": out(usage); code = 0
    default:
        err("unknown command '\(command)'\n")
        err(usage)
        code = 2
    }
} catch {
    err("stringer: \(error)")
    code = 1
}
exit(code)
