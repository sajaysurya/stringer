import Foundation
import Testing
@testable import CaptureKit
@testable import StringerCore
@testable import StringerKit

func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appending("stringer-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func tone(_ hz: Double, seconds: Double, rate: Double, amp: Float = 0.5) -> [Float] {
    (0..<Int(seconds * rate)).map { amp * Float(sin(2 * .pi * hz * Double($0) / rate)) }
}

/// Energy at one frequency (Goertzel), normalised by length.
func power(_ x: [Float], hz: Double, rate: Double) -> Double {
    let k = 2 * cos(2 * .pi * hz / rate)
    var s1 = 0.0, s2 = 0.0
    for v in x {
        let s = Double(v) + k * s1 - s2
        s2 = s1
        s1 = s
    }
    return (s1 * s1 + s2 * s2 - k * s1 * s2) / Double(x.count * x.count)
}

/// Speech-like far end: broadband noise, gently low-passed, in syllable
/// bursts. (Pure tones are a poor AEC test: the echo path is ambiguous.)
func speechLike(seconds: Double, seed: UInt64 = 42, rate: Double = 2.5) -> [Float] {
    let n = Int(seconds * 16_000)
    var rng = SplitMix(seed: seed)
    var lp: Float = 0
    var out = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let white = Float(rng.next() % 2001) / 1000 - 1
        lp = 0.7 * lp + 0.3 * white
        let env = Float(max(0, sin(2 * Double.pi * rate * Double(i) / 16_000)))
        out[i] = 0.6 * env * lp
    }
    return out
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

func scaled(_ x: [Float], _ k: Float) -> [Float] { x.map { $0 * k } }
