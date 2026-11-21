import Foundation
import Combine
import AVFoundation

/// What the UI shows for one track while recording.
struct LiveTrack: Identifiable, Equatable {
    var id: String            // "mix" or the channel's UUID string
    var name: String
    var isMix: Bool
    var frames: Int64
    var droppedFrames: Int
    var peaks: [WaveformPeak]
    var error: String?
}

/// Records the stereo mix and/or armed application channels to separate WAV files.
///
/// Processing policy (documented, deliberate):
///  - MIX file: the final output after all master processing (master EQ, volume, DIM/MONO, limiter),
///    i.e. exactly what is sent to the output device, including reverb/delay returns.
///  - STEM files: one per armed channel, taken after the channel's EQ and compressor and BEFORE its fader,
///    mute, solo, group and ducking gains, and BEFORE reverb/delay sends. Stems are dry, so shared effects
///    are never duplicated inside them and later mixing is not affected by live fader moves.
/// Audio travels from the real-time mixer to the recorder through lock-free rings; file I/O happens on a
/// background queue, never on the audio thread.
final class RecordingEngine: ObservableObject {
    enum State: Equatable { case idle, recording, paused }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var liveTracks: [LiveTrack] = []
    @Published private(set) var lastError: String?
    @Published private(set) var sessionFolder: URL?
    @Published var recordMix = true
    /// Session name used for the recording folder ("<name> <date time>").
    @Published var sessionName = "Session 1"
    /// Stem options: apply each channel's EQ/compressor, and/or its fader (levels). Reverb/delay are shared and only ever in the mix.
    @Published var stemsIncludeEQ = true
    @Published var stemsIncludeFader = false
    private var stemMode: UInt8 { stemsIncludeFader ? 2 : (stemsIncludeEQ ? 1 : 0) }
    @Published private(set) var freeBytes: Int64?

    private struct Active {
        var key: String
        var channelID: UUID?
        var writer: RecordingTrackWriter
    }

    private let engine: AudioEngine
    let library: RecordingLibrary
    private let queue = DispatchQueue(label: "MacAudioOo.recorder", qos: .userInitiated)
    private var active: [Active] = []                  // mutated on `queue`, read on main for UI via snapshots
    private var drainTimer: DispatchSourceTimer?
    private var uiTimer: Timer?
    private let pausedFlag = NSLock()
    private var pausedValue = false
    private var startedAt = Date()
    private var startRate: Double = 0
    private var activeSessionName = ""
    private var bag = Set<AnyCancellable>()

    init(engine: AudioEngine, library: RecordingLibrary) {
        self.engine = engine; self.library = library
        // A recorded application quitting must finalize just its file.
        engine.$channels.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] chans in
            self?.channelsChanged(Set(chans.map { $0.id }))
        }.store(in: &bag)
        // Changing the output device's sample rate mid-recording would corrupt timing: stop cleanly.
        engine.$status.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self = self, self.state != .idle, self.engine.sampleRate != self.startRate else { return }
            self.stop(reason: "The output device's sample rate changed during recording; the recording was stopped and saved.")
        }.store(in: &bag)
        refreshFreeSpace()
    }

    var isPaused: Bool { pausedFlag.lock(); defer { pausedFlag.unlock() }; return pausedValue }
    private func setPaused(_ v: Bool) { pausedFlag.lock(); pausedValue = v; pausedFlag.unlock() }

    var armedChannels: [AudioChannel] { engine.channels.filter { $0.recArm } }
    var plannedTrackCount: Int { (recordMix ? 1 : 0) + armedChannels.count }

    func refreshFreeSpace() { freeBytes = RecordingLibrary.availableBytes(at: library.root) }

    /// Estimated remaining recording time for the planned tracks.
    var remainingSeconds: Double? {
        guard let free = freeBytes, plannedTrackCount > 0 else { return nil }
        return Double(free) / Double(RecordingLibrary.bytesPerSecond(tracks: plannedTrackCount))
    }

    // MARK: Transport

    func start() {
        guard state == .idle else { return }
        lastError = nil
        guard engine.status.isRunning, engine.sampleRate > 0 else { lastError = "The audio engine is not running."; return }
        let armed = armedChannels
        guard recordMix || !armed.isEmpty else { lastError = "Nothing to record: enable MIX or arm at least one channel."; return }
        if let free = RecordingLibrary.availableBytes(at: library.root), free < 200_000_000 {
            lastError = "Less than 200 MB of free disk space at the recording destination."; return
        }
        let now = Date()
        let folder = library.root.appendingPathComponent(RecordingLibrary.sessionFolderName(for: now, name: sessionName), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            startRate = engine.sampleRate
            var names = Set<String>()
            var list: [Active] = []
            var planned: [RecordedTrackInfo] = []
            func add(_ title: String, key: String, channel: UUID?, isMix: Bool) throws {
                let file = RecordingLibrary.fileName(for: title, existing: names); names.insert(file.lowercased())
                let w = try RecordingTrackWriter(name: title, url: folder.appendingPathComponent(file), isMix: isMix, sourceRate: startRate)
                list.append(Active(key: key, channelID: channel, writer: w))
                planned.append(RecordedTrackInfo(name: title, fileName: file, frames: 0, droppedFrames: 0, isMix: isMix))
            }
            if recordMix { try add("Mix", key: "mix", channel: nil, isMix: true) }
            for ch in armed { try add(ch.name, key: ch.id.uuidString, channel: ch.id, isMix: false) }

            activeSessionName = folder.lastPathComponent
            let marker = RecordingSessionInfo(id: activeSessionName, name: activeSessionName, startedAt: now, sampleRate: 48_000,
                                              bitDepth: 24, tracks: planned, recovered: false)
            try RecordingLibrary.encoder.encode(marker).write(to: folder.appendingPathComponent(RecordingLibrary.markerName), options: .atomic)

            queue.sync { self.active = list }
            setPaused(false)
            startedAt = now; sessionFolder = folder; elapsed = 0
            // Attach taps last: audio starts flowing into the rings from here on.
            for a in list {
                if a.key == "mix" { engine.setMixTap(a.writer.ring) }
                else if let ch = engine.channels.first(where: { $0.id == a.channelID }) { ch.recordTapMode = stemMode; engine.setStemTap(ch, ring: a.writer.ring) }
            }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
            t.setEventHandler { [weak self] in self?.drainAll() }
            t.resume(); drainTimer = t
            uiTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.uiTick() }
            state = .recording
            uiTick()
        } catch {
            lastError = "Could not start recording: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: folder)
        }
    }

    func pause() { guard state == .recording else { return }; setPaused(true); state = .paused }
    func resume() { guard state == .paused else { return }; setPaused(false); state = .recording }

    func stop(reason: String? = nil) {
        guard state != .idle else { return }
        state = .idle
        uiTimer?.invalidate(); uiTimer = nil
        // Detach taps first so no more audio enters the rings, then finalize on the recorder queue.
        engine.setMixTap(nil)
        for ch in engine.channels { engine.setStemTap(ch, ring: nil) }
        drainTimer?.cancel(); drainTimer = nil
        let folder = sessionFolder, started = startedAt, name = activeSessionName
        var errors: [String] = []
        var infos: [RecordedTrackInfo] = []
        queue.sync {
            for a in self.active {
                do { try a.writer.finish() } catch { errors.append("\(a.writer.name): \(error.localizedDescription)") }
                if let e = a.writer.error { errors.append(e) }
                infos.append(RecordedTrackInfo(name: a.writer.name, fileName: a.writer.url.lastPathComponent,
                                               frames: a.writer.framesWritten, droppedFrames: a.writer.overflowedFrames, isMix: a.writer.isMix))
            }
            self.active.removeAll()
        }
        if let folder = folder {
            let info = RecordingSessionInfo(id: name, name: name, startedAt: started, sampleRate: 48_000, bitDepth: 24,
                                            tracks: infos, recovered: false)
            do {
                try RecordingLibrary.encoder.encode(info).write(to: folder.appendingPathComponent(RecordingLibrary.infoName), options: .atomic)
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(RecordingLibrary.markerName))
            } catch { errors.append("session.json: \(error.localizedDescription)") }
        }
        let dropped = infos.reduce(0) { $0 + $1.droppedFrames }
        var msg = reason ?? ""
        if dropped > 0 { msg += (msg.isEmpty ? "" : " ") + "Warning: \(dropped) frames were dropped because the disk could not keep up." }
        if !errors.isEmpty { msg += (msg.isEmpty ? "" : " ") + errors.joined(separator: "; ") }
        lastError = msg.isEmpty ? nil : msg
        liveTracks = []; sessionFolder = nil
        library.refresh(); refreshFreeSpace()
    }

    // MARK: Background drain

    private func drainAll() {
        let discard = isPaused
        for a in active { a.writer.drain(discard: discard) }
    }

    private func channelsChanged(_ alive: Set<UUID>) {
        guard state != .idle else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            let gone = self.active.filter { $0.channelID != nil && !alive.contains($0.channelID!) }
            for a in gone { try? a.writer.finish() }
            self.active.removeAll { a in gone.contains { $0.key == a.key } }
        }
    }

    // MARK: UI refresh (10 Hz)

    private func uiTick() {
        var tracks: [LiveTrack] = []
        var maxFrames: Int64 = 0
        var failure: String?
        queue.sync {
            for a in self.active {
                let w = a.writer
                maxFrames = max(maxFrames, w.framesWritten)
                if failure == nil, let e = w.error { failure = e }
                tracks.append(LiveTrack(id: a.key, name: w.name, isMix: w.isMix, frames: w.framesWritten,
                                        droppedFrames: w.overflowedFrames, peaks: w.recentPeaks(2000), error: w.error))
            }
        }
        liveTracks = tracks
        elapsed = Double(maxFrames) / Double(RecordingTrackWriter.outputRate)
        refreshFreeSpace()
        if let f = failure { stop(reason: f); return }
        if let free = freeBytes, free < 50_000_000 { stop(reason: "Recording stopped: less than 50 MB of disk space left.") }
    }
}
