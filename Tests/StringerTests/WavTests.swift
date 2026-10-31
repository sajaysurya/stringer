import Foundation
import Testing
@testable import CaptureKit
@testable import StringerCore
@testable import StringerKit

@Suite struct WavTests {
    @Test func roundTrip() throws {
        let url = tempDir().appending("a.wav")
        let w = try WavWriter(url: url)
        w.write([0, 0.5, -0.5, 1, -1])
        w.close()
        let info = try #require(WavReader.info(url))
        #expect(info.dataOffset == 44 && info.sampleCount == 5 && info.sampleRate == 16_000)
        let r = WavReader.read(url)
        #expect(abs(r[1] - 0.5) < 0.001 && abs(r[4] + 1) < 0.001)
    }

    @Test func readsAFileStillBeingWritten() throws {
        // Header sizes stale (0) while samples keep landing: trust the file size.
        let url = tempDir().appending("b.wav")
        let w = try WavWriter(url: url)
        w.write([Float](repeating: 0.25, count: 16_000))
        #expect(WavReader.info(url)?.sampleCount == 16_000)
        w.write([Float](repeating: 0.25, count: 8_000))
        #expect(WavReader.info(url)?.sampleCount == 24_000)
        w.close()
    }

    @Test func parsesChunksInsteadOfAssuming44() throws {
        // AVAudioFile-style: an extra chunk puts the samples at byte 78.
        let url = tempDir().appending("c.wav")
        var d = Wav.header(dataBytes: 4)
        let fmtEnd = 36
        var junk = Data("FLLR".utf8)
        junk.append(contentsOf: [26, 0, 0, 0])
        junk.append(Data(count: 26))
        d.insert(contentsOf: junk, at: fmtEnd)
        d.append(contentsOf: [0x00, 0x40, 0x00, 0xC0])  // 0.5, -0.5
        try d.write(to: url)
        let info = try #require(WavReader.info(url))
        #expect(info.dataOffset == 78)
        let r = WavReader.read(url)
        #expect(r.count == 2 && abs(r[0] - 0.5) < 0.001 && abs(r[1] + 0.5) < 0.001)
    }

    @Test func repairFixesHeaderOfAKilledWriter() throws {
        let url = tempDir().appending("d.wav")
        let w = try WavWriter(url: url)
        w.write([Float](repeating: 0.1, count: 1000))  // never closed: sizes are 0
        let n = Wav.repair(url)
        #expect(n == 1000)
        let bytes = try Data(contentsOf: url)
        let dataSize = bytes[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(dataSize == 2000)
    }
}
