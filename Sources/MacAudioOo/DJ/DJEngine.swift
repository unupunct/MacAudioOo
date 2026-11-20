import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

/// The DJ audio graph: up to four decks mixed through per-deck gain/fader/crossfader into a master mixer.
///
///   deck player → time-pitch → 3-band EQ → DJ filter → deck mixer ─┐
///   (×4)                                                           ├→ main mixer → output device
///
/// Only local files are played. External applications (Spotify, …) are never controlled by this engine;
/// if they are captured by the Console they appear there as mixer inputs with volume/EQ only.
/// There is no headphone-cue output: that would need a genuine second output path, which is not implemented.
final class DJEngine: ObservableObject {
    let engine = AVAudioEngine()
    let decks: [DJDeck]
    private let manual: Bool
    private var running = false
    private var masterTapInstalled = false

    @Published var fourDecks = false
    @Published var crossfader: Float = 0 { didSet { updateGains() } }
    @Published var curve: CrossfaderCurve = .smooth { didSet { updateGains() } }
    @Published var masterDB: Float = 0 { didSet { engine.mainMixerNode.outputVolume = dbToLinear(masterDB) } }
    @Published private(set) var masterLevelDB: Float = -120
    @Published private(set) var error: String?
    /// ±8 / ±16 / ±50 %
    var tempoRange: Double = 8
    var bpmRange: ClosedRange<Double> = 70...180
    var onAnalysis: ((UUID, BPMResult) -> Void)?
    var onPlayed: ((UUID) -> Void)?
    private var uiTimer: Timer?
    private var outputDeviceID: AudioDeviceID?
    private var lastMasterPublish = Date.distantPast

    var activeDecks: [DJDeck] { fourDecks ? decks : Array(decks.prefix(2)) }

    /// `manualFormat` != nil runs the graph in offline manual-rendering mode (no audio hardware) — used by tests.
    init(manualFormat: AVAudioFormat? = nil) {
        decks = [DJDeck(id: 0, name: "DECK A", side: .left), DJDeck(id: 1, name: "DECK B", side: .right),
                 DJDeck(id: 2, name: "DECK C", side: .left), DJDeck(id: 3, name: "DECK D", side: .right)]
        manual = manualFormat != nil
        for d in decks {
            d.dj = self
            for n in [d.player, d.timePitch, d.toneEQ, d.filterEQ, d.output] as [AVAudioNode] { engine.attach(n) }
        }
        if let f = manualFormat {
            do { try engine.enableManualRenderingMode(.offline, format: f, maximumFrameCount: 4096) }
            catch { self.error = "Manual rendering unavailable: \(error.localizedDescription)" }
        }
        updateGains()
    }
    deinit { uiTimer?.invalidate(); if engine.isRunning { engine.stop() } }

    /// Wires one deck's chain for the file's format. Safe to call while the engine runs.
    func connect(_ d: DJDeck, format: AVAudioFormat) {
        engine.disconnectNodeOutput(d.player)
        engine.connect(d.player, to: d.timePitch, format: format)
        engine.connect(d.timePitch, to: d.toneEQ, format: format)
        engine.connect(d.toneEQ, to: d.filterEQ, format: format)
        engine.connect(d.filterEQ, to: d.output, format: format)
        engine.connect(d.output, to: engine.mainMixerNode, format: nil)
        d.output.removeTap(onBus: 0)
        d.output.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak d] buf, _ in
            guard let d = d, let data = buf.floatChannelData else { return }
            var peak: Float = 0
            let n = Int(buf.frameLength), ch = Int(buf.format.channelCount)
            for c in 0..<ch { for i in 0..<n { peak = max(peak, abs(data[c][i])) } }
            d.receiveLevel(linearToDB(peak))
        }
        if !running { engine.prepare() }
        applyAll(d)
    }

    private func applyAll(_ d: DJDeck) { d.applyEQ(); d.applyFilter(); updateGains() }

    func ensureRunning() throws {
        guard !engine.isRunning else { return }
        if !manual { applyOutputDevice() }
        engine.prepare()
        try engine.start()
        running = true
        installMasterTap()
        startTimer()
    }

    private func installMasterTap() {
        guard !masterTapInstalled else { return }
        masterTapInstalled = true
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            guard let self = self, let data = buf.floatChannelData else { return }
            var peak: Float = 0
            let n = Int(buf.frameLength), ch = Int(buf.format.channelCount)
            for c in 0..<ch { for i in 0..<n { peak = max(peak, abs(data[c][i])) } }
            let now = Date()
            guard now.timeIntervalSince(self.lastMasterPublish) > 0.033 else { return }
            self.lastMasterPublish = now
            let db = linearToDB(peak)
            DispatchQueue.main.async { self.masterLevelDB = db }
        }
    }

    private func startTimer() {
        guard !manual, uiTimer == nil else { return }
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.decks.forEach { $0.refreshPosition() }
        }
    }

    // MARK: Output device

    /// Plays through `id` (the device MacAudioOo's mixer uses), never the system default, so the DJ output
    /// can neither loop through the virtual driver nor surprise the user.
    func setOutputDevice(id: AudioDeviceID?) {
        guard id != outputDeviceID else { return }
        outputDeviceID = id
        guard !manual, engine.isRunning else { return }
        let wasRunning = engine.isRunning
        engine.stop(); running = false
        applyOutputDevice()
        if wasRunning { do { try engine.start(); running = true } catch { self.error = "Audio engine could not restart: \(error.localizedDescription)" } }
    }

    private func applyOutputDevice() {
        guard let id = outputDeviceID else { return }
        do { try engine.outputNode.auAudioUnit.setDeviceID(id) } catch { self.error = "Could not select the DJ output device: \(error.localizedDescription)" }
    }

    // MARK: Mixing

    func updateGains() {
        for d in decks {
            let cross = Crossfader.gain(for: d.side, position: crossfader, curve: curve)
            d.output.outputVolume = dbToLinear(d.gainDB) * d.channelFader * cross
        }
    }

    /// First other deck that is loaded with a beat grid (preferring one that is playing).
    func syncMaster(excluding d: DJDeck) -> DJDeck? {
        let others = activeDecks.filter { $0.id != d.id && $0.grid != nil }
        return others.first { $0.isPlaying } ?? others.first
    }

    func sync(_ d: DJDeck) { if let m = syncMaster(excluding: d) { d.sync(to: m) } }

    // MARK: Offline rendering (tests)

    /// Renders `frames` frames of the mixed output (manual-rendering mode only). Returns left-channel samples.
    func renderOffline(frames: Int) -> [Float] {
        guard manual, let fmt = Optional(engine.manualRenderingFormat),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else { return [] }
        var out: [Float] = []; out.reserveCapacity(frames)
        var remaining = frames
        while remaining > 0 {
            let n = min(remaining, 4096)
            do { let st = try engine.renderOffline(AVAudioFrameCount(n), to: buf); if st == .error { break } } catch { break }
            if let d = buf.floatChannelData { for i in 0..<Int(buf.frameLength) { out.append(d[0][i]) } }
            remaining -= n
        }
        return out
    }
}
