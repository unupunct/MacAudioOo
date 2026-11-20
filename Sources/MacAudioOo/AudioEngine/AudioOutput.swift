import Foundation
import AudioToolbox
import CoreAudio

enum AudioOutputError: Error, CustomStringConvertible {
    case osStatus(String, OSStatus)
    var description: String {
        switch self { case .osStatus(let w, let s): return "\(w) failed (OSStatus \(s))" }
    }
}

/// Plays an `AudioMixer` through a chosen output device using an AUHAL unit.
/// Does not change the system default output device.
final class AudioOutput {
    private var unit: AudioUnit?
    private(set) var mixer: AudioMixer?
    private(set) var deviceID: AudioDeviceID = 0
    private(set) var sampleRate: Double = 0
    private(set) var bufferFrames: UInt32 = 0
    private(set) var latencyFrames: UInt32 = 0
    /// Render-thread counters (read from UI for diagnostics only).
    let counters = UnsafeMutablePointer<UInt64>.allocate(capacity: 4)   // [0]=rendered, [1]=frames, [2]=entered, [3]=buffer count

    init() { counters.initialize(repeating: 0, count: 4) }
    deinit { stop(); counters.deallocate() }

    var isRunning: Bool { unit != nil }

    func start(device: AudioDevice, mixerFactory: (Double) -> AudioMixer) throws {
        stop()
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw AudioOutputError.osStatus("Find HAL output component", -1)
        }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au), "Create output unit")
        guard let u = au else { throw AudioOutputError.osStatus("Create output unit", -1) }

        do {
            // Output only: disable the input bus that HALOutput enables by default.
            var zero: UInt32 = 0, one: UInt32 = 1
            try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &zero, 4), "Disable input")
            try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, 4), "Enable output")
            var dev = device.id
            try check(AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev,
                                           UInt32(MemoryLayout<AudioDeviceID>.size)), "Select output device")

            let rate = device.nominalSampleRate > 0 ? device.nominalSampleRate : 48000
            var fmt = AudioStreamBasicDescription(
                mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            try check(AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt,
                                           UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Set stream format")

            let m = mixerFactory(rate)
            mixer = m
            for i in 0..<4 { counters[i] = 0 }
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            var cb = AURenderCallbackStruct(inputProc: { refCon, _, _, _, frames, ioData -> OSStatus in
                let out = Unmanaged<AudioOutput>.fromOpaque(refCon).takeUnretainedValue()
                out.counters[2] += 1                       // callback entered
                guard let io = ioData, let mixer = out.mixer else { return noErr }
                let bufs = UnsafeMutableAudioBufferListPointer(io)
                out.counters[3] = UInt64(bufs.count)       // buffers supplied by the HAL
                guard bufs.count >= 2,
                      let l = bufs[0].mData?.assumingMemoryBound(to: Float.self),
                      let r = bufs[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                mixer.render(frames: Int(frames), left: l, right: r)
                out.counters[0] += 1; out.counters[1] += UInt64(frames)
                return noErr
            }, inputProcRefCon: ctx)
            try check(AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb,
                                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Set render callback")
            try check(AudioUnitInitialize(u), "Initialize output unit")
            try check(AudioOutputUnitStart(u), "Start output unit")

            unit = u; deviceID = device.id; sampleRate = rate
            bufferFrames = Self.u32(device.id, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)
            latencyFrames = Self.u32(device.id, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput)
                + Self.u32(device.id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput)
        } catch {
            AudioComponentInstanceDispose(u)
            mixer = nil
            throw error
        }
    }

    func stop() {
        guard let u = unit else { return }
        AudioOutputUnitStop(u)
        AudioUnitUninitialize(u)
        AudioComponentInstanceDispose(u)
        unit = nil
    }

    var callbackCount: UInt64 { counters[0] }
    var debugCounters: String { "rendered \(counters[0]) entered \(counters[2]) bufs \(counters[3])" }

    private func check(_ s: OSStatus, _ what: String) throws {
        if s != noErr { throw AudioOutputError.osStatus(what, s) }
    }

    private static func u32(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0, size = UInt32(4)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v)
        return v
    }
}
