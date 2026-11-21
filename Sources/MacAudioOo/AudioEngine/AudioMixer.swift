import Foundation

/// Per-channel state shared between the UI thread (writes parameters) and the
/// real-time thread (reads parameters, writes meters). Lives in fixed, pre-allocated
/// memory so the render path never allocates or takes locks. Single aligned
/// Float/Bool fields are read/written atomically on supported CPUs.
struct ChannelState {
    var active = false
    var volumeTarget: Float = 1       // linear
    var volumeCurrent: Float = 1      // smoothed, owned by render thread
    var balance: Float = 0            // -1 ... +1
    var mute = false
    var solo = false
    var peak: Float = 0               // post-fader peak since last UI read
    var rmsSquares: Float = 0         // sum of squares of last block
    var rmsCount: Float = 0
    var source: Unmanaged<ChannelSource>? = nil
    var dsp: Unmanaged<ChannelDSP>? = nil      // optional EQ/compressor/sends chain
    var gainReductionDB: Float = 0             // compressor gain reduction (render thread)
    var recRing: Unmanaged<AudioRingBuffer>? = nil   // stem recording tap
    /// Where the stem is taken: 0 = raw (before EQ/compressor), 1 = after EQ/compressor, before the fader (default, dry), 2 = after the fader.
    var recMode: UInt8 = 1
    var mono = false                           // sum this channel to mono before processing
    var group: Int32 = -1                      // -1 none, 0...3 = group A...D
    var duckGain: Float = 1                    // set by the ducking controller (linear)
    var inputRmsSquares: Float = 0             // pre-fader level of the last block (for ducking triggers)
    var inputRmsCount: Float = 0
}

/// Per-group settings used by the render thread (group fader acts as a multiplier on members).
struct GroupRT {
    var gain: Float = 1
    var mute = false
    var solo = false
}

struct MasterState {
    var volumeTarget: Float = 1
    var volumeCurrent: Float = 1
    var mute = false
    var dim = false
    var dimAmount: Float = 0.1        // linear gain applied while DIM is on (-20 dB)
    var mono = false
    var limiterEnabled = true
    var limiterThreshold: Float = 0.891
    var limiterReleaseMs: Float = 100
    var peakL: Float = 0, peakR: Float = 0
    var rmsSquares: Float = 0, rmsCount: Float = 0
    var limiterGain: Float = 1        // minimum gain seen in last block (gain-reduction meter)
    var reverb = ReverbParams()
    var delay = DelayParams()
    var eq: Unmanaged<EQProcessor>? = nil      // master EQ (optional)
    var mixRing: Unmanaged<AudioRingBuffer>? = nil   // stereo-mix recording tap (after master processing)
}

/// Sums channels (each: EQ → compressor → volume/balance/mute/solo), adds shared reverb and
/// delay returns, then master EQ → volume/dim/mono → limiter → meters. `render` is real-time safe:
/// no allocation, no locks, no Objective-C/Swift runtime calls beyond fixed-size buffers.
final class AudioMixer {
    static let maxChannels = 32
    static let maxBlock = 4096

    let slots: UnsafeMutablePointer<ChannelState>
    let master: UnsafeMutablePointer<MasterState>
    private let scratchL: UnsafeMutablePointer<Float>
    private let scratchR: UnsafeMutablePointer<Float>
    private let accL: UnsafeMutablePointer<Float>
    private let accR: UnsafeMutablePointer<Float>
    private let revSend: UnsafeMutablePointer<Float>
    private let dlySend: UnsafeMutablePointer<Float>
    private let wetL: UnsafeMutablePointer<Float>
    private let wetR: UnsafeMutablePointer<Float>
    private var limiter = Limiter()
    private let reverb: ReverbProcessor
    private let delay: DelayProcessor
    let sampleRate: Float
    private let smoothing: Float
    private let ownsStorage: Bool

    /// Parameter storage that can outlive a mixer (the engine recreates the mixer when the
    /// output device or sample rate changes, while channel handles keep pointing here).
    struct Storage {
        let slots: UnsafeMutablePointer<ChannelState>
        let master: UnsafeMutablePointer<MasterState>
        let groups: UnsafeMutablePointer<GroupRT>
        static func allocate() -> Storage {
            let s = UnsafeMutablePointer<ChannelState>.allocate(capacity: AudioMixer.maxChannels)
            s.initialize(repeating: ChannelState(), count: AudioMixer.maxChannels)
            let m = UnsafeMutablePointer<MasterState>.allocate(capacity: 1); m.initialize(to: MasterState())
            let g = UnsafeMutablePointer<GroupRT>.allocate(capacity: 4); g.initialize(repeating: GroupRT(), count: 4)
            return Storage(slots: s, master: m, groups: g)
        }
        func deallocate() { slots.deallocate(); master.deallocate(); groups.deallocate() }
    }
    let groups: UnsafeMutablePointer<GroupRT>

    /// Uses `storage` if given (not owned); otherwise allocates and owns its own.
    init(sampleRate: Double, storage: Storage? = nil) {
        self.sampleRate = Float(sampleRate)
        smoothing = 1 - expf(-1 / (0.010 * Float(sampleRate)))   // ~10 ms time constant
        let st = storage ?? Storage.allocate()
        ownsStorage = storage == nil
        slots = st.slots; master = st.master; groups = st.groups
        func buf() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: AudioMixer.maxBlock)
            p.initialize(repeating: 0, count: AudioMixer.maxBlock); return p
        }
        scratchL = buf(); scratchR = buf(); accL = buf(); accR = buf()
        revSend = buf(); dlySend = buf(); wetL = buf(); wetR = buf()
        reverb = ReverbProcessor(sampleRate: sampleRate)
        delay = DelayProcessor(sampleRate: sampleRate)
    }
    deinit {
        if ownsStorage { slots.deallocate(); master.deallocate(); groups.deallocate() }
        for p in [scratchL, scratchR, accL, accR, revSend, dlySend, wetL, wetR] { p.deallocate() }
    }

    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        var done = 0
        while done < frames {
            let n = min(Self.maxBlock, frames - done)
            renderBlock(n, left + done, right + done)
            done += n
        }
    }

    private func renderBlock(_ n: Int, _ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>) {
        for i in 0..<n { accL[i] = 0; accR[i] = 0; revSend[i] = 0; dlySend[i] = 0 }

        var anySolo = false
        for c in 0..<Self.maxChannels where slots[c].active {
            let g = Int(slots[c].group)
            if slots[c].solo || (g >= 0 && g < 4 && groups[g].solo) { anySolo = true; break }
        }

        for c in 0..<Self.maxChannels {
            guard slots[c].active, let src = slots[c].source else { continue }
            src._withUnsafeGuaranteedRef { $0.pull(scratchL, scratchR, frames: n) }
            if slots[c].mono { for i in 0..<n { let m = (scratchL[i] + scratchR[i]) * 0.5; scratchL[i] = m; scratchR[i] = m } }
            // Stem tap mode 0: raw channel audio, before any processing.
            if slots[c].recMode == 0, let rr = slots[c].recRing { rr._withUnsafeGuaranteedRef { $0.write(scratchL, scratchR, frames: n) } }

            var revAmt: Float = 0, dlyAmt: Float = 0
            if let d = slots[c].dsp {
                d._withUnsafeGuaranteedRef { dsp in
                    dsp.eq.process(scratchL, scratchR, frames: n)
                    let params = dsp.fx.pointee
                    if params.comp.enabled != 0 {
                        let gr = dsp.compressor.process(scratchL, scratchR, frames: n, params: params.comp, sampleRate: sampleRate)
                        slots[c].gainReductionDB = gr
                    } else {
                        dsp.compressor.reset(); slots[c].gainReductionDB = 0
                    }
                    revAmt = params.reverbSend; dlyAmt = params.delaySend
                }
            }

            // Pre-fader level (post EQ/compressor): used by ducking triggers.
            var inSq: Float = 0
            for i in 0..<n { inSq += scratchL[i] * scratchL[i] + scratchR[i] * scratchR[i] }
            slots[c].inputRmsSquares = inSq; slots[c].inputRmsCount = Float(n * 2)

            // Stem tap mode 1 (default): dry, post EQ/compressor, before fader/mute/solo/sends.
            if slots[c].recMode == 1, let rr = slots[c].recRing { rr._withUnsafeGuaranteedRef { $0.write(scratchL, scratchR, frames: n) } }

            let grp = Int(slots[c].group)
            let inGroup = grp >= 0 && grp < 4
            let soloed = slots[c].solo || (inGroup && groups[grp].solo)
            let muted = slots[c].mute || (inGroup && groups[grp].mute)
            let gate: Float = (muted || (anySolo && !soloed)) ? 0 : 1
            let target = slots[c].volumeTarget * gate * (inGroup ? groups[grp].gain : 1) * slots[c].duckGain
            let bal = slots[c].balance
            let balL: Float = min(1, 1 - bal), balR: Float = min(1, 1 + bal)
            var g = slots[c].volumeCurrent
            var peak: Float = 0, sq: Float = 0
            for i in 0..<n {
                g += (target - g) * smoothing
                let l = scratchL[i] * g * balL, r = scratchR[i] * g * balR
                scratchL[i] = l; scratchR[i] = r                      // post-fader signal (stem tap mode 2)
                accL[i] += l; accR[i] += r
                let m = (l + r) * 0.5
                if revAmt > 0 { revSend[i] += m * revAmt }
                if dlyAmt > 0 { dlySend[i] += m * dlyAmt }
                let a = max(abs(l), abs(r))
                if a > peak { peak = a }
                sq += l * l + r * r
            }
            if abs(g - target) < 1e-5 { g = target }
            // Stem tap mode 2: as heard, after fader/mute/solo/group/duck (not including the shared effects).
            if slots[c].recMode == 2, let rr = slots[c].recRing { rr._withUnsafeGuaranteedRef { $0.write(scratchL, scratchR, frames: n) } }
            slots[c].volumeCurrent = g
            if peak > slots[c].peak { slots[c].peak = peak }
            slots[c].rmsSquares = sq; slots[c].rmsCount = Float(n * 2)
        }

        // Shared effects feed the master bus.
        let reverbParams = master.pointee.reverb, delayParams = master.pointee.delay
        if reverbParams.enabled != 0 {
            reverb.process(input: revSend, outL: wetL, outR: wetR, frames: n, params: reverbParams)
            let rl = reverbParams.returnLevel
            for i in 0..<n { accL[i] += wetL[i] * rl; accR[i] += wetR[i] * rl }
        }
        if delayParams.enabled != 0 {
            delay.process(input: dlySend, outL: wetL, outR: wetR, frames: n, params: delayParams)
            let dl = delayParams.returnLevel
            for i in 0..<n { accL[i] += wetL[i] * dl; accR[i] += wetR[i] * dl }
        }

        // Master section. Only render-thread-owned fields are written back, so UI changes made
        // while a block is rendering are never overwritten.
        if let e = master.pointee.eq { e._withUnsafeGuaranteedRef { $0.process(accL, accR, frames: n) } }
        let mute = master.pointee.mute, dim = master.pointee.dim, mono = master.pointee.mono
        let mTarget: Float = mute ? 0 : master.pointee.volumeTarget * (dim ? master.pointee.dimAmount : 1)
        var mg = master.pointee.volumeCurrent
        for i in 0..<n {
            mg += (mTarget - mg) * smoothing
            var l = accL[i] * mg, r = accR[i] * mg
            if mono { let s = (l + r) * 0.5; l = s; r = s }
            outL[i] = l; outR[i] = r
        }
        if abs(mg - mTarget) < 1e-5 { mg = mTarget }
        master.pointee.volumeCurrent = mg

        if master.pointee.limiterEnabled {
            limiter.threshold = master.pointee.limiterThreshold
            limiter.releaseCoef = Limiter.releaseCoefficient(milliseconds: master.pointee.limiterReleaseMs, sampleRate: sampleRate)
            master.pointee.limiterGain = limiter.process(outL, outR, frames: n)
        } else {
            master.pointee.limiterGain = 1
        }

        // Stereo-mix recording tap: after all master processing (EQ, volume, DIM/MONO, limiter).
        if let mr = master.pointee.mixRing { mr._withUnsafeGuaranteedRef { $0.write(outL, outR, frames: n) } }

        var pl: Float = 0, pr: Float = 0, sq: Float = 0
        for i in 0..<n {
            let a = abs(outL[i]), b = abs(outR[i])
            if a > pl { pl = a }; if b > pr { pr = b }
            sq += outL[i] * outL[i] + outR[i] * outR[i]
        }
        if pl > master.pointee.peakL { master.pointee.peakL = pl }
        if pr > master.pointee.peakR { master.pointee.peakR = pr }
        master.pointee.rmsSquares = sq; master.pointee.rmsCount = Float(n * 2)
    }
}
