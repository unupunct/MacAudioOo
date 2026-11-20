import Foundation

/// Something that produces stereo audio for a mixer channel. `pull` runs on the
/// real-time thread: it must not allocate, lock or block.
class ChannelSource {
    func pull(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames { l[i] = 0; r[i] = 0 }
    }
}

/// Reads audio written by a capture backend into an `AudioRingBuffer`.
final class RingSource: ChannelSource {
    let ring: AudioRingBuffer
    init(ring: AudioRingBuffer) { self.ring = ring }
    override func pull(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        ring.read(into: l, r, frames: frames)
    }
}

/// Generated sine tone for diagnostics and automated tests (a genuine test signal,
/// not a stand-in for application audio).
final class ToneSource: ChannelSource {
    var frequency: Float
    var amplitude: Float
    private var phase: Float = 0
    private let sampleRate: Float
    init(frequency: Float, amplitude: Float = 0.5, sampleRate: Float) {
        self.frequency = frequency; self.amplitude = amplitude; self.sampleRate = sampleRate
    }
    override func pull(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        let inc = 2 * Float.pi * frequency / sampleRate
        var p = phase
        for i in 0..<frames {
            let s = sinf(p) * amplitude
            l[i] = s; r[i] = s
            p += inc
            if p > 2 * Float.pi { p -= 2 * Float.pi }
        }
        phase = p
    }
}
