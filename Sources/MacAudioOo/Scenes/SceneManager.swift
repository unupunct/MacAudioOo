import Foundation
import Combine

/// Stores, applies and manages mixer scenes (create, rename, duplicate, delete). Scenes are saved
/// as JSON in Application Support. A scene keeps per-application channel settings keyed by app name;
/// when an application that belongs to the loaded scene appears later, its settings are applied then.
final class SceneManager: ObservableObject {
    @Published private(set) var scenes: [MixerScene] = []
    @Published private(set) var currentID: UUID?
    private let engine: AudioEngine
    private let storeURL: URL
    private var pending: [String: ChannelSnapshot] = [:]
    private var seenChannels = Set<UUID>()
    private var bag = Set<AnyCancellable>()
    /// Optional hooks so scenes can carry the output device preference.
    var currentOutputUID: () -> String? = { nil }
    var applyOutputUID: (String?) -> Void = { _ in }

    init(engine: AudioEngine, storeURL: URL = SceneManager.defaultStoreURL) {
        self.engine = engine; self.storeURL = storeURL
        load()
        engine.$channels.receive(on: DispatchQueue.main).sink { [weak self] chans in self?.channelsChanged(chans) }.store(in: &bag)
    }

    static var defaultStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("MacAudioOo", isDirectory: true).appendingPathComponent("scenes.json")
    }

    var current: MixerScene? { scenes.first { $0.id == currentID } }

    // MARK: CRUD

    /// New scene capturing the current mixer state.
    @discardableResult
    func create(name: String) -> MixerScene {
        let s = MixerScene(name: uniqueName(name), snapshot: MixerSnapshot.capture(from: engine, outputUID: currentOutputUID()))
        scenes.append(s); currentID = s.id; save(); return s
    }

    /// Overwrites a scene with the current mixer state.
    func update(_ scene: MixerScene) {
        guard let i = scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        scenes[i].snapshot = MixerSnapshot.capture(from: engine, outputUID: currentOutputUID())
        save()
    }

    func rename(_ scene: MixerScene, to name: String) {
        guard let i = scenes.firstIndex(where: { $0.id == scene.id }) else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        scenes[i].name = n == scene.name ? n : uniqueName(n); save()
    }

    @discardableResult
    func duplicate(_ scene: MixerScene) -> MixerScene {
        var copy = scene; copy.id = UUID(); copy.name = uniqueName(scene.name + " copy")
        scenes.append(copy); save(); return copy
    }

    func delete(_ scene: MixerScene) {
        scenes.removeAll { $0.id == scene.id }
        if currentID == scene.id { currentID = nil; pending = [:] }
        save()
    }

    func load(_ scene: MixerScene) {
        currentID = scene.id
        pending = [:]
        let missing = scene.snapshot.apply(to: engine, respectRecallSafe: true)
        for m in missing { pending[m.key] = m }
        if let uid = scene.snapshot.outputUID { applyOutputUID(uid) }
    }

    private func uniqueName(_ base: String) -> String {
        let b = base.trimmingCharacters(in: .whitespaces).isEmpty ? "Scene" : base.trimmingCharacters(in: .whitespaces)
        var name = b, n = 2
        while scenes.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { name = "\(b) \(n)"; n += 1 }
        return name
    }

    /// Replaces every scene (configuration import).
    func replaceAll(_ list: [MixerScene]) {
        guard !list.isEmpty else { return }
        scenes = list; currentID = nil; pending = [:]; save()
    }

    // MARK: New channels

    private func channelsChanged(_ chans: [AudioChannel]) {
        guard !pending.isEmpty else { seenChannels = Set(chans.map { $0.id }); return }
        let keys = MixerSnapshot.keys(for: chans)
        engine.linkingSuspended = true
        for (key, ch) in zip(keys, chans) where !seenChannels.contains(ch.id) {
            if let snap = pending[key] { if !ch.recallSafe { MixerSnapshot.apply(snap, to: ch) }; pending[key] = nil }
        }
        engine.linkingSuspended = false
        seenChannels = Set(chans.map { $0.id })
    }

    // MARK: Persistence

    private func load() {
        if let data = try? Data(contentsOf: storeURL), let list = try? JSONDecoder().decode([MixerScene].self, from: data), !list.isEmpty {
            scenes = list
        } else {
            scenes = Self.defaultScenes()
            save()
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
            try e.encode(scenes).write(to: storeURL, options: .atomic)
        } catch { NSLog("MacAudioOo: could not save scenes: \(error)") }
    }

    /// Example scenes (master/effect settings only; they hold no per-app channels until the user saves some).
    static func defaultScenes() -> [MixerScene] {
        func scene(_ name: String, eq: String, reverb: Float?, delay: Float?, dim: Bool = false) -> MixerScene {
            var s = MixerSnapshot.neutral()
            let g = EQPresets.gains(named: eq) ?? [Float](repeating: 0, count: 10)
            s.master.eqGains = g + [0, 0, 0]; s.master.eqPreset = eq
            if let r = reverb { s.reverb.enabled = 1; s.reverb.returnLevel = r } else { s.reverb.enabled = 0 }
            if let d = delay { s.delay.enabled = 1; s.delay.returnLevel = d } else { s.delay.enabled = 0 }
            s.master.dim = dim
            return MixerScene(name: name, snapshot: s)
        }
        return [scene("Work", eq: "Flat", reverb: nil, delay: nil),
                scene("Gaming", eq: "Bass Boost", reverb: nil, delay: nil),
                scene("Movie Night", eq: "Cinema", reverb: 0.3, delay: nil),
                scene("Music", eq: "Music", reverb: 0.2, delay: 0.15),
                scene("Video Calls", eq: "Voice Clarity", reverb: nil, delay: nil),
                scene("Podcast", eq: "Podcast", reverb: nil, delay: nil)]
    }
}
