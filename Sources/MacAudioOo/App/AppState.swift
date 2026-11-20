import Foundation
import Combine

/// Top-level observable state shared by every view.
final class AppState: ObservableObject {
    let settings = AppSettings()
    let devices = AudioDeviceManager()
    let capabilities: [BackendCapability]
    let preferredBackend: BackendCapability?
    private var bag = Set<AnyCancellable>()

    init() {
        capabilities = CapabilityDetector.detectCurrent()
        preferredBackend = CapabilityDetector.preferred(from: capabilities)
        // Forward child changes so views observing AppState refresh.
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        devices.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
    }

    /// The device the user chose, or the system default if none/unplugged.
    var effectiveOutput: AudioDevice? {
        devices.device(uid: settings.outputDeviceUID) ?? devices.device(uid: devices.defaultOutputUID)
    }

    var selectedOutputMissing: Bool {
        settings.outputDeviceUID != nil && devices.device(uid: settings.outputDeviceUID) == nil
    }

    enum EngineStatus {
        case stopped(reason: String)
        var text: String { switch self { case .stopped: return "ENGINE STOPPED" } }
        var detail: String { switch self { case .stopped(let r): return r } }
    }

    /// Phase 1: no capture engine exists yet, so status is honestly "stopped".
    var engineStatus: EngineStatus {
        if let b = preferredBackend {
            return .stopped(reason: "Backend ready: \(b.kind.rawValue). Capture engine arrives in Phase 2.")
        }
        return .stopped(reason: "No per-app mixing backend available on macOS \(OSVersion.current.description). See Settings ▸ Audio.")
    }
}
