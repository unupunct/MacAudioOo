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
    let counters = UnsafeMutablePointer<UInt64>.allocate(capacity: 8)   // [0]=rendered, [1]=frames, [2]=entered, [3]=buffer count, [4]=render ticks, [5]=worst block ticks, [6]=blocks over 80 % budget

    /// Constants for converting render time to load (read by the render callback, set before start).
    fileprivate(set) var sampleRateForLoad: Double = 48000
    let ticksPerSecond: Double = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return 1e9 * Double(tb.denom) / Double(tb.numer)
    }()

    init() { counters.initialize(repeating: 0, count: 8) }

    /// Fraction of real time spent rendering (0...1). Near or above 1 means the engine cannot keep up and audio will glitch.
    var cpuLoad: Double {
        let frames = Double(counters[1]); guard frames > 0, sampleRate > 0 else { return 0 }
        return Double(counters[4]) / ticksPerSecond / (frames / sampleRate)
    }
    var worstBlockLoad: Double {
        guard bufferFrames > 0, sampleRate > 0 else { return 0 }
        return Double(counters[5]) / ticksPerSecond / (Double(bufferFrames) / sampleRate)
    }
    var overBudgetBlocks: UInt64 { counters[6] }
    deinit { stop(); counters.deallocate() }

    var isRunning: Bool { unit != nil }
    /// 0 = leave the device's current buffer size alone. Otherwise requested (clamped to the device's range) at start.
    var requestedBufferFrames: UInt32 = 0

    private func applyBufferRequest(device: AudioDeviceID) {
        guard requestedBufferFrames > 0 else { return }
        var rangeAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSizeRange, mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var range = AudioValueRange(); var rsize = UInt32(MemoryLayout<AudioValueRange>.size)
        var want = Float64(requestedBufferFrames)
        if AudioObjectGetPropertyData(device, &rangeAddr, 0, nil, &rsize, &range) == noErr {
            want = min(max(want, range.mMinimum), range.mMaximum)
        }
        var frames = UInt32(want)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
    }

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
            applyBufferRequest(device: device.id)
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
            for i in 0..<8 { counters[i] = 0 }
            sampleRateForLoad = rate
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
                let t0 = mach_absolute_time()
                mixer.render(frames: Int(frames), left: l, right: r)
                let spent = mach_absolute_time() &- t0                      // mach ticks spent rendering this block
                out.counters[0] += 1; out.counters[1] += UInt64(frames)
                out.counters[4] += spent                                    // total render ticks
                if spent > out.counters[5] { out.counters[5] = spent }      // worst block since start
                if Double(spent) > Double(frames) / out.sampleRateForLoad * out.ticksPerSecond * 0.8 { out.counters[6] += 1 }   // used > 80 % of the block's time
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
