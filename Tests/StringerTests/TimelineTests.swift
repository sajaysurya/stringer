import Foundation
import Testing
@testable import CaptureKit
@testable import StringerCore
@testable import StringerKit

@Suite struct TimelineTests {
    @Test func overlappingSourcesAreAveragedNotSummed() {
        let bus = Bus()
        bus.add([Float](repeating: 0.8, count: 100), at: 0)
        bus.add([Float](repeating: 0.8, count: 100), at: 50)
        let out = bus.take(upTo: 150)
        #expect(out.max()! <= 0.8001)  // no clipping
        #expect(abs(out[75] - 0.8) < 1e-6)
    }

    @Test func gapsReadAsSilenceAndLateAudioIsDropped() {
        let bus = Bus()
        bus.add([1, 1], at: 4)
        let out = bus.take(upTo: 8)
        #expect(out == [0, 0, 0, 0, 1, 1, 0, 0])
        bus.add([1, 1, 1, 1], at: 6)  // first two positions already flushed
        #expect(bus.take(upTo: 10) == [1, 1])
    }

    /// Every rate lands on the 16 kHz grid with the right duration (C-5, C-11),
    /// fed in device-sized buffers, and the tone survives.
    @Test(arguments: [24_000.0, 44_100.0, 48_000.0, 16_000.0])
    func resamplerKeepsDurationAndPitch(rate: Double) {
        let r = Resampler(inputRate: rate)
        let x = tone(440, seconds: 10, rate: rate)
        var out: [Float] = []
        var i = 0
        while i < x.count {
            let n = min(512, x.count - i)
            out += r.process(Array(x[i..<i + n]))
            i += n
        }
        let seconds = Double(out.count) / 16_000
        #expect(abs(seconds - 10) / 10 <= 0.015, "\(rate) Hz → \(seconds) s")
        let body = Array(out[16_000..<out.count - 16_000])
        #expect(power(body, hz: 440, rate: 16_000) > 100 * power(body, hz: 1000, rate: 16_000))
    }
}
