import Foundation

/// 16 kHz mono 16-bit PCM WAV, written by hand: a fixed 44-byte header whose
/// sizes are patched periodically and at close. A file cut off mid-write
/// still has every sample, and readers never trust the header sizes anyway.
public final class WavWriter {
    public static let sampleRate = 16_000
    public let url: URL
    private var handle: FileHandle?
    public private(set) var samplesWritten = 0
    public private(set) var peak: Float = 0

    public init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: Wav.header(dataBytes: 0))
        handle = try FileHandle(forWritingTo: url)
        try handle?.seekToEnd()
    }

    public func write(_ samples: [Float]) {
        guard let handle, !samples.isEmpty else { return }
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, x) in samples.enumerated() {
            let a = abs(x)
            if a > peak { peak = a }
            pcm[i] = Int16(max(-32768, min(32767, (x * 32767).rounded())))
        }
        pcm.withUnsafeBytes { handle.write(Data($0)) }
        samplesWritten += samples.count
    }

    /// Rewrites the header sizes in place.
    public func patchHeader() {
        guard let handle else { return }
        let end = (try? handle.offset()) ?? 0
        try? handle.seek(toOffset: 0)
        handle.write(Wav.header(dataBytes: samplesWritten * 2))
        try? handle.seek(toOffset: end)
    }

    public func close() {
        patchHeader()
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }

    public var seconds: Double { Double(samplesWritten) / Double(Self.sampleRate) }
}

public enum Wav {
    public static func header(dataBytes: Int, sampleRate: Int = 16_000) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        return d
    }

    /// Fixes the header sizes of a file whose writer died. Returns the sample count.
    @discardableResult
    public static func repair(_ url: URL) -> Int? {
        guard let info = WavReader.info(url) else { return nil }
        guard info.format == 1, info.bitsPerSample == 16, info.channels == 1 else { return nil }
        let bytes = info.sampleCount * 2
        guard let h = try? FileHandle(forUpdating: url) else { return nil }
        defer { try? h.close() }
        // Truncate a trailing odd byte, then rewrite the RIFF and data sizes.
        try? h.truncate(atOffset: UInt64(info.dataOffset + bytes))
        try? h.seek(toOffset: 4)
        h.write(withUnsafeBytes(of: UInt32(info.dataOffset - 8 + bytes).littleEndian) { Data($0) })
        try? h.seek(toOffset: UInt64(info.dataOffset - 4))
        h.write(withUnsafeBytes(of: UInt32(bytes).littleEndian) { Data($0) })
        return info.sampleCount
    }
}

/// Reads 16-bit PCM WAVs, including ones still being written: the `data`
/// chunk is found by parsing the chunks, and its length is taken from the
/// file size, not from (possibly stale) header sizes.
public enum WavReader {
    public struct Info {
        public var format: Int
        public var channels: Int
        public var sampleRate: Int
        public var bitsPerSample: Int
        public var dataOffset: Int
        /// Frames available now, from the file size.
        public var sampleCount: Int
        public var seconds: Double { Double(sampleCount) / Double(max(sampleRate, 1)) }
    }

    public static func info(_ url: URL) -> Info? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 4096), head.count >= 12 else { return nil }
        let size = (try? h.seekToEnd()).map(Int.init) ?? 0
        let b = [UInt8](head)
        guard b[0..<4] == [0x52, 0x49, 0x46, 0x46], b[8..<12] == [0x57, 0x41, 0x56, 0x45] else { return nil }
        func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        var o = 12
        var fmt: (Int, Int, Int, Int)?
        while o + 8 <= b.count {
            let id = String(bytes: b[o..<o + 4], encoding: .ascii) ?? ""
            let len = u32(o + 4)
            if id == "fmt ", o + 24 <= b.count {
                fmt = (u16(o + 8), u16(o + 10), u32(o + 12), u16(o + 22))
            } else if id == "data" {
                guard let fmt else { return nil }
                let offset = o + 8
                let frameBytes = max(1, fmt.1 * fmt.3 / 8)
                return Info(format: fmt.0, channels: fmt.1, sampleRate: fmt.2, bitsPerSample: fmt.3,
                            dataOffset: offset, sampleCount: max(0, size - offset) / frameBytes)
            }
            o += 8 + len + (len & 1)
        }
        return nil
    }

    /// Reads mono 16-bit samples `[from, from+count)` as floats. Short at EOF.
    public static func read(_ url: URL, from: Int = 0, count: Int? = nil) -> [Float] {
        guard let info = info(url), info.bitsPerSample == 16 else { return [] }
        let ch = max(info.channels, 1)
        let start = min(max(from, 0), info.sampleCount)
        let n = min(count ?? (info.sampleCount - start), info.sampleCount - start)
        guard n > 0, let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        try? h.seek(toOffset: UInt64(info.dataOffset + start * 2 * ch))
        guard let data = try? h.read(upToCount: n * 2 * ch) else { return [] }
        let frames = data.count / (2 * ch)
        var out = [Float](repeating: 0, count: frames)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                var acc: Float = 0
                for c in 0..<ch { acc += Float(Int16(littleEndian: p[i * ch + c])) }
                out[i] = acc / Float(ch) / 32768
            }
        }
        return out
    }

    /// Peak absolute value over a sample range.
    public static func peak(_ url: URL, from: Int, count: Int) -> Float {
        read(url, from: from, count: count).reduce(0) { max($0, abs($1)) }
    }
}

public enum Signal {
    public static func peak(_ x: ArraySlice<Float>) -> Float { x.reduce(0) { max($0, abs($1)) } }
    public static func peak(_ x: [Float]) -> Float { peak(x[...]) }

    public static func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    public static func dbfs(_ v: Float) -> Float { v > 0 ? 20 * log10(v) : -.infinity }

    /// −50 dBFS: below it a slice is silence (recognisers hallucinate on it)
    /// and the menu-bar waveform is a flat line.
    public static let silencePeak: Float = 0.00316
}
