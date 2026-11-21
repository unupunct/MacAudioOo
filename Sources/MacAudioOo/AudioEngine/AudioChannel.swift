import Foundation
import AppKit

/// UI-side handle for one mixer channel. Property changes are written straight
/// into the mixer's pre-allocated slot / DSP chain, where the render thread picks them up.
final class AudioChannel: ObservableObject, Identifiable {
    let id = UUID()
    let slotIndex: Int
    let name: String
    let pid: pid_t?
    let icon: NSImage?
    private let slot: UnsafeMutablePointer<ChannelState>
    let dsp: ChannelDSP

    /// Called by the engine so linked groups can move together. (channel, previous volume in dB)
    var onVolumeChange: ((AudioChannel, Float) -> Void)?

    @Published var volumeDB: Float = 0 {
        didSet { slot.pointee.volumeTarget = dbToLinear(volumeDB); onVolumeChange?(self, oldValue) }
    }
    /// Group assignment: -1 none, 0...3 = GROUP A...D.
    @Published var group: Int = -1 { didSet { slot.pointee.group = Int32(group) } }
    /// Armed for stem recording (locked while a recording is running).
    @Published var recArm = false
    /// Sum this channel to mono (before EQ/compressor).
    @Published var mono = false { didSet { slot.pointee.mono = mono } }
    /// Scene recall leaves this channel's settings alone.
    @Published var recallSafe = false
    /// This channel lowers the other applications while it is audible (in addition to the trigger-app list).
    @Published var ducksOthers = false
    @Published var balance: Float = 0 { didSet { slot.pointee.balance = balance } }
    @Published var mute = false { didSet { slot.pointee.mute = mute } }
    @Published var solo = false { didSet { slot.pointee.solo = solo } }

    /// 10 graphic bands then LOW, MID, HIGH tone gains (dB).
    @Published var eqGains = [Float](repeating: 0, count: EQProcessor.bandCount) {
        didSet { dsp.eq.set(gains: eqGains) }
    }
    @Published var eqBypass = false { didSet { dsp.eq.isBypassed = eqBypass } }
    @Published var eqPresetName = "Flat"
    @Published var comp = CompressorParams() {
        didSet { dsp.fx.pointee.comp.enabled = comp.enabled; dsp.fx.pointee.comp.thresholdDB = comp.thresholdDB
                 dsp.fx.pointee.comp.ratio = comp.ratio; dsp.fx.pointee.comp.attackMs = comp.attackMs
                 dsp.fx.pointee.comp.releaseMs = comp.releaseMs; dsp.fx.pointee.comp.makeupDB = comp.makeupDB
                 dsp.fx.pointee.comp.kneeDB = comp.kneeDB }
    }
    /// Reverb / delay send amounts, 0...1 (post-fader).
    @Published var reverbSend: Float = 0 { didSet { dsp.fx.pointee.reverbSend = reverbSend } }
    @Published var delaySend: Float = 0 { didSet { dsp.fx.pointee.delaySend = delaySend } }

    init(slotIndex: Int, slot: UnsafeMutablePointer<ChannelState>, dsp: ChannelDSP, name: String, pid: pid_t?, icon: NSImage?) {
        self.slotIndex = slotIndex; self.slot = slot; self.dsp = dsp
        self.name = name; self.pid = pid; self.icon = icon
    }

    /// Where this channel's stem is recorded from: 0 raw, 1 after EQ/compressor (default), 2 after the fader.
    var recordTapMode: UInt8 {
        get { slot.pointee.recMode }
        set { slot.pointee.recMode = newValue }
    }

    func applyEQPreset(_ presetName: String) {
        guard let g = EQPresets.gains(named: presetName) else { return }
        var all = eqGains
        for i in 0..<10 { all[i] = g[i] }
        eqPresetName = presetName
        eqGains = all
    }

    /// Called by the engine when the output sample rate changes.
    func applySampleRate(_ rate: Double) { dsp.eq.set(gains: eqGains, sampleRate: rate) }

    struct Meter { var peakDB: Float; var rmsDB: Float }

    /// Reads (and resets) the peak accumulator. Call from the UI at display rate.
    func readMeter() -> Meter {
        let p = slot.pointee.peak
        slot.pointee.peak = 0
        let rms = slot.pointee.rmsCount > 0 ? sqrtf(slot.pointee.rmsSquares / slot.pointee.rmsCount) : 0
        return Meter(peakDB: linearToDB(p), rmsDB: linearToDB(rms))
    }

    /// Compressor gain reduction in dB (>= 0).
    func readGainReduction() -> Float { slot.pointee.gainReductionDB }

    /// Non-destructive pre-fader RMS level of the last rendered block, in dB (for ducking triggers).
    func inputRMSdB() -> Float {
        let c = slot.pointee.inputRmsCount
        return c > 0 ? linearToDB(sqrtf(slot.pointee.inputRmsSquares / c)) : -120
    }

    /// Linear gain applied by the ducking controller (1 = no ducking).
    var duckGain: Float {
        get { slot.pointee.duckGain }
        set { slot.pointee.duckGain = newValue }
    }
}
