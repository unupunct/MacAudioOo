import Foundation
import Combine

/// Undo/redo for mixer changes. Every change to a channel, the master section, the effects or the
/// groups is detected, coalesced (a whole fader drag becomes one step) and stored as a full snapshot.
/// Adding or removing a channel (an application starting or quitting) is not an undoable user action:
/// it only refreshes the baseline.
final class MixerHistory: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private let engine: AudioEngine
    private var undoStack: [MixerSnapshot] = []
    private var redoStack: [MixerSnapshot] = []
    private var last: MixerSnapshot
    private var suppress = false
    private let trigger = PassthroughSubject<Void, Never>()
    private var channelBag = Set<AnyCancellable>()
    private var bag = Set<AnyCancellable>()
    let limit = 100
    private let settle: TimeInterval

    init(engine: AudioEngine, settle: TimeInterval = 0.4) {
        self.engine = engine; self.settle = settle
        last = MixerSnapshot.capture(from: engine)
        engine.objectWillChange.sink { [weak self] _ in self?.trigger.send() }.store(in: &bag)
        engine.$channels.receive(on: DispatchQueue.main).sink { [weak self] chans in self?.watch(chans) }.store(in: &bag)
        trigger.debounce(for: .seconds(settle), scheduler: DispatchQueue.main).sink { [weak self] in self?.settled() }.store(in: &bag)
    }

    private func watch(_ chans: [AudioChannel]) {
        channelBag.removeAll()
        for c in chans { c.objectWillChange.sink { [weak self] _ in self?.trigger.send() }.store(in: &channelBag) }
        trigger.send()
    }

    /// Called after changes have been quiet for `settle` seconds.
    func settled() {
        guard !suppress else { return }
        let now = MixerSnapshot.capture(from: engine)
        if now == last { return }
        let structural = now.channels.map { $0.key } != last.channels.map { $0.key }
        if !structural {
            undoStack.append(last)
            if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
            redoStack.removeAll()
        }
        last = now
        publish()
    }

    func undo() {
        settled()                                   // include a change still waiting to settle
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(last)
        restore(prev)
    }

    func redo() {
        settled()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(last)
        restore(next)
    }

    private func restore(_ s: MixerSnapshot) {
        suppress = true
        s.apply(to: engine)
        last = MixerSnapshot.capture(from: engine)   // what actually got applied (channels may differ)
        publish()
        DispatchQueue.main.asyncAfter(deadline: .now() + settle + 0.1) { [weak self] in
            guard let self = self else { return }
            self.suppress = false
            self.last = MixerSnapshot.capture(from: self.engine)
        }
    }

    func clear() { undoStack.removeAll(); redoStack.removeAll(); last = MixerSnapshot.capture(from: engine); publish() }

    private func publish() { canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty }
}
