import XCTest
@testable import MacAudioOo

final class SceneTests: XCTestCase {
    let sr = 48000.0

    func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date(timeIntervalSinceNow: s)) }
    func tempStore() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MacAudioOoScenes-\(UUID().uuidString)/scenes.json")
    }
    func makeEngine(_ names: [String]) -> (AudioEngine, [AudioChannel]) {
        let e = AudioEngine()
        return (e, names.compactMap { e.addChannel(name: $0, source: ChannelSource()) })
    }

    // MARK: Groups in the real-time mixer

    func toneSlot(_ m: AudioMixer, _ i: Int, group: Int32) {
        m.slots[i] = ChannelState(active: true, volumeTarget: 1, volumeCurrent: 1, balance: 0, mute: false, solo: false,
                                  peak: 0, rmsSquares: 0, rmsCount: 0,
                                  source: Unmanaged.passRetained(ToneSource(frequency: 800, amplitude: 0.4, sampleRate: Float(sr))),
                                  dsp: nil, gainReductionDB: 0, recRing: nil, group: group)
    }
    func render(_ m: AudioMixer, _ blocks: Int = 30) {
        var l = [Float](repeating: 0, count: 512), r = l
        for _ in 0..<blocks { l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            m.render(frames: 512, left: lp.baseAddress!, right: rp.baseAddress!) } } }
    }
    func peaks(_ m: AudioMixer) -> (Float, Float) {
        m.slots[0].peak = 0; m.slots[1].peak = 0; render(m, 10); return (m.slots[0].peak, m.slots[1].peak)
    }

    func testGroupMuteVolumeAndSoloActOnMembersOnly() {
        let m = AudioMixer(sampleRate: sr)
        m.master.pointee.limiterEnabled = false
        toneSlot(m, 0, group: 0); toneSlot(m, 1, group: -1)
        render(m)
        let base = peaks(m)
        m.groups[0].gain = dbToLinear(-12)                         // group fader
        render(m); var p = peaks(m)
        XCTAssertEqual(linearToDB(p.0) - linearToDB(base.0), -12, accuracy: 0.3)
        XCTAssertEqual(p.1, base.1, accuracy: 0.002)               // non-member unaffected
        m.groups[0].gain = 1; m.groups[0].mute = true              // group mute
        render(m); p = peaks(m)
        XCTAssertLessThan(p.0, 0.001); XCTAssertEqual(p.1, base.1, accuracy: 0.002)
        m.groups[0].mute = false; m.groups[0].solo = true          // group solo gates everything else
        render(m); p = peaks(m)
        XCTAssertEqual(p.0, base.0, accuracy: 0.002); XCTAssertLessThan(p.1, 0.001)
        m.groups[0].solo = false
        render(m); p = peaks(m)
        XCTAssertEqual(p.1, base.1, accuracy: 0.002)
    }

    func testLinkedGroupMovesAllMembersByTheSameAmount() {
        let (e, ch) = makeEngine(["A", "B", "C"])
        ch[0].group = 0; ch[1].group = 0; ch[2].group = 1
        ch[1].volumeDB = -10
        e.groups[0].linked = true
        ch[0].volumeDB = -6                                        // linked: B follows by the same -6 dB
        XCTAssertEqual(ch[1].volumeDB, -16, accuracy: 0.001)
        XCTAssertEqual(ch[2].volumeDB, 0, accuracy: 0.001)         // other group untouched
        e.groups[0].linked = false
        ch[0].volumeDB = -3
        XCTAssertEqual(ch[1].volumeDB, -16, accuracy: 0.001)       // unlinked: independent
        e.groups[0].linked = true
        ch[1].volumeDB = -60                                       // clamps at the bottom of the range
        XCTAssertEqual(ch[0].volumeDB, -3 + (-60 - -16), accuracy: 0.001)
    }

    // MARK: Snapshots and scenes

    func testSnapshotRoundTripRestoresEverything() throws {
        let (e, ch) = makeEngine(["Safari", "Music"])
        ch[0].volumeDB = -7; ch[0].balance = -0.4; ch[0].mute = true; ch[0].group = 2
        ch[0].eqGains[3] = 4; ch[0].comp.enabled = 1; ch[0].comp.thresholdDB = -25; ch[0].reverbSend = 0.3
        ch[1].solo = true; ch[1].delaySend = 0.6
        e.masterVolumeDB = -4; e.dim = true; e.mono = true; e.limiterThresholdDB = -6
        e.masterEQGains[5] = 3; e.reverb.roomSize = 0.9; e.delay.timeMs = 500; e.groups[2].volumeDB = -5; e.groups[2].linked = true
        let snap = MixerSnapshot.capture(from: e, outputUID: "UID-1")
        let decoded = try JSONDecoder().decode(MixerSnapshot.self, from: JSONEncoder().encode(snap))
        XCTAssertEqual(decoded, snap)                              // serializable without loss

        // Scramble, then restore.
        ch[0].volumeDB = 0; ch[0].mute = false; ch[0].group = -1; ch[0].eqGains = [Float](repeating: 0, count: 13)
        ch[1].solo = false; e.masterVolumeDB = 0; e.dim = false; e.reverb = ReverbParams(); e.groups = GroupState.defaults()
        XCTAssertNotEqual(MixerSnapshot.capture(from: e, outputUID: "UID-1"), snap)
        decoded.apply(to: e)
        XCTAssertEqual(MixerSnapshot.capture(from: e, outputUID: "UID-1"), snap)
        XCTAssertEqual(ch[0].volumeDB, -7, accuracy: 0.001)
        XCTAssertTrue(ch[0].mute)
        XCTAssertEqual(e.masterVolumeDB, -4, accuracy: 0.001)
    }

    func testSceneCreateRenameDuplicateDeleteAndPersistence() throws {
        let store = tempStore()
        let (e, _) = makeEngine([])
        let sm = SceneManager(engine: e, storeURL: store)
        XCTAssertEqual(sm.scenes.map { $0.name }, ["Work", "Gaming", "Movie Night", "Music", "Video Calls", "Podcast"])
        e.masterVolumeDB = -9
        let s = sm.create(name: "Evening")
        XCTAssertEqual(s.snapshot.master.volumeDB, -9, accuracy: 0.001)
        XCTAssertEqual(sm.create(name: "evening").name, "evening 2")          // names stay unique
        sm.rename(s, to: "Late")
        XCTAssertEqual(sm.scenes.first { $0.id == s.id }?.name, "Late")
        let copy = sm.duplicate(sm.scenes.first { $0.id == s.id }!)
        XCTAssertEqual(copy.name, "Late copy")
        XCTAssertEqual(copy.snapshot, s.snapshot)
        sm.delete(copy)
        XCTAssertNil(sm.scenes.first { $0.id == copy.id })
        let reloaded = SceneManager(engine: e, storeURL: store)             // persisted to disk
        XCTAssertEqual(reloaded.scenes.map { $0.name }, sm.scenes.map { $0.name })
        e.masterVolumeDB = 0
        reloaded.load(try XCTUnwrap(reloaded.scenes.first { $0.name == "Late" }))
        XCTAssertEqual(e.masterVolumeDB, -9, accuracy: 0.001)
    }

    func testBuiltInScenesApplyTheirMasterEQAndEffects() throws {
        let (e, _) = makeEngine([])
        let sm = SceneManager(engine: e, storeURL: tempStore())
        sm.load(try XCTUnwrap(sm.scenes.first { $0.name == "Movie Night" }))
        XCTAssertEqual(e.masterEQPresetName, "Cinema")
        XCTAssertEqual(Array(e.masterEQGains.prefix(10)), EQPresets.gains(named: "Cinema")!)
        XCTAssertEqual(e.reverb.enabled, 1)
        sm.load(try XCTUnwrap(sm.scenes.first { $0.name == "Gaming" }))
        XCTAssertEqual(e.reverb.enabled, 0)
    }

    func testSceneSettingsReachAnApplicationThatStartsLater() throws {
        let (e, ch) = makeEngine(["Spotify"])
        ch[0].volumeDB = -14; ch[0].eqGains[10] = 5; ch[0].group = 1
        let sm = SceneManager(engine: e, storeURL: tempStore())
        let scene = sm.create(name: "Music night")
        e.removeChannel(ch[0])                                              // the app quits
        spin(0.1)
        sm.load(scene)                                                      // Spotify is not running: remembered
        let again = try XCTUnwrap(e.addChannel(name: "Spotify", source: ChannelSource()))
        spin(0.2)                                                           // channel list change is delivered on the main queue
        XCTAssertEqual(again.volumeDB, -14, accuracy: 0.001)
        XCTAssertEqual(again.eqGains[10], 5, accuracy: 0.001)
        XCTAssertEqual(again.group, 1)
    }

    // MARK: Undo / redo

    func testUndoRedoOfMixerChanges() {
        let (e, ch) = makeEngine(["A"])
        let h = MixerHistory(engine: e, settle: 0.05)
        XCTAssertFalse(h.canUndo)
        ch[0].volumeDB = -3; ch[0].volumeDB = -6; ch[0].volumeDB = -9          // one drag = one step
        h.settled()
        XCTAssertTrue(h.canUndo); XCTAssertFalse(h.canRedo)
        e.masterVolumeDB = -5
        h.settled()
        h.undo()                                                              // undoes the master change only
        XCTAssertEqual(e.masterVolumeDB, 0, accuracy: 0.001)
        XCTAssertEqual(ch[0].volumeDB, -9, accuracy: 0.001)
        XCTAssertTrue(h.canRedo)
        spin(0.3)
        h.undo()                                                              // now the fader drag
        XCTAssertEqual(ch[0].volumeDB, 0, accuracy: 0.001)
        XCTAssertFalse(h.canUndo)
        spin(0.3)
        h.redo()
        XCTAssertEqual(ch[0].volumeDB, -9, accuracy: 0.001)
        spin(0.3)
        h.redo()
        XCTAssertEqual(e.masterVolumeDB, -5, accuracy: 0.001)
        XCTAssertFalse(h.canRedo)
        spin(0.3)
        h.undo(); spin(0.3)                                                   // a new change clears the redo stack
        ch[0].mute = true; h.settled()
        XCTAssertFalse(h.canRedo)
    }

    func testAddingAChannelIsNotAnUndoStep() {
        let (e, _) = makeEngine(["A"])
        let h = MixerHistory(engine: e, settle: 0.05)
        _ = e.addChannel(name: "B", source: ChannelSource())
        spin(0.05)
        h.settled()
        XCTAssertFalse(h.canUndo)
    }
}
