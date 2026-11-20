import Foundation
import Combine

/// Top-level observable state shared by every view.
final class AppState: ObservableObject {
    let settings = AppSettings()
    let devices = AudioDeviceManager()
    let engine = AudioEngine()
    let processes = AudioProcessManager()
    @Published private(set) var capabilities: [BackendCapability] = CapabilityDetector.detectCurrent()
    @Published private(set) var driverBackend: VirtualDriverBackend?
    var preferredBackend: BackendCapability? { CapabilityDetector.preferred(from: capabilities) }
    private var bag = Set<AnyCancellable>()

    /// Re-detects backends (e.g. after the user installs the driver) and (re)starts the
    /// Monterey driver backend when it is usable. Never touches system audio settings.
    func refreshBackends() {
        capabilities = CapabilityDetector.detectCurrent()
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
        engine.selectOutput(uid: settings.outputDeviceUID, devices: devices)
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
        // The driver device appearing/disappearing (install, removal, audio restart) restarts the backend.
        devices.$driverDeviceLoaded.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshBackends()
        }.store(in: &bag)

        // Tear down a channel when its application quits.
        processes.onTerminate = { [weak self] pid in
            guard let self = self else { return }
            for ch in self.engine.channels where ch.pid == pid { self.engine.removeChannel(ch) }
        }
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
            var s = "Output: \(d) @ \(Int(r)) Hz."
            if preferredBackend == nil {
                s += " No app-capture backend on macOS \(OSVersion.current.description); only generated test signals can be mixed."
            }
            return s
        case .stopped: return "The audio engine is not running."
        case .failed(let m): return m
        }
    }
}
