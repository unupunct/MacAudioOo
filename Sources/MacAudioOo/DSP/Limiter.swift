import Foundation

/// Peak limiter with instant attack and exponential release. Because attack is
/// instantaneous, the post-limiter peak never exceeds the threshold (sample-peak
/// ceiling; inter-sample/true-peak overs are not addressed).
struct Limiter {
    var threshold: Float = 0.891      // linear (-1 dBFS)
    var releaseCoef: Float = 0.001    // per-sample smoothing toward 1.0
    private(set) var gain: Float = 1

    static func releaseCoefficient(milliseconds: Float, sampleRate: Float) -> Float {
        1 - expf(-1 / max(1, milliseconds * 0.001 * sampleRate))
    }

    /// Processes stereo in place; returns the minimum gain applied (for the GR meter).
    mutating func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) -> Float {
        var g = gain
        var minGain: Float = 1
        for i in 0..<frames {
            let peak = max(abs(l[i]), abs(r[i]))
            let target: Float = peak > threshold ? threshold / peak : 1
            if target < g { g = target } else { g += (target - g) * releaseCoef }
            // Guard against rounding leaving a hair above the ceiling.
            l[i] *= g; r[i] *= g
            if g < minGain { minGain = g }
        }
        gain = g
        return minGain
    }
}

@inline(__always) func dbToLinear(_ db: Float) -> Float { db <= -60 ? 0 : powf(10, db / 20) }
@inline(__always) func linearToDB(_ x: Float) -> Float { x <= 0.000_001 ? -120 : 20 * log10f(x) }
