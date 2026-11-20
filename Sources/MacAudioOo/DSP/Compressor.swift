import Foundation

/// Compressor settings shared between UI (writer) and real-time thread (reader).
struct CompressorParams: Codable, Equatable {
    var enabled: Int32 = 0
    var thresholdDB: Float = -18
    var ratio: Float = 3
    var attackMs: Float = 10
    var releaseMs: Float = 120
    var makeupDB: Float = 0
    var kneeDB: Float = 6
    var grDB: Float = 0          // written by the render thread: gain reduction in dB (>= 0)

    static let presets: [(name: String, p: CompressorParams)] = [
        ("Gentle",  CompressorParams(enabled: 1, thresholdDB: -18, ratio: 2,  attackMs: 20, releaseMs: 200, makeupDB: 2)),
        ("Voice",   CompressorParams(enabled: 1, thresholdDB: -20, ratio: 3,  attackMs: 8,  releaseMs: 120, makeupDB: 4)),
        ("Music",   CompressorParams(enabled: 1, thresholdDB: -14, ratio: 2.5, attackMs: 15, releaseMs: 180, makeupDB: 2)),
        ("Limiting", CompressorParams(enabled: 1, thresholdDB: -10, ratio: 10, attackMs: 2,  releaseMs: 80,  makeupDB: 0)),
    ]
}

/// Stereo-linked feed-forward compressor with soft knee. Gain reduction is smoothed in the
/// dB domain with separate attack/release time constants.
struct Compressor {
    private(set) var reductionDB: Float = 0     // current smoothed reduction

    mutating func reset() { reductionDB = 0 }

    /// Processes in place; real-time safe. Returns the largest reduction (dB) in this block.
    mutating func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int,
                          params p: CompressorParams, sampleRate: Float) -> Float {
        let attack = 1 - expf(-1 / max(1, p.attackMs * 0.001 * sampleRate))
        let release = 1 - expf(-1 / max(1, p.releaseMs * 0.001 * sampleRate))
        let ratio = max(1, p.ratio), knee = max(0.001, p.kneeDB)
        let makeup = powf(10, p.makeupDB / 20)
        var red = reductionDB, maxRed: Float = 0
        for i in 0..<frames {
            let level = max(abs(l[i]), abs(r[i]), 1e-6)
            let over = 20 * log10f(level) - p.thresholdDB
            var target: Float
            if 2 * over < -knee { target = 0 }
            else if 2 * abs(over) <= knee { let x = over + knee / 2; target = (1 - 1 / ratio) * x * x / (2 * knee) }
            else { target = over * (1 - 1 / ratio) }
            red += (target - red) * (target > red ? attack : release)
            if red > maxRed { maxRed = red }
            let g = powf(10, -red / 20) * makeup
            l[i] *= g; r[i] *= g
        }
        reductionDB = red
        return maxRed
    }
}
