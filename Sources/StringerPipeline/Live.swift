import Foundation
import StringerCore

/// The live transcript: `live.txt`, appended a line at a time while
/// recording and never rewritten, so a crash loses at most one slice.
///
/// Lines are `Me` (mic) or `Them` (system), never diarized: speaker
/// identities are not stable across independently diarized slices. A line is
/// held until both tracks have been transcribed past it, so lines come out in
/// time order and the mic copy of an echo can be dropped.
public final class LiveTranscriber {
    final class TrackState {
        let track: Track
        let url: URL
        var cursor = 0  // samples consumed
        init(track: Track, url: URL) {
            self.track = track
            self.url = url
        }
        var through: Double { Double(cursor) / 16_000 }
    }

    let recognizer: Recognizer
    let chunk: Int
    let tracks: [TrackState]
    let out: URL
    let log: (String) -> Void
    let onLine: (String) -> Void
    var pending: [Segment] = []
    var recentSystem: [Segment] = []
    public private(set) var lines = 0

    public init(dir: URL, recognizer: Recognizer, chunkSeconds: Double, hasMic: Bool,
                log: @escaping (String) -> Void, onLine: @escaping (String) -> Void = { _ in })
    {
        self.recognizer = recognizer
        chunk = Int(chunkSeconds * 16_000)
        var t = [TrackState(track: .system, url: dir.appending(MeetingFile.system))]
        if hasMic { t.insert(TrackState(track: .mic, url: dir.appending(MeetingFile.mic)), at: 0) }
        tracks = t
        out = dir.appending(MeetingFile.live)
        self.log = log
        self.onLine = onLine
        if !out.exists { FileManager.default.createFile(atPath: out.path, contents: nil) }
    }

    /// Transcribes whatever whole slices are available. With `final`, also
    /// the remainder, and then emits everything.
    public func step(final: Bool = false) async {
        for t in tracks {
            let available = WavReader.info(t.url)?.sampleCount ?? 0
            while true {
                let target = t.cursor + chunk
                var cut: Int
                if available >= target + 16_000 {
                    cut = Self.quietestCut(t.url, around: target)
                } else if final, available > t.cursor {
                    cut = min(available, target)
                } else {
                    break
                }
                cut = max(cut, t.cursor + 1)
                await transcribe(t, from: t.cursor, to: cut)
                t.cursor = cut
            }
        }
        emit(final: final)
    }

    /// The start of the quietest 20 ms window within ±1 s of `target`, so
    /// slices rarely split a word.
    static func quietestCut(_ url: URL, around target: Int) -> Int {
        let from = max(0, target - 16_000)
        let x = WavReader.read(url, from: from, count: 32_000)
        let win = 320
        guard x.count >= win else { return target }
        var best = target, bestE = Float.infinity
        var e: Float = x[0..<win].reduce(0) { $0 + $1 * $1 }
        var i = 0
        while true {
            if e < bestE {
                bestE = e
                best = from + i + win / 2
            }
            let j = i + win
            guard j < x.count else { break }
            e += x[j] * x[j] - x[i] * x[i]
            i += 1
        }
        return best
    }

    func transcribe(_ t: TrackState, from: Int, to: Int) async {
        let x = WavReader.read(t.url, from: from, count: to - from)
        // Below −50 dBFS is silence: recognisers hallucinate on it ("Thank you.").
        guard x.count >= 1_600, Signal.peak(x) >= Signal.silencePeak else { return }
        do {
            let offset = Double(from) / 16_000
            let tokens = try await recognizer.tokens(x).map { $0.shifted(offset) }
                .filter { $0.start < Double(to) / 16_000 + 0.05 }
            var words = Transcript.words(tokens)
            words = await recognizer.rescore(words, tokens: tokens, audio: x, offset: offset)
            for s in Transcript.sentences(words) where !s.isEmpty {
                pending.append(Segment(track: t.track, speaker: t.track.plainLabel, words: s))
            }
        } catch {
            log("live: \(t.track.rawValue) slice at \(Clock.stamp(Double(from) / 16_000)) failed: \(error)")
        }
    }

    func emit(final: Bool) {
        let horizon = final ? Double.infinity : (tracks.map(\.through).min() ?? 0)
        pending.sort { $0.start < $1.start }
        var ready: [Segment] = []
        // Emit from the front while lines are complete, so time order holds.
        while let first = pending.first, first.end <= horizon {
            ready.append(pending.removeFirst())
        }
        guard !ready.isEmpty else { return }
        let systemKnown = recentSystem + ready.filter { $0.track == .system } + pending.filter { $0.track == .system }
        var text = ""
        for s in ready {
            if s.track == .mic, Transcript.isEcho(s, against: systemKnown) { continue }
            let line = Transcript.line(s)
            text += line + "\n"
            lines += 1
            onLine(line)
        }
        recentSystem += ready.filter { $0.track == .system }
        if let last = ready.last { recentSystem.removeAll { $0.end < last.start - 60 } }
        if !text.isEmpty, let h = try? FileHandle(forWritingTo: out) {
            _ = try? h.seekToEnd()
            h.write(Data(text.utf8))
            try? h.synchronize()
            try? h.close()
        }
    }
}
