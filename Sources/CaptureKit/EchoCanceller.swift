import CStringerAEC
import Foundation

/// WebRTC AEC3 on the mic track, with the system track as the reference.
/// Never Apple's Voice Processing I/O: it ducks and garbles every other
/// app's audio, which the tap then records.
public final class EchoCanceller {
    private let handle: OpaquePointer
    public let frameSize: Int

    public init?(sampleRate: Int = timelineRate) {
        guard let h = stringer_aec_create(Int32(sampleRate)) else { return nil }
        handle = h
        frameSize = Int(stringer_aec_frame_size(h))
    }

    deinit { stringer_aec_destroy(handle) }

    /// Cancels `mic` in place. Both arrays are the same length; a trailing
    /// partial frame is zero-padded for processing.
    public func process(mic: inout [Float], system: [Float]) {
        precondition(mic.count == system.count)
        var renderFrame = [Float](repeating: 0, count: frameSize)
        var captureFrame = [Float](repeating: 0, count: frameSize)
        var i = 0
        while i < mic.count {
            let n = min(frameSize, mic.count - i)
            for k in 0..<frameSize {
                renderFrame[k] = k < n ? system[i + k] : 0
                captureFrame[k] = k < n ? mic[i + k] : 0
            }
            _ = renderFrame.withUnsafeBufferPointer { r in
                captureFrame.withUnsafeMutableBufferPointer { c in
                    stringer_aec_process(handle, r.baseAddress, c.baseAddress)
                }
            }
            for k in 0..<n { mic[i + k] = captureFrame[k] }
            i += n
        }
    }
}
