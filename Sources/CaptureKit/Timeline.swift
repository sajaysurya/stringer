import AVFoundation
import CoreAudio
import Foundation
import StringerCore

public let timelineRate = 16_000

/// Converts mono float audio at a device's rate to 16 kHz.
///
/// The output buffer is sized exactly `ceil(in × 16000 / inRate)`: a larger
/// buffer makes `AVAudioConverter` ask for more input, get `.noDataNow`, and
/// flush its resampler early, dropping the tail of every buffer.
public final class Resampler {
    public private(set) var inputRate: Double
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(timelineRate), channels: 1, interleaved: false)!

    public init(inputRate: Double) {
        self.inputRate = inputRate
        configure()
    }

    public func setInputRate(_ rate: Double) {
        guard rate != inputRate else { return }
        inputRate = rate
        configure()
    }

    private func configure() {
        if inputRate == Double(timelineRate) {
            converter = nil
            inFormat = nil
            return
        }
        inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)
        converter = inFormat.flatMap { AVAudioConverter(from: $0, to: outFormat) }
        converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
    }

    public func process(_ x: [Float]) -> [Float] {
        guard let converter, let inFormat, !x.isEmpty else { return x }
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(x.count)) else { return [] }
        inBuf.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        let outCap = AVAudioFrameCount((Double(x.count) * Double(timelineRate) / inputRate).rounded(.up))
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else { return [] }
        var supplied = false
        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return inBuf
        }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }
}

/// One track's shared timeline at 16 kHz. Sources add samples at absolute
/// positions; overlapping sources are averaged (not summed) so two mics
/// hearing the same voice cannot clip. Unwritten positions read as silence.
public final class Bus: @unchecked Sendable {
    private var sum: [Float] = []
    private var count: [UInt16] = []
    public private(set) var base = 0
    public private(set) var highWater = 0
    private let lock = NSLock()

    public init() {}

    public func add(_ x: [Float], at position: Int) {
        lock.lock()
        defer { lock.unlock() }
        var x = x[...]
        var pos = position
        if pos < base {
            // Arrived after its region was flushed; keep only the new part.
            let skip = min(base - pos, x.count)
            x = x.dropFirst(skip)
            pos += skip
        }
        guard !x.isEmpty else { return }
        let end = pos + x.count - base
        if end > sum.count {
            sum.append(contentsOf: repeatElement(0, count: end - sum.count))
            count.append(contentsOf: repeatElement(0, count: end - count.count))
        }
        var i = pos - base
        for v in x {
            sum[i] += v
            count[i] &+= 1
            i += 1
        }
        highWater = max(highWater, pos + x.count)
    }

    /// Removes and returns `[base, end)`, averaged per position.
    public func take(upTo end: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let n = end - base
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        let have = min(n, sum.count)
        for i in 0..<have where count[i] > 0 {
            out[i] = count[i] == 1 ? sum[i] : sum[i] / Float(count[i])
        }
        sum.removeFirst(have)
        count.removeFirst(have)
        base = end
        return out
    }
}

/// Maps host time to timeline positions. Position 0 is `start`.
public protocol TimelineClock: AnyObject, Sendable {
    var startDate: Date { get }
    func position(hostTime: UInt64) -> Int
    func nowPosition() -> Int
}

public final class HostClock: TimelineClock, @unchecked Sendable {
    public let startHost: UInt64
    public let startDate: Date

    public init() {
        startHost = AudioGetCurrentHostTime()
        startDate = Date()
    }

    public func position(hostTime: UInt64) -> Int {
        let ns = Double(AudioConvertHostTimeToNanos(hostTime)) - Double(AudioConvertHostTimeToNanos(startHost))
        return Int((ns / 1e9 * Double(timelineRate)).rounded())
    }

    public func nowPosition() -> Int { position(hostTime: AudioGetCurrentHostTime()) }
}

/// One device feeding one bus. Each source converts to 16 kHz on its own
/// before it touches the timeline, so 24, 44.1 and 48 kHz hardware all land
/// on the same grid. It is placed by wall clock and re-pegged when its own
/// sample count drifts more than 100 ms from it.
public final class Source: @unchecked Sendable {
    public let name: String
    private let bus: Bus
    private let clock: TimelineClock
    private let resampler: Resampler
    private let queue: DispatchQueue
    private let log: FileLog
    private var next: Int?
    public private(set) var repegs = 0
    // Delivered-rate measurement, to catch a device that lies about its rate.
    private var firstHost: UInt64 = 0
    private var framesSinceFirst = 0
    private var rateChecked = false
    public static let repegThreshold = timelineRate / 10

    public init(name: String, rate: Double, bus: Bus, clock: TimelineClock, log: FileLog) {
        self.name = name
        self.bus = bus
        self.clock = clock
        self.log = log
        resampler = Resampler(inputRate: rate)
        queue = DispatchQueue(label: "stringer.source.\(name)", qos: .userInitiated)
    }

    /// Called from an IOProc with interleaved-per-buffer float audio. Downmixes
    /// here (cheap) and resamples on the source's own queue.
    public func push(_ list: UnsafePointer<AudioBufferList>, hostTime: UInt64) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var frames = 0
        for b in buffers where b.mNumberChannels > 0 {
            frames = max(frames, Int(b.mDataByteSize) / (4 * Int(b.mNumberChannels)))
        }
        guard frames > 0 else { return }
        var mono = [Float](repeating: 0, count: frames)
        var channels = 0
        for b in buffers where b.mNumberChannels > 0 {
            guard let data = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ch = Int(b.mNumberChannels)
            let n = min(frames, Int(b.mDataByteSize) / (4 * ch))
            for i in 0..<n {
                var acc: Float = 0
                for c in 0..<ch { acc += data[i * ch + c] }
                mono[i] += acc
            }
            channels += ch
        }
        if channels > 1 {
            let k = 1 / Float(channels)
            for i in 0..<frames { mono[i] *= k }
        }
        queue.async { self.place(mono, hostTime: hostTime) }
    }

    /// Places already-mono audio at the device's input rate.
    public func push(mono: [Float], hostTime: UInt64) {
        queue.async { self.place(mono, hostTime: hostTime) }
    }

    /// Places audio at an explicit position (replay).
    public func push(mono: [Float], position: Int) {
        queue.async {
            let out = self.resampler.process(mono)
            if self.next == nil { self.next = position }
            self.bus.add(out, at: self.next!)
            self.next! += out.count
        }
    }

    private func place(_ mono: [Float], hostTime: UInt64) {
        checkRate(frames: mono.count, hostTime: hostTime)
        let out = resampler.process(mono)
        let wall = clock.position(hostTime: hostTime)
        if let n = next, abs(wall - n) > Self.repegThreshold {
            repegs += 1
            log("\(name): re-pegged by \(String(format: "%.0f", Double(wall - n) / 16)) ms")
            next = wall
        } else if next == nil {
            next = wall
        }
        bus.add(out, at: next!)
        next! += out.count
    }

    /// After ~3 s, compares delivered frames per second with the claimed rate
    /// (`kAudioTapPropertyFormat` and stream formats lie at non-48 kHz rates).
    private func checkRate(frames: Int, hostTime: UInt64) {
        guard !rateChecked else { return }
        if firstHost == 0 {
            firstHost = hostTime
            return
        }
        framesSinceFirst += frames
        let secs = Double(AudioConvertHostTimeToNanos(hostTime) - AudioConvertHostTimeToNanos(firstHost)) / 1e9
        guard secs >= 3 else { return }
        rateChecked = true
        let measured = Double(framesSinceFirst) / secs
        let claimed = resampler.inputRate
        if abs(measured - claimed) / claimed > 0.03 {
            let fixed = Self.standardRates.min { abs($0 - measured) < abs($1 - measured) } ?? measured
            log("\(name): claimed \(Int(claimed)) Hz but delivers \(Int(measured)) Hz — using \(Int(fixed)) Hz")
            resampler.setInputRate(fixed)
        } else {
            log("\(name): rate ok (\(Int(claimed)) Hz claimed, \(Int(measured)) Hz measured)")
        }
    }

    static let standardRates: [Double] = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000]

    /// Waits for queued conversions to land on the bus.
    public func drain() { queue.sync {} }
}
