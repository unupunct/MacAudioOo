import Foundation
import AVFoundation

/// Plays back a recorded WAV through the chosen output device (AVAudioPlayer with `currentDevice`),
/// and computes waveform overviews from the real file contents.
final class RecordingPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingURL: URL?
    @Published private(set) var progress: Double = 0           // 0...1
    @Published private(set) var error: String?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(url: URL, deviceUID: String?) {
        if playingURL == url { stop(); return }
        play(url: url, deviceUID: deviceUID)
    }

    func play(url: URL, deviceUID: String?) {
        stop(); error = nil
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            if let uid = deviceUID { p.currentDevice = uid }       // never the system default: avoids the virtual device loop
            p.delegate = self
            guard p.prepareToPlay(), p.play() else { error = "Could not start playback of \(url.lastPathComponent)."; return }
            player = p; playingURL = url
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self = self, let p = self.player else { return }
                self.progress = p.duration > 0 ? p.currentTime / p.duration : 0
            }
        } catch { self.error = "Playback failed: \(error.localizedDescription)" }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.stop(); player = nil
        playingURL = nil; progress = 0
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in self?.stop() }
    }
}

enum WaveformOverview {
    /// Max-abs amplitude (0...1) in `buckets` equal slices of the file, read from the actual samples.
    static func compute(url: URL, buckets: Int) -> [Float] {
        guard buckets > 0, let file = try? AVAudioFile(forReading: url), file.length > 0 else { return [] }
        let total = Int(file.length)
        var out = [Float](repeating: 0, count: buckets)
        let chunk: AVAudioFrameCount = 65_536
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return [] }
        var pos = 0
        while pos < total {
            do { try file.read(into: buf, frameCount: chunk) } catch { break }
            let n = Int(buf.frameLength); if n == 0 { break }
            guard let data = buf.floatChannelData else { break }
            let chans = Int(buf.format.channelCount)
            for i in 0..<n {
                var m: Float = 0
                for c in 0..<chans { m = max(m, abs(data[c][i])) }
                let b = min(buckets - 1, (pos + i) * buckets / total)
                if m > out[b] { out[b] = m }
            }
            pos += n
        }
        return out
    }
}
