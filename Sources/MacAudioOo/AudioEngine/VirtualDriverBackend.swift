import Foundation
import AppKit

/// Monterey backend: applications that play to the "MacAudioOo Mixer" virtual device show
/// up as independent HAL clients in the driver's shared memory. This class turns each
/// active client into a mixer channel and removes it when the client goes away.
///
/// Polling is deliberate and cheap (4 Hz, 32 slot headers): the driver cannot push
/// notifications into the app without a Mach service, which the sandboxed HAL host does
/// not need to expose for this design.
final class VirtualDriverBackend: ObservableObject, AudioBackend {
    enum State: Equatable {
        case stopped
        case driverNotLoaded(String)
        case running(clients: Int)
    }

    @Published private(set) var state: State = .stopped
    let capability: BackendCapability
    private weak var engine: AudioEngine?
    private var shm: DriverSharedMemory?
    private var timer: Timer?
    private var channels: [Int: (generation: UInt32, channel: AudioChannel)] = [:]

    init(capability: BackendCapability, engine: AudioEngine) {
        self.capability = capability; self.engine = engine
    }

    func start() throws {
        stop()
        guard let shm = DriverSharedMemory() else {
            state = .driverNotLoaded(FileManager.default.fileExists(atPath: CapabilityDetector.driverPath)
                ? "The driver is installed but not loaded. Restart the audio system (see Documentation/DRIVER.md) or log out and back in."
                : "The MacAudioOo driver is not installed.")
            return
        }
        self.shm = shm
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.reconcile() }
        reconcile()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let e = engine { for (_, v) in channels { e.removeChannel(v.channel) } }
        channels.removeAll(); shm = nil; state = .stopped
    }

    /// Public so tests and diagnostics can drive it deterministically.
    func reconcile() {
        guard let shm = shm, let engine = engine, engine.status.isRunning else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let active = shm.activeSlots().filter { $0.pid != me }
        let activeIdx = Set(active.map { $0.index })

        for (idx, v) in channels where !activeIdx.contains(idx) {
            engine.removeChannel(v.channel); channels[idx] = nil
        }
        for s in active {
            if let existing = channels[s.index], existing.generation == s.generation { continue }
            if let old = channels[s.index] { engine.removeChannel(old.channel) }   // slot reused by a new client
            let app = NSRunningApplication(processIdentifier: s.pid)
            let name = app?.localizedName ?? (s.bundleID.isEmpty ? "Process \(s.pid)" : s.bundleID)
            let src = DriverSlotSource(shm: shm, slot: s.index, outputRate: engine.sampleRate)
            if let ch = engine.addChannel(name: name, pid: s.pid, icon: app?.icon, source: src) {
                channels[s.index] = (s.generation, ch)
            }
        }
        state = .running(clients: channels.count)
    }
}
