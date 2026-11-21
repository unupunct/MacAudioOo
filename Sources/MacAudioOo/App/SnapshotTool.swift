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
        if args.contains("--select-first") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let c = state.engine.channels.first else { return }
                c.applyEQPreset("Music")                              // generated demo channel only
                EQSelection.shared.channelID = c.id
            }
        }
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

    // MARK: Real-driver test (used by scripts/driver-realtest.sh; changes the system output only on explicit request)

    /// `--query-output file` writes the current default output UID; `--set-output <uid|driver>` sets it and quits.
    static func runOutputToolsIfRequested(state: AppState) {
        if let f = argValue("--query-output") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                try? (state.devices.defaultOutputUID ?? "").write(toFile: f, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
        }
        if let uid = argValue("--set-output") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let target = uid == "driver" ? AudioDeviceManager.driverDeviceUID : uid
                let ok = state.devices.setDefaultOutput(uid: target)
                AppLog.shared.log("--set-output \(target): \(ok)")
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: Hot-plug, crash and quit tests (used by scripts/driver-crashtest.sh)

    /// `--probe-log file seconds`: appends one line per second (status, channels with live peaks, device, callbacks) and quits
    /// after `seconds` (0 = keep running). Lets an external script observe the app while it kills/quits other things.
    static func runProbeLogIfRequested(state: AppState) {
        guard let path = argValue("--probe-log") else { return }
        let seconds = Int(CommandLine.arguments.drop { $0 != "--probe-log" }.dropFirst(2).first ?? "0") ?? 0
        let engine = state.engine
        var n = 0
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { t in
            let chans = engine.channels.map { "\($0.name):" + String(format: "%.1f", $0.readMeter().peakDB) }.joined(separator: ",")
            let line = "\(Int(Date().timeIntervalSince1970))|\(engine.status.isRunning ? "running" : "not-running")|n=\(engine.channels.count)|\(chans)|dev=\(engine.currentDeviceUID ?? "-")|cb=\(engine.callbackCount)\n"
            if let h = FileHandle(forWritingAtPath: path) { _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8)); try? h.close() }
            else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
            n += 1
            if seconds > 0 && n >= seconds { t.invalidate(); NSApp.terminate(nil) }
        }
    }

    /// `--quit-restore-test`: sets the system output to the driver, then quits normally. With the opt-in setting on, the quit
    /// hook must put the previous output back (the calling script checks and resets the setting).
    static func runQuitRestoreTestIfRequested(state: AppState) {
        guard CommandLine.arguments.contains("--quit-restore-test") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            AppLog.shared.log("quit-restore-test: setting output to the driver, restore-on-quit = \(state.settings.restoreOutputOnQuit)")
            state.devices.setDefaultOutput(uid: AudioDeviceManager.driverDeviceUID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
        }
    }

    /// Output-device unplug/replug without hardware: a temporary aggregate output device (public Core Audio API) stands in for
    /// a USB/Bluetooth device. MacAudioOo plays through it, it is destroyed mid-playback (unplug), then recreated with the same
    /// UID (replug). A recording runs across the whole sequence.
    ///   MacAudioOo --hotplug-test report.txt
    static func runHotplugTestIfRequested(state: AppState) {
        guard let report = argValue("--hotplug-test") else { return }
        let engine = state.engine, devices = state.devices
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MacAudioOo-hotplug-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        state.recordingLibrary.setRoot(tempRoot)              // never write into the user's recordings folder
        var out = "", ok = true
        func line(_ s: String) { out += s + "\n" }
        func check(_ c: Bool, _ m: String) { line((c ? "PASS " : "FAIL ") + m); if !c { ok = false } }
        func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }
        func waitUntil(_ timeout: Double, _ cond: @escaping () -> Bool, _ then: @escaping (Bool, Double) -> Void) {
            let start = Date()
            func poll() {
                if cond() { then(true, Date().timeIntervalSince(start)) }
                else if Date().timeIntervalSince(start) > timeout { then(false, timeout) }
                else { after(0.1, poll) }
            }
            poll()
        }
        let aggUID = "com.unupunct.MacAudioOo.test.unpluggable"
        var aggID = AudioObjectID(0)
        func makeAggregate(_ builtinUID: String) -> Bool {
            let desc: [String: Any] = ["name": "MacAudioOo Test Output", "uid": aggUID, "master": builtinUID,
                                       "subdevices": [["uid": builtinUID]], "private": 0, "stacked": 0]
            return AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID) == noErr
        }
        func finish() {
            state.settings.outputDeviceUID = nil
            if aggID != 0 { AudioHardwareDestroyAggregateDevice(aggID) }
            line("result: \(ok ? "PASS" : "FAIL")")
            try? out.write(toFile: report, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        after(1.5) {
            guard engine.status.isRunning, let builtin = devices.outputDevices.first(where: { $0.transport == "Built-in" }) else {
                check(false, "engine running on a built-in output"); finish(); return
            }
            line("built-in output: \(builtin.name) (\(builtin.uid))")
            let tone = engine.addChannel(name: "Hotplug tone", source: ToneSource(frequency: 523, amplitude: 0.05, sampleRate: Float(max(44100, engine.sampleRate))))
            tone?.volumeDB = 0
            check(makeAggregate(builtin.uid), "temporary output device created (stands in for a USB/Bluetooth device)")
            waitUntil(6, { devices.outputDevices.contains { $0.uid == aggUID } }) { appeared, t in
                check(appeared, String(format: "it appears in the output device list (%.1f s)", t))
                guard appeared else { finish(); return }
                state.settings.outputDeviceUID = aggUID
                waitUntil(6, { engine.currentDeviceUID == aggUID && engine.status.isRunning }) { onAgg, t in
                    check(onAgg, String(format: "engine switched to the chosen device (%.1f s)", t))
                    let c0 = engine.callbackCount
                    state.recorder.recordMix = true
                    state.recorder.start()                       // records the mix across unplug and replug
                    after(1.5) {
                        check(engine.callbackCount > c0 + 20, "audio flows through the chosen device")
                        // --- unplug
                        let tUnplug = Date()
                        AudioHardwareDestroyAggregateDevice(aggID); aggID = 0
                        waitUntil(8, { engine.currentDeviceUID == builtin.uid && engine.status.isRunning }) { fell, t in
                            check(fell, String(format: "after unplug the engine falls back to the built-in output (%.1f s)", Date().timeIntervalSince(tUnplug)))
                            check(state.selectedOutputMissing, "the chosen device is reported as disconnected")
                            let c1 = engine.callbackCount
                            after(1.5) {
                                check(engine.callbackCount > c1 + 20, "audio keeps flowing on the fallback device")
                                // --- replug
                                let tReplug = Date()
                                _ = makeAggregate(builtin.uid)
                                waitUntil(10, { engine.currentDeviceUID == aggUID && engine.status.isRunning }) { back, _ in
                                    check(back, String(format: "after replug the engine returns to the chosen device by itself (%.1f s)", Date().timeIntervalSince(tReplug)))
                                    let c2 = engine.callbackCount
                                    after(1.5) {
                                        check(engine.callbackCount > c2 + 20, "audio flows again after replug")
                                        state.recorder.stop()
                                        analyzeRecording()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        func analyzeRecording() {
            if let e = state.recorder.lastError { line("recorder message: \(e)") }
            guard let s = state.recordingLibrary.sessions.first, let t = s.info.tracks.first,
                  let f = try? AVAudioFile(forReading: s.folder.appendingPathComponent(t.fileName)), f.length > 0,
                  let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
                  (try? f.read(into: buf)) != nil, let d = buf.floatChannelData else { check(false, "recording across the hot-plug is readable"); finish(); return }
            let n = Int(buf.frameLength), rate = f.processingFormat.sampleRate
            let x = UnsafeBufferPointer(start: d[0], count: n)
            // Longest run of digital silence = the audible gap caused by each device change.
            var longest = 0, run = 0
            for v in x { if abs(v) < 1e-5 { run += 1; longest = max(longest, run) } else { run = 0 } }
            line(String(format: "recording: %.2f s, longest silent gap %.0f ms, dropped %d", Double(n) / rate, Double(longest) / rate * 1000, t.droppedFrames))
            check(n > Int(rate * 3), "the recording continued across unplug and replug (\(String(format: "%.1f", Double(n) / rate)) s)")
            check(Double(longest) / rate < 2.0, "the gap caused by a device change stays under 2 s")
            check(t.droppedFrames == 0, "no frames dropped")
            if let h = state.recordingLibrary.sessions.first { try? FileManager.default.trashItem(at: h.folder, resultingItemURL: nil) }
            finish()
        }
    }

    /// Real applications through the real driver, end to end:
    ///   MacAudioOo --driver-test report.txt ready-file
    /// Sets the system output to the MacAudioOo driver, waits for two external players (started by the script once
    /// `ready-file` exists) to appear as two channels, checks volume/mute/solo independence on the live meters, records
    /// the stems, and restores the previous output. Only runs when explicitly invoked.
    static func runDriverTestIfRequested(state: AppState) {
        guard let report = argValue("--driver-test"), let ready = argValue("--driver-ready") else { return }
        let engine = state.engine
        var out = ""
        var ok = true
        func line(_ s: String) { out += s + "\n" }
        func check(_ cond: Bool, _ msg: String) { line((cond ? "PASS " : "FAIL ") + msg); if !cond { ok = false } }
        func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }
        let previous = state.devices.defaultOutputUID
        func finish() {
            if let p = previous, state.devices.systemDefaultIsDriver { state.devices.setDefaultOutput(uid: p) }
            line("system output restored to previous device: \(state.devices.defaultOutputUID == previous)")
            line("result: \(ok ? "PASS" : "FAIL")")
            try? out.write(toFile: report, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        after(1.5) {
            line("previous system output UID: \(previous ?? "none")")
            check(state.devices.driverDeviceLoaded, "driver device loaded by macOS")
            guard state.devices.driverDeviceLoaded, engine.status.isRunning else { finish(); return }
            check(state.devices.setDefaultOutput(uid: AudioDeviceManager.driverDeviceUID), "system output set to MacAudioOo Mixer")
            after(1.0) {
                check(state.devices.systemDefaultIsDriver, "system default is now the driver device")
                check(engine.currentDeviceUID == previous, "engine keeps playing through the real device (\(engine.currentDeviceUID ?? "?"))")
                try? "go".write(toFile: ready, atomically: true, encoding: .utf8)
                var waited = 0.0
                let maxWait = Double(argValue("--driver-wait") ?? "25") ?? 25
                func waitForChannels() {
                    if engine.channels.count >= 2 || waited > maxWait { channelsAppeared() } else { waited += 0.5; after(0.5, waitForChannels) }
                }
                after(1.0, waitForChannels)
            }
        }

        func peaks() -> [Float] { engine.channels.map { $0.readMeter().peakDB } }
        func channelsAppeared() {
            line("channels: \(engine.channels.map { "\($0.name)[pid \($0.pid.map(String.init) ?? "-")]" })")
            check(engine.channels.count == 2, "two external players appear as two channels (\(engine.channels.count))")
            if let expect = argValue("--driver-expect") {
                for want in expect.split(separator: ",").map({ String($0) }) {
                    check(engine.channels.contains { $0.name.localizedCaseInsensitiveContains(want) }, "a channel is named after the application \"\(want)\"")
                }
                line("channel icons present: \(engine.channels.map { $0.icon != nil })")
            }
            guard engine.channels.count >= 2 else { finish(); return }
            let c0 = engine.channels[0], c1 = engine.channels[1]
            _ = peaks()
            after(1.0) {
                let base = peaks()
                line("peaks (dB): \(base.map { String(format: "%.1f", $0) })")
                check(base.allSatisfy { $0 > -40 }, "both channels carry real audio")
                c0.volumeDB = -20
                after(1.2) {
                    _ = peaks(); after(1.0) {
                        let p = peaks()
                        check(abs((base[0] - p[0]) - 20) < 3, String(format: "lowering channel 1 by 20 dB drops its meter by %.1f dB", base[0] - p[0]))
                        check(abs(base[1] - p[1]) < 1.5, String(format: "channel 2 unchanged (%.1f dB change)", base[1] - p[1]))
                        c0.volumeDB = 0; c1.mute = true
                        after(1.2) {
                            _ = peaks(); after(0.8) {
                                let m = peaks()
                                check(m[1] < -80, String(format: "muting channel 2 silences it (%.1f dB)", m[1]))
                                check(abs(m[0] - base[0]) < 2, String(format: "channel 1 keeps playing at its level (%.1f dB)", m[0]))
                                c1.mute = false; c0.solo = true
                                after(1.2) {
                                    _ = peaks(); after(0.8) {
                                        let s = peaks()
                                        check(s[1] < -80 && s[0] > -40, "solo channel 1 silences channel 2")
                                        c0.solo = false
                                        recordStems()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        func recordStems() {
            for c in engine.channels { c.recArm = true }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacAudioOo-driver-test-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            state.recordingLibrary.setRoot(dir)
            state.recorder.start()
            after(3.0) {
                state.recorder.stop()
                if let e = state.recorder.lastError { line("recorder message: \(e)") }
                guard let s = state.recordingLibrary.sessions.first else { check(false, "recording session found"); finish(); return }
                /// Goertzel magnitude of `x` at `f` Hz (sample rate `rate`): how much of that tone the stem contains.
                func goertzel(_ x: [Float], _ f: Double, _ rate: Double) -> Double {
                    let w = 2 * Double.pi * f / rate, c = 2 * cos(w)
                    var s1 = 0.0, s2 = 0.0
                    for v in x { let s0 = Double(v) + c * s1 - s2; s2 = s1; s1 = s0 }
                    return (s1 * s1 + s2 * s2 - c * s1 * s2).squareRoot() * 2 / Double(x.count)
                }
                var dominant: [String] = []
                for t in s.info.tracks {
                    let url = s.folder.appendingPathComponent(t.fileName)
                    guard let f = try? AVAudioFile(forReading: url), f.length > 0,
                          let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
                          (try? f.read(into: buf)) != nil, let d = buf.floatChannelData else { check(false, "\(t.fileName) readable"); continue }
                    let n = Int(buf.frameLength); let a = Array(Array(UnsafeBufferPointer(start: d[0], count: n))[(n / 8)..<(n - n / 8)])
                    let rate = f.processingFormat.sampleRate
                    let m440 = goertzel(a, 440, rate), m660 = goertzel(a, 660, rate)
                    let pk = a.map { abs($0) }.max() ?? 0
                    line(String(format: "%@: %.2f s  peak %.3f  level@440 Hz %.3f  level@660 Hz %.3f  dropped %d", t.fileName, Double(n) / 48000, pk, m440, m660, t.droppedFrames))
                    if !t.isMix {
                        check(pk > 0.05 && t.droppedFrames == 0, "\(t.fileName): real audio, nothing dropped")
                        dominant.append(m440 > m660 * 5 ? "440" : (m660 > m440 * 5 ? "660" : "mixed"))
                    }
                }
                check(Set(dominant) == ["440", "660"], "each stem carries exactly one of the two source tones, no leakage (\(dominant))")
                try? FileManager.default.removeItem(at: dir)
                finish()
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
