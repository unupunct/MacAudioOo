import Foundation

struct DelayParams: Codable, Equatable {
    var enabled: Int32 = 0
    var returnLevel: Float = 1.0     // linear (the UI shows it in dB)
    var timeMs: Float = 375
    var feedback: Float = 0.35       // "repeats"; clamped to 0...0.85 so the loop can never run away
    var toneHz: Float = 6000         // low-pass cutoff in the feedback path: repeats get darker

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Keys.self)
        enabled = try c.decodeIfPresent(Int32.self, forKey: .enabled) ?? 0
        returnLevel = try c.decodeIfPresent(Float.self, forKey: .returnLevel) ?? 1.0
        timeMs = try c.decodeIfPresent(Float.self, forKey: .timeMs) ?? 375
        feedback = try c.decodeIfPresent(Float.self, forKey: .feedback) ?? 0.35
        toneHz = try c.decodeIfPresent(Float.self, forKey: .toneHz) ?? 6000
    }
    private enum Keys: String, CodingKey { case enabled, returnLevel, timeMs, feedback, toneHz }
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
        let lpCoef = 1 - expf(-2 * Float.pi * max(500, min(16000, p.toneHz)) / fs)    // one-pole low-pass cutoff
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
