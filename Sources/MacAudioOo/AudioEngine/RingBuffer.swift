import Foundation
import Darwin

/// Lock-free single-producer / single-consumer stereo ring buffer.
/// A capture thread writes; the real-time render callback reads. No allocation
/// or locking after init. Indices are monotonic frame counters.
final class AudioRingBuffer {
    let capacity: Int            // frames, power of two
    private let mask: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let idx: UnsafeMutablePointer<Int>   // [0] = write, [1] = read
    private let underruns: UnsafeMutablePointer<Int>

    init(minimumFrames: Int) {
        var c = 1
        while c < minimumFrames { c <<= 1 }
        capacity = c; mask = c - 1
        left = .allocate(capacity: c); right = .allocate(capacity: c)
        left.initialize(repeating: 0, count: c); right.initialize(repeating: 0, count: c)
        idx = .allocate(capacity: 2); idx.initialize(repeating: 0, count: 2)
        underruns = .allocate(capacity: 1); underruns.initialize(to: 0)
    }
    deinit { left.deallocate(); right.deallocate(); idx.deallocate(); underruns.deallocate() }

    var availableToRead: Int { idx[0] - idx[1] }
    var underrunCount: Int { underruns.pointee }

    /// Producer side. Returns frames actually written (drops excess when full).
    @discardableResult
    func write(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, frames: Int) -> Int {
        let w = idx[0], rd = idx[1]
        let n = min(frames, capacity - (w - rd))
        if n <= 0 { return 0 }
        for i in 0..<n { left[(w + i) & mask] = l[i]; right[(w + i) & mask] = r[i] }
        OSMemoryBarrier()
        idx[0] = w + n
        return n
    }

    /// Consumer side (real-time safe). Zero-fills any shortfall and counts an underrun.
    @discardableResult
    func read(into l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let w = idx[0], rd = idx[1]
        OSMemoryBarrier()
        let n = min(frames, w - rd)
        if n > 0 { for i in 0..<n { l[i] = left[(rd + i) & mask]; r[i] = right[(rd + i) & mask] } }
        if n < frames {
            for i in max(n, 0)..<frames { l[i] = 0; r[i] = 0 }
            underruns.pointee += 1
        }
        OSMemoryBarrier()
        idx[1] = rd + max(n, 0)
        return max(n, 0)
    }
}
