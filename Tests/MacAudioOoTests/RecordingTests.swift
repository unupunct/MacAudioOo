import XCTest
import AVFoundation
@testable import MacAudioOo

final class RecordingTests: XCTestCase {
    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("MacAudioOoTests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func sine(_ f: Double, amp: Float, rate: Double, seconds: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { amp * Float(sin(2 * Double.pi * f * Double($0) / rate)) }
    }

    func readWAV(_ url: URL) -> (samples: [Float], rate: Double, frames: Int)? {
        guard let f = try? AVAudioFile(forReading: url), f.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return nil }
        do { try f.read(into: buf) } catch { return nil }
        let n = Int(buf.frameLength)
        return ((0..<n).map { buf.floatChannelData![0][$0] }, f.processingFormat.sampleRate, n)
    }

    func frequency(_ s: [Float], rate: Double) -> Double {
        var c = 0; for i in 1..<s.count where (s[i - 1] < 0) != (s[i] < 0) { c += 1 }
        return Double(c) / 2 / (Double(s.count) / rate)
    }

    func testWAVHeaderAnd24BitEncoding() throws {
        let url = tempDir().appendingPathComponent("a.wav")
        let w = try WAVWriter(url: url, sampleRate: 48000)
        let l: [Float] = [1.0, -1.0, 0.5, 0], r: [Float] = [0, 0, 0, 0]
        try l.withUnsafeBufferPointer { lp in try r.withUnsafeBufferPointer { rp in try w.write(left: lp.baseAddress!, right: rp.baseAddress!, frames: 4) } }
        try w.finalize()
        let d = try Data(contentsOf: url)
        XCTAssertEqual(d.count, 44 + 4 * 6)
        XCTAssertEqual(String(data: d[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: d[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(d[20], 1)                                     // PCM
        XCTAssertEqual(d[22], 2)                                     // stereo
        XCTAssertEqual(Int(d[24]) | Int(d[25]) << 8 | Int(d[26]) << 16, 48000)
        XCTAssertEqual(d[34], 24)                                    // bits per sample
        XCTAssertEqual(Int(d[40]) | Int(d[41]) << 8, 24)             // data size
        XCTAssertEqual(Array(d[44..<47]), [0xFF, 0xFF, 0x7F])        //  +1.0 -> 0x7FFFFF
        XCTAssertEqual(Array(d[50..<53]), [0x01, 0x00, 0x80])        //  -1.0 -> 0x800001
        XCTAssertEqual(Array(d[56..<59]), [0x00, 0x00, 0x40])        //  +0.5 -> 0x400000
    }

    func testWrittenFileIsReadableByAVFoundationWithExpectedAudio() throws {
        let url = tempDir().appendingPathComponent("b.wav")
        let w = try WAVWriter(url: url, sampleRate: 48000)
        let x = sine(1000, amp: 0.5, rate: 48000, seconds: 1)
        try x.withUnsafeBufferPointer { p in try w.write(left: p.baseAddress!, right: p.baseAddress!, frames: x.count) }
        try w.finalize()
        let got = try XCTUnwrap(readWAV(url))
        XCTAssertEqual(got.frames, 48000)
        XCTAssertEqual(got.rate, 48000, accuracy: 0.1)
        XCTAssertEqual(got.samples[1234], x[1234], accuracy: 2e-7)
        XCTAssertEqual(frequency(got.samples, rate: 48000), 1000, accuracy: 1)
    }

    func testInterruptedFileIsRepairedExactly() throws {
        let url = tempDir().appendingPathComponent("c.wav")
        do {
            let w = try WAVWriter(url: url, sampleRate: 48000)
            let x = sine(440, amp: 0.4, rate: 48000, seconds: 2.5)           // header last refreshed at 2 s
            try x.withUnsafeBufferPointer { p in try w.write(left: p.baseAddress!, right: p.baseAddress!, frames: x.count) }
            // Simulated crash: no finalize(), plus a torn half-frame at the end of the file.
            let h = try FileHandle(forWritingTo: url); try h.seekToEnd(); try h.write(contentsOf: Data([1, 2, 3])); try h.close()
        }
        let frames = try WAVWriter.repairHeader(at: url)
        XCTAssertEqual(frames, 120_000)
        let got = try XCTUnwrap(readWAV(url))
        XCTAssertEqual(got.frames, 120_000)
        XCTAssertEqual(frequency(got.samples, rate: 48000), 440, accuracy: 1)
    }

    func testNonWAVIsRejectedByRepair() throws {
        let url = tempDir().appendingPathComponent("junk.wav")
        try Data(repeating: 7, count: 100).write(to: url)
        XCTAssertThrowsError(try WAVWriter.repairHeader(at: url))
    }

    func testTrackWriterAt48kIsBitTransparent() throws {
        let url = tempDir().appendingPathComponent("t48.wav")
        let t = try RecordingTrackWriter(name: "T", url: url, isMix: false, sourceRate: 48000)
        let x = sine(440, amp: 0.5, rate: 48000, seconds: 1)
        var i = 0
        while i < x.count { let n = min(4096, x.count - i); let c = Array(x[i..<(i + n)]); t.ingest(c, c, frames: n); i += n }
        try t.finish()
        let got = try XCTUnwrap(readWAV(url))
        XCTAssertEqual(got.frames, 48000)
        XCTAssertEqual(got.samples.map { abs($0) }.max()!, 0.5, accuracy: 0.001)
        XCTAssertEqual(frequency(got.samples, rate: 48000), 440, accuracy: 1)
        XCTAssertNil(t.error)
    }

    func testTrackWriterConvertsFrom44100To48000() throws {
        let url = tempDir().appendingPathComponent("t44.wav")
        let t = try RecordingTrackWriter(name: "T", url: url, isMix: true, sourceRate: 44100)
        let x = sine(1000, amp: 0.5, rate: 44100, seconds: 2)
        // Goes through the ring exactly as it does from the real-time mixer.
        var i = 0
        while i < x.count {
            let n = min(2048, x.count - i); let c = Array(x[i..<(i + n)])
            c.withUnsafeBufferPointer { p in _ = t.ring.write(p.baseAddress!, p.baseAddress!, frames: n) }
            t.drain(discard: false); i += n
        }
        try t.finish()
        let got = try XCTUnwrap(readWAV(url))
        XCTAssertEqual(Double(got.frames), 96000, accuracy: 600)               // 2 s at 48 kHz (± converter latency)
        let mid = Array(got.samples[4800..<(got.frames - 4800)])
        XCTAssertEqual(frequency(mid, rate: 48000), 1000, accuracy: 15)
        XCTAssertEqual(mid.map { abs($0) }.max()!, 0.5, accuracy: 0.03)
    }

    func testPausedAudioIsDiscardedAndOverflowIsCounted() throws {
        let url = tempDir().appendingPathComponent("p.wav")
        let t = try RecordingTrackWriter(name: "T", url: url, isMix: false, sourceRate: 48000, ringFrames: 1024)
        let x = [Float](repeating: 0.3, count: 512)
        x.withUnsafeBufferPointer { p in _ = t.ring.write(p.baseAddress!, p.baseAddress!, frames: 512) }
        t.drain(discard: true)
        XCTAssertEqual(t.framesWritten, 0)                                      // paused: nothing written
        x.withUnsafeBufferPointer { p in for _ in 0..<4 { _ = t.ring.write(p.baseAddress!, p.baseAddress!, frames: 512) } }
        XCTAssertGreaterThan(t.overflowedFrames, 0)                              // 2048 frames into a 1024-frame ring
        try t.finish()
    }

    func testWaveformPeaksComeFromTheWrittenAudio() throws {
        let url = tempDir().appendingPathComponent("w.wav")
        let t = try RecordingTrackWriter(name: "T", url: url, isMix: false, sourceRate: 48000)
        let quiet = [Float](repeating: 0.1, count: 4800), loud = [Float](repeating: 0.8, count: 4800)
        t.ingest(quiet, quiet, frames: 4800); t.ingest(loud, loud, frames: 4800)
        let peaks = t.recentPeaks(100)
        XCTAssertEqual(peaks.count, 20)                                          // 9600 frames / 480
        XCTAssertEqual(peaks[0].max, 0.1, accuracy: 1e-6)
        XCTAssertEqual(peaks[19].max, 0.8, accuracy: 1e-6)
        try t.finish()
        let o = WaveformOverview.compute(url: url, buckets: 2)
        XCTAssertEqual(o[0], 0.1, accuracy: 0.001); XCTAssertEqual(o[1], 0.8, accuracy: 0.001)
    }

    func testNamingDiskSpaceAndRates() {
        XCTAssertEqual(RecordingLibrary.fileName(for: "Spotify", existing: []), "Spotify.wav")
        XCTAssertEqual(RecordingLibrary.fileName(for: "Spotify", existing: ["spotify.wav"]), "Spotify 2.wav")
        XCTAssertEqual(RecordingLibrary.fileName(for: "a/b:c", existing: []), "a_b_c.wav")
        XCTAssertEqual(RecordingLibrary.fileName(for: "   ", existing: []), "Track.wav")
        XCTAssertEqual(RecordingLibrary.bytesPerSecond(tracks: 2), 576_000)
        let free = RecordingLibrary.availableBytes(at: tempDir().appendingPathComponent("not/yet/created"))
        XCTAssertNotNil(free)
        XCTAssertGreaterThan(free ?? 0, 0)
        let name = RecordingLibrary.sessionFolderName(for: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(name.hasPrefix("Recording 19"))
    }

    func testInterruptedSessionIsRecoveredOnNextLaunch() throws {
        let root = tempDir()
        let folder = root.appendingPathComponent("Recording 2026-01-01 10.00.00")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let planned = RecordingSessionInfo(id: folder.lastPathComponent, name: folder.lastPathComponent, startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                           sampleRate: 48000, bitDepth: 24,
                                           tracks: [RecordedTrackInfo(name: "Mix", fileName: "Mix.wav", frames: 0, droppedFrames: 0, isMix: true),
                                                    RecordedTrackInfo(name: "Safari", fileName: "Safari.wav", frames: 0, droppedFrames: 0, isMix: false)],
                                           recovered: false)
        try RecordingLibrary.encoder.encode(planned).write(to: folder.appendingPathComponent(RecordingLibrary.markerName))
        for (name, seconds) in [("Mix.wav", 1.5), ("Safari.wav", 1.2)] {
            let w = try WAVWriter(url: folder.appendingPathComponent(name), sampleRate: 48000)       // never finalized
            let x = sine(500, amp: 0.3, rate: 48000, seconds: seconds)
            try x.withUnsafeBufferPointer { p in try w.write(left: p.baseAddress!, right: p.baseAddress!, frames: x.count) }
        }
        let lib = RecordingLibrary(root: root)
        XCTAssertEqual(lib.recoverInterrupted(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(RecordingLibrary.markerName).path))
        lib.refresh()
        let s = try XCTUnwrap(lib.sessions.first)
        XCTAssertTrue(s.info.recovered)
        XCTAssertEqual(s.info.tracks.count, 2)
        XCTAssertEqual(s.info.tracks.first { $0.name == "Safari" }?.frames, 57_600)
        let mixWAV = try XCTUnwrap(readWAV(folder.appendingPathComponent("Mix.wav")))
        XCTAssertEqual(mixWAV.frames, 72_000)
        XCTAssertEqual(lib.recoverInterrupted(), 0)                                                  // nothing left to recover
    }

    // MARK: Real mixer taps

    func testStemTapIsDryPreFaderAndMixTapIsPostMaster() {
        let sr = 48000.0
        let m = AudioMixer(sampleRate: sr)
        m.master.pointee.limiterEnabled = false
        m.master.pointee.reverb.enabled = 1; m.master.pointee.reverb.returnLevel = 1
        let stemA = AudioRingBuffer(minimumFrames: 1 << 17), stemB = AudioRingBuffer(minimumFrames: 1 << 17), mix = AudioRingBuffer(minimumFrames: 1 << 17)
        let dspA = ChannelDSP(sampleRate: sr)
        dspA.fx.pointee.reverbSend = 1                                  // A feeds the shared reverb
        m.slots[0] = ChannelState(active: true, volumeTarget: dbToLinear(-20), volumeCurrent: dbToLinear(-20), balance: 0, mute: true, solo: false,
                                  peak: 0, rmsSquares: 0, rmsCount: 0,
                                  source: Unmanaged.passRetained(ToneSource(frequency: 500, amplitude: 0.5, sampleRate: Float(sr))),
                                  dsp: Unmanaged.passRetained(dspA), gainReductionDB: 0, recRing: Unmanaged.passRetained(stemA))
        m.slots[1] = ChannelState(active: true, volumeTarget: 1, volumeCurrent: 1, balance: 0, mute: false, solo: false,
                                  peak: 0, rmsSquares: 0, rmsCount: 0,
                                  source: Unmanaged.passRetained(ToneSource(frequency: 900, amplitude: 0.25, sampleRate: Float(sr))),
                                  dsp: nil, gainReductionDB: 0, recRing: Unmanaged.passRetained(stemB))
        m.master.pointee.mixRing = Unmanaged.passRetained(mix)
        var l = [Float](repeating: 0, count: 512), r = l
        for _ in 0..<60 { l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            m.render(frames: 512, left: lp.baseAddress!, right: rp.baseAddress!) } } }

        func drain(_ ring: AudioRingBuffer) -> [Float] {
            var out: [Float] = []
            var a = [Float](repeating: 0, count: 512), b = a
            while ring.availableToRead >= 512 { ring.read(into: &a, &b, frames: 512); out += a }
            return out
        }
        let a = drain(stemA), b = drain(stemB), mx = drain(mix)
        XCTAssertEqual(a.count, 60 * 512)
        // Stem A: muted AND at -20 dB on the fader, yet recorded dry at full level (pre-fader/mute).
        XCTAssertEqual(a.map { abs($0) }.max()!, 0.5, accuracy: 0.001)
        XCTAssertEqual(b.map { abs($0) }.max()!, 0.25, accuracy: 0.001)
        // The reverb is fed only post-fader (A is muted), so the stems contain no reverb either way,
        // and the mix (after all master processing) carries B only.
        let tail = Array(mx.suffix(4096))
        XCTAssertEqual(tail.map { abs($0) }.max()!, 0.25, accuracy: 0.05)
        XCTAssertEqual(mx.count, 60 * 512)
    }

    func testStemsNeverContainSharedEffects() {
        let sr = 48000.0
        let m = AudioMixer(sampleRate: sr)
        m.master.pointee.limiterEnabled = false
        m.master.pointee.reverb.enabled = 1; m.master.pointee.reverb.returnLevel = 1
        let stem = AudioRingBuffer(minimumFrames: 1 << 17), mix = AudioRingBuffer(minimumFrames: 1 << 17)
        let d = ChannelDSP(sampleRate: sr); d.fx.pointee.reverbSend = 1
        m.slots[0] = ChannelState(active: true, volumeTarget: 1, volumeCurrent: 1, balance: 0, mute: false, solo: false,
                                  peak: 0, rmsSquares: 0, rmsCount: 0,
                                  source: Unmanaged.passRetained(ToneSource(frequency: 500, amplitude: 0.5, sampleRate: Float(sr))),
                                  dsp: Unmanaged.passRetained(d), gainReductionDB: 0, recRing: Unmanaged.passRetained(stem))
        m.master.pointee.mixRing = Unmanaged.passRetained(mix)
        var l = [Float](repeating: 0, count: 512), r = l
        func render(_ n: Int) { for _ in 0..<n { l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            m.render(frames: 512, left: lp.baseAddress!, right: rp.baseAddress!) } } } }
        render(60)
        m.slots[0].mute = true                                      // dry stops; the reverb tail rings on in the MIX only
        var a = [Float](repeating: 0, count: 512), b = a
        while stem.availableToRead >= 512 { stem.read(into: &a, &b, frames: 512) }
        while mix.availableToRead >= 512 { mix.read(into: &a, &b, frames: 512) }
        render(8)
        var stemTail: Float = 0, mixTail: Float = 0
        while stem.availableToRead >= 512 { stem.read(into: &a, &b, frames: 512); stemTail = max(stemTail, a.map { abs($0) }.max()!) }
        while mix.availableToRead >= 512 { mix.read(into: &a, &b, frames: 512); mixTail = max(mixTail, a.map { abs($0) }.max()!) }
        XCTAssertEqual(stemTail, 0.5, accuracy: 0.001)              // stem is the dry tone only (no tail, no reverb added)
        XCTAssertGreaterThan(mixTail, 0.0005)                       // the mix contains the reverb return
    }
}
