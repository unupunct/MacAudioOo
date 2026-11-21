import Foundation
import AVFoundation

struct LoopRegion: Equatable { var inTime: Double; var outTime: Double; var length: Double { outTime - inTime } }

/// One DJ deck: file player → time-stretch/pitch unit (pitch-preserving tempo) → 3-band EQ → DJ filter →
/// channel mixer node (gain / channel fader / crossfader). All of it runs in the shared AVAudioEngine of
/// `DJEngine`; only local files are played, and only the controls that really act on them are exposed.
final class DJDeck: ObservableObject, Identifiable {
    let id: Int
    let name: String
    let player = AVAudioPlayerNode()
    let timePitch = AVAudioUnitTimePitch()
    let toneEQ = AVAudioUnitEQ(numberOfBands: 3)
    let filterEQ = AVAudioUnitEQ(numberOfBands: 2)
    let output = AVAudioMixerNode()
    weak var dj: DJEngine?

    @Published private(set) var track: TrackMetadata?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var grid: BeatGrid?
    @Published private(set) var waveform: WaveformData?
    @Published private(set) var hotCues: [Double?] = Array(repeating: nil, count: 8)
    @Published private(set) var cuePoint: Double = 0
    @Published private(set) var loop: LoopRegion?
    @Published private(set) var loopActive = false
    @Published private(set) var levelDB: Float = -120
    @Published private(set) var analyzing = false
    @Published private(set) var loadError: String?
    @Published var side: DeckSide

    @Published var tempoPercent: Double = 0 { didSet { applyRate() } }
    @Published var keyLock = true { didSet { applyRate() } }
    @Published var gainDB: Float = 0 { didSet { dj?.updateGains() } }
    @Published var channelFader: Float = 1 { didSet { dj?.updateGains() } }
    @Published var lowDB: Float = 0 { didSet { applyEQ() } }
    @Published var midDB: Float = 0 { didSet { applyEQ() } }
    @Published var highDB: Float = 0 { didSet { applyEQ() } }
    /// DJ filter: -1 = low-pass sweep, 0 = off, +1 = high-pass sweep.
    @Published var filter: Float = 0 { didSet { applyFilter() } }
    /// Quantize loop/cue creation to the beat grid when one exists.
    var quantize = true
    /// SLIP: while a loop runs, the track keeps its true position underneath and playback jumps there when the loop ends.
    @Published var slip = false
    /// Size of the auto loop in beats (shown as "4 BEATS").
    @Published var loopBeats: Double = 4
    private var slipAnchor: (pos: Double, at: Date)?
    private var taps: [Date] = []

    private var file: AVAudioFile?
    private var fileRate: Double = 44100
    private var fileLength: AVAudioFramePosition = 0
    private var anchorFrame: AVAudioFramePosition = 0
    private var parkedFrame: AVAudioFramePosition = 0
    private var needsSchedule = true
    private var generation = 0
    private var nudge: Double = 0
    private var lastLevelPublish = Date.distantPast

    init(id: Int, name: String, side: DeckSide) {
        self.id = id; self.name = name; self.side = side
        let low = toneEQ.bands[0]; low.filterType = .lowShelf; low.frequency = 120; low.gain = 0; low.bypass = false
        let mid = toneEQ.bands[1]; mid.filterType = .parametric; mid.frequency = 1000; mid.bandwidth = 1.2; mid.gain = 0; mid.bypass = false
        let high = toneEQ.bands[2]; high.filterType = .highShelf; high.frequency = 6000; high.gain = 0; high.bypass = false
        let lp = filterEQ.bands[0]; lp.filterType = .lowPass; lp.frequency = 20000; lp.bypass = true
        let hp = filterEQ.bands[1]; hp.filterType = .highPass; hp.frequency = 20; hp.bypass = true
        timePitch.rate = 1; timePitch.pitch = 0
    }

    var rate: Double { 1 + tempoPercent / 100 }
    var effectiveBPM: Double? { grid.map { $0.bpm * rate } }
    var isLoaded: Bool { file != nil }
    var remaining: Double { max(0, duration - position) }

    // MARK: Loading

    /// Opens the file, builds the waveform and (if the library has no result yet) analyzes BPM/beat grid in the background.
    func load(_ t: TrackMetadata) {
        AppLog.shared.log("\(name): loading \(t.url.lastPathComponent)")
        stopPlayback()
        loadError = nil
        do {
            let f = try AVAudioFile(forReading: t.url)
            // Wire the chain for this file's format first, then make sure the engine runs.
            dj?.connect(self, format: f.processingFormat)
            try dj?.ensureRunning()
            file = f; fileRate = f.processingFormat.sampleRate; fileLength = f.length
            duration = Double(f.length) / fileRate
            track = t; grid = t.grid; waveform = nil
            hotCues = Array(repeating: nil, count: 8); cuePoint = 0; loop = nil; loopActive = false
            position = 0; parkedFrame = 0; anchorFrame = 0; needsSchedule = true
            tempoPercent = 0
            let url = t.url, bucket = 512
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let w = WaveformData.compute(url: url, bucketFrames: bucket)
                DispatchQueue.main.async { if self?.track?.id == t.id { self?.waveform = w } }
            }
            if t.grid == nil { analyze(t) }
        } catch {
            file = nil; track = nil
            loadError = "Cannot open \(t.url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func analyze(_ t: TrackMetadata) {
        analyzing = true
        let minB = dj?.bpmRange.lowerBound ?? 70, maxB = dj?.bpmRange.upperBound ?? 180
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = BPMAnalyzer.analyze(url: t.url, minBPM: minB, maxBPM: maxB)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.analyzing = false
                guard self.track?.id == t.id, let r = r else { return }
                self.grid = r.grid
                self.track?.bpm = r.bpm; self.track?.firstBeat = r.firstBeat
                self.dj?.onAnalysis?(t.id, r)
            }
        }
    }

    func eject() {
        stopPlayback(); file = nil; track = nil; grid = nil; waveform = nil; duration = 0; position = 0
        loop = nil; loopActive = false; hotCues = Array(repeating: nil, count: 8); levelDB = -120
    }

    // MARK: Transport

    private func stopPlayback() {
        generation += 1
        if player.engine != nil { player.stop() }
        isPlaying = false; needsSchedule = true
    }

    /// File frame currently being played (or parked at while paused/stopped).
    func currentFrame() -> AVAudioFramePosition {
        // lastRenderTime can be non-nil but not yet valid (nothing rendered since play); querying it then raises.
        guard isPlaying, let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid || nodeTime.isHostTimeValid,
              let pt = player.playerTime(forNodeTime: nodeTime), pt.isSampleTimeValid else { return parkedFrame }
        if loopActive, let l = loop {
            let inF = AVAudioFramePosition(l.inTime * fileRate), len = max(1, AVAudioFramePosition(l.length * fileRate))
            return inF + (max(0, pt.sampleTime) % len)
        }
        return min(fileLength, max(0, anchorFrame + pt.sampleTime))
    }

    /// Refreshes `position` (called by the engine's UI timer).
    func refreshPosition() {
        guard file != nil else { return }
        let p = Double(currentFrame()) / fileRate
        if abs(p - position) > 0.0005 { position = p }
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let f = file else { return }
        generation += 1
        let gen = generation
        player.stop()
        anchorFrame = frame; parkedFrame = frame
        let remaining = f.length - frame
        guard remaining > 0 else { return }
        player.scheduleSegment(f, startingFrame: frame, frameCount: AVAudioFrameCount(remaining), at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.trackEnded(gen) }
        }
        needsSchedule = false
    }

    private func trackEnded(_ gen: Int) {
        guard gen == generation, !loopActive else { return }
        isPlaying = false; parkedFrame = 0; needsSchedule = true; position = 0
        player.stop()
    }

    func play() {
        guard file != nil else { return }
        do { try dj?.ensureRunning() } catch { loadError = "Audio engine could not start: \(error.localizedDescription)"; return }
        if needsSchedule { if loopActive { engageLoop() } else { schedule(from: parkedFrame) } }
        player.play()
        isPlaying = true
        if let id = track?.id { dj?.onPlayed?(id) }
    }

    func pause() {
        guard isPlaying else { return }
        parkedFrame = currentFrame()
        player.pause(); isPlaying = false
        position = Double(parkedFrame) / fileRate
    }

    func togglePlay() { isPlaying ? pause() : play() }

    /// STOP: halt and rewind to the start of the track.
    func stop() {
        stopPlayback(); parkedFrame = 0; anchorFrame = 0; position = 0
        if loopActive { loopActive = false }
    }

    /// CUE: while playing, return to the cue point and pause; while paused, set the cue point here.
    func cue() {
        guard file != nil else { return }
        if isPlaying { seek(to: cuePoint, resume: false) }
        else { cuePoint = quantized(position) ; seek(to: cuePoint, resume: false) }
    }

    func seek(to time: Double, resume: Bool? = nil) {
        guard file != nil else { return }
        let wasPlaying = resume ?? isPlaying
        let f = AVAudioFramePosition(max(0, min(duration, time)) * fileRate)
        if loopActive { loopActive = false }
        slipAnchor = nil
        let p = player.engine != nil
        if p { player.stop() }
        generation += 1
        isPlaying = false; parkedFrame = f; anchorFrame = f; needsSchedule = true
        position = Double(f) / fileRate
        if wasPlaying { play() }
    }

    // MARK: Tempo / sync / jog

    private func applyRate() {
        let r = rate * (1 + nudge)
        timePitch.rate = Float(max(0.25, min(4, r)))
        timePitch.pitch = keyLock ? 0 : Float(1200 * log2(max(0.25, min(4, r))))
    }

    /// Temporary speed change while the jog wheel is dragged (pitch bend), e.g. -0.08...+0.08.
    func nudge(_ amount: Double) { nudge = max(-0.12, min(0.12, amount)); applyRate() }
    func endNudge() { nudge = 0; applyRate() }

    /// Scrub while paused: move the parked position by `seconds`.
    func scrub(by seconds: Double) {
        guard file != nil, !isPlaying else { return }
        seek(to: position + seconds, resume: false)
    }

    /// Match tempo (and beat phase if both decks are playing) to `master`.
    func sync(to master: DJDeck) {
        guard let g = grid, let mg = master.grid, let target = master.effectiveBPM else { return }
        let range = dj?.tempoRange ?? 8
        tempoPercent = max(-range, min(range, (target / g.bpm - 1) * 100))
        if isPlaying, master.isPlaying {
            let corr = g.phaseCorrection(from: position, toMasterPhase: mg.phase(at: master.position))
            seek(to: position + corr, resume: true)
        }
    }

    // MARK: Hot cues and loops

    private func quantized(_ t: Double) -> Double { (quantize ? grid?.nearestBeatTime(to: t) : nil).map { max(0, $0) } ?? t }

    /// Pad pressed: sets the cue if empty, otherwise jumps to it (and plays).
    func hotCue(_ i: Int) {
        guard file != nil, hotCues.indices.contains(i) else { return }
        if let t = hotCues[i] { seek(to: t, resume: true) } else { hotCues[i] = quantized(position) }
    }
    func clearHotCue(_ i: Int) { if hotCues.indices.contains(i) { hotCues[i] = nil } }

    func setLoopIn() {
        guard file != nil else { return }
        loopActive = false
        loop = LoopRegion(inTime: quantized(position), outTime: quantized(position))
    }

    func setLoopOut() {
        guard file != nil, var l = loop else { return }
        let out = quantized(position)
        guard out > l.inTime + 0.01 else { return }
        l.outTime = out; loop = l
        engageLoop()
    }

    /// Loop `beats` beats starting at the nearest beat (needs a beat grid).
    func autoLoop(beats: Double) {
        guard file != nil, let g = grid else { return }
        let start = max(0, g.nearestBeatTime(to: position))
        let len = g.loopLength(beats: beats)
        guard start + len <= duration else { return }
        loopBeats = beats
        loop = LoopRegion(inTime: start, outTime: start + len)
        engageLoop()
    }

    // MARK: Loop size, slip, tap tempo, BPM correction

    /// Halves / doubles the loop length (in beats, 1/4 ... 32). A running loop is re-cut from its start; otherwise only the size is remembered.
    func scaleLoop(by factor: Double) {
        loopBeats = max(0.25, min(32, loopBeats * factor))
        if loopActive, let g = grid, let l = loop {
            let len = g.loopLength(beats: loopBeats)
            guard l.inTime + len <= duration else { return }
            loop = LoopRegion(inTime: l.inTime, outTime: l.inTime + len)
            engageLoop()
        }
    }

    /// Pad-style loop toggle: engage a `beats`-beat loop, or leave the loop when that same size is already running.
    func toggleAutoLoop(beats: Double) {
        if loopActive, abs(loopBeats - beats) < 0.001 { exitLoop() } else { autoLoop(beats: beats) }
    }

    /// Tap tempo: the average spacing of the last taps (taps more than 2 s apart start over) becomes the track's BPM.
    func tapTempo() {
        let now = Date()
        if let last = taps.last, now.timeIntervalSince(last) > 2 { taps = [] }
        taps.append(now); if taps.count > 8 { taps.removeFirst() }
        guard taps.count >= 3 else { return }
        let intervals = zip(taps.dropFirst(), taps).map { $0.timeIntervalSince($1) }
        let bpm = 60 / (intervals.reduce(0, +) / Double(intervals.count))
        setBPM(bpm)
    }

    /// Replaces the grid's tempo, keeping the first beat (or using the playhead when the track has no grid).
    func setBPM(_ bpm: Double) {
        guard file != nil, bpm.isFinite, bpm >= 40, bpm <= 240 else { return }
        grid = BeatGrid(bpm: bpm, firstBeat: grid?.firstBeat ?? max(0, position))
    }

    /// Fixes a detected tempo that is an octave off (half-time / double-time).
    func scaleBPM(by factor: Double) { if let g = grid { setBPM(g.bpm * factor) } }

    /// Tempo match without phase alignment (SYNC also aligns beats).
    func matchTempo(to master: DJDeck) {
        guard let g = grid, let target = master.effectiveBPM else { return }
        let range = dj?.tempoRange ?? 8
        tempoPercent = max(-range, min(range, (target / g.bpm - 1) * 100))
    }

    func exitLoop() {
        guard loopActive, let l = loop, file != nil else { return }
        var f = currentFrame()
        // Slip: the track kept running underneath the loop; resume where it would be now.
        if slip, let a = slipAnchor {
            f = AVAudioFramePosition(min(duration, a.pos + Date().timeIntervalSince(a.at) * rate) * fileRate)
        }
        slipAnchor = nil
        let wasPlaying = isPlaying
        loopActive = false
        if player.engine != nil { player.stop() }
        generation += 1
        isPlaying = false
        parkedFrame = min(f, AVAudioFramePosition(duration * fileRate))
        _ = l
        needsSchedule = true
        position = Double(parkedFrame) / fileRate
        if wasPlaying { play() }
    }

    func toggleLoop() {
        if loopActive { exitLoop() } else if loop != nil { engageLoop() }
    }

    /// Plays the loop region repeatedly (the region is read into memory; loops are short).
    private func engageLoop() {
        guard let f = file, let l = loop, l.length > 0.01 else { return }
        let inF = AVAudioFramePosition(l.inTime * fileRate), len = AVAudioFrameCount(l.length * fileRate)
        guard len > 0, let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: len) else { return }
        let wasPlaying = isPlaying
        do { f.framePosition = inF; try f.read(into: buf, frameCount: len) } catch { loadError = "Loop could not be read: \(error.localizedDescription)"; return }
        generation += 1
        player.stop()
        anchorFrame = inF; parkedFrame = inF
        player.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
        if slip, !loopActive, slipAnchor == nil, wasPlaying { slipAnchor = (position, Date()) }
        loopActive = true; needsSchedule = false
        if wasPlaying { player.play(); isPlaying = true }
    }

    // MARK: Mixer-facing

    func applyEQ() {
        toneEQ.bands[0].gain = lowDB; toneEQ.bands[1].gain = midDB; toneEQ.bands[2].gain = highDB
    }

    func applyFilter() {
        let lp = filterEQ.bands[0], hp = filterEQ.bands[1]
        if filter < -0.02 {
            lp.bypass = false; lp.frequency = Float(20000 * pow(10, Double(filter) * 2))     // -1 -> 200 Hz
            hp.bypass = true
        } else if filter > 0.02 {
            hp.bypass = false; hp.frequency = Float(20 * pow(10, Double(filter) * 2.7))      // +1 -> ~10 kHz
            lp.bypass = true
        } else { lp.bypass = true; hp.bypass = true }
    }

    /// Called from the audio tap (any thread).
    func receiveLevel(_ db: Float) {
        let now = Date()
        guard now.timeIntervalSince(lastLevelPublish) > 0.033 else { return }
        lastLevelPublish = now
        DispatchQueue.main.async { [weak self] in self?.levelDB = db }
    }
}
