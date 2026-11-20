import Foundation
import AppKit
import CoreAudio
import AudioToolbox

// =====================================================================================================
//  macOS 14.2+ backend: one Core Audio *process tap* per application that is playing audio.
//
//  STATUS: written against Apple's documented Core Audio process-tap API but NOT compiled against the
//  macOS 14.2 SDK and NOT run on macOS 14.2+ (the development Mac runs Monterey, SDK 13.1). The tap
//  symbols are therefore resolved at run time (dlsym / Objective-C runtime) so the binary still loads on
//  macOS 12/13, and every OS call is checked and surfaced in `state`. Verify on a macOS 14.2+ machine before
//  calling it working. FourCC selector values and the aggregate-device dictionary keys are from the public
//  headers; they are listed in `Tap` below so they are easy to audit.
// =====================================================================================================

/// FourCC helper.
@inline(__always) private func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

private enum Tap {
    // AudioHardware.h (macOS 14.2): process object list / PID translation, and AudioHardwareTapping.h.
    static let processObjectList = fourCC("prs#")      // kAudioHardwarePropertyProcessObjectList
    static let translatePID = fourCC("id2p")           // kAudioHardwarePropertyTranslatePIDToProcessObject
    static let processPID = fourCC("ppid")             // kAudioProcessPropertyPID
    static let processBundleID = fourCC("pbid")        // kAudioProcessPropertyBundleID
    static let processRunningOutput = fourCC("piro")   // kAudioProcessPropertyIsRunningOutput
    static let tapFormat = fourCC("tfmt")              // kAudioTapPropertyFormat
    // CATapMuteBehavior
    static let mutedWhenTapped = 2
    // Aggregate device dictionary keys.
    static let aggName = "name", aggUID = "uid", aggMain = "master", aggPrivate = "private", aggStacked = "stacked"
    static let aggSubDevices = "subdevices", subDeviceUID = "uid"
    static let aggTapList = "taps", aggTapAutoStart = "tapautostart", subTapUID = "uid", subTapDrift = "drift"

    typealias CreateTap = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<AudioObjectID>) -> OSStatus
    typealias DestroyTap = @convention(c) (AudioObjectID) -> OSStatus

    static func symbol<T>(_ name: String, as: T.Type) -> T? {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }   // RTLD_DEFAULT
        return unsafeBitCast(p, to: T.self)
    }
}

/// One application's tap + private aggregate device + IO proc writing into a ring buffer.
final class ProcessTap {
    let processObject: AudioObjectID
    let pid: pid_t
    let ring = AudioRingBuffer(minimumFrames: 1 << 16)
    private(set) var sampleRate: Double = 48000
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "MacAudioOo.tap", qos: .userInteractive)
    private var tmpL = [Float](repeating: 0, count: 8192), tmpR = [Float](repeating: 0, count: 8192)

    init(processObject: AudioObjectID, pid: pid_t) { self.processObject = processObject; self.pid = pid }
    deinit { stop() }

    /// `outputDeviceUID`: the device MacAudioOo plays through; it clocks the aggregate device.
    func start(outputDeviceUID: String, muteOriginal: Bool) throws {
        guard let create = Tap.symbol("AudioHardwareCreateProcessTap", as: Tap.CreateTap.self),
              let cls = NSClassFromString("CATapDescription") as? NSObject.Type else {
            throw TapError.unavailable
        }
        // CATapDescription *d = [[CATapDescription alloc] initStereoMixdownOfProcesses:@[ @(processObject) ]];
        let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject
        guard let desc = allocated?.perform(NSSelectorFromString("initStereoMixdownOfProcesses:"),
                                            with: [NSNumber(value: processObject)])?.takeUnretainedValue() as? NSObject else {
            throw TapError.unavailable
        }
        let uuid = UUID()
        desc.setValue(uuid, forKey: "UUID")
        desc.setValue("MacAudioOo \(pid)", forKey: "name")
        desc.setValue(muteOriginal ? Tap.mutedWhenTapped : 0, forKey: "muteBehavior")   // CATapMuteBehavior
        var tap: AudioObjectID = 0
        var st = create(Unmanaged.passUnretained(desc).toOpaque(), &tap)
        guard st == noErr, tap != 0 else { throw TapError.os("AudioHardwareCreateProcessTap", st) }
        tapID = tap

        // Stream format of the tap (sample rate, channel layout).
        var fmtAddr = AudioObjectPropertyAddress(mSelector: Tap.tapFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        st = AudioObjectGetPropertyData(tap, &fmtAddr, 0, nil, &size, &asbd)
        guard st == noErr else { stop(); throw TapError.os("read tap format", st) }
        sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000
        let interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let channels = max(1, Int(asbd.mChannelsPerFrame))

        let aggUID = UUID().uuidString
        let dict: [String: Any] = [
            Tap.aggName: "MacAudioOo Tap \(pid)", Tap.aggUID: aggUID, Tap.aggMain: outputDeviceUID,
            Tap.aggPrivate: true, Tap.aggStacked: false, Tap.aggTapAutoStart: true,
            Tap.aggSubDevices: [[Tap.subDeviceUID: outputDeviceUID]],
            Tap.aggTapList: [[Tap.subTapDrift: true, Tap.subTapUID: uuid.uuidString]],
        ]
        var agg: AudioObjectID = 0
        st = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        guard st == noErr else { stop(); throw TapError.os("AudioHardwareCreateAggregateDevice", st) }
        aggregateID = agg

        let ring = self.ring
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, queue) { [weak self] _, inData, _, _, _ in
            guard let self = self else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard list.count > 0 else { return }
            if interleaved || list.count == 1 {
                let ch = interleaved ? channels : 1
                guard let base = list[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                let frames = Int(list[0].mDataByteSize) / (MemoryLayout<Float>.size * max(1, ch))
                var done = 0
                while done < frames {
                    let n = min(frames - done, self.tmpL.count)
                    for i in 0..<n {
                        let s = (done + i) * ch
                        self.tmpL[i] = base[s]; self.tmpR[i] = ch > 1 ? base[s + 1] : base[s]
                    }
                    self.tmpL.withUnsafeBufferPointer { l in self.tmpR.withUnsafeBufferPointer { r in _ = ring.write(l.baseAddress!, r.baseAddress!, frames: n) } }
                    done += n
                }
            } else {
                guard let l = list[0].mData?.assumingMemoryBound(to: Float.self), let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return }
                ring.write(l, r, frames: Int(list[0].mDataByteSize) / MemoryLayout<Float>.size)
            }
        }
        guard st == noErr else { stop(); throw TapError.os("AudioDeviceCreateIOProcIDWithBlock", st) }
        st = AudioDeviceStart(agg, procID)
        guard st == noErr else { stop(); throw TapError.os("AudioDeviceStart", st) }
    }

    func stop() {
        if aggregateID != 0, let p = procID { AudioDeviceStop(aggregateID, p); AudioDeviceDestroyIOProcID(aggregateID, p) }
        procID = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0, let destroy = Tap.symbol("AudioHardwareDestroyProcessTap", as: Tap.DestroyTap.self) { _ = destroy(tapID); tapID = 0 }
    }
}

enum TapError: Error, CustomStringConvertible {
    case unavailable
    case os(String, OSStatus)
    var description: String {
        switch self {
        case .unavailable: return "Core Audio process taps are not available on this macOS version."
        case .os(let what, let st): return "\(what) failed (OSStatus \(st)). If macOS asked for audio-capture permission, allow it in System Settings ▸ Privacy & Security."
        }
    }
}

/// Discovers applications that are producing audio (Core Audio process objects) and gives each one a mixer
/// channel fed by its own tap. The application's own output is muted while tapped, so the mixer is the only
/// path to the speakers; if MacAudioOo quits, taps disappear with it and the applications sound normally again.
final class CoreAudioTapBackend: ObservableObject, AudioBackend {
    enum State: Equatable { case stopped, running(taps: Int), failed(String), unavailable(String) }
    @Published private(set) var state: State = .stopped
    let capability: BackendCapability
    private weak var engine: AudioEngine?
    private var timer: Timer?
    private var taps: [AudioObjectID: (tap: ProcessTap, channel: AudioChannel, idleSince: Date?)] = [:]
    private var failedObjects = Set<AudioObjectID>()

    init(capability: BackendCapability, engine: AudioEngine) { self.capability = capability; self.engine = engine }

    func start() throws {
        stop()
        guard OSVersion.current >= OSVersion(major: 14, minor: 2, patch: 0), Tap.symbol("AudioHardwareCreateProcessTap", as: Tap.CreateTap.self) != nil else {
            state = .unavailable("Requires macOS 14.2 or later."); return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let e = engine { for (_, v) in taps { e.removeChannel(v.channel) } }
        for (_, v) in taps { v.tap.stop() }
        taps.removeAll(); failedObjects.removeAll()
        if state != .unavailable("Requires macOS 14.2 or later.") { state = .stopped }
    }

    // MARK: Polling (1 Hz: the process list has no change notification we can rely on)

    private func poll() {
        guard let engine = engine, engine.status.isRunning, let uid = engine.currentDeviceUID else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let objects = Self.processObjects()
        var seen = Set<AudioObjectID>()
        for obj in objects {
            guard let pid = Self.readPID(obj), pid != me else { continue }
            seen.insert(obj)
            let outputting = Self.readBool(obj, Tap.processRunningOutput)
            if var existing = taps[obj] {
                existing.idleSince = outputting ? nil : (existing.idleSince ?? Date())
                taps[obj] = existing
                continue
            }
            guard outputting, !failedObjects.contains(obj) else { continue }
            let tap = ProcessTap(processObject: obj, pid: pid)
            do {
                try tap.start(outputDeviceUID: uid, muteOriginal: true)
                let app = NSRunningApplication(processIdentifier: pid)
                let bundle = Self.readString(obj, Tap.processBundleID)
                let name = app?.localizedName ?? bundle ?? "Process \(pid)"
                let src = RingResamplerSource(ring: tap.ring, sourceRate: tap.sampleRate, outputRate: engine.sampleRate)
                if let ch = engine.addChannel(name: name, pid: pid, icon: app?.icon, source: src) {
                    taps[obj] = (tap, ch, nil)
                } else { tap.stop() }
            } catch {
                tap.stop(); failedObjects.insert(obj)
                state = .failed("\(error)"); AppLog.shared.log("Tap for pid \(pid) failed: \(error)")
            }
        }
        // Remove taps whose process is gone or silent for 5 s (un-muting the application again).
        for (obj, v) in taps where !seen.contains(obj) || (v.idleSince.map { Date().timeIntervalSince($0) > 5 } ?? false) {
            engine.removeChannel(v.channel); v.tap.stop(); taps[obj] = nil
        }
        failedObjects.formIntersection(seen)
        if case .failed = state, taps.isEmpty == false { state = .running(taps: taps.count) }
        else if case .failed = state {} else { state = .running(taps: taps.count) }
    }

    // MARK: Property helpers

    private static func processObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: Tap.processObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
    private static func readPID(_ obj: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(mSelector: Tap.processPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1; var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &pid) == noErr && pid > 0 ? pid : nil
    }
    private static func readBool(_ obj: AudioObjectID, _ sel: UInt32) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0; var size = UInt32(4)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr && v != 0
    }
    private static func readString(_ obj: AudioObjectID, _ sel: UInt32) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var ref: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &ref) == noErr, let r = ref else { return nil }
        let s = r.takeRetainedValue() as String
        return s.isEmpty ? nil : s
    }
}
