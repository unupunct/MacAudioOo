import Foundation
import AVFoundation

struct BPMResult: Equatable {
    var bpm: Double
    var firstBeat: Double        // seconds
    var confidence: Double       // 0...1, peak-to-mean ratio of the tempo score (informational)
    var grid: BeatGrid { BeatGrid(bpm: bpm, firstBeat: firstBeat) }
}

/// Tempo and beat-grid estimation from mono samples.
///
/// Method: energy of 128-sample blocks → log-compressed positive onset function (mean-removed) →
/// autocorrelation over the allowed BPM range with a comb that rewards periodicity at 2x and 4x the beat
/// and a mild preference for 100–160 BPM → parabolic peak refinement → beat phase by maximizing the onset
/// energy collected on the grid. Assumes a roughly constant tempo (typical dance music); it is an
/// estimate, not ground truth, and can still pick a half/double-tempo reading for sparse material.
enum BPMAnalyzer {
    static let blockSize = 128

    static func analyze(samples: [Float], sampleRate: Double, minBPM: Double = 70, maxBPM: Double = 180) -> BPMResult? {
        guard sampleRate > 0, samples.count > Int(sampleRate * 8), minBPM > 20, maxBPM > minBPM else { return nil }
        let hop = blockSize
        let n = samples.count / hop
        let hopSec = Double(hop) / sampleRate

        // 1. Block energy -> log-compressed onset strength.
        var onset = [Double](repeating: 0, count: n)
        var prev = 0.0
        for b in 0..<n {
            var e: Float = 0
            let base = b * hop
            for i in 0..<hop { let x = samples[base + i]; e += x * x }
            let c = log(1 + 1000 * Double(e))
            onset[b] = max(0, c - prev); prev = c
        }
        // Remove the local mean (~0.5 s) so loud sections don't dominate.
        let w = max(1, Int(0.5 / hopSec)) | 1
        var out = onset, run = 0.0
        for i in 0..<n {
            run += onset[i]; if i >= w { run -= onset[i - w] }
            let mean = run / Double(min(i + 1, w))
            out[i] = max(0, onset[i] - mean)
        }
        // Smooth over ~±9 ms so each onset is a few blocks wide. Without this the autocorrelation at integer lags
        // depends heavily on how the (fractional) beat period happens to fall against one-block-wide spikes.
        let kernel: [Double] = [1, 2, 3, 4, 3, 2, 1].map { $0 / 16 }
        var smooth = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var s = 0.0
            for (j, w) in kernel.enumerated() { let k = i + j - 3; if k >= 0 && k < n { s += w * out[k] } }
            smooth[i] = s
        }
        onset = smooth

        // 2. Autocorrelation over the lags of interest (+ multiples for the comb).
        let lagMin = max(2, Int((60 / maxBPM / hopSec).rounded(.down)))
        let lagMax = Int((60 / minBPM / hopSec).rounded(.up))
        guard lagMax * 4 + 2 < n else { return nil }
        func acf(_ lag: Int) -> Double {
            var s = 0.0
            let m = n - lag
            var i = 0
            while i < m { s += onset[i] * onset[i + lag]; i += 1 }
            return s / Double(m)
        }
        var r = [Double](repeating: 0, count: lagMax * 4 + 2)
        for l in max(1, lagMin - 1)...(lagMax * 4 + 1) { r[l] = acf(l) }

        var best = 0.0, bestLag = lagMin, scoreSum = 0.0, count = 0.0
        var scores = [Double](repeating: 0, count: lagMax + 2)
        for l in lagMin...lagMax {
            let bpm = 60 / (Double(l) * hopSec)
            let pref = exp(-pow((bpm - 128) / 55, 2) / 2) * 0.3 + 0.7           // mild preference for 100–160 BPM
            let s = (r[l] + 0.5 * r[2 * l] + 0.25 * r[4 * l]) * pref
            scores[l] = s; scoreSum += s; count += 1
            if s > best { best = s; bestLag = l }
        }
        guard best > 0 else { return nil }

        // 3. Parabolic refinement of the autocorrelation peak around the best lag.
        var lag = Double(bestLag)
        if bestLag > lagMin, bestLag < lagMax {
            let a = scores[bestLag - 1], b = scores[bestLag], c = scores[bestLag + 1]
            let denom = a - 2 * b + c
            if denom != 0 { lag += 0.5 * (a - c) / denom }
        }
        // 4. Joint refinement of tempo and beat phase. The autocorrelation gives the period only to a fraction of a
        //    block; a 0.1 % period error would drift the grid by ~40 ms over a 40 s track. So search the period in two
        //    passes (±1 % in 0.1 % steps, then ±0.1 % in 0.01 % steps), each time choosing the phase that collects the
        //    most onset energy on the whole grid.
        func bestPhase(for period: Double) -> (phase: Double, score: Double) {
            var best = (phase: 0.0, score: -1.0)
            var phase = 0.0
            while phase < period {
                var s = 0.0, k = 0.0
                var pos = phase
                while pos < Double(n - 1) {
                    let i = Int(pos), f = pos - Double(i)
                    s += onset[i] * (1 - f) + onset[i + 1] * f
                    k += 1; pos += period
                }
                let avg = s / max(1, k)
                if avg > best.score { best = (phase, avg) }
                phase += 0.25
            }
            return best
        }
        var bestPeriod = lag, bestResult = bestPhase(for: lag)
        for step in [0.001, 0.0001] {
            let center = bestPeriod
            for k in -10...10 where k != 0 {
                let p = center * (1 + Double(k) * step)
                let r = bestPhase(for: p)
                if r.score > bestResult.score { bestResult = r; bestPeriod = p }
            }
        }
        let bpm = 60 / (bestPeriod * hopSec)
        let firstBeat = bestResult.phase * hopSec
        let mean = scoreSum / max(1, count)
        return BPMResult(bpm: bpm, firstBeat: firstBeat, confidence: min(1, max(0, 1 - mean / best)))
    }

    /// Decodes up to `maxSeconds` of the file to mono and analyzes it. Runs synchronously (call off the main thread).
    static func analyze(url: URL, maxSeconds: Double = 120, minBPM: Double = 70, maxBPM: Double = 180) -> BPMResult? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        let total = min(Int(file.length), Int(maxSeconds * rate))
        guard total > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else { return nil }
        var mono = [Float](); mono.reserveCapacity(total)
        let chans = Int(file.processingFormat.channelCount)
        while mono.count < total {
            do { try file.read(into: buf, frameCount: min(65_536, AVAudioFrameCount(total - mono.count))) } catch { break }
            let got = Int(buf.frameLength); if got == 0 { break }
            guard let d = buf.floatChannelData else { break }
            for i in 0..<got {
                var s: Float = 0
                for c in 0..<chans { s += d[c][i] }
                mono.append(s / Float(chans))
            }
        }
        return analyze(samples: mono, sampleRate: rate, minBPM: minBPM, maxBPM: maxBPM)
    }
}
