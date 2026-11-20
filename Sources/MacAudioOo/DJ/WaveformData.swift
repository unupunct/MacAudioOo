import Foundation
import AVFoundation

/// Min/max peak data of a whole track, computed from the decoded samples (never synthesized).
struct WaveformData: Equatable {
    var minPeaks: [Float]
    var maxPeaks: [Float]
    var bucketFrames: Int
    var sampleRate: Double

    var bucketCount: Int { maxPeaks.count }
    var duration: Double { Double(bucketCount * bucketFrames) / sampleRate }

    /// Peaks for the time window [start, start + length) rendered into `columns` columns.
    func columns(start: Double, length: Double, columns n: Int) -> [(min: Float, max: Float)] {
        guard n > 0, bucketCount > 0, length > 0 else { return [] }
        let bucketSec = Double(bucketFrames) / sampleRate
        return (0..<n).map { c in
            let t0 = start + length * Double(c) / Double(n), t1 = start + length * Double(c + 1) / Double(n)
            let b0 = Int((t0 / bucketSec).rounded(.down)), b1 = max(b0, Int((t1 / bucketSec).rounded(.up)) - 1)
            if b1 < 0 || b0 >= bucketCount { return (0, 0) }
            var lo: Float = 0, hi: Float = 0
            for b in max(0, b0)...min(bucketCount - 1, b1) { lo = min(lo, minPeaks[b]); hi = max(hi, maxPeaks[b]) }
            return (lo, hi)
        }
    }

    /// Reads the file once (off the main thread) and builds peak buckets of `bucketFrames` frames.
    static func compute(url: URL, bucketFrames: Int = 512) -> WaveformData? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else { return nil }
        var mins: [Float] = [], maxs: [Float] = []
        mins.reserveCapacity(Int(file.length) / bucketFrames + 1); maxs.reserveCapacity(mins.capacity)
        var lo: Float = 0, hi: Float = 0, filled = 0
        let chans = Int(file.processingFormat.channelCount)
        while file.framePosition < file.length {
            do { try file.read(into: buf, frameCount: 65_536) } catch { break }
            let n = Int(buf.frameLength); if n == 0 { break }
            guard let d = buf.floatChannelData else { break }
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<chans { s += d[c][i] }
                s /= Float(chans)
                lo = min(lo, s); hi = max(hi, s); filled += 1
                if filled == bucketFrames { mins.append(lo); maxs.append(hi); lo = 0; hi = 0; filled = 0 }
            }
        }
        if filled > 0 { mins.append(lo); maxs.append(hi) }
        return WaveformData(minPeaks: mins, maxPeaks: maxs, bucketFrames: bucketFrames, sampleRate: file.processingFormat.sampleRate)
    }
}
