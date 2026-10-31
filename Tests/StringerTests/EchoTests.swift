import Foundation
import Testing
@testable import CaptureKit
@testable import StringerCore
@testable import StringerKit

/// AEC3 on speech. Synthetic noise or tones mislead here (they suggested an
/// 8 dB loss on echo-free speech that real speech does not show), so these
/// use `say` output (skipped where no voices are installed). A real
/// loudspeaker and mic are still the final word.
let echoFar = spoken("Good morning everyone. Today we need to decide whether to migrate the authentication service to the new cluster. Odalys will own the rollout plan and the reviewers will check the schema changes before Friday.", voice: "Samantha")
let echoLocal = spoken("This is me talking on my own microphone. I keep talking for a while so that we can measure it properly over many seconds of speech, and then I stop talking.", voice: "Daniel")

@Suite(.enabled(if: echoFar != nil && echoLocal != nil, "needs `say` voices"))
struct EchoTests {

    func echoed(_ far: [Float], delay: Int = 720) -> [Float] {
        far.indices.map { i in
            (i >= delay ? 0.35 * far[i - delay] : 0) + (i >= delay + 40 ? 0.12 * far[i - delay - 40] : 0)
        }
    }

    func padded(_ x: [Float], _ n: Int) -> [Float] { x.count >= n ? Array(x.prefix(n)) : x + [Float](repeating: 0, count: n - x.count) }

    @Test func removesLoudspeakerEcho() throws {
        let far = try #require(echoFar)
        let echo = echoed(far)
        var mic = echo
        let aec = try #require(EchoCanceller())
        aec.process(mic: &mic, system: far)
        // Once converged: after the first 3 s.
        let reduction = Signal.dbfs(Signal.rms(echo[48_000...])) - Signal.dbfs(Signal.rms(mic[48_000...]))
        #expect(reduction >= 30, "only \(reduction) dB")
    }

    @Test func leavesEchoFreeSpeechAlone() throws {
        // Headphones: no echo path, so AEC changes essentially nothing (E-3).
        let far = try #require(echoFar), local = try #require(echoLocal)
        let n = max(far.count, local.count)
        let ref = padded(local, n)
        var mic = ref
        let aec = try #require(EchoCanceller())
        aec.process(mic: &mic, system: padded(far, n))
        let diff = Signal.dbfs(Signal.rms(ref[32_000...])) - Signal.dbfs(Signal.rms(mic[32_000...]))
        #expect(abs(diff) <= 1, "changed by \(diff) dB")
    }

    @Test func keepsLocalSpeechDuringDoubleTalk() throws {
        let far = try #require(echoFar), local = try #require(echoLocal)
        let n = max(far.count, local.count)
        let localP = padded(local, n), farP = padded(far, n)
        let echo = echoed(farP)
        var mic = zip(echo, localP).map { $0 + $1 }
        let aec = try #require(EchoCanceller())
        aec.process(mic: &mic, system: farP)
        // After convergence the local talker keeps its level. (Whether the
        // far end is gone from the words is E-2, checked by transcribing:
        // the suppressor shapes the spectrum, so waveform error says little.)
        let tail = 64_000
        let localLevel = Signal.dbfs(Signal.rms(localP[tail...]))
        let outLevel = Signal.dbfs(Signal.rms(mic[tail...]))
        #expect(abs(outLevel - localLevel) <= 3, "local speech level changed \(outLevel - localLevel) dB")
    }
}

/// 16 kHz mono speech from `say` (nil if it fails, e.g. no voices). Checks
/// the duration: `say` can write an empty clip once Siri is on.
func spoken(_ text: String, voice: String) -> [Float]? {
    let dir = tempDir()
    let aiff = dir.appending("s.aiff"), wav = dir.appending("s.wav")
    func run(_ exe: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
    guard run("/usr/bin/say", ["-v", voice, "-o", aiff.path, text]),
          run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path]) else { return nil }
    let x = WavReader.read(wav)
    return x.count > 16_000 ? x : nil
}
