import Foundation
import AppKit
import Combine

/// Owns the mixer and the output stage. Follows the selected output device,
/// falling back to the system default when it disappears and returning when it
/// comes back. Never changes the system default device.
final class AudioEngine: ObservableObject {
    enum Status: Equatable {
        case stopped
        case running(device: String, sampleRate: Double)
        case failed(String)
        var isRunning: Bool { if case .running = self { return true }; return false }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var channels: [AudioChannel] = []
    @Published var masterVolumeDB: Float = 0 { didSet { storage.master.pointee.volumeTarget = dbToLinear(masterVolumeDB) } }
    @Published var masterMute = false { didSet { storage.master.pointee.mute = masterMute } }
    @Published var dim = false { didSet { storage.master.pointee.dim = dim } }
    @Published var mono = false { didSet { storage.master.pointee.mono = mono } }
    @Published var limiterThresholdDB: Float = -1 { didSet { storage.master.pointee.limiterThreshold = dbToLinear(limiterThresholdDB) } }

    private let output = AudioOutput()
    private let storage = AudioMixer.Storage.allocate()
    private(set) var mixer: AudioMixer?

    init() {
        storage.master.pointee.limiterThreshold = dbToLinear(limiterThresholdDB)
    }
    deinit { output.stop(); storage.deallocate() }
    private var preferredUID: String?
    private var retired: [Unmanaged<ChannelSource>] = []

    var sampleRate: Double { output.sampleRate }
    var bufferFrames: UInt32 { output.bufferFrames }
    var latencyMs: Double {
        guard output.sampleRate > 0 else { return 0 }
        return Double(output.bufferFrames + output.latencyFrames) / output.sampleRate * 1000
    }
    var callbackCount: UInt64 { output.callbackCount }
    var debugCounters: String { output.debugCounters }

    /// (Re)selects the output device. `uid == nil` means system default.
    func selectOutput(uid: String?, devices: AudioDeviceManager) {
        preferredUID = uid
        reconcile(devices: devices)
    }

    /// Call whenever the device list or default device changes.
    func reconcile(devices: AudioDeviceManager) {
        // Chosen device -> system default -> built-in -> anything. (When the system default is
        // the MacAudioOo virtual device it is not in this list, so we fall through to real hardware.)
        let target = devices.device(uid: preferredUID)
            ?? devices.device(uid: devices.defaultOutputUID)
            ?? devices.outputDevices.first { $0.transport == "Built-in" }
            ?? devices.outputDevices.first
        guard let device = target else {
            output.stop(); status = .failed("No output device available"); return
        }
        if output.isRunning, output.deviceID == device.id, case .running = status { return }
        start(on: device)
    }

    private func start(on device: AudioDevice) {
        do {
            try output.start(device: device) { [weak self] rate in
                // Channel/master parameters live in engine-owned storage, so a new mixer keeps them.
                let m = AudioMixer(sampleRate: rate, storage: self?.storage)
                self?.mixer = m
                return m
            }
            status = .running(device: device.name, sampleRate: output.sampleRate)
        } catch {
            status = .failed("\(device.name): \(error)")
        }
    }

    /// Adds a channel fed by `source`. Returns nil if all slots are in use.
    @discardableResult
    func addChannel(name: String, pid: pid_t? = nil, icon: NSImage? = nil, source: ChannelSource) -> AudioChannel? {
        let slots = storage.slots
        guard let free = (0..<AudioMixer.maxChannels).first(where: { !slots[$0].active }) else { return nil }
        let ch = AudioChannel(slotIndex: free, slot: slots + free, name: name, pid: pid, icon: icon)
        slots[free] = ChannelState(active: false, volumeTarget: 1, volumeCurrent: 0, balance: 0, mute: false, solo: false,
                                     peak: 0, rmsSquares: 0, rmsCount: 0, source: Unmanaged.passRetained(source))
        slots[free].active = true   // published last
        channels.append(ch)
        return ch
    }

    func removeChannel(_ ch: AudioChannel) {
        let slots = storage.slots
        slots[ch.slotIndex].active = false
        let src = slots[ch.slotIndex].source
        slots[ch.slotIndex].source = nil
        channels.removeAll { $0.id == ch.id }
        // Release after the render thread has certainly finished its current block.
        if let s = src { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { s.release() } }
    }

    func masterMeter() -> (peakL: Float, peakR: Float, rmsDB: Float, grDB: Float) {
        let p = storage.master.pointee
        storage.master.pointee.peakL = 0; storage.master.pointee.peakR = 0
        let rms = p.rmsCount > 0 ? sqrtf(p.rmsSquares / p.rmsCount) : 0
        return (linearToDB(p.peakL), linearToDB(p.peakR), linearToDB(rms), linearToDB(p.limiterGain))
    }
}
