import XCTest
import AVFoundation
@testable import MacAudioOo

final class DJTests: XCTestCase {
    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("MacAudioOoDJ-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }

    /// A real WAV file containing a sine tone.
    func makeTone(_ dir: URL, name: String, freq: Double, amp: Float = 0.5, seconds: Double = 12, rate: Int = 44100) throws -> URL {
        let url = dir.appendingPathComponent(name + ".wav")
        let w = try WAVWriter(url: url, sampleRate: rate)
        let x = (0..<Int(seconds * Double(rate))).map { amp * Float(sin(2 * Double.pi * freq * Double($0) / Double(rate))) }
        try x.withUnsafeBufferPointer { p in try w.write(left: p.baseAddress!, right: p.baseAddress!, frames: x.count) }
        try w.finalize()
        return url
    }

    /// Click track: short decaying 1 kHz bursts on every beat.
    func clickTrack(bpm: Double, offset: Double, seconds: Double, rate: Double, accentEvery: Int = 0) -> [Float] {
        var x = [Float](repeating: 0, count: Int(seconds * rate))
        let period = 60 / bpm
        var k = 0
        while true {
            let t = offset + Double(k) * period
            let start = Int(t * rate)
            if start >= x.count - 2000 { break }
            let amp: Float = (accentEvery > 0 && k % accentEvery != 0) ? 0.55 : 0.9
            for i in 0..<1500 { x[start + i] += amp * Float(sin(2 * Double.pi * 1000 * Double(i) / rate) * exp(-Double(i) / 300)) }
            k += 1
        }
        return x
    }

    func freq(_ s: ArraySlice<Float>, rate: Double) -> Double {
        let a = Array(s); var c = 0
        for i in 1..<a.count where (a[i - 1] < 0) != (a[i] < 0) { c += 1 }
        return Double(c) / 2 / (Double(a.count) / rate)
    }
    func rms(_ s: ArraySlice<Float>) -> Float { sqrtf(s.reduce(0) { $0 + $1 * $1 } / Float(max(1, s.count))) }

    // MARK: Beat grid / crossfader

    func testBeatGridMath() {
        let g = BeatGrid(bpm: 120, firstBeat: 0.25)
        XCTAssertEqual(g.beatDuration, 0.5, accuracy: 1e-9)
        XCTAssertEqual(g.time(ofBeat: 4), 2.25, accuracy: 1e-9)
        XCTAssertEqual(g.beatPosition(at: 1.25), 2, accuracy: 1e-9)
        XCTAssertEqual(g.phase(at: 1.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(g.nearestBeatTime(to: 1.4), 1.25, accuracy: 1e-9)
        XCTAssertEqual(g.nearestBeatTime(to: 1.6), 1.75, accuracy: 1e-9)
        XCTAssertEqual(g.loopLength(beats: 4), 2, accuracy: 1e-9)
        XCTAssertEqual(g.rateToMatch(targetBPM: 126), 1.05, accuracy: 1e-9)
        // Phase correction takes the short way around the beat.
        // Phase 0.9 -> 0.05 is +0.15 beat forward (0.075 s); phase 0.1 -> 0.95 is -0.15 beat back.
        XCTAssertEqual(g.phaseCorrection(from: 1.25 + 0.45, toMasterPhase: 0.05), 0.075, accuracy: 1e-9)
        XCTAssertEqual(g.phaseCorrection(from: 1.25 + 0.05, toMasterPhase: 0.95), -0.075, accuracy: 1e-9)
    }

    func testCrossfaderCurves() {
        let s0 = Crossfader.gains(position: -1, curve: .smooth), s1 = Crossfader.gains(position: 1, curve: .smooth)
        XCTAssertEqual(s0.left, 1, accuracy: 1e-6); XCTAssertEqual(s0.right, 0, accuracy: 1e-6)
        XCTAssertEqual(s1.left, 0, accuracy: 1e-6); XCTAssertEqual(s1.right, 1, accuracy: 1e-6)
        let c = Crossfader.gains(position: 0, curve: .smooth)
        XCTAssertEqual(c.left, 0.7071, accuracy: 1e-3); XCTAssertEqual(c.left * c.left + c.right * c.right, 1, accuracy: 1e-4)   // constant power
        let sharp = Crossfader.gains(position: 0, curve: .sharp)
        XCTAssertEqual(sharp.left, 1, accuracy: 1e-6); XCTAssertEqual(sharp.right, 1, accuracy: 1e-6)
        XCTAssertEqual(Crossfader.gains(position: 0.5, curve: .sharp).left, 0.5, accuracy: 1e-6)     // fades out only in the last quarter
        XCTAssertEqual(Crossfader.gain(for: .thru, position: 1, curve: .smooth), 1)
        XCTAssertEqual(Crossfader.gains(position: 9, curve: .smooth).right, 1, accuracy: 1e-6)         // clamped
    }

    // MARK: BPM analysis

    func testBPMDetectionOnSyntheticClickTracks() throws {
        for (bpm, offset) in [(124.0, 0.25), (90.0, 0.4), (150.0, 0.1), (100.0, 0.0)] {
            let rate = 44100.0
            let x = clickTrack(bpm: bpm, offset: offset, seconds: 40, rate: rate)
            let r = try XCTUnwrap(BPMAnalyzer.analyze(samples: x, sampleRate: rate), "\(bpm) BPM")
            XCTAssertEqual(r.bpm, bpm, accuracy: 0.6, "BPM \(bpm)")
            // Beat phase: the first detected beat must sit on the click grid.
            let period = 60 / bpm
            var d = (r.firstBeat - offset).truncatingRemainder(dividingBy: period)
            if d > period / 2 { d -= period } else if d < -period / 2 { d += period }
            XCTAssertEqual(d, 0, accuracy: 0.02, "phase of \(bpm) BPM (first beat \(r.firstBeat))")
        }
    }

    func testBPMDetectionWithOffbeatsAndAccents() throws {
        let rate = 44100.0
        var x = clickTrack(bpm: 128, offset: 0.2, seconds: 40, rate: rate, accentEvery: 4)
        let off = clickTrack(bpm: 128, offset: 0.2 + 60.0 / 128 / 2, seconds: 40, rate: rate)      // quieter off-beat hats
        for i in 0..<min(x.count, off.count) { x[i] += off[i] * 0.2 }
        let r = try XCTUnwrap(BPMAnalyzer.analyze(samples: x, sampleRate: rate))
        XCTAssertEqual(r.bpm, 128, accuracy: 1.0)
    }

    func testBPMAnalyzerRejectsTooShortOrSilentInput() {
        XCTAssertNil(BPMAnalyzer.analyze(samples: [Float](repeating: 0.1, count: 1000), sampleRate: 44100))
        XCTAssertNil(BPMAnalyzer.analyze(samples: [Float](repeating: 0, count: 44100 * 20), sampleRate: 44100))
    }

    func testBPMAnalyzerReadsAFile() throws {
        let dir = tempDir()
        let rate = 44100
        let x = clickTrack(bpm: 118, offset: 0.3, seconds: 30, rate: Double(rate))
        let url = dir.appendingPathComponent("clicks.wav")
        let w = try WAVWriter(url: url, sampleRate: rate)
        try x.withUnsafeBufferPointer { p in try w.write(left: p.baseAddress!, right: p.baseAddress!, frames: x.count) }
        try w.finalize()
        let r = try XCTUnwrap(BPMAnalyzer.analyze(url: url))
        XCTAssertEqual(r.bpm, 118, accuracy: 0.6)
    }

    // MARK: Waveform

    func testWaveformPeaksMatchTheFile() throws {
        let dir = tempDir()
        let url = try makeTone(dir, name: "w", freq: 200, amp: 0.8, seconds: 2)
        let w = try XCTUnwrap(WaveformData.compute(url: url, bucketFrames: 512))
        XCTAssertEqual(w.duration, 2, accuracy: 0.02)
        XCTAssertEqual(w.maxPeaks.max()!, 0.8, accuracy: 0.001)
        XCTAssertEqual(w.minPeaks.min()!, -0.8, accuracy: 0.001)
        let cols = w.columns(start: 0.5, length: 1, columns: 100)
        XCTAssertEqual(cols.count, 100)
        XCTAssertEqual(cols.map { $0.max }.max()!, 0.8, accuracy: 0.01)
        XCTAssertEqual(w.columns(start: 10, length: 1, columns: 5).map { $0.max }.max()!, 0)          // outside the track
    }

    // MARK: Library

    func testLibraryImportMetadataSearchSortFavoritesAndPlaylists() throws {
        let dir = tempDir()
        let a = try makeTone(dir, name: "Alpha Song", freq: 300, seconds: 3)
        let b = try makeTone(dir, name: "Beta Track", freq: 500, seconds: 5)
        try "not audio".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try Data(repeating: 1, count: 500).write(to: dir.appendingPathComponent("broken.wav"))
        let store = dir.appendingPathComponent("lib.json")
        let lib = MusicLibrary(storeURL: store)
        lib.importURLs([dir])
        for _ in 0..<50 where lib.importing || lib.tracks.isEmpty { spin(0.1) }
        spin(0.2)
        XCTAssertEqual(lib.tracks.count, 2)                                     // txt and corrupt wav skipped
        XCTAssertTrue((lib.lastImportMessage ?? "").contains("could not be played"))
        let ta = try XCTUnwrap(lib.track(forPath: a.path))
        XCTAssertEqual(ta.title, "Alpha Song")                                  // no tags: file name
        XCTAssertEqual(ta.artist, "Unknown Artist")
        XCTAssertEqual(ta.duration, 3, accuracy: 0.05)
        lib.importURLs([a]); spin(0.5)
        XCTAssertEqual(lib.tracks.count, 2)                                     // duplicate ignored

        let tb = try XCTUnwrap(lib.track(forPath: b.path))
        XCTAssertEqual(MusicLibrary.filter(lib.tracks, query: "beta").map { $0.title }, ["Beta Track"])
        XCTAssertEqual(MusicLibrary.filter(lib.tracks, query: "song alpha").count, 1)                 // all terms, any order
        XCTAssertEqual(MusicLibrary.filter(lib.tracks, query: "zzz").count, 0)
        XCTAssertEqual(MusicLibrary.sort(lib.tracks, by: .title, ascending: true).first?.title, "Alpha Song")
        XCTAssertEqual(MusicLibrary.sort(lib.tracks, by: .duration, ascending: false).first?.title, "Beta Track")

        lib.toggleFavorite(tb.id)
        XCTAssertEqual(lib.tracks(in: .favorites).map { $0.title }, ["Beta Track"])
        lib.markPlayed(ta.id, at: Date(timeIntervalSince1970: 100)); lib.markPlayed(tb.id, at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(lib.tracks(in: .recent).map { $0.title }, ["Beta Track", "Alpha Song"])        // most recent first
        lib.setAnalysis(ta.id, bpm: 124.5, firstBeat: 0.2)
        XCTAssertEqual(lib.track(id: ta.id)?.bpm, 124.5)
        XCTAssertEqual(MusicLibrary.sort(lib.tracks, by: .bpm, ascending: false).first?.title, "Alpha Song")

        let p = lib.createPlaylist(name: "Warmup")
        lib.add([ta.id, tb.id, ta.id], to: p.id)                                // duplicates ignored
        XCTAssertEqual(lib.tracks(in: .playlist(p.id)).map { $0.title }, ["Alpha Song", "Beta Track"])
        lib.remove([ta.id], from: p.id)
        XCTAssertEqual(lib.tracks(in: .playlist(p.id)).count, 1)

        spin(0.3)                                                               // let the background save finish
        let reloaded = MusicLibrary(storeURL: store)
        XCTAssertEqual(reloaded.tracks.count, 2)
        XCTAssertEqual(reloaded.playlists.first?.name, "Warmup")
        XCTAssertEqual(reloaded.tracks.first { $0.title == "Alpha Song" }?.bpm, 124.5)
        XCTAssertTrue(reloaded.tracks.first { $0.title == "Beta Track" }?.favorite ?? false)
        lib.remove([tb.id])
        XCTAssertEqual(lib.tracks(in: .playlist(p.id)).count, 0)                // removal also drops it from playlists
    }

    // MARK: DJ engine (offline rendering, no audio hardware)

    func makeDJ() -> DJEngine {
        DJEngine(manualFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!)
    }
    func track(_ url: URL, bpm: Double? = nil, firstBeat: Double? = nil) -> TrackMetadata {
        TrackMetadata(path: url.path, title: url.deletingPathExtension().lastPathComponent, artist: "t", album: "t", duration: 12, bpm: bpm, firstBeat: firstBeat)
    }

    func testTwoDecksPlayAndCrossfaderSelectsBetweenThem() throws {
        let dir = tempDir()
        let dj = makeDJ()
        let a = try makeTone(dir, name: "a", freq: 440), b = try makeTone(dir, name: "b", freq: 1320)
        dj.decks[0].load(track(a, bpm: 120, firstBeat: 0)); dj.decks[1].load(track(b, bpm: 120, firstBeat: 0))
        XCTAssertTrue(dj.decks[0].isLoaded && dj.decks[1].isLoaded)
        dj.decks[0].play(); dj.decks[1].play()
        _ = dj.renderOffline(frames: 22050)                                     // let both start
        dj.crossfader = -1; _ = dj.renderOffline(frames: 8192)
        let left = dj.renderOffline(frames: 44100)
        XCTAssertEqual(freq(left[4000...], rate: 44100), 440, accuracy: 15)      // only deck A
        dj.crossfader = 1; _ = dj.renderOffline(frames: 8192)
        let right = dj.renderOffline(frames: 44100)
        XCTAssertEqual(freq(right[4000...], rate: 44100), 1320, accuracy: 40)    // only deck B
        dj.crossfader = 0; _ = dj.renderOffline(frames: 8192)
        let both = dj.renderOffline(frames: 44100)
        XCTAssertGreaterThan(rms(both[4000...]), rms(left[4000...]) * 0.9)       // both decks are audible in the centre
        XCTAssertNil(dj.error)
    }

    func testDeckGainFilterAndMute() throws {
        let dir = tempDir()
        let dj = makeDJ()
        let hi = try makeTone(dir, name: "hi", freq: 6000, amp: 0.5)
        dj.decks[0].load(track(hi)); dj.decks[0].play()
        _ = dj.renderOffline(frames: 22050)
        let base = rms(dj.renderOffline(frames: 22050)[2000...])
        dj.decks[0].gainDB = -6; _ = dj.renderOffline(frames: 8192)
        XCTAssertEqual(20 * log10(rms(dj.renderOffline(frames: 22050)[2000...]) / base), -6, accuracy: 1.0)
        dj.decks[0].gainDB = 0
        dj.decks[0].filter = -1                                                  // low-pass sweep to ~200 Hz: a 6 kHz tone is removed
        _ = dj.renderOffline(frames: 8192)
        XCTAssertLessThan(rms(dj.renderOffline(frames: 22050)[2000...]), base * 0.05)
        dj.decks[0].filter = 0
        dj.decks[0].highDB = -15                                                 // HIGH shelf (corner 6 kHz): a tone AT the corner gets half the cut
        _ = dj.renderOffline(frames: 8192)
        let cut = rms(dj.renderOffline(frames: 22050)[2000...])
        XCTAssertLessThan(cut, base * 0.5)                                       // ≈ -7.5 dB at the corner
        XCTAssertGreaterThan(cut, base * 0.25)
        dj.decks[0].highDB = 0; dj.decks[0].channelFader = 0; _ = dj.renderOffline(frames: 8192)
        XCTAssertLessThan(rms(dj.renderOffline(frames: 22050)[2000...]), base * 0.001)
    }

    func testTimeStretchKeepsPitchWhenKeyLockIsOn() throws {
        let dir = tempDir()
        let dj = makeDJ()
        let t = try makeTone(dir, name: "t", freq: 880, seconds: 20)
        dj.decks[0].load(track(t)); dj.decks[0].play()
        dj.decks[0].tempoPercent = 8
        dj.decks[0].keyLock = true
        _ = dj.renderOffline(frames: 22050)
        XCTAssertEqual(freq(dj.renderOffline(frames: 44100)[2000...], rate: 44100), 880, accuracy: 20)      // pitch preserved
        dj.decks[0].keyLock = false
        _ = dj.renderOffline(frames: 22050)
        XCTAssertEqual(freq(dj.renderOffline(frames: 44100)[2000...], rate: 44100), 880 * 1.08, accuracy: 25) // pitch follows tempo
    }

    func testSyncMatchesTempoAndHotCuesLoopsAndSeek() throws {
        let dir = tempDir()
        let dj = makeDJ()
        let a = try makeTone(dir, name: "a", freq: 440), b = try makeTone(dir, name: "b", freq: 660)
        dj.decks[0].load(track(a, bpm: 120, firstBeat: 0)); dj.decks[1].load(track(b, bpm: 126, firstBeat: 0))
        dj.decks[0].play()
        dj.decks[1].sync(to: dj.decks[0])
        XCTAssertEqual(dj.decks[1].effectiveBPM ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(dj.decks[1].tempoPercent, (120.0 / 126 - 1) * 100, accuracy: 0.001)
        dj.decks[1].tempoPercent = 40; dj.decks[1].sync(to: dj.decks[0])
        XCTAssertEqual(dj.decks[1].tempoPercent, (120.0 / 126 - 1) * 100, accuracy: 0.001)                // not clamped when in range

        let d = dj.decks[0]
        d.seek(to: 3.1, resume: false)
        XCTAssertEqual(d.position, 3.1, accuracy: 0.001)
        d.hotCue(0)                                                              // sets a cue (quantized to the 120 BPM grid)
        let cue0 = try XCTUnwrap(d.hotCues[0])
        XCTAssertEqual(cue0, 3.0, accuracy: 0.001)
        d.seek(to: 8, resume: false); d.hotCue(0)
        XCTAssertEqual(d.position, 3.0, accuracy: 0.001)                          // jumped back to the cue
        d.clearHotCue(0); XCTAssertNil(d.hotCues[0])
        d.pause()
        d.seek(to: 2.2, resume: false)
        d.autoLoop(beats: 4)
        XCTAssertEqual(d.loop?.inTime ?? -1, 2.0, accuracy: 0.001)               // 4 beats at 120 BPM = 2 s
        XCTAssertEqual(d.loop?.outTime ?? -1, 4.0, accuracy: 0.001)
        XCTAssertTrue(d.loopActive)
        d.exitLoop()
        XCTAssertFalse(d.loopActive)
        XCTAssertEqual(d.cuePoint, 0)
        d.stop()
        XCTAssertEqual(d.position, 0, accuracy: 0.001)
        XCTAssertFalse(d.isPlaying)
    }
}
