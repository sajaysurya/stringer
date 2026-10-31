import Foundation
import Testing
@testable import StringerPipeline

func tok(_ text: String, _ start: Double, _ end: Double) -> Token { Token(text: text, start: start, end: end) }

func words(_ spec: [(String, Double, String?)]) -> [Word] {
    spec.map { Word(text: $0.0, start: $0.1, end: $0.1 + 0.3, speaker: $0.2) }
}

@Suite struct TranscriptTests {
    @Test func wordsSplitOnlyAtWordStarts() {
        // "Agreed." as three tokens must stay one word (T-9).
        let w = Transcript.words([tok("▁Ag", 0, 0.2), tok("reed", 0.2, 0.4), tok(".", 0.4, 3.0), tok(" Next", 3.0, 3.3)])
        #expect(w.map(\.text) == ["Agreed.", "Next"])
        // The period's stretched duration doesn't extend the word across the silence.
        #expect(w[0].end < 1.0)
    }

    @Test func repeatedPunctuationCollapses() {
        let w = Transcript.words([tok(" Yeah", 0, 0.3), tok(".", 0.3, 2), tok(".", 2, 5)])
        #expect(w.map(\.text) == ["Yeah."])
    }

    @Test func sentencesSplitOnPunctuationAndPauses() {
        let w = [Word(text: "Hi.", start: 0, end: 0.3), Word(text: "How", start: 0.4, end: 0.6),
                 Word(text: "are", start: 0.6, end: 0.8), Word(text: "you", start: 3.0, end: 3.2)]
        #expect(Transcript.sentences(w).map { $0.map(\.text) } == [["Hi."], ["How", "are"], ["you"]])
    }

    @Test func echoIsScoredOnTheMicWords() {
        let system = Segment(track: .system, speaker: "Them", words: words([
            ("We", 10, nil), ("all", 10.3, nil), ("agreed.", 10.6, nil), ("Ship", 11, nil), ("it", 11.3, nil), ("Friday.", 11.6, nil),
        ]))
        // A short fragment of the far-end sentence is echo, though a symmetric
        // similarity would score it low.
        let fragment = Segment(track: .mic, speaker: "Me", words: words([("Agreed.", 10.7, nil)]))
        #expect(Transcript.isEcho(fragment, against: [system]))
        // Your own words over the same moment are not.
        let mine = Segment(track: .mic, speaker: "Me", words: words([("No,", 10.5, nil), ("wait", 10.8, nil), ("Monday.", 11.1, nil)]))
        #expect(!Transcript.isEcho(mine, against: [system]))
        // The same words much later don't overlap in time: not echo.
        let later = Segment(track: .mic, speaker: "Me", words: words([("Agreed.", 40, nil)]))
        #expect(!Transcript.isEcho(later, against: [system]))
    }

    @Test func speakersAssignedPerWordByOverlap() {
        let w = words([("Yes", 0, nil), ("that", 0.4, nil), ("works.", 0.8, nil), ("Great", 1.6, nil)])
        let turns = [Transcript.Turn(speaker: "A", start: 0, end: 1.2), Transcript.Turn(speaker: "B", start: 1.5, end: 3)]
        #expect(Transcript.label(w, turns: turns).map(\.speaker) == ["A", "A", "A", "B"])
    }

    @Test func splitBySpeakerNeverLeadsWithPunctuation() {
        let s = words([("Agreed.", 0, "A"), ("Yeah.", 0.5, "B"), ("So", 1, "A")])
        let segs = Transcript.splitBySpeaker(s, track: .system)
        #expect(segs.map(\.text) == ["Agreed.", "Yeah.", "So"])
        #expect(segs.allSatisfy { !($0.text.first?.isPunctuation ?? false) })
    }

    @Test func renumberAfterEchoRemovalStartsAtOne() {
        // The mic diarizer put the echo in its own cluster, seen first.
        let system = Segment(track: .system, speaker: "S9", words: words([("Ship", 1, nil), ("it", 1.3, nil), ("Friday.", 1.6, nil)]))
        let echo = Segment(track: .mic, speaker: "M0", words: words([("Ship", 1.05, nil), ("it", 1.35, nil), ("Friday.", 1.65, nil)]))
        let me = Segment(track: .mic, speaker: "M1", words: words([("Sounds", 5, nil), ("good.", 5.3, nil)]))
        let out = Transcript.renumber(Transcript.dropEcho([system, echo, me]))
        #expect(out.map(\.speaker) == ["Speaker 1", "Mic 1"])
    }

    @Test func pruneFoldsTinySpeakers() {
        var w: [Word] = []
        for i in 0..<100 { w.append(Word(text: "a", start: Double(i), end: Double(i) + 0.5, speaker: i % 2 == 0 ? "A" : "B")) }
        w.append(Word(text: "huh", start: 50.2, end: 50.4, speaker: "C"))
        let out = Transcript.prune(w)
        #expect(Set(out.compactMap(\.speaker)) == ["A", "B"])
    }

    @Test func pruneKeepsAlmostSilentMeetingsLabelled() {
        let w = [Word(text: "hi", start: 0, end: 0.3, speaker: "A"), Word(text: "yo", start: 1, end: 1.2, speaker: "B")]
        #expect(Set(Transcript.prune(w).compactMap(\.speaker)).count == 1)
    }

    @Test func assembleWithoutDiarizationUsesMeThem() {
        let mic = words([("Two", 13, nil), ("weeks.", 13.3, nil)])
        let sys = words([("Good", 0, nil), ("morning.", 0.3, nil)])
        let segs = Transcript.assemble(mic: mic, system: sys, diarized: false)
        #expect(segs.map(\.speaker) == ["Them", "Me"])
        #expect(Transcript.render(segs).hasPrefix("[00:00] Them: Good morning."))
    }

    @Test func mergeJoinsSameSpeakerTurns() {
        let a = Segment(track: .system, speaker: "Speaker 1", words: words([("One.", 0, nil)]))
        let b = Segment(track: .system, speaker: "Speaker 1", words: words([("Two.", 1, nil)]))
        let c = Segment(track: .mic, speaker: "Mic 1", words: words([("Three.", 2, nil)]))
        #expect(Transcript.merge([c, b, a]).map(\.text) == ["One. Two.", "Three."])
    }

    @Test func speakerListOrdersMicFirst() {
        let segs = ["Speaker 2", "Mic 1", "Speaker 1"].map { Segment(track: .system, speaker: $0, words: []) }
        #expect(Transcript.speakers(segs) == ["Mic 1", "Speaker 1", "Speaker 2"])
    }
}

@Suite struct TitleTests {
    @Test func validation() {
        #expect(Titler.validate("Billing Service Migration") == "Billing Service Migration")
        #expect(Titler.validate("\"Leeds Lease Renewal\"\n") == "Leeds Lease Renewal")
        #expect(Titler.validate("Planning") == nil)  // 1 word
        #expect(Titler.validate("Speaker 1 Budget Review") == nil)
        #expect(Titler.validate("one two three four five six seven") == nil)
    }

    @Test func excerptSamplesTheWholeMeeting() {
        // The subject only appears in the second half (A-6).
        var segs: [Segment] = []
        for i in 0..<400 {
            let text = i < 200 ? "small talk about the weather and the weekend plans" : "the warehouse lease in Leeds expires in March"
            segs.append(Segment(track: .system, speaker: "Speaker 1", words: [Word(text: text, start: Double(i), end: Double(i) + 1)]))
        }
        let e = Titler.excerpt(segs)
        #expect(e.count <= 8200)
        #expect(e.contains("warehouse"))
        #expect(e.contains("weather"))
    }
}
