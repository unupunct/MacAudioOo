import Foundation
import CoreAudio

struct AudioDevice: Identifiable, Hashable {
    var id: AudioDeviceID
    var uid: String
    var name: String
    var outputChannels: Int
    var inputChannels: Int
    var nominalSampleRate: Double
    var transport: String
}

/// Real Core Audio device enumeration with hot-plug and default-device
/// change notifications. Never changes the system default device.
final class AudioDeviceManager: ObservableObject {
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var defaultOutputUID: String?

    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "MacAudioOo.devices")

    init() {
        refresh()
        var devAddr = Self.address(kAudioHardwarePropertyDevices)
        let l1: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refreshAsync() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devAddr, queue, l1)
        devicesListener = l1
        var defAddr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let l2: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refreshAsync() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defAddr, queue, l2)
        defaultListener = l2
    }

    deinit {
        var devAddr = Self.address(kAudioHardwarePropertyDevices)
        if let l = devicesListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devAddr, queue, l)
        }
        var defAddr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        if let l = defaultListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defAddr, queue, l)
        }
    }

    private func refreshAsync() { DispatchQueue.main.async { [weak self] in self?.refresh() } }

    func refresh() {
        let all = Self.allDevices()
        outputDevices = all.filter { $0.outputChannels > 0 }
        defaultOutputUID = Self.defaultOutputDeviceID().flatMap { id in all.first { $0.id == id }?.uid }
    }

    func device(uid: String?) -> AudioDevice? {
        guard let uid = uid else { return nil }
        return outputDevices.first { $0.uid == uid }
    }

    // MARK: Core Audio helpers

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return (st == noErr && id != 0) ? id : nil
    }

    static func allDevices() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(describe)
    }

    private static func describe(_ id: AudioDeviceID) -> AudioDevice? {
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        var rateAddr = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var rsize = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &rateAddr, 0, nil, &rsize, &rate)
        var tAddr = address(kAudioDevicePropertyTransportType)
        var t = UInt32(0)
        var tsize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &tAddr, 0, nil, &tsize, &t)
        return AudioDevice(id: id, uid: uid, name: name,
                           outputChannels: channelCount(id, kAudioObjectPropertyScopeOutput),
                           inputChannels: channelCount(id, kAudioObjectPropertyScopeInput),
                           nominalSampleRate: rate, transport: transportName(t))
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ref) == noErr, let r = ref else { return nil }
        return r.takeRetainedValue() as String
    }

    private static func channelCount(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transportName(_ t: UInt32) -> String {
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "HDMI/DisplayPort"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        default: return "Other"
        }
    }
}
