import XCTest
@testable import MacAudioOo

/// Offline tests that drive the real mixer with generated test signals.
final class MixerTests: XCTestCase {
    let sr = 48000.0
    let block = 512

    /// Adds a tone channel directly into the mixer's slot and returns its index.
    func addTone(_ m: AudioMixer, slot: Int, freq: Float = 1000, amp: Float = 0.5) {
        let src = ToneSource(frequency: freq, amplitude: amp, sampleRate: Float(sr))
        m.slots[slot] = ChannelState(active: true, volumeTarget: 1, volumeCurrent: 1, balance: 0, mute: false, solo: false,
                                     peak: 0, rmsSquares: 0, rmsCount: 0, source: Unmanaged.passRetained(src))
    }

    /// Renders `blocks` blocks; returns the last block's output.
    @discardableResult
    func run(_ m: AudioMixer, blocks: Int = 40) -> (l: [Float], r: [Float]) {
        var l = [Float](repeating: 0, count: block), r = l
        for _ in 0..<blocks { l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            m.render(frames: block, left: lp.baseAddress!, right: rp.baseAddress!) } } }
        return (l, r)
    }

    func peak(_ m: AudioMixer, slot: Int) -> Float {
        let p = m.slots[slot].peak; m.slots[slot].peak = 0; return p
    }

    func testDBConversion() {
        XCTAssertEqual(dbToLinear(0), 1, accuracy: 1e-6)
        XCTAssertEqual(dbToLinear(-6.0206), 0.5, accuracy: 1e-3)
        XCTAssertEqual(dbToLinear(-80), 0, accuracy: 0)
        XCTAssertEqual(linearToDB(1), 0, accuracy: 1e-4)
    }

    func testLoweringChannelAFollowsDBAndDoesNotChangeB() {
        let m = AudioMixer(sampleRate: sr)
        addTone(m, slot: 0); addTone(m, slot: 1)
        m.master.pointee.limiterEnabled = false
        run(m); let bBefore = peak(m, slot: 1); _ = peak(m, slot: 0)
        m.slots[0].volumeTarget = dbToLinear(-12)
        run(m); _ = peak(m, slot: 0); _ = peak(m, slot: 1)
        run(m)
        let a = peak(m, slot: 0), b = peak(m, slot: 1)
        XCTAssertEqual(linearToDB(a), linearToDB(0.5) - 12, accuracy: 0.3)
        XCTAssertEqual(b, bBefore, accuracy: 0.002)
    }

    func testMuteSilencesOnlyThatChannel() {
        let m = AudioMixer(sampleRate: sr)
        addTone(m, slot: 0); addTone(m, slot: 1)
        m.slots[0].mute = true
        run(m); _ = peak(m, slot: 0); _ = peak(m, slot: 1)
        let out = run(m)
        XCTAssertLessThan(peak(m, slot: 0), 0.0005)
        XCTAssertGreaterThan(peak(m, slot: 1), 0.45)
        XCTAssertGreaterThan(out.l.map { abs($0) }.max()!, 0.4)   // B still reaches the output
    }

    func testSoloGatesOtherChannels() {
        let m = AudioMixer(sampleRate: sr)
        addTone(m, slot: 0); addTone(m, slot: 1)
        m.slots[1].solo = true
        run(m); _ = peak(m, slot: 0); _ = peak(m, slot: 1)
        run(m)
        XCTAssertLessThan(peak(m, slot: 0), 0.0005)
        XCTAssertGreaterThan(peak(m, slot: 1), 0.45)
        m.slots[1].solo = false
        run(m); _ = peak(m, slot: 0)
        run(m)
        XCTAssertGreaterThan(peak(m, slot: 0), 0.45)   // un-solo restores everything
    }

    func testGainChangesAreSmoothed() {
        let m = AudioMixer(sampleRate: sr)
        addTone(m, slot: 0, freq: 100, amp: 0.8)
        m.master.pointee.limiterEnabled = false
        run(m)
        m.slots[0].mute = true
        var l = [Float](repeating: 0, count: block), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            m.render(frames: block, left: lp.baseAddress!, right: rp.baseAddress!) } }
        var maxStep: Float = 0
        for i in 1..<block { maxStep = max(maxStep, abs(l[i] - l[i - 1])) }
        XCTAssertLessThan(maxStep, 0.06)       // a hard cut from 0.8 would step by up to 0.8
        // ~10 ms time constant: still fading after one 10.7 ms block, silent after a few more.
        XCTAssertLessThan(abs(l[block - 1]), 0.5)
        let settled = run(m, blocks: 10)
        XCTAssertLessThan(settled.l.map { abs($0) }.max()!, 0.001)
    }

    func testBalanceHardRightSilencesLeft() {
        let m = AudioMixer(sampleRate: sr)
        addTone(m, slot: 0)
        m.slots[0].balance = 1
        run(m)
        let out = run(m)
        XCTAssertLessThan(out.l.map { abs($0) }.max()!, 0.0005)
        XCTAssertGreaterThan(out.r.map { abs($0) }.max()!, 0.4)
    }

    func testMasterVolumeMuteDimMono() {
        let m = AudioMixer(sampleRate: sr)
        addTone(m, slot: 0, amp: 0.5)
        m.master.pointee.limiterEnabled = false
        m.master.pointee.volumeTarget = dbToLinear(-6.0206)
        run(m)
        XCTAssertEqual(run(m).l.map { abs($0) }.max()!, 0.25, accuracy: 0.01)
        m.master.pointee.dim = true
        run(m)
        XCTAssertEqual(run(m).l.map { abs($0) }.max()!, 0.025, accuracy: 0.004)
        m.master.pointee.dim = false; m.master.pointee.mute = true
        run(m)
        XCTAssertLessThan(run(m).l.map { abs($0) }.max()!, 0.001)
        // Mono: balance hard right leaves L = 0, mono monitoring makes both = (L+R)/2.
        m.master.pointee.mute = false; m.master.pointee.volumeTarget = 1
        m.slots[0].balance = 1; m.master.pointee.mono = true
        run(m)
        let out = run(m)
        XCTAssertEqual(out.l.map { abs($0) }.max()!, out.r.map { abs($0) }.max()!, accuracy: 0.001)
        XCTAssertEqual(out.l.map { abs($0) }.max()!, 0.25, accuracy: 0.02)
    }

    func testLimiterNeverExceedsThreshold() {
        let m = AudioMixer(sampleRate: sr)
        addTone(m, slot: 0, amp: 0.9); addTone(m, slot: 1, freq: 1300, amp: 0.9)
        m.master.pointee.limiterEnabled = true
        m.master.pointee.limiterThreshold = dbToLinear(-6)
        var worst: Float = 0
        var l = [Float](repeating: 0, count: block), r = l
        for _ in 0..<60 {
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                m.render(frames: block, left: lp.baseAddress!, right: rp.baseAddress!) } }
            worst = max(worst, l.map { abs($0) }.max()!, r.map { abs($0) }.max()!)
        }
        XCTAssertLessThan(worst, dbToLinear(-6) + 0.001)
        XCTAssertLessThan(m.master.pointee.limiterGain, 1)
    }

    func testRingBufferIntegrityAcrossWrapAndUnderrun() {
        let ring = AudioRingBuffer(minimumFrames: 64)
        var next: Float = 0
        var expect: Float = 0
        var ok = true
        for _ in 0..<50 {
            let l = (0..<40).map { _ in next += 1; return next }
            XCTAssertEqual(ring.write(l, l, frames: 40), 40)
            var ol = [Float](repeating: 0, count: 40), or = ol
            XCTAssertEqual(ring.read(into: &ol, &or, frames: 40), 40)
            for v in ol { expect += 1; if v != expect { ok = false } }
        }
        XCTAssertTrue(ok)
        var ol = [Float](repeating: 9, count: 8), or = ol
        XCTAssertEqual(ring.read(into: &ol, &or, frames: 8), 0)       // empty -> underrun
        XCTAssertEqual(ol.max()!, 0)                                  // zero-filled
        XCTAssertEqual(ring.underrunCount, 1)
    }

    func testRingSourceFeedsChannelAsIndependentStream() {
        // Two ring-fed channels carry different signals; each meter sees only its own.
        let m = AudioMixer(sampleRate: sr)
        let ra = AudioRingBuffer(minimumFrames: 8192), rb = AudioRingBuffer(minimumFrames: 8192)
        for (slot, ring) in [(0, ra), (1, rb)] {
            m.slots[slot] = ChannelState(active: true, volumeTarget: 1, volumeCurrent: 1, balance: 0, mute: false, solo: false,
                                         peak: 0, rmsSquares: 0, rmsCount: 0, source: Unmanaged.passRetained(RingSource(ring: ring)))
        }
        let a = [Float](repeating: 0.2, count: block), b = [Float](repeating: 0.6, count: block)
        m.master.pointee.limiterEnabled = false
        ra.write(a, a, frames: block); rb.write(b, b, frames: block)
        run(m, blocks: 1)
        XCTAssertEqual(peak(m, slot: 0), 0.2, accuracy: 0.01)
        XCTAssertEqual(peak(m, slot: 1), 0.6, accuracy: 0.01)
    }
}
