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
        case running(clients: Int, apps: Int)
    }

    @Published private(set) var state: State = .stopped
    let capability: BackendCapability
    private weak var engine: AudioEngine?
    private var shm: DriverSharedMemory?
    private var timer: Timer?
    private var manager: GroupedChannelManager?
    private var identityCache: [String: AppIdentity] = [:]
    /// Overridable for tests (default: real process lookups).
    var resolverEnv: AppIdentityResolver.Env = .system

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
        if let e = engine { manager = GroupedChannelManager(engine: e) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.reconcile() }
        reconcile()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        manager?.removeAll(); manager = nil; identityCache.removeAll()
        shm = nil; state = .stopped
    }

    /// Public so tests and diagnostics can drive it deterministically.
    /// Every driver client (one per audio connection of a process) is attributed to its application; all clients of
    /// one application (browser helper processes, Electron renderers, …) share a single mixer channel.
    func reconcile() {
        guard let shm = shm, let engine = engine, let manager = manager, engine.status.isRunning else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let active = shm.activeSlots().filter { $0.pid != me }

        var desired: [String: GroupedChannelManager.Desired] = [:]
        var liveKeys = Set<String>()
        for s in active {
            let slotKey = "\(s.index)#\(s.generation)"
            liveKeys.insert(slotKey)
            let identity: AppIdentity
            if let cached = identityCache[slotKey] { identity = cached } else {
                identity = AppIdentityResolver.resolve(pid: s.pid, bundleHint: s.bundleID.isEmpty ? nil : s.bundleID, env: resolverEnv)
                identityCache[slotKey] = identity
            }
            var d = desired[identity.key] ?? GroupedChannelManager.Desired(identity: identity, members: [])
            let index = s.index, rate = engine.sampleRate
            d.members.append((id: slotKey, make: { DriverSlotSource(shm: shm, slot: index, outputRate: rate) }))
            desired[identity.key] = d
        }
        identityCache = identityCache.filter { liveKeys.contains($0.key) }
        manager.reconcile(desired)
        state = .running(clients: active.count, apps: manager.channelCount)
    }
}
