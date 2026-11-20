import Foundation

/// Complete, comparable, serializable state of one channel.
struct ChannelSnapshot: Codable, Equatable {
    var key: String                 // application name (+ "#n" for duplicates): PIDs change between launches
    var volumeDB: Float
    var balance: Float
    var mute: Bool
    var solo: Bool
    var eqGains: [Float]
    var eqBypass: Bool
    var eqPreset: String
    var comp: CompressorParams
    var reverbSend: Float
    var delaySend: Float
    var group: Int
}

struct MasterSnapshot: Codable, Equatable {
    var volumeDB: Float
    var mute: Bool
    var dim: Bool
    var mono: Bool
    var limiterThresholdDB: Float
    var eqGains: [Float]
    var eqBypass: Bool
    var eqPreset: String
}

/// Everything a scene or an undo step stores: channels, mute/solo, EQ, compressor, effects, groups,
/// master settings and (optionally) the preferred output device.
struct MixerSnapshot: Codable, Equatable {
    var channels: [ChannelSnapshot]
    var master: MasterSnapshot
    var reverb: ReverbParams
    var delay: DelayParams
    var groups: [GroupState]
    var outputUID: String?

    /// Stable per-channel keys: name, with "#2", "#3"… for repeated names.
    static func keys(for channels: [AudioChannel]) -> [String] {
        var seen: [String: Int] = [:]
        return channels.map { ch in
            let n = (seen[ch.name] ?? 0) + 1; seen[ch.name] = n
            return n == 1 ? ch.name : "\(ch.name)#\(n)"
        }
    }

    static func capture(from engine: AudioEngine, outputUID: String? = nil) -> MixerSnapshot {
        let keys = keys(for: engine.channels)
        let chans = zip(keys, engine.channels).map { key, c in
            ChannelSnapshot(key: key, volumeDB: c.volumeDB, balance: c.balance, mute: c.mute, solo: c.solo,
                            eqGains: c.eqGains, eqBypass: c.eqBypass, eqPreset: c.eqPresetName, comp: c.comp,
                            reverbSend: c.reverbSend, delaySend: c.delaySend, group: c.group)
        }
        let m = MasterSnapshot(volumeDB: engine.masterVolumeDB, mute: engine.masterMute, dim: engine.dim, mono: engine.mono,
                               limiterThresholdDB: engine.limiterThresholdDB, eqGains: engine.masterEQGains,
                               eqBypass: engine.masterEQBypass, eqPreset: engine.masterEQPresetName)
        return MixerSnapshot(channels: chans, master: m, reverb: engine.reverb, delay: engine.delay,
                             groups: engine.groups, outputUID: outputUID)
    }

    /// Applies master/effect/group state and every channel whose key matches a live channel.
    /// Returns the channel snapshots that had no live channel (they can be applied when the app appears).
    @discardableResult
    func apply(to engine: AudioEngine, applyChannels: Bool = true) -> [ChannelSnapshot] {
        engine.linkingSuspended = true
        defer { engine.linkingSuspended = false }
        engine.groups = groups
        engine.masterVolumeDB = master.volumeDB; engine.masterMute = master.mute
        engine.dim = master.dim; engine.mono = master.mono
        engine.limiterThresholdDB = master.limiterThresholdDB
        engine.masterEQGains = master.eqGains; engine.masterEQBypass = master.eqBypass; engine.masterEQPresetName = master.eqPreset
        engine.reverb = reverb; engine.delay = delay
        guard applyChannels else { return [] }
        let live = Dictionary(uniqueKeysWithValues: zip(Self.keys(for: engine.channels), engine.channels).map { ($0, $1) })
        var missing: [ChannelSnapshot] = []
        for snap in channels {
            if let ch = live[snap.key] { Self.apply(snap, to: ch) } else { missing.append(snap) }
        }
        return missing
    }

    static func apply(_ s: ChannelSnapshot, to c: AudioChannel) {
        c.volumeDB = s.volumeDB; c.balance = s.balance; c.mute = s.mute; c.solo = s.solo
        c.eqGains = s.eqGains; c.eqBypass = s.eqBypass; c.eqPresetName = s.eqPreset
        c.comp = s.comp; c.reverbSend = s.reverbSend; c.delaySend = s.delaySend; c.group = s.group
    }

    /// A neutral starting point (unity everything, flat EQ, default effects).
    static func neutral() -> MixerSnapshot {
        let flat = [Float](repeating: 0, count: EQProcessor.bandCount)
        return MixerSnapshot(channels: [],
                             master: MasterSnapshot(volumeDB: 0, mute: false, dim: false, mono: false, limiterThresholdDB: -1,
                                                    eqGains: flat, eqBypass: false, eqPreset: "Flat"),
                             reverb: ReverbParams(), delay: DelayParams(), groups: GroupState.defaults(), outputUID: nil)
    }
}
