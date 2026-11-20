import Foundation

/// Normalized biquad coefficients (a0 = 1). Filter designs follow the RBJ audio-EQ cookbook.
struct BiquadCoefficients {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    static let identity = BiquadCoefficients()

    private static func normalized(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> BiquadCoefficients {
        BiquadCoefficients(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0), a1: Float(a1 / a0), a2: Float(a2 / a0))
    }

    static func peaking(frequency f: Double, gainDB: Double, q: Double, sampleRate fs: Double) -> BiquadCoefficients {
        let f = min(f, fs * 0.45)
        let A = pow(10, gainDB / 40), w0 = 2 * Double.pi * f / fs
        let alpha = sin(w0) / (2 * q), c = cos(w0)
        return normalized(1 + alpha * A, -2 * c, 1 - alpha * A, 1 + alpha / A, -2 * c, 1 - alpha / A)
    }

    static func lowShelf(frequency f: Double, gainDB: Double, sampleRate fs: Double) -> BiquadCoefficients {
        let A = pow(10, gainDB / 40), w0 = 2 * Double.pi * min(f, fs * 0.45) / fs
        let c = cos(w0), s = sqrt(A), alpha = sin(w0) / 2 * 2.0.squareRoot()
        return normalized(A * ((A + 1) - (A - 1) * c + 2 * s * alpha),
                          2 * A * ((A - 1) - (A + 1) * c),
                          A * ((A + 1) - (A - 1) * c - 2 * s * alpha),
                          (A + 1) + (A - 1) * c + 2 * s * alpha,
                          -2 * ((A - 1) + (A + 1) * c),
                          (A + 1) + (A - 1) * c - 2 * s * alpha)
    }

    static func highShelf(frequency f: Double, gainDB: Double, sampleRate fs: Double) -> BiquadCoefficients {
        let A = pow(10, gainDB / 40), w0 = 2 * Double.pi * min(f, fs * 0.45) / fs
        let c = cos(w0), s = sqrt(A), alpha = sin(w0) / 2 * 2.0.squareRoot()
        return normalized(A * ((A + 1) + (A - 1) * c + 2 * s * alpha),
                          -2 * A * ((A - 1) + (A + 1) * c),
                          A * ((A + 1) + (A - 1) * c - 2 * s * alpha),
                          (A + 1) - (A - 1) * c + 2 * s * alpha,
                          2 * ((A - 1) - (A + 1) * c),
                          (A + 1) - (A - 1) * c - 2 * s * alpha)
    }

    /// Magnitude response in dB at `frequency`.
    func magnitudeDB(at frequency: Double, sampleRate fs: Double) -> Double {
        let w = 2 * Double.pi * frequency / fs
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = Double(b0) + Double(b1) * c1 + Double(b2) * c2, ni = -(Double(b1) * s1 + Double(b2) * s2)
        let dr = 1 + Double(a1) * c1 + Double(a2) * c2, di = -(Double(a1) * s1 + Double(a2) * s2)
        let mag = sqrt((nr * nr + ni * ni) / max(1e-30, dr * dr + di * di))
        return 20 * log10(max(1e-12, mag))
    }
}
