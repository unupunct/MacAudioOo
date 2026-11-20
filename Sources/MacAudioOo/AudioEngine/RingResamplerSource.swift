import Foundation

/// Real-time channel source that reads a lock-free `AudioRingBuffer` written by a capture thread, converts
/// from the capture sample rate to the output rate with linear interpolation, and trims the ratio by up to
/// ±1 % with a proportional controller that holds the buffered amount near `targetFill` frames. That absorbs
/// the slow clock drift between a capture device and the output device. No allocation after init.
final class RingResamplerSource: ChannelSource {
    private let ring: AudioRingBuffer
    private var srcRate: Double
    private let dstRate: Double
    private let targetFill: Double
    private let capacity = 16384
    private let bufL: UnsafeMutablePointer<Float>
    private let bufR: UnsafeMutablePointer<Float>
    private var count = 0              // valid source frames in the local buffers
    private var pos = 0.0              // fractional read position inside the local buffers
    private var primed = false
    private(set) var underruns = 0

    init(ring: AudioRingBuffer, sourceRate: Double, outputRate: Double, targetFillFrames: Double = 2048) {
        self.ring = ring; srcRate = sourceRate; dstRate = outputRate; targetFill = targetFillFrames
        bufL = .allocate(capacity: capacity); bufR = .allocate(capacity: capacity)
        bufL.initialize(repeating: 0, count: capacity); bufR.initialize(repeating: 0, count: capacity)
    }
    deinit { bufL.deallocate(); bufR.deallocate() }

    private func buffered() -> Double { Double(ring.availableToRead + count) - pos }

    override func pull(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        if !primed {
            if buffered() >= targetFill { primed = true } else { for i in 0..<frames { l[i] = 0; r[i] = 0 }; return }
        }
        let err = max(-1, min(1, (buffered() - targetFill) / targetFill))
        let ratio = (srcRate / dstRate) * (1 + 0.01 * err)

        // Top up the local buffer so the whole block can be generated.
        let need = Int(Double(frames) * ratio) + 3
        while Int(pos) + need > count, ring.availableToRead > 0, count < capacity {
            let n = min(ring.availableToRead, capacity - count)
            ring.read(into: bufL + count, bufR + count, frames: n)
            count += n
        }

        var i = 0
        while i < frames {
            let idx = Int(pos)
            if idx + 1 >= count { break }                      // starved
            let f = Float(pos - Double(idx))
            l[i] = bufL[idx] + (bufL[idx + 1] - bufL[idx]) * f
            r[i] = bufR[idx] + (bufR[idx + 1] - bufR[idx]) * f
            pos += ratio; i += 1
        }
        if i < frames {
            for j in i..<frames { l[j] = 0; r[j] = 0 }
            underruns += 1; primed = false                      // re-prime before resuming
        }
        // Drop consumed frames.
        let shift = min(Int(pos), count)
        if shift > 0 {
            let remain = count - shift
            if remain > 0 { memmove(bufL, bufL + shift, remain * MemoryLayout<Float>.size); memmove(bufR, bufR + shift, remain * MemoryLayout<Float>.size) }
            count = remain; pos -= Double(shift)
        }
    }
}
