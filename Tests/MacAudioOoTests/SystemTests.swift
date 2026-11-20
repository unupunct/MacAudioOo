import XCTest
@testable import MacAudioOo

final class SystemTests: XCTestCase {
    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("MacAudioOoSys-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    func makeEngine(_ names: [String]) -> (AudioEngine, [AudioChannel]) {
        let e = AudioEngine()
        return (e, names.compactMap { e.addChannel(name: $0, source: ChannelSource()) })
    }

    // MARK: Ducking

    func testTriggerMatchingUsesNameOrBundleIDCaseInsensitively() {
        let d = DuckingConfig().triggerApps
        XCTAssertEqual(d, ["FaceTime", "zoom.us", "Zoom", "Microsoft Teams", "Discord", "Slack"])
        XCTAssertTrue(DuckingLogic.matches(d, name: "FaceTime", bundleID: nil))
        XCTAssertTrue(DuckingLogic.matches(d, name: "zoom.us", bundleID: "us.zoom.xos"))
        XCTAssertTrue(DuckingLogic.matches(d, name: "Helper", bundleID: "com.hnc.Discord.helper"))
        XCTAssertTrue(DuckingLogic.matches(d, name: "SLACK", bundleID: nil))
        XCTAssertFalse(DuckingLogic.matches(d, name: "Spotify", bundleID: "com.spotify.client"))
        XCTAssertFalse(DuckingLogic.matches([""], name: "Anything", bundleID: nil))
        XCTAssertFalse(DuckingLogic.matches([], name: "Anything", bundleID: nil))
    }

    func testDuckingStepHasAttackAndReleaseTimeConstants() {
        var v: Float = 0
        for _ in 0..<30 { v = DuckingLogic.step(current: v, target: 12, dt: 0.01, attackMs: 100, releaseMs: 1000) }   // 300 ms
        XCTAssertGreaterThan(v, 12 * 0.9)                                   // ~95 % after 3 time constants of the fast attack
        let afterAttack = v
        for _ in 0..<30 { v = DuckingLogic.step(current: v, target: 0, dt: 0.01, attackMs: 100, releaseMs: 1000) }    // 300 ms release
        XCTAssertGreaterThan(v, afterAttack * 0.6)                          // release is much slower
        XCTAssertLessThan(v, afterAttack)
        XCTAssertEqual(DuckingLogic.step(current: 11.995, target: 12, dt: 0.01, attackMs: 100, releaseMs: 100), 12)    // snaps when close
    }

    func testDuckingLowersOnlyBackgroundAppsWhileATriggerIsReallySpeaking() {
        let (e, ch) = makeEngine(["Zoom", "Spotify", "Safari", "Music"])
        let suite = UserDefaults(suiteName: "MacAudioOoDuck-\(UUID().uuidString)")!
        let d = DuckingController(engine: e, defaults: suite)
        var level: Float = -90                                              // Zoom's own audio level
        d.levelProvider = { $0.name == "Zoom" ? level : -20 }
        d.bundleIDProvider = { _ in nil }
        d.config.enabled = true
        d.config.excludedApps = ["Music"]
        d.config.reductionDB = 12; d.config.attackMs = 50; d.config.releaseMs = 400; d.config.triggerThresholdDB = -45

        for _ in 0..<40 { d.tick(dt: 0.02) }                                // silence on the call: nothing happens
        XCTAssertFalse(d.triggerActive)
        XCTAssertEqual(ch[1].duckGain, 1, accuracy: 1e-4)

        level = -30                                                         // speech starts
        for _ in 0..<40 { d.tick(dt: 0.02) }
        XCTAssertTrue(d.triggerActive)
        let expected = dbToLinear(-12)
        XCTAssertEqual(ch[1].duckGain, expected, accuracy: 0.01)            // Spotify ducked
        XCTAssertEqual(ch[2].duckGain, expected, accuracy: 0.01)            // Safari ducked
        XCTAssertEqual(ch[0].duckGain, 1, accuracy: 1e-4)                   // the call itself is never ducked
        XCTAssertEqual(ch[3].duckGain, 1, accuracy: 1e-4)                   // excluded app untouched

        level = -90                                                         // speech stops: gain returns, slowly
        d.tick(dt: 0.02)
        XCTAssertLessThan(ch[1].duckGain, 0.5)
        for _ in 0..<150 { d.tick(dt: 0.02) }
        XCTAssertEqual(ch[1].duckGain, 1, accuracy: 0.01)
        XCTAssertFalse(d.triggerActive)
    }

    func testManualDuckWorksWithoutAnyTriggerAndDisabledDuckingDoesNothing() {
        let (e, ch) = makeEngine(["Zoom", "Spotify"])
        let d = DuckingController(engine: e, defaults: UserDefaults(suiteName: "MacAudioOoDuck-\(UUID().uuidString)")!)
        d.levelProvider = { _ in 0 }                                        // loud everywhere, but ducking is disabled
        d.bundleIDProvider = { _ in nil }
        for _ in 0..<30 { d.tick(dt: 0.02) }
        XCTAssertEqual(ch[1].duckGain, 1, accuracy: 1e-4)
        d.config.manualDuck = true; d.config.reductionDB = 18; d.config.attackMs = 20
        for _ in 0..<60 { d.tick(dt: 0.02) }
        XCTAssertEqual(ch[1].duckGain, dbToLinear(-18), accuracy: 0.01)
        XCTAssertEqual(ch[0].duckGain, 1, accuracy: 1e-4)                   // trigger apps are not ducked by manual duck either
    }

    func testDuckGainReachesTheRealTimeMixer() {
        let sr = 48000.0
        let m = AudioMixer(sampleRate: sr)
        m.master.pointee.limiterEnabled = false
        m.slots[0] = ChannelState(active: true, volumeTarget: 1, volumeCurrent: 1, balance: 0, mute: false, solo: false,
                                  peak: 0, rmsSquares: 0, rmsCount: 0,
                                  source: Unmanaged.passRetained(ToneSource(frequency: 500, amplitude: 0.5, sampleRate: Float(sr))))
        var l = [Float](repeating: 0, count: 512), r = l
        func render(_ n: Int) { for _ in 0..<n { l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            m.render(frames: 512, left: lp.baseAddress!, right: rp.baseAddress!) } } } }
        render(20); m.slots[0].peak = 0; render(5)
        let base = m.slots[0].peak
        m.slots[0].duckGain = dbToLinear(-12); render(20); m.slots[0].peak = 0; render(5)
        XCTAssertEqual(linearToDB(m.slots[0].peak) - linearToDB(base), -12, accuracy: 0.3)
        XCTAssertGreaterThan(m.slots[0].inputRmsCount, 0)                   // pre-fader level for triggers is measured
        XCTAssertEqual(m.slots[0].inputRmsSquares / m.slots[0].inputRmsCount, 0.5 * 0.5 / 2, accuracy: 0.01)
    }

    // MARK: Login item, log, config backup

    func testLoginItemWritesAndRemovesAValidLaunchAgent() throws {
        let url = tempDir().appendingPathComponent("agent.plist")
        XCTAssertNil(LoginItem.set(true, bundlePath: "/Applications/MacAudioOo.app", url: url))
        let d = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil) as? [String: Any])
        XCTAssertEqual(d["Label"] as? String, LoginItem.label)
        XCTAssertEqual(d["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(d["ProgramArguments"] as? [String], ["/usr/bin/open", "-g", "-a", "/Applications/MacAudioOo.app"])
        XCTAssertNil(LoginItem.set(false, bundlePath: "", url: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(LoginItem.set(false, bundlePath: "", url: url))        // removing twice is harmless
    }

    func testLogWritesToFileAndRotates() {
        let dir = tempDir()
        let log = AppLog(fileURL: dir.appendingPathComponent("test.log"))
        log.log("hello"); log.log("world")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        let text = (try? String(contentsOf: dir.appendingPathComponent("test.log"))) ?? ""
        XCTAssertTrue(text.contains("hello") && text.contains("world"))
        XCTAssertEqual(log.lines.count, 2)
        log.clear()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertEqual(log.lines.count, 0)
        XCTAssertEqual((try? String(contentsOf: dir.appendingPathComponent("test.log"))) ?? "x", "")
    }

    func testConfigurationExportAndImportRoundTrip() throws {
        let suiteA = UserDefaults(suiteName: "MacAudioOoCfgA-\(UUID().uuidString)")!
        let a = AppSettings(defaults: suiteA)
        a.theme = .light; a.defaultTab = .dj; a.djFourDecks = true; a.bpmMin = 85; a.djTempoRange = 16; a.bufferFrames = 256
        a.libraryFolder = "/Users/x/Music"; a.outputDeviceUID = "UID-9"
        let scenes = SceneManager.defaultScenes()
        var duck = DuckingConfig(); duck.enabled = true; duck.reductionDB = 20; duck.excludedApps = ["Music"]
        let data = try ConfigBackup.export(settings: a, scenes: scenes, ducking: duck, defaults: suiteA)

        let suiteB = UserDefaults(suiteName: "MacAudioOoCfgB-\(UUID().uuidString)")!
        let b = AppSettings(defaults: suiteB)
        XCTAssertEqual(b.theme, .dark)
        let imported = try ConfigBackup.importData(data, into: b)
        XCTAssertEqual(b.theme, .light); XCTAssertEqual(b.defaultTab, .dj); XCTAssertTrue(b.djFourDecks)
        XCTAssertEqual(b.bpmMin, 85, accuracy: 0.001); XCTAssertEqual(b.djTempoRange, 16, accuracy: 0.001)
        XCTAssertEqual(b.bufferFrames, 256); XCTAssertEqual(b.libraryFolder, "/Users/x/Music"); XCTAssertEqual(b.outputDeviceUID, "UID-9")
        XCTAssertEqual(imported.scenes.map { $0.name }, scenes.map { $0.name })
        XCTAssertEqual(imported.scenes, scenes)
        XCTAssertEqual(imported.ducking, duck)
        XCTAssertEqual(AppSettings(defaults: suiteB).theme, .light)              // persisted, not just in memory
        XCTAssertThrowsError(try ConfigBackup.importData(Data("{\"app\":\"other\"}".utf8), into: b))
        XCTAssertThrowsError(try ConfigBackup.importData(Data("garbage".utf8), into: b))
    }
}
