import Foundation

/// Reverb parameters (shared effect). Read by the render thread, written by the UI.
struct ReverbParams: Codable, Equatable {
    var enabled: Int32 = 1
    var returnLevel: Float = 0.5     // linear gain of the wet return into the master bus
    var roomSize: Float = 0.5        // 0...1 : scales the delay-line lengths (0.6x ... 1.4x)
    var decaySeconds: Float = 1.8    // RT60
    var tone: Float = 0.6            // 0 = dark ... 1 = bright (comb damping)
}

/// Freeverb-style reverb: 8 parallel damped comb filters per side into 4 series all-pass
/// filters, with a stereo spread. Comb feedback is derived from the requested RT60 so decay
/// time is meaningful and always < 1 (unconditionally stable). All buffers are allocated at
/// init; `process` does no allocation.
final class ReverbProcessor {
    private static let combBase: [Int] = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    private static let allpassBase: [Int] = [556, 441, 341, 225]
    private static let spread = 23
    private static let maxScale: Float = 1.4

    private let fs: Float
    private let combCount = 8, apCount = 4
    private var combBuf: [UnsafeMutablePointer<Float>] = []     // [side*8 + i]
    private var combLen: [Int] = []                               // current lengths
    private var combMax: [Int] = []
    private var combIdx: [Int] = []
    private var combLP: [Float] = []
    private var apBuf: [UnsafeMutablePointer<Float>] = []
    private var apLen: [Int] = []
    private var apIdx: [Int] = []
    private var scaleStep = -1
    private var feedback = [Float](repeating: 0.8, count: 16)
    private var lastDecay: Float = -1

    init(sampleRate: Double) {
        fs = Float(sampleRate)
        let k = Float(sampleRate) / 44100
        for side in 0..<2 {
            for i in 0..<combCount {
                let base = Int(Float(Self.combBase[i] + side * Self.spread) * k)
                let maxLen = Int(Float(base) * Self.maxScale) + 4
                let p = UnsafeMutablePointer<Float>.allocate(capacity: maxLen); p.initialize(repeating: 0, count: maxLen)
                combBuf.append(p); combMax.append(maxLen); combLen.append(base); combIdx.append(0); combLP.append(0)
            }
            for i in 0..<apCount {
                let len = Int(Float(Self.allpassBase[i] + side * Self.spread) * k)
                let p = UnsafeMutablePointer<Float>.allocate(capacity: len); p.initialize(repeating: 0, count: len)
                apBuf.append(p); apLen.append(len); apIdx.append(0)
            }
        }
    }
    deinit { combBuf.forEach { $0.deallocate() }; apBuf.forEach { $0.deallocate() } }

    private func baseLength(side: Int, comb i: Int) -> Int {
        Int(Float(Self.combBase[i] + side * Self.spread) * fs / 44100)
    }

    private func update(params p: ReverbParams) {
        let step = Int(max(0, min(1, p.roomSize)) * 16)
        if step != scaleStep {
            scaleStep = step
            let scale = 0.6 + 0.8 * Float(step) / 16
            for side in 0..<2 { for i in 0..<combCount {
                let n = side * combCount + i
                let len = min(combMax[n] - 2, max(8, Int(Float(baseLength(side: side, comb: i)) * scale)))
                combLen[n] = len
                if combIdx[n] >= len { combIdx[n] = 0 }
            } }
            lastDecay = -1
        }
        let decay = max(0.1, min(10, p.decaySeconds))
        if decay != lastDecay {
            lastDecay = decay
            for n in 0..<16 {
                // RT60: gain per trip so that after `decay` seconds the level is -60 dB.
                let g = powf(10, -3 * Float(combLen[n]) / (fs * decay))
                feedback[n] = min(0.985, g)
            }
        }
    }

    /// `input`: mono send bus. Writes the wet signal (no return level applied) to outL/outR.
    func process(input: UnsafePointer<Float>, outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>,
                 frames: Int, params p: ReverbParams) {
        update(params: p)
        let damp = (1 - max(0, min(1, p.tone))) * 0.7
        let inGain: Float = 0.03
        for i in 0..<frames {
            let x = input[i] * inGain
            var sums: (Float, Float) = (0, 0)
            for side in 0..<2 {
                var acc: Float = 0
                for c in 0..<combCount {
                    let n = side * combCount + c
                    let idx = combIdx[n]
                    let y = combBuf[n][idx]
                    combLP[n] = y * (1 - damp) + combLP[n] * damp
                    combBuf[n][idx] = x + combLP[n] * feedback[n]
                    combIdx[n] = idx + 1 >= combLen[n] ? 0 : idx + 1
                    acc += y
                }
                for a in 0..<apCount {
                    let n = side * apCount + a
                    let idx = apIdx[n]
                    let buffered = apBuf[n][idx]
                    let out = -acc + buffered
                    apBuf[n][idx] = acc + buffered * 0.5
                    apIdx[n] = idx + 1 >= apLen[n] ? 0 : idx + 1
                    acc = out
                }
                if side == 0 { sums.0 = acc } else { sums.1 = acc }
            }
            outL[i] = sums.0; outR[i] = sums.1
        }
    }
}
