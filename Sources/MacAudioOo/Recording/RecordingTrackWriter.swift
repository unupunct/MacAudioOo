import Foundation
import AVFoundation

/// Min/max sample values of one 10 ms bucket of recorded audio (for the live waveform).
struct WaveformPeak: Equatable { var min: Float; var max: Float }

/// Writes one track to a 48 kHz / 24-bit WAV file. Audio arrives from a lock-free ring filled by
/// the real-time mixer; this class runs on the recorder queue (never on the audio thread).
/// If the engine's sample rate is not 48 kHz the audio is converted with AVAudioConverter.
final class RecordingTrackWriter {
    static let outputRate = 48_000
    static let bucketFrames = 480                       // 10 ms at 48 kHz

    let name: String
    let url: URL
    let isMix: Bool
    let ring: AudioRingBuffer
    let sourceRate: Double
    private let wav: WAVWriter
    private let converter: AVAudioConverter?
    private let inFormat: AVAudioFormat?
    private let outFormat: AVAudioFormat?

    private let lock = NSLock()
    private var peaks: [WaveformPeak] = []
    private var bucketMin: Float = 0, bucketMax: Float = 0, bucketCount = 0
    private(set) var error: String?
    private var chunkL = [Float](repeating: 0, count: 4096), chunkR = [Float](repeating: 0, count: 4096)

    init(name: String, url: URL, isMix: Bool, sourceRate: Double, ringFrames: Int = 1 << 17) throws {
        self.name = name; self.url = url; self.isMix = isMix; self.sourceRate = sourceRate
        ring = AudioRingBuffer(minimumFrames: ringFrames)
        wav = try WAVWriter(url: url, sampleRate: Self.outputRate)
        if Int(sourceRate.rounded()) != Self.outputRate {
            let i = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 2, interleaved: false)!
            let o = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.outputRate), channels: 2, interleaved: false)!
            inFormat = i; outFormat = o; converter = AVAudioConverter(from: i, to: o)
        } else { inFormat = nil; outFormat = nil; converter = nil }
    }

    var framesWritten: Int64 { wav.framesWritten }
    var overflowedFrames: Int { ring.overflowedFrames }

    /// Moves everything currently in the ring into the file (or discards it while paused).
    func drain(discard: Bool) {
        while ring.availableToRead > 0 {
            let n = min(ring.availableToRead, chunkL.count)
            chunkL.withUnsafeMutableBufferPointer { l in chunkR.withUnsafeMutableBufferPointer { r in
                ring.read(into: l.baseAddress!, r.baseAddress!, frames: n) } }
            if !discard { ingest(chunkL, chunkR, frames: n) }
        }
    }

    /// Converts (if needed), writes and measures `frames` frames of source-rate audio.
    func ingest(_ l: [Float], _ r: [Float], frames: Int) {
        guard error == nil, frames > 0 else { return }
        do {
            if let conv = converter, let inF = inFormat, let outF = outFormat {
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(frames)),
                      let outBuf = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: AVAudioFrameCount(Double(frames) * outF.sampleRate / inF.sampleRate) + 64)
                else { return }
                inBuf.frameLength = AVAudioFrameCount(frames)
                for i in 0..<frames { inBuf.floatChannelData![0][i] = l[i]; inBuf.floatChannelData![1][i] = r[i] }
                var supplied = false
                var convError: NSError?
                conv.convert(to: outBuf, error: &convError) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true; status.pointee = .haveData; return inBuf
                }
                if let e = convError { error = "Sample-rate conversion failed: \(e.localizedDescription)"; return }
                let n = Int(outBuf.frameLength)
                if n > 0 {
                    let ol = UnsafePointer(outBuf.floatChannelData![0]), or = UnsafePointer(outBuf.floatChannelData![1])
                    try wav.write(left: ol, right: or, frames: n)
                    measure(ol, or, n)
                }
            } else {
                try l.withUnsafeBufferPointer { lp in try r.withUnsafeBufferPointer { rp in
                    try wav.write(left: lp.baseAddress!, right: rp.baseAddress!, frames: frames)
                    measure(lp.baseAddress!, rp.baseAddress!, frames)
                } }
            }
        } catch {
            self.error = "Writing \(url.lastPathComponent) failed: \(error.localizedDescription)"
        }
    }

    private func measure(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int) {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<n {
            let v = max(l[i], r[i]), w = min(l[i], r[i])
            if bucketCount == 0 { bucketMin = w; bucketMax = v } else { bucketMin = min(bucketMin, w); bucketMax = max(bucketMax, v) }
            bucketCount += 1
            if bucketCount >= Self.bucketFrames {
                peaks.append(WaveformPeak(min: bucketMin, max: bucketMax)); bucketCount = 0
            }
        }
    }

    /// The most recent `count` peak buckets (thread-safe).
    func recentPeaks(_ count: Int) -> [WaveformPeak] {
        lock.lock(); defer { lock.unlock() }
        return Array(peaks.suffix(count))
    }

    func finish() throws {
        drain(discard: false)
        try wav.finalize()
    }
}
