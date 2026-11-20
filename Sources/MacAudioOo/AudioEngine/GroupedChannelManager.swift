import Foundation
import AppKit

/// A channel source that sums several sub-sources (one per audio process of the same application). Membership changes
/// come from the UI thread; the render thread only reads fixed-size slots, so it never allocates or locks. A removed
/// member is released after a delay, once the render thread has certainly finished the block that might still use it.
final class GroupedSource: ChannelSource {
    static let capacity = 16
    private let slots = UnsafeMutablePointer<Unmanaged<ChannelSource>?>.allocate(capacity: GroupedSource.capacity)
    private let count = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let tmpL = UnsafeMutablePointer<Float>.allocate(capacity: AudioMixer.maxBlock)
    private let tmpR = UnsafeMutablePointer<Float>.allocate(capacity: AudioMixer.maxBlock)

    override init() {
        slots.initialize(repeating: nil, count: Self.capacity); count.initialize(to: 0)
        tmpL.initialize(repeating: 0, count: AudioMixer.maxBlock); tmpR.initialize(repeating: 0, count: AudioMixer.maxBlock)
        super.init()
    }
    deinit {
        for i in 0..<Int(count.pointee) { slots[i]?.release() }
        slots.deallocate(); count.deallocate(); tmpL.deallocate(); tmpR.deallocate()
    }

    var memberCount: Int { Int(count.pointee) }

    @discardableResult
    func add(_ s: ChannelSource) -> Bool {
        let n = Int(count.pointee)
        guard n < Self.capacity else { return false }
        slots[n] = Unmanaged.passRetained(s)
        OSMemoryBarrier()
        count.pointee = Int32(n + 1)
        return true
    }

    func remove(_ s: ChannelSource) {
        let n = Int(count.pointee)
        guard let i = (0..<n).first(where: { slots[$0]?.takeUnretainedValue() === s }) else { return }
        let removed = slots[i]
        slots[i] = slots[n - 1]            // swap with the last member
        slots[n - 1] = nil
        OSMemoryBarrier()
        count.pointee = Int32(n - 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { removed?.release() }
    }

    override func pull(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        let n = min(frames, AudioMixer.maxBlock)
        for i in 0..<frames { l[i] = 0; r[i] = 0 }
        let members = Int(count.pointee)
        for m in 0..<members {
            guard let u = slots[m] else { continue }
            u._withUnsafeGuaranteedRef { $0.pull(tmpL, tmpR, frames: n) }
            for i in 0..<n { l[i] += tmpL[i]; r[i] += tmpR[i] }
        }
    }
}

/// Keeps one mixer channel per application and adds/removes that application's audio processes as members.
/// Backends describe what should exist (`reconcile`); this creates, updates and removes channels to match.
final class GroupedChannelManager {
    struct Desired {
        var identity: AppIdentity
        var members: [(id: String, make: () -> ChannelSource)]
    }

    private final class Group {
        let channel: AudioChannel
        let source: GroupedSource          // the very instance the channel plays
        var members: [String: ChannelSource] = [:]
        init(channel: AudioChannel, source: GroupedSource) { self.channel = channel; self.source = source }
    }

    private weak var engine: AudioEngine?
    private var groups: [String: Group] = [:]

    init(engine: AudioEngine) { self.engine = engine }

    var channelCount: Int { groups.count }
    var memberCount: Int { groups.values.reduce(0) { $0 + $1.members.count } }
    func channel(forKey key: String) -> AudioChannel? { groups[key]?.channel }

    func reconcile(_ desired: [String: Desired]) {
        guard let engine = engine else { return }
        let live = Set(engine.channels.map { $0.id })
        // A channel may already have been removed elsewhere (its application quit): never remove it twice, because its
        // slot may meanwhile belong to another channel.
        for (key, g) in groups where !live.contains(g.channel.id) { groups[key] = nil }
        for (key, g) in groups where desired[key] == nil {
            engine.removeChannel(g.channel); groups[key] = nil
        }
        for (key, d) in desired {
            let g: Group
            if let existing = groups[key] {
                g = existing
            } else {
                let src = GroupedSource()
                guard let ch = engine.addChannel(name: d.identity.name, pid: d.identity.mainPID, icon: d.identity.icon, source: src) else { continue }
                g = Group(channel: ch, source: src)
                groups[key] = g
            }
            let wanted = Set(d.members.map { $0.id })
            for (id, s) in g.members where !wanted.contains(id) { g.source.remove(s); g.members[id] = nil }
            for m in d.members where g.members[m.id] == nil {
                let s = m.make()
                if g.source.add(s) { g.members[m.id] = s }
            }
        }
    }

    func removeAll() {
        guard let engine = engine else { return }
        let live = Set(engine.channels.map { $0.id })
        for (_, g) in groups where live.contains(g.channel.id) { engine.removeChannel(g.channel) }
        groups.removeAll()
    }
}
