import Foundation
import StringerCore
import StringerKit

/// The final transcript, made from the complete files after recording stops.
public struct FinalPass {
    public struct Output: Codable {
        public var segments: [Segment]
        public var speakers: [String]
        public var diarized: Bool
        public var words: Int
        public var notes: [String]
    }

    let dir: URL
    let settings: Settings
    let recognizer: Recognizer
    let log: (String) -> Void

    public init(dir: URL, settings: Settings, recognizer: Recognizer, log: @escaping (String) -> Void) {
        self.dir = dir
        self.settings = settings
        self.recognizer = recognizer
        self.log = log
    }

    /// A track worth transcribing: at least 0.5 s and not silence.
    static func usable(_ url: URL) -> Bool {
        guard let info = WavReader.info(url), info.sampleCount >= 8_000 else { return false }
        // Scan in 30 s blocks so a 4-hour file is never held in memory.
        var at = 0
        while at < info.sampleCount {
            if WavReader.peak(url, from: at, count: 480_000) >= Signal.silencePeak { return true }
            at += 480_000
        }
        return false
    }

    public func run() async throws -> Output {
        var notes: [String] = []
        var words: [Track: [Word]] = [:]
        var files: [Track: URL] = [:]
        for track in [Track.mic, .system] {
            let url = dir.appending(track == .mic ? MeetingFile.mic : MeetingFile.system)
            guard url.exists, Self.usable(url) else { continue }
            let t0 = Date()
            let tokens = try await recognizer.tokens(file: url)
            var w = Transcript.words(tokens)
            if settings.vocabURL != nil { w = await Self.rescore(w, tokens: tokens, url: url, recognizer: recognizer) }
            log(String(format: "final: %@ recognised %d words in %.1fs", track.rawValue, w.count, Date().timeIntervalSince(t0)))
            words[track] = w
            files[track] = url
        }

        var diarized = false
        if settings.diarize, !words.isEmpty {
            do {
                let models = try await Models.loadDiarizer()
                let d = Diarizer(models: models, speakers: settings.speakers, threshold: settings.clusterThreshold)
                var labelled: [Track: [Word]] = [:]
                for (track, w) in words where !w.isEmpty {
                    let t0 = Date()
                    let r = try await d.run(files[track]!)
                    var l = Transcript.label(w, turns: r.turns)
                    if settings.speakers == 0 { l = Transcript.prune(l, embeddings: r.embeddings) }
                    labelled[track] = l
                    log(String(format: "final: %@ diarized into %d speakers in %.1fs", track.rawValue,
                               Set(l.compactMap(\.speaker)).count, Date().timeIntervalSince(t0)))
                }
                for (k, v) in labelled { words[k] = v }
                diarized = true
            } catch {
                notes.append("diarization failed: \(error) — labelled Me/Them")
                log("final: diarization failed: \(error) — falling back to Me/Them")
            }
        }

        let segs = Transcript.assemble(mic: words[.mic], system: words[.system], diarized: diarized)
        return Output(segments: segs, speakers: Transcript.speakers(segs), diarized: diarized,
                      words: segs.reduce(0) { $0 + $1.words.count }, notes: notes)
    }

    /// Vocabulary rescoring per sentence, with that sentence's audio.
    public static func rescore(_ words: [Word], tokens: [Token], url: URL, recognizer: Recognizer) async -> [Word] {
        var out: [Word] = []
        for s in Transcript.sentences(words) {
            guard let a = s.first?.start, let b = s.last?.end else { continue }
            let from = max(0, Int((a - 0.2) * 16_000))
            let audio = WavReader.read(url, from: from, count: Int((b - a + 0.4) * 16_000))
            let toks = tokens.filter { $0.start >= a - 0.01 && $0.end <= b + 0.01 }
            out += await recognizer.rescore(s, tokens: toks, audio: audio, offset: Double(from) / 16_000)
        }
        return out
    }
}

/// Meeting titles from Apple Intelligence, on-device, via `stringer-title`.
public enum Titler {
    public static let banned = ["meeting", "discussion", "overview", "sync", "call", "update", "session"]

    /// About 8000 characters: four slices spread across the whole meeting, so
    /// the title isn't named after the opening small talk.
    public static func excerpt(_ segments: [Segment], limit: Int = 8000, slices: Int = 4) -> String {
        let lines = segments.map { "\($0.speaker): \($0.text)" }
        let total = lines.reduce(0) { $0 + $1.count + 1 }
        if total <= limit { return lines.joined(separator: "\n") }
        let per = limit / slices
        var parts: [String] = []
        for k in 0..<slices {
            var i = lines.count * k / slices
            var chunk: [String] = []
            var size = 0
            while i < lines.count, size < per {
                let l = String(lines[i].prefix(per - size))
                chunk.append(l)
                size += l.count + 1
                i += 1
            }
            parts.append(chunk.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n…\n")
    }

    /// A usable title, or nil to keep the automatic name.
    public static func validate(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’*#.:"))
        if let first = t.split(separator: "\n").first { t = String(first) }
        let words = t.split(separator: " ")
        guard (2...6).contains(words.count) else { return nil }
        if t.range(of: #"\b(Mic|Speaker) \d+\b"#, options: .regularExpression) != nil { return nil }
        return t
    }

    /// Runs the helper. Returns nil when there is too little speech, Apple
    /// Intelligence is unavailable, or the reply is unusable.
    public static func propose(_ segments: [Segment], helper: URL, log: (String) -> Void) -> String? {
        let words = segments.reduce(0) { $0 + Text.wordCount($1.text) }
        guard words >= 50 else {
            log("title: only \(words) words — keeping the automatic name")
            return nil
        }
        guard helper.exists else {
            log("title: helper not found at \(helper.path)")
            return nil
        }
        let p = Process()
        p.executableURL = helper
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        do { try p.run() } catch {
            log("title: \(error)")
            return nil
        }
        stdin.fileHandleForWriting.write(Data(excerpt(segments).utf8))
        try? stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(90)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning {
            p.terminate()
            log("title: helper timed out")
            return nil
        }
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            log("title: keeping the automatic name (\(err.trimmingCharacters(in: .whitespacesAndNewlines)))")
            return nil
        }
        guard let t = validate(out) else {
            log("title: rejected '\(out.trimmingCharacters(in: .whitespacesAndNewlines))'")
            return nil
        }
        return t
    }
}
