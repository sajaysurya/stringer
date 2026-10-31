import CaptureKit
import Foundation
import StringerCore

// aec-offline MIC SYSTEM OUT
// Replays a kept recording through the same echo canceller the recorder uses
// and reports how much the mic track changed.

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: aec-offline MIC.wav SYSTEM.wav OUT.wav\n".utf8))
    exit(2)
}
let mic = WavReader.read(URL(fileURLWithPath: args[1]))
let system = WavReader.read(URL(fileURLWithPath: args[2]))
guard !mic.isEmpty else {
    FileHandle.standardError.write(Data("aec-offline: cannot read \(args[1])\n".utf8))
    exit(1)
}
guard let aec = EchoCanceller() else {
    FileHandle.standardError.write(Data("aec-offline: AEC3 unavailable\n".utf8))
    exit(1)
}
let n = mic.count
var out = mic
let ref = system.count >= n ? Array(system.prefix(n)) : system + [Float](repeating: 0, count: n - system.count)
aec.process(mic: &out, system: ref)

let writer = try WavWriter(url: URL(fileURLWithPath: args[3]))
writer.write(out)
writer.close()

// Per-second level change, after the first two seconds (convergence).
func db(_ x: ArraySlice<Float>) -> Float { Signal.dbfs(Signal.rms(x)) }
let skip = min(2 * 16_000, n)
let before = db(mic[skip...]), after = db(out[skip...])
print(String(format: "mic %.1f dBFS -> %.1f dBFS (%.1f dB) over %.1fs", before, after, before - after, Double(n) / 16_000))
