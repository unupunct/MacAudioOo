import XCTest
@testable import MacAudioOo

/// Offline DSP tests on generated signals.
final class DSPTests: XCTestCase {
    let sr = 48000.0

    func sine(_ f: Double, amp: Float, seconds: Double) -> [Float] {
        (0..<Int(seconds * sr)).map { amp * Float(sin(2 * Double.pi * f * Double($0) / sr)) }
    }
    func rms(_ x: ArraySlice<Float>) -> Float { sqrtf(x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))) }
    func peak(_ x: ArraySlice<Float>) -> Float { x.map { abs($0) }.max() ?? 0 }

    /// Runs `x` (mono, copied to both channels) through `body` in 512-frame blocks.
    func run(_ x: [Float], _ body: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int) -> Void) -> [Float] {
        var l = x, r = x
        var i = 0
        while i < x.count {
            let n = min(512, x.count - i)
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                body(lp.baseAddress! + i, rp.baseAddress! + i, n) } }
            i += n
        }
        return l
    }

    func eqGainDB(band gains: [Float], freq: Double) -> Float {
        let eq = EQProcessor(sampleRate: sr)
        eq.set(gains: gains)
        let x = sine(freq, amp: 0.1, seconds: 0.6)
        let y = run(x) { l, r, n in eq.process(l, r, frames: n) }
        let half = x.count / 2
        return linearToDB(rms(y[half...])) - linearToDB(rms(x[half...]))
    }

    func testEQFlatIsTransparent() {
        let eq = EQProcessor(sampleRate: sr)
        let x = sine(1000, amp: 0.5, seconds: 0.2)
        let y = run(x) { l, r, n in eq.process(l, r, frames: n) }
        XCTAssertTrue(zip(x, y).allSatisfy { $0 == $1 })
    }

    func testEQEveryGraphicBandHitsItsGain() {
        for (i, f) in EQProcessor.graphicFrequencies.enumerated() {
            var g = [Float](repeating: 0, count: EQProcessor.bandCount)
            g[i] = 6
            let measured = eqGainDB(band: g, freq: f)
            XCTAssertEqual(measured, 6, accuracy: 0.5, "band \(f) Hz")
            g[i] = -6
            XCTAssertEqual(eqGainDB(band: g, freq: f), -6, accuracy: 0.5, "band \(f) Hz cut")
        }
    }

    func testEQBandLeavesDistantFrequenciesAlone() {
        var g = [Float](repeating: 0, count: EQProcessor.bandCount)
        g[5] = 12                                          // +12 dB at 1 kHz
        XCTAssertEqual(eqGainDB(band: g, freq: 63), 0, accuracy: 0.5)
        XCTAssertEqual(eqGainDB(band: g, freq: 16000), 0, accuracy: 0.5)
    }

    func testEQResponseCurveMatchesMeasuredResponse() {
        let eq = EQProcessor(sampleRate: sr)
        var g = [Float](repeating: 0, count: EQProcessor.bandCount)
        g[3] = 5; g[7] = -4
        eq.set(gains: g)
        for f in [250.0, 500.0, 4000.0] {
            XCTAssertEqual(Float(eq.responseDB(at: f)), eqGainDB(band: g, freq: f), accuracy: 0.4, "\(f) Hz")
        }
    }

    func testEQToneKnobsAndBypass() {
        var g = [Float](repeating: 0, count: EQProcessor.bandCount)
        g[10] = 8                                          // LOW shelf +8 dB
        XCTAssertGreaterThan(eqGainDB(band: g, freq: 60), 6)
        XCTAssertEqual(eqGainDB(band: g, freq: 8000), 0, accuracy: 0.5)
        let eq = EQProcessor(sampleRate: sr); eq.set(gains: g); eq.isBypassed = true
        let x = sine(60, amp: 0.3, seconds: 0.1)
        let y = run(x) { l, r, n in eq.process(l, r, frames: n) }
        XCTAssertTrue(zip(x, y).allSatisfy { $0 == $1 })
    }

    func testEQIsStableAtMaximumSettings() {
        let eq = EQProcessor(sampleRate: sr)
        eq.set(gains: [Float](repeating: 12, count: EQProcessor.bandCount))
        var x = [Float](repeating: 0, count: Int(sr * 3)); x[0] = 1
        let y = run(x) { l, r, n in eq.process(l, r, frames: n) }
        XCTAssertTrue(y.allSatisfy { $0.isFinite })
        XCTAssertLessThan(peak(y[Int(sr * 2)...]), 1e-3)   // impulse response decays
    }

    func testEQPresetsAndUserPresets() {
        XCTAssertEqual(EQPresets.builtInNames, ["Flat", "Bass Boost", "Voice Clarity", "Podcast", "Night", "Music", "Cinema"])
        XCTAssertTrue(EQPresets.builtIn.allSatisfy { $0.gains.count == 10 })
        XCTAssertGreaterThan(EQPresets.gains(named: "Bass Boost")![0], 0)
        let suite = UserDefaults(suiteName: "MacAudioOoEQ-\(UUID().uuidString)")!
        EQPresets.save(name: "Mine", gains: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], defaults: suite)
        XCTAssertEqual(EQPresets.gains(named: "Mine", defaults: suite)!, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        EQPresets.delete(name: "Mine", defaults: suite)
        XCTAssertNil(EQPresets.gains(named: "Mine", defaults: suite))
    }

    func testCompressorReducesLoudSignalsAndLeavesQuietOnesAlone() {
        var p = CompressorParams()
        p.enabled = 1; p.thresholdDB = -20; p.ratio = 4; p.attackMs = 1; p.releaseMs = 100; p.makeupDB = 0; p.kneeDB = 1
        var comp = Compressor()
        let loud = sine(1000, amp: 0.4, seconds: 1.0)               // peaks at -8 dBFS
        let y = run(loud) { l, r, n in _ = comp.process(l, r, frames: n, params: p, sampleRate: Float(sr)) }
        let reduction = linearToDB(peak(loud[24000...])) - linearToDB(peak(y[24000...]))
        XCTAssertGreaterThan(reduction, 3)                          // clearly compressed
        XCTAssertLessThan(reduction, 10)                            // but never beyond the ideal 9 dB
        comp.reset()
        let quiet = sine(1000, amp: 0.01, seconds: 0.5)             // -40 dBFS, below threshold
        let q = run(quiet) { l, r, n in _ = comp.process(l, r, frames: n, params: p, sampleRate: Float(sr)) }
        XCTAssertEqual(linearToDB(rms(q[12000...])), linearToDB(rms(quiet[12000...])), accuracy: 0.2)
    }

    func testCompressorMakeupAndGainReductionMeter() {
        var p = CompressorParams()
        p.enabled = 1; p.thresholdDB = -20; p.ratio = 4; p.makeupDB = 6
        var comp = Compressor()
        let quiet = sine(1000, amp: 0.01, seconds: 0.3)
        let q = run(quiet) { l, r, n in _ = comp.process(l, r, frames: n, params: p, sampleRate: Float(sr)) }
        XCTAssertEqual(linearToDB(rms(q[8000...])) - linearToDB(rms(quiet[8000...])), 6, accuracy: 0.3)
        var gr: Float = 0
        _ = run(sine(1000, amp: 0.8, seconds: 0.5)) { l, r, n in gr = max(gr, comp.process(l, r, frames: n, params: p, sampleRate: Float(sr))) }
        XCTAssertGreaterThan(gr, 3)
    }

    func testReverbDecaysAndStaysBounded() {
        let rv = ReverbProcessor(sampleRate: sr)
        var p = ReverbParams(); p.decaySeconds = 1.0
        var input = [Float](repeating: 0, count: Int(sr * 4)); input[0] = 1
        var outL = [Float](repeating: 0, count: input.count), outR = outL
        input.withUnsafeBufferPointer { ip in outL.withUnsafeMutableBufferPointer { lp in outR.withUnsafeMutableBufferPointer { rp in
            var i = 0
            while i < input.count {
                let n = min(512, input.count - i)
                rv.process(input: ip.baseAddress! + i, outL: lp.baseAddress! + i, outR: rp.baseAddress! + i, frames: n, params: p)
                i += n
            }
        } } }
        XCTAssertTrue(outL.allSatisfy { $0.isFinite } && outR.allSatisfy { $0.isFinite })
        let early = rms(outL[0..<Int(sr * 0.5)]), late = rms(outL[Int(sr * 3.5)...])
        XCTAssertGreaterThan(early, 1e-5)                           // there is a tail
        XCTAssertLessThan(late, early * 0.01)                       // and it decays (RT60 = 1 s)
    }

    func testReverbAndDelayStayBoundedAtExtremeSettings() {
        let rv = ReverbProcessor(sampleRate: sr), dl = DelayProcessor(sampleRate: sr)
        var rp = ReverbParams(); rp.roomSize = 1; rp.decaySeconds = 10; rp.tone = 1
        var dp = DelayParams(); dp.feedback = 1.0; dp.timeMs = 50; dp.tone = 1
        var seed: UInt32 = 12345
        func noise() -> Float { seed = seed &* 1664525 &+ 1013904223; return Float(seed >> 8) / Float(1 << 24) * 2 - 1 }
        let input = (0..<Int(sr * 6)).map { _ in noise() * 0.5 }
        var oL = [Float](repeating: 0, count: 512), oR = oL
        var maxRv: Float = 0, maxDl: Float = 0
        input.withUnsafeBufferPointer { ip in
            var i = 0
            while i + 512 <= input.count {
                oL.withUnsafeMutableBufferPointer { lp in oR.withUnsafeMutableBufferPointer { rp in
                    rv.process(input: ip.baseAddress! + i, outL: lp.baseAddress!, outR: rp.baseAddress!, frames: 512, params: rp_)
                } }
                maxRv = max(maxRv, oL.map { abs($0) }.max()!, oR.map { abs($0) }.max()!)
                oL.withUnsafeMutableBufferPointer { lp in oR.withUnsafeMutableBufferPointer { rp in
                    dl.process(input: ip.baseAddress! + i, outL: lp.baseAddress!, outR: rp.baseAddress!, frames: 512, params: dp)
                } }
                maxDl = max(maxDl, oL.map { abs($0) }.max()!, oR.map { abs($0) }.max()!)
                i += 512
            }
        }
        XCTAssertLessThan(maxRv, 50); XCTAssertTrue(maxRv.isFinite)
        XCTAssertLessThan(maxDl, 20); XCTAssertTrue(maxDl.isFinite)   // feedback is clamped to 0.85
    }

    var rp_: ReverbParams { var p = ReverbParams(); p.roomSize = 1; p.decaySeconds = 10; p.tone = 1; return p }

    func testDelayEchoTimingAndFeedback() {
        let dl = DelayProcessor(sampleRate: sr)
        var p = DelayParams(); p.timeMs = 100; p.feedback = 0.5; p.tone = 1
        // Let the internal time glide settle on 100 ms first.
        let warm = [Float](repeating: 0, count: Int(sr))
        var l = [Float](repeating: 0, count: 512), r = l
        warm.withUnsafeBufferPointer { wp in
            var i = 0; while i + 512 <= warm.count { l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                dl.process(input: wp.baseAddress! + i, outL: lp.baseAddress!, outR: rp.baseAddress!, frames: 512, params: p) } }; i += 512 } }
        var input = [Float](repeating: 0, count: Int(sr * 1)); input[0] = 1
        var outL = [Float](repeating: 0, count: input.count), outR = outL
        input.withUnsafeBufferPointer { ip in outL.withUnsafeMutableBufferPointer { lp in outR.withUnsafeMutableBufferPointer { rp in
            var i = 0; while i + 512 <= input.count {
                dl.process(input: ip.baseAddress! + i, outL: lp.baseAddress! + i, outR: rp.baseAddress! + i, frames: 512, params: p); i += 512 }
        } } }
        let firstEcho = outL.enumerated().max { abs($0.element) < abs($1.element) }!.offset
        XCTAssertEqual(Double(firstEcho) / sr * 1000, 100, accuracy: 2)
        XCTAssertEqual(abs(outL[firstEcho]), 1, accuracy: 0.05, "neighbours \(outL[firstEcho - 1]) \(outL[firstEcho]) \(outL[firstEcho + 1]) firstEcho \(firstEcho) curDelay \(dl.currentDelaySamples)")
        XCTAssertLessThan(peak(outL[(firstEcho + 100)...]), 0.6)     // later repeats are quieter (cross-fed, fb 0.5)
    }

    func testMixerChannelEQAndCompressorAreIndependentPerChannel() {
        let m = AudioMixer(sampleRate: sr)
        m.master.pointee.limiterEnabled = false
        let dspA = ChannelDSP(sampleRate: sr), dspB = ChannelDSP(sampleRate: sr)
        for (i, d) in [dspA, dspB].enumerated() {
            let src = ToneSource(frequency: 1000, amplitude: 0.1, sampleRate: Float(sr))
            m.slots[i] = ChannelState(active: true, volumeTarget: 1, volumeCurrent: 1, balance: 0, mute: false, solo: false,
                                      peak: 0, rmsSquares: 0, rmsCount: 0, source: Unmanaged.passRetained(src),
                                      dsp: Unmanaged.passRetained(d), gainReductionDB: 0)
        }
        var l = [Float](repeating: 0, count: 512), r = l
        func blocks(_ n: Int) { for _ in 0..<n { l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            m.render(frames: 512, left: lp.baseAddress!, right: rp.baseAddress!) } } } }
        blocks(20); let bBefore = m.slots[1].peak; m.slots[0].peak = 0; m.slots[1].peak = 0
        // EQ +6 dB at 1 kHz on A only.
        var g = [Float](repeating: 0, count: EQProcessor.bandCount); g[5] = 6
        dspA.eq.set(gains: g)
        blocks(20); m.slots[0].peak = 0; m.slots[1].peak = 0; blocks(20)
        XCTAssertEqual(linearToDB(m.slots[0].peak) - linearToDB(bBefore), 6, accuracy: 0.6)
        XCTAssertEqual(m.slots[1].peak, bBefore, accuracy: 0.002)
        // Compressor on A only (loud tone, low threshold).
        m.slots[0].peak = 0; m.slots[1].peak = 0
        dspA.fx.pointee.comp = CompressorParams(enabled: 1, thresholdDB: -30, ratio: 8, attackMs: 1, releaseMs: 50, makeupDB: 0, kneeDB: 1, grDB: 0)
        blocks(40); m.slots[0].peak = 0; m.slots[1].peak = 0; blocks(20)
        XCTAssertLessThan(m.slots[0].peak, 0.19)                    // well below the EQ-boosted level (0.2)
        XCTAssertGreaterThan(m.slots[0].gainReductionDB, 1)
        XCTAssertEqual(m.slots[1].peak, bBefore, accuracy: 0.002)
        XCTAssertEqual(m.slots[1].gainReductionDB, 0, accuracy: 0.0001)
    }

    func testMasterEQAffectsTheSummedBus() {
        let m = AudioMixer(sampleRate: sr)
        m.master.pointee.limiterEnabled = false
        let eq = EQProcessor(sampleRate: sr)
        m.master.pointee.eq = Unmanaged.passRetained(eq)
        let src = ToneSource(frequency: 1000, amplitude: 0.1, sampleRate: Float(sr))
        m.slots[0] = ChannelState(active: true, volumeTarget: 1, volumeCurrent: 1, balance: 0, mute: false, solo: false,
                                  peak: 0, rmsSquares: 0, rmsCount: 0, source: Unmanaged.passRetained(src))
        var l = [Float](repeating: 0, count: 512), r = l
        func lastPeak(_ n: Int) -> Float { var p: Float = 0
            for _ in 0..<n { l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                m.render(frames: 512, left: lp.baseAddress!, right: rp.baseAddress!) } }; p = l.map { abs($0) }.max()! }
            return p }
        let before = lastPeak(20)
        var g = [Float](repeating: 0, count: EQProcessor.bandCount); g[5] = 6; eq.set(gains: g)
        _ = lastPeak(10)
        XCTAssertEqual(linearToDB(lastPeak(10)) - linearToDB(before), 6, accuracy: 0.6)
    }

    func testReverbSendOnlyFeedsTheReverbWhenRaised() {
        func tailEnergy(send: Float) -> Float {
            let m = AudioMixer(sampleRate: sr)
            m.master.pointee.limiterEnabled = false
            m.master.pointee.reverb.enabled = 1; m.master.pointee.reverb.returnLevel = 1
            m.master.pointee.delay.enabled = 0
            let d = ChannelDSP(sampleRate: sr); d.fx.pointee.reverbSend = send
            m.slots[0] = ChannelState(active: true, volumeTarget: 1, volumeCurrent: 1, balance: 0, mute: false, solo: false,
                                      peak: 0, rmsSquares: 0, rmsCount: 0,
                                      source: Unmanaged.passRetained(ToneSource(frequency: 500, amplitude: 0.5, sampleRate: Float(sr))),
                                      dsp: Unmanaged.passRetained(d), gainReductionDB: 0)
            var l = [Float](repeating: 0, count: 512), r = l
            for _ in 0..<60 { l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                m.render(frames: 512, left: lp.baseAddress!, right: rp.baseAddress!) } } }
            m.slots[0].mute = true                                   // dry signal stops; reverb tail remains
            for _ in 0..<10 { l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                m.render(frames: 512, left: lp.baseAddress!, right: rp.baseAddress!) } } }
            return rms(l[0...])
        }
        XCTAssertLessThan(tailEnergy(send: 0), 1e-4)                // only the dry fade-out remains
        XCTAssertGreaterThan(tailEnergy(send: 1), 1e-3)
    }
}
