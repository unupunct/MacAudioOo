import AppKit
import SwiftUI
import AVFoundation

/// Developer/documentation aid: renders MacAudioOo's own main window to a PNG and quits.
/// Only the app's window is captured (never the screen).
///   MacAudioOo --snapshot out.png [--tab console|classic|recording|dj|library|settings] [--demo-channels]
/// `--demo-channels` adds clearly-labelled generated test tones so the console has content.
enum SnapshotTool {
    static func argValue(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static func runIfRequested(state: AppState) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        let previousTab = state.settings.selectedTab
        if let t = args.firstIndex(of: "--tab"), t + 1 < args.count, let tab = AppTab(rawValue: args[t + 1].uppercased()) {
            state.settings.selectedTab = tab
        }
        // Show a neutral recording folder instead of the real home path (screenshots are published); restored afterwards.
        let previousRecordingDir = state.settings.recordingDirectory
        if let r = argValue("--recording-root") {
            state.recordingLibrary.setRoot(URL(fileURLWithPath: r))
            state.settings.recordingDirectory = argValue("--recording-label") ?? r
        }
        if args.contains("--demo-channels") { addDemoChannels(state) }
        var demoIDs = Set<UUID>()
        if args.contains("--demo-dj") { addDemoDJ(state) { demoIDs = $0 } }
        let delay = args.contains("--demo-dj") ? 7.0 : 2.5

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            defer {
                state.settings.selectedTab = previousTab
                state.settings.recordingDirectory = previousRecordingDir
                if !demoIDs.isEmpty { state.library.remove(demoIDs) }       // leave the user's library untouched
                NSApp.terminate(nil)
            }
            guard let view = NSApp.windows.first(where: { $0.contentView != nil })?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    /// Acceptance test 8: switch Console <-> Classic repeatedly while audio plays and verify the
    /// output callbacks kept arriving at the device's rate (no interruption).
    ///   MacAudioOo --switch-test result.txt
    static func runSwitchTestIfRequested(state: AppState) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--switch-test"), i + 1 < args.count else { return }
        let path = args[i + 1]
        addDemoChannels(state)
        let engine = state.engine
        var samples: [(Double, UInt64)] = []
        func sample() { samples.append((Date().timeIntervalSince1970, engine.callbackCount)) }
        let tabs: [AppTab] = [.console, .classic, .console, .classic, .console, .classic, .console]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            sample()
            for (n, tab) in tabs.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(n) * 0.5) { state.settings.selectedTab = tab; sample() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(tabs.count) * 0.5 + 0.3) {
                sample()
                let expectedPerSec = engine.sampleRate / Double(max(1, engine.bufferFrames))
                var worst = 0.0
                for k in 1..<samples.count {
                    let dt = samples[k].0 - samples[k - 1].0
                    let got = Double(samples[k].1 &- samples[k - 1].1)
                    if dt > 0.2 { worst = max(worst, abs(got / (dt * expectedPerSec) - 1)) }
                }
                let ok = engine.status.isRunning && worst < 0.15 && samples.last!.1 > samples.first!.1
                let text = "tab switches: \(tabs.count)\nexpected callbacks/s: \(Int(expectedPerSec))\nworst deviation: \(String(format: "%.1f", worst * 100))%\nresult: \(ok ? "PASS" : "FAIL")\n"
                try? text.write(toFile: path, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
    }

    /// Acceptance tests 9, 10 and 16 on real hardware: record the stereo mix and two armed stems from the running
    /// engine, then read the files back and check length, level and frequency.
    ///   MacAudioOo --record-test result.txt [--keep]
    static func runRecordTestIfRequested(state: AppState) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--record-test"), i + 1 < args.count else { return }
        let path = args[i + 1]
        let dir = argValue("--recording-root").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("MacAudioOo-record-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        state.recordingLibrary.setRoot(dir)
        let engine = state.engine
        let rate = Float(max(engine.sampleRate, 44100))
        let a = engine.addChannel(name: "Tone A", source: ToneSource(frequency: 440, amplitude: 0.3, sampleRate: rate))
        let b = engine.addChannel(name: "Tone B", source: ToneSource(frequency: 1000, amplitude: 0.2, sampleRate: rate))
        a?.recArm = true; b?.recArm = true
        a?.volumeDB = -6                                         // stems must ignore the fader, the mix must not
        var report = ""
        func line(_ s: String) { report += s + "\n" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            state.recorder.start()
            let cb0 = engine.callbackCount, t0 = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                let elapsedLive = state.recorder.elapsed
                line(String(format: "engine callbacks during the test: %llu in %.2f s wall clock (state %@)", engine.callbackCount &- cb0,
                            Date().timeIntervalSince(t0), String(describing: state.recorder.state)))
                line(String(format: "render load %.1f %%  worst block %.1f %% of its time  blocks over 80 %%: %llu  health %@", engine.cpuLoad * 100,
                            engine.worstBlockLoad * 100, engine.overBudgetBlocks, String(describing: engine.health)))
                if let lt = state.recorder.liveTracks.first { line("live track frames \(lt.frames) dropped \(lt.droppedFrames) error \(lt.error ?? "none")") }
                state.recorder.stop()
                line("engine: \(engine.status)  rate \(Int(engine.sampleRate))")
                line(String(format: "live elapsed before stop: %.2f s", elapsedLive))
                var ok = state.recorder.lastError == nil
                if let e = state.recorder.lastError { line("recorder message: \(e)") }
                let sessions = state.recordingLibrary.sessions
                guard let s = sessions.first else { line("no session found"); finish(false); return }
                line("session: \(s.info.name) tracks: \(s.info.tracks.map { $0.fileName })")
                func analyze(_ name: String) -> (frames: Int, peak: Float, freq: Double)? {
                    let url = s.folder.appendingPathComponent(name)
                    guard let f = try? AVAudioFile(forReading: url), f.length > 0,
                          let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { return nil }
                    guard (try? f.read(into: buf)) != nil, let d = buf.floatChannelData else { return nil }
                    let n = Int(buf.frameLength); let x = Array(UnsafeBufferPointer(start: d[0], count: n))
                    let mid = Array(x[(n / 8)..<(n - n / 8)])
                    var zc = 0; for k in 1..<mid.count where (mid[k - 1] < 0) != (mid[k] < 0) { zc += 1 }
                    return (n, mid.map { abs($0) }.max() ?? 0, Double(zc) / 2 / (Double(mid.count) / f.processingFormat.sampleRate))
                }
                for t in s.info.tracks {
                    guard let r = analyze(t.fileName) else { line("\(t.fileName): UNREADABLE"); ok = false; continue }
                    line(String(format: "%@: %d frames (%.2f s @48k) peak %.3f  dominant ≈ %.0f Hz  dropped %d", t.fileName, r.frames, Double(r.frames) / 48000, r.peak, r.freq, t.droppedFrames))
                    if abs(Double(r.frames) / 48000 - 4.0) > 0.4 { ok = false; line("  ^ length off") }
                    if t.droppedFrames > 0 { ok = false }
                    if t.fileName == "Tone A.wav", abs(r.freq - 440) > 6 || abs(r.peak - 0.3) > 0.01 { ok = false; line("  ^ stem A should be dry 440 Hz at 0.3 (fader -6 dB ignored)") }
                    if t.fileName == "Tone B.wav", abs(r.freq - 1000) > 12 || abs(r.peak - 0.2) > 0.01 { ok = false; line("  ^ stem B should be 1000 Hz at 0.2") }
                    if t.isMix, r.peak < 0.3 || r.peak > 0.6 { ok = false; line("  ^ mix peak implausible") }
                }
                finish(ok)
            }
        }
        func finish(_ ok: Bool) {
            line("result: \(ok ? "PASS" : "FAIL")")
            try? report.write(toFile: path, atomically: true, encoding: .utf8)
            if !args.contains("--keep") { try? FileManager.default.removeItem(at: dir) }
            NSApp.terminate(nil)
        }
    }

    /// Two synthetic 4-on-the-floor tracks (kick + hat), imported into the library and loaded on decks A and B, so
    /// the DJ and Library screens show real analysis results (BPM, beat grid, waveform) for known input.
    private static func addDemoDJ(_ state: AppState, onImported: @escaping (Set<UUID>) -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacAudioOo-demo-tracks")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func make(_ name: String, bpm: Double, hatLevel: Float) -> URL? {
            let rate = 44100, secs = 40
            var x = [Float](repeating: 0, count: rate * secs)
            let beat = 60 / bpm
            var seed: UInt32 = 7
            var k = 0
            while Double(k) * beat < Double(secs) - 1 {
                let t = 0.1 + Double(k) * beat
                let s0 = Int(t * Double(rate))
                for i in 0..<Int(0.3 * Double(rate)) where s0 + i < x.count {
                    let tau = Double(i) / Double(rate)
                    x[s0 + i] += Float(0.8 * exp(-tau / 0.08) * sin(2 * Double.pi * (50 + 110 * exp(-tau / 0.02)) * tau))
                }
                let h0 = s0 + Int(beat / 2 * Double(rate))
                for i in 0..<900 where h0 + i < x.count {
                    seed = seed &* 1664525 &+ 1013904223
                    x[h0 + i] += hatLevel * (Float(seed >> 8) / Float(1 << 24) * 2 - 1) * Float(exp(-Double(i) / 250))
                }
                k += 1
            }
            let url = dir.appendingPathComponent(name + ".wav")
            guard let w = try? WAVWriter(url: url, sampleRate: rate) else { return nil }
            do { try x.withUnsafeBufferPointer { p in try w.write(left: p.baseAddress!, right: p.baseAddress!, frames: x.count) }; try w.finalize() } catch { return nil }
            return url
        }
        guard let a = make("Demo Track A (synthetic 124 BPM)", bpm: 124, hatLevel: 0.25),
              let b = make("Demo Track B (synthetic 128 BPM)", bpm: 128, hatLevel: 0.3) else { return }
        state.library.importURLs([a, b]) {
            let ids = Set(state.library.tracks.filter { $0.path.contains("MacAudioOo-demo-tracks") || $0.title.hasPrefix("Demo Track") }.map { $0.id })
            onImported(ids)
            AppLog.shared.log("demo DJ: imported \(ids.count) tracks; a=\(state.library.track(forPath: a.path) != nil) b=\(state.library.track(forPath: b.path) != nil)")
            if let ta = state.library.track(forPath: a.path) { state.dj.decks[0].load(ta); state.dj.decks[0].seek(to: 5.2, resume: false) }
            if let tb = state.library.track(forPath: b.path) { state.dj.decks[1].load(tb); state.dj.decks[1].seek(to: 9.0, resume: false) }
        }
    }

    private static func addDemoChannels(_ state: AppState) {
        let engine = state.engine
        let rate = Float(max(engine.sampleRate, 44100))
        let specs: [(Float, Float, Float)] = [(220, -6, -0.3), (330, -14, 0.0), (440, -3, 0.4), (660, -22, 0.0)]
        for (f, vol, bal) in specs {
            let src = ToneSource(frequency: f, amplitude: 0.25, sampleRate: rate)
            if let ch = engine.addChannel(name: "Test tone \(Int(f)) Hz", source: src) {
                ch.volumeDB = vol; ch.balance = bal
            }
        }
        if let c = engine.channels.first {
            var g = c.eqGains; g[10] = 3; g[12] = -2; c.eqGains = g
            c.comp.enabled = 1; c.reverbSend = 0.35
        }
        if engine.channels.count > 2 { engine.channels[2].solo = false; engine.channels[2].mute = true }
    }
}
