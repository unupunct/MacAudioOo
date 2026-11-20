import Foundation
import AppKit
import Combine

/// Top-level observable state shared by every view.
final class AppState: ObservableObject {
    let settings = AppSettings()
    let devices = AudioDeviceManager()
    let engine = AudioEngine()
    let processes = AudioProcessManager()
    lazy var recordingLibrary = RecordingLibrary(root: URL(fileURLWithPath: settings.recordingDirectory))
    lazy var recorder = RecordingEngine(engine: engine, library: recordingLibrary)
    lazy var library = MusicLibrary()
    lazy var dj = DJEngine()
    lazy var scenes = SceneManager(engine: engine)
    lazy var history = MixerHistory(engine: engine)
    lazy var ducking = DuckingController(engine: engine)
    private(set) var menuBar: MenuBarController?
    @Published private(set) var capabilities: [BackendCapability] = CapabilityDetector.detectCurrent()
    @Published private(set) var driverBackend: VirtualDriverBackend?
    @Published private(set) var tapBackend: CoreAudioTapBackend?
    var preferredBackend: BackendCapability? { CapabilityDetector.preferred(from: capabilities) }
    private var bag = Set<AnyCancellable>()

    /// Re-detects backends (e.g. after the user installs the driver) and (re)starts the
    /// Monterey driver backend when it is usable. Never touches system audio settings.
    func refreshBackends() {
        capabilities = CapabilityDetector.detectCurrent()
        tapBackend?.stop(); tapBackend = nil
        if let cap = capabilities.first(where: { $0.kind == .coreAudioTap && $0.usable }) {
            let b = CoreAudioTapBackend(capability: cap, engine: engine)
            b.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
            tapBackend = b
            try? b.start()
        }
        driverBackend?.stop(); driverBackend = nil
        if let cap = capabilities.first(where: { $0.kind == .virtualDriver && $0.usable }) {
            let b = VirtualDriverBackend(capability: cap, engine: engine)
            b.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
            driverBackend = b
            try? b.start()
        }
    }

    init() {
        // Forward child changes so views observing AppState refresh.
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        devices.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)

        // Follow output-device choice and hot-plug/default changes.
        AppLog.shared.log("MacAudioOo started on macOS \(OSVersion.current.description)")
        engine.preferredBufferFrames = UInt32(max(0, settings.bufferFrames))
        engine.selectOutput(uid: settings.outputDeviceUID, devices: devices)
        settings.$bufferFrames.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] n in
            guard let self = self else { return }
            self.engine.preferredBufferFrames = UInt32(max(0, n))
            self.engine.restartOutput(devices: self.devices)
            AppLog.shared.log("Requested buffer size: \(n == 0 ? "device default" : "\(n) frames")")
        }.store(in: &bag)
        engine.$status.removeDuplicates().receive(on: DispatchQueue.main).sink { status in
            switch status {
            case .running(let d, let r): AppLog.shared.log("Engine running on \(d) @ \(Int(r)) Hz")
            case .stopped: AppLog.shared.log("Engine stopped")
            case .failed(let m): AppLog.shared.log("Engine ERROR: \(m)")
            }
        }.store(in: &bag)
        settings.$outputDeviceUID.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] uid in
            guard let self = self else { return }
            self.engine.selectOutput(uid: uid, devices: self.devices)
        }.store(in: &bag)
        devices.$outputDevices.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self = self else { return }
            self.engine.reconcile(devices: self.devices)
        }.store(in: &bag)
        devices.$defaultOutputUID.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self = self else { return }
            self.engine.reconcile(devices: self.devices)
        }.store(in: &bag)

        refreshBackends()
        recordingLibrary.refresh()          // also repairs recordings interrupted by a crash
        _ = recorder                        // start observing channels/engine right away
        scenes.currentOutputUID = { [weak self] in self?.settings.outputDeviceUID }
        scenes.applyOutputUID = { [weak self] uid in
            guard let self = self, let uid = uid, self.devices.device(uid: uid) != nil else { return }
            self.settings.outputDeviceUID = uid
        }
        _ = history

        // DJ: preferences, library hooks, and the output device (the mixer's device, never the system default).
        dj.fourDecks = settings.djFourDecks
        dj.bpmRange = settings.bpmMin...max(settings.bpmMin + 10, settings.bpmMax)
        dj.tempoRange = settings.djTempoRange
        dj.onAnalysis = { [weak self] id, r in self?.library.setAnalysis(id, bpm: r.bpm, firstBeat: r.firstBeat) }
        dj.onPlayed = { [weak self] id in self?.library.markPlayed(id) }
        engine.$status.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self = self else { return }
            self.dj.setOutputDevice(id: self.devices.device(uid: self.engine.currentDeviceUID)?.id)
        }.store(in: &bag)
        Publishers.CombineLatest3(settings.$bpmMin, settings.$bpmMax, settings.$djTempoRange).sink { [weak self] lo, hi, range in
            self?.dj.bpmRange = lo...max(lo + 10, hi); self?.dj.tempoRange = range
        }.store(in: &bag)
        // The driver device appearing/disappearing (install, removal, audio restart) restarts the backend.
        devices.$driverDeviceLoaded.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshBackends()
        }.store(in: &bag)

        // Remember the last real system output, so it can be restored (opt-in) when the app quits while the silent
        // MacAudioOo driver device is selected.
        settings.previousOutputUID = OutputRestorePolicy.remembered(current: settings.previousOutputUID,
                                                                    newDefaultUID: devices.defaultOutputUID, driverUID: AudioDeviceManager.driverDeviceUID)
        devices.$defaultOutputUID.receive(on: DispatchQueue.main).sink { [weak self] uid in
            guard let self = self else { return }
            let next = OutputRestorePolicy.remembered(current: self.settings.previousOutputUID, newDefaultUID: uid,
                                                      driverUID: AudioDeviceManager.driverDeviceUID)
            if next != self.settings.previousOutputUID { self.settings.previousOutputUID = next }
        }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restoreOutputIfEnabled()
        }

        // Menu bar item, launch at login, ducking.
        let bar = MenuBarController(engine: engine)
        bar.restoreTitle = { [weak self] in self?.restoreOutputTitle }
        bar.onRestore = { [weak self] in self?.restoreOutputNow() }
        menuBar = bar
        settings.$menuBarEnabled.receive(on: DispatchQueue.main).sink { bar.setVisible($0) }.store(in: &bag)
        settings.$launchAtLogin.dropFirst().sink { on in
            if let err = LoginItem.set(on) { AppLog.shared.log(err) } else { AppLog.shared.log("Launch at login \(on ? "enabled" : "disabled")") }
        }.store(in: &bag)
        _ = ducking
        recorder.$lastError.compactMap { $0 }.sink { AppLog.shared.log("Recording: \($0)") }.store(in: &bag)
        dj.$error.compactMap { $0 }.sink { AppLog.shared.log("DJ: \($0)") }.store(in: &bag)

        // Tear down a channel when its application quits.
        processes.onTerminate = { [weak self] pid in
            guard let self = self else { return }
            for ch in self.engine.channels where ch.pid == pid { self.engine.removeChannel(ch) }
        }
    }

    // MARK: Leaving the silent driver device

    /// Name of the device the system output would be switched back to, or nil if there is nothing to switch
    /// (the system output is not the MacAudioOo driver device, or the previous device is unknown/unplugged).
    var restoreOutputTitle: String? {
        guard devices.systemDefaultIsDriver, let uid = settings.previousOutputUID, let d = devices.device(uid: uid) else { return nil }
        return d.name
    }

    /// Explicit user action: set the system output back to the previous real device.
    @discardableResult
    func restoreOutputNow() -> Bool {
        guard devices.systemDefaultIsDriver, let uid = settings.previousOutputUID else { return false }
        let ok = devices.setDefaultOutput(uid: uid)
        AppLog.shared.log(ok ? "System output switched back to the previous device (user request)" : "Could not switch the system output back")
        return ok
    }

    /// Opt-in (Settings): on a normal quit, do the same so the Mac is not left on a device that is silent without the app.
    func restoreOutputIfEnabled() {
        guard let uid = OutputRestorePolicy.target(enabled: settings.restoreOutputOnQuit, defaultIsDriver: devices.systemDefaultIsDriver,
                                                   previousUID: settings.previousOutputUID,
                                                   availableUIDs: devices.outputDevices.map { $0.uid }) else { return }
        let ok = devices.setDefaultOutput(uid: uid)
        AppLog.shared.log(ok ? "Quit: system output restored to the previous device (setting enabled)" : "Quit: could not restore the system output")
    }

    /// The device the user chose, or the system default if none/unplugged.
    var effectiveOutput: AudioDevice? {
        devices.device(uid: settings.outputDeviceUID) ?? devices.device(uid: devices.defaultOutputUID)
    }

    var selectedOutputMissing: Bool {
        settings.outputDeviceUID != nil && devices.device(uid: settings.outputDeviceUID) == nil
    }

    var engineStatusText: String {
        switch engine.status {
        case .running: return "ENGINE RUNNING"
        case .stopped: return "ENGINE STOPPED"
        case .failed: return "ENGINE ERROR"
        }
    }

    var engineStatusDetail: String {
        switch engine.status {
        case .running(let d, let r):
            var s = "Output: \(d) @ \(Int(r)) Hz. Render load \(Int(engine.cpuLoad * 100)) % (worst block \(Int(engine.worstBlockLoad * 100)) % of its time)."
            if engine.health == .strained || engine.health == .overloaded { s += " The engine is struggling to keep up: close other heavy apps or raise the buffer size in Settings." }
            if preferredBackend == nil {
                s += " No app-capture backend on macOS \(OSVersion.current.description); only generated test signals can be mixed."
            }
            return s
        case .stopped: return "The audio engine is not running."
        case .failed(let m): return m
        }
    }
}
