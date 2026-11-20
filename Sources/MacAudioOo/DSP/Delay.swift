import Foundation

struct DelayParams {
    var enabled: Int32 = 1
    var returnLevel: Float = 0.5
    var timeMs: Float = 350
    var feedback: Float = 0.35       // clamped to 0...0.85 so the loop can never run away
    var tone: Float = 0.6            // 0 = dark ... 1 = bright (low-pass in the feedback path)
}

/// Stereo feedback delay. Delay time changes are smoothed; feedback is hard-limited below
/// unity; the feedback path is low-passed so repeats get darker.
final class DelayProcessor {
    static let maxSeconds: Float = 2.0
    private let fs: Float
    private let size: Int
    private let bufL: UnsafeMutablePointer<Float>
    private let bufR: UnsafeMutablePointer<Float>
    private var write = 0
    // Double: Float's resolution at ~5000 samples (0.0005) is larger than the final glide steps,
    // which made the delay stall half a sample short of its target.
    private var curDelay: Double
    private var lpL: Float = 0, lpR: Float = 0

    /// Current (smoothed) delay in samples; exposed for diagnostics and tests.
    var currentDelaySamples: Double { curDelay }

    init(sampleRate: Double) {
        fs = Float(sampleRate)
        size = Int(Self.maxSeconds * Float(sampleRate)) + 8
        bufL = .allocate(capacity: size); bufL.initialize(repeating: 0, count: size)
        bufR = .allocate(capacity: size); bufR.initialize(repeating: 0, count: size)
        curDelay = 0.35 * Double(sampleRate)
    }
    deinit { bufL.deallocate(); bufR.deallocate() }

    func process(input: UnsafePointer<Float>, outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>,
                 frames: Int, params p: DelayParams) {
        let target = Double(max(1, min(Self.maxSeconds * 1000, p.timeMs))) * 0.001 * Double(fs)
        let fb = max(0, min(0.85, p.feedback))
        let lpCoef = 0.05 + 0.95 * max(0, min(1, p.tone))
        var diff = target - curDelay
        if abs(diff) < 0.001 { curDelay = target; diff = 0 }
        let step = diff / Double(max(1, frames)) * 0.2                  // glide toward the new time
        for i in 0..<frames {
            curDelay += step
            var rp = Double(write) - curDelay
            if rp < 0 { rp += Double(size) }
            let i0 = Int(rp) % size, i1 = (i0 + 1) % size, fr = Float(rp - Double(Int(rp)))
            let dl = bufL[i0] + (bufL[i1] - bufL[i0]) * fr
            let dr = bufR[i0] + (bufR[i1] - bufR[i0]) * fr
            lpL += (dl - lpL) * lpCoef; lpR += (dr - lpR) * lpCoef
            // Cross-feed gives a light ping-pong spread.
            bufL[write] = input[i] + lpR * fb
            bufR[write] = input[i] + lpL * fb
            write = write + 1 >= size ? 0 : write + 1
            outL[i] = dl; outR[i] = dr
        }
    }
}
