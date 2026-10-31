import Foundation
import StringerCore

public enum Track: String, Codable, Sendable {
    case mic, system

    /// The label when there is no diarization (always, in the live transcript).
    public var plainLabel: String { self == .mic ? "Me" : "Them" }
    /// The diarized label prefix. Separate namespaces: `Mic 1` and
    /// `Speaker 1` are different people.
    public var prefix: String { self == .mic ? "Mic" : "Speaker" }
}

/// A recogniser token with absolute times. SentencePiece marks a word start
/// with `▁` (FluidAudio passes it through as a leading space).
public struct Token: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }

    public var isWordStart: Bool { text.hasPrefix("▁") || text.hasPrefix(" ") }
    public var clean: String { text.replacingOccurrences(of: "▁", with: " ") }
    public func shifted(_ dt: Double) -> Token { Token(text: text, start: start + dt, end: end + dt) }
}

/// A word: one or more tokens, starting at a word start.
public struct Word: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var speaker: String?

    public init(text: String, start: Double, end: Double, speaker: String? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// A line of transcript: one speaker, contiguous words.
public struct Segment: Codable, Sendable, Equatable {
    public var track: Track
    public var speaker: String
    public var words: [Word]

    public init(track: Track, speaker: String, words: [Word]) {
        self.track = track
        self.speaker = speaker
        self.words = words
    }

    public var start: Double { words.first?.start ?? 0 }
    public var end: Double { words.last?.end ?? 0 }
    public var text: String { Text.join(words.map(\.text)) }
}

public enum Text {
    /// Joins word texts; punctuation-only pieces attach to the previous word.
    public static func join(_ words: [String]) -> String {
        words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Lowercased words without punctuation, for comparisons.
    public static func normalized(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    public static func wordCount(_ s: String) -> Int { normalized(s).count }
}

public enum Transcript {
    // MARK: tokens → words → sentences

    /// Groups tokens into words. A word begins only at a word-start token,
    /// so trailing punctuation stays on its word ("Agreed." never becomes
    /// "Ag" / "reed.").
    public static func words(_ tokens: [Token]) -> [Word] {
        var out: [Word] = []
        for t in tokens {
            let piece = t.clean
            if piece.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let p = piece.trimmingCharacters(in: .whitespaces)
            let punctuation = p.allSatisfy { $0.isPunctuation }
            if (t.isWordStart && !punctuation) || out.isEmpty {
                out.append(Word(text: p, start: t.start, end: punctuation ? t.start + 0.1 : t.end))
            } else if punctuation {
                // Punctuation tokens' durations stretch across the following
                // silence, and the recogniser sometimes repeats them: keep
                // one mark and don't let it extend the word.
                var w = out[out.count - 1]
                if w.text.last.map({ !$0.isPunctuation || String($0) != p }) ?? true { w.text += p }
                w.end = max(w.end, min(t.end, w.end + 0.2))
                out[out.count - 1] = w
            } else {
                out[out.count - 1].text += p
                out[out.count - 1].end = max(out[out.count - 1].end, t.end)
            }
        }
        return out
    }

    /// Splits words into sentences: after `.`, `?` or `!`, at pauses longer
    /// than `gap` seconds, and at `maxLength` seconds.
    public static func sentences(_ words: [Word], gap: Double = 1.5, maxLength: Double = 30) -> [[Word]] {
        var out: [[Word]] = []
        var cur: [Word] = []
        for w in words {
            if let last = cur.last, w.start - last.end > gap || w.end - cur[0].start > maxLength {
                out.append(cur)
                cur = []
            }
            cur.append(w)
            if let c = w.text.last, ".?!".contains(c) {
                out.append(cur)
                cur = []
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    // MARK: echo

    /// A mic segment is echo when it overlaps system speech in time and more
    /// than 60 % of *its* words appear, in order, in that system speech. The
    /// share is of the mic words: the quieter echo copy often comes back as a
    /// fragment ("Agreed." against the full sentence).
    public static func isEcho(_ mic: Segment, against system: [Segment], threshold: Double = 0.6, slack: Double = 1.0) -> Bool {
        let mw = Text.normalized(mic.text)
        guard !mw.isEmpty else { return false }
        let near = system.filter { $0.start <= mic.end + slack && $0.end >= mic.start - slack }.sorted { $0.start < $1.start }
        guard !near.isEmpty else { return false }
        let sw = near.flatMap { Text.normalized($0.text) }
        var j = 0, hits = 0
        for w in mw {
            if let k = sw[j...].firstIndex(of: w) {
                hits += 1
                j = k + 1
            }
        }
        return Double(hits) / Double(mw.count) > threshold
    }

    public static func dropEcho(_ segments: [Segment]) -> [Segment] {
        let system = segments.filter { $0.track == .system }
        return segments.filter { $0.track == .system || !isEcho($0, against: system) }
    }

    // MARK: speakers

    public struct Turn: Sendable, Equatable {
        public var speaker: String
        public var start: Double
        public var end: Double
        public init(speaker: String, start: Double, end: Double) {
            self.speaker = speaker
            self.start = start
            self.end = end
        }
    }

    /// Gives each word the diarizer speaker that overlaps it most, else the
    /// nearest turn within 2 s, else the previous word's speaker.
    public static func label(_ words: [Word], turns: [Turn]) -> [Word] {
        let turns = turns.sorted { $0.start < $1.start }
        var prev: String?
        return words.map { w in
            var w = w
            var best: (String, Double)?
            for t in turns where t.start < w.end && t.end > w.start {
                let o = min(t.end, w.end) - max(t.start, w.start)
                if o > (best?.1 ?? -1) { best = (t.speaker, o) }
            }
            if best == nil {
                let mid = (w.start + w.end) / 2
                if let t = turns.min(by: { dist(mid, $0) < dist(mid, $1) }), dist(mid, t) <= 2 { best = (t.speaker, 0) }
            }
            w.speaker = best?.0 ?? prev ?? turns.first?.speaker
            prev = w.speaker
            return w
        }
    }

    static func dist(_ x: Double, _ t: Turn) -> Double { x < t.start ? t.start - x : (x > t.end ? x - t.end : 0) }

    /// Folds speakers with under `minShare` of the talking (or under
    /// `minSeconds`) into the nearest real speaker: by embedding similarity
    /// when embeddings are known, else the neighbouring word's speaker.
    /// Clusterers invent speakers from a second or two of crosstalk.
    public static func prune(_ words: [Word], embeddings: [String: [Float]] = [:],
                             minShare: Double = 0.04, minSeconds: Double = 5) -> [Word]
    {
        var talk: [String: Double] = [:]
        for w in words { if let s = w.speaker { talk[s, default: 0] += max(0.05, w.end - w.start) } }
        let total = talk.values.reduce(0, +)
        guard total > 0, talk.count > 1 else { return words }
        // Word durations understate talk time; scale the absolute floor to match.
        var major = Set(talk.filter { $0.value / total >= minShare && $0.value >= minSeconds * 0.5 }.keys)
        if major.isEmpty, let top = talk.max(by: { $0.value < $1.value })?.key { major = [top] }
        let minor = Set(talk.keys).subtracting(major)
        guard !minor.isEmpty else { return words }

        var target: [String: String] = [:]
        for m in minor {
            if let e = embeddings[m] {
                let best = major.compactMap { k in embeddings[k].map { (k, cosine(e, $0)) } }.max { $0.1 < $1.1 }
                if let best { target[m] = best.0 }
            }
        }
        var out = words
        for i in out.indices {
            guard let s = out[i].speaker, minor.contains(s) else { continue }
            if let t = target[s] {
                out[i].speaker = t
                continue
            }
            // Nearest major speaker in time.
            var best: (String, Double)?
            for j in out.indices where j != i {
                guard let sj = words[j].speaker, major.contains(sj) else { continue }
                let d = abs(words[j].start - out[i].start)
                if d < (best?.1 ?? .infinity) { best = (sj, d) }
            }
            out[i].speaker = best?.0 ?? major.first
        }
        return out
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return dot / max((na * nb).squareRoot(), 1e-9)
    }

    /// Cuts a sentence wherever the word speaker changes. Cuts only fall
    /// between words, so no word is split and no punctuation leads a line.
    public static func splitBySpeaker(_ sentence: [Word], track: Track) -> [Segment] {
        var out: [Segment] = []
        for w in sentence {
            let s = w.speaker ?? track.plainLabel
            if let last = out.last, last.speaker == s {
                out[out.count - 1].words.append(w)
            } else {
                out.append(Segment(track: track, speaker: s, words: [w]))
            }
        }
        return out
    }

    /// Renumbers each track's diarized labels by first appearance: `Mic 1`,
    /// `Mic 2`… and `Speaker 1`, `Speaker 2`…. Run after echo removal, so you
    /// are never left as "Mic 2" with no "Mic 1".
    public static func renumber(_ segments: [Segment]) -> [Segment] {
        var maps: [Track: [String: String]] = [.mic: [:], .system: [:]]
        let ordered = segments.sorted { $0.start < $1.start }
        for s in ordered where !["Me", "Them"].contains(s.speaker) {
            if maps[s.track]![s.speaker] == nil {
                maps[s.track]![s.speaker] = "\(s.track.prefix) \(maps[s.track]!.count + 1)"
            }
        }
        return ordered.map { s in
            var s = s
            s.speaker = maps[s.track]![s.speaker] ?? s.speaker
            return s
        }
    }

    /// Sorts by time and joins consecutive turns by the same speaker.
    public static func merge(_ segments: [Segment], joinGap: Double = 5) -> [Segment] {
        var out: [Segment] = []
        for s in segments.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, last.speaker == s.speaker, last.track == s.track, s.start - last.end <= joinGap {
                out[out.count - 1].words += s.words
            } else {
                out.append(s)
            }
        }
        return out
    }

    public static func speakers(_ segments: [Segment]) -> [String] {
        var seen: [String] = []
        for s in segments where !seen.contains(s.speaker) { seen.append(s.speaker) }
        return seen.sorted { a, b in
            func key(_ l: String) -> (Int, Int) {
                let n = Int(l.split(separator: " ").last ?? "") ?? 0
                if l == "Me" || l.hasPrefix("Mic") { return (0, n) }
                return (1, n)
            }
            return key(a) < key(b)
        }
    }

    public static func line(_ s: Segment) -> String { "[\(Clock.stamp(s.start))] \(s.speaker): \(s.text)" }

    public static func render(_ segments: [Segment]) -> String {
        segments.map(line).joined(separator: "\n\n")
    }

    /// The full final-pass assembly for one or two tracks.
    public static func assemble(mic: [Word]?, system: [Word]?, diarized: Bool) -> [Segment] {
        var segs: [Segment] = []
        for (track, words) in [(Track.mic, mic), (Track.system, system)] {
            guard let words else { continue }
            for sentence in sentences(words) {
                if diarized {
                    segs += splitBySpeaker(sentence, track: track)
                } else {
                    segs.append(Segment(track: track, speaker: track.plainLabel, words: sentence))
                }
            }
        }
        segs = dropEcho(segs)
        if diarized { segs = renumber(segs) }
        return merge(segs)
    }
}
