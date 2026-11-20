import SwiftUI

/// Scene selector with save / new / rename / duplicate / delete, plus mixer undo and redo.
struct SceneBarView: View {
    @ObservedObject var scenes: SceneManager
    @ObservedObject var history: MixerHistory
    private enum Prompt: Identifiable { case new, rename; var id: Int { self == .new ? 0 : 1 } }
    @State private var prompt: Prompt?
    @State private var name = ""
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 6) {
            Text("SCENE").font(Theme.label).foregroundColor(Theme.textSecondary)
            Menu(scenes.current?.name ?? "Select…") {
                ForEach(scenes.scenes) { s in
                    Button(s.name) { scenes.load(s) }
                }
            }.frame(width: 112)
            Button("Save") { if let s = scenes.current { scenes.update(s) } }
                .disabled(scenes.current == nil).help("Overwrite the selected scene with the current mixer state")
            Button("New…") { name = ""; prompt = .new }.help("Create a scene from the current mixer state")
            Menu("More") {
                Button("Rename…") { name = scenes.current?.name ?? ""; prompt = .rename }.disabled(scenes.current == nil)
                Button("Duplicate") { if let s = scenes.current { let c = scenes.duplicate(s); scenes.load(c) } }.disabled(scenes.current == nil)
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = true }.disabled(scenes.current == nil)
            }.frame(width: 64)
            Divider().frame(height: 16)
            Button(action: { history.undo() }) { Image(systemName: "arrow.uturn.backward") }
                .disabled(!history.canUndo).help("Undo mixer change (⌘Z)")
            Button(action: { history.redo() }) { Image(systemName: "arrow.uturn.forward") }
                .disabled(!history.canRedo).help("Redo mixer change (⇧⌘Z)")
        }
        .sheet(item: $prompt) { p in
            VStack(alignment: .leading, spacing: 12) {
                Text(p == .new ? "New scene" : "Rename scene").font(Theme.title)
                TextField("Scene name", text: $name).textFieldStyle(.roundedBorder).frame(width: 260)
                HStack {
                    Spacer()
                    Button("Cancel") { prompt = nil }
                    Button(p == .new ? "Create" : "Rename") {
                        if p == .new { scenes.create(name: name) } else if let s = scenes.current { scenes.rename(s, to: name) }
                        prompt = nil
                    }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }.padding(20)
        }
        .confirmationDialog("Delete scene “\(scenes.current?.name ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { if let s = scenes.current { scenes.delete(s) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This cannot be undone.") }
    }
}

/// GROUP A–D controls: group fader (multiplies member channels), mute, solo, link, and spill.
struct GroupBarView: View {
    @ObservedObject var engine: AudioEngine
    @Binding var spill: Int?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(engine.groups) { g in
                let members = engine.channels.filter { $0.group == g.id }.count
                HStack(spacing: 4) {
                    Text(GroupState.letters[g.id]).font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundColor(Theme.textPrimary).frame(width: 12)
                    HorizontalFaderView(db: Binding(get: { engine.groups[g.id].volumeDB }, set: { engine.groups[g.id].volumeDB = $0 }), width: 52)
                    ConsoleButton(title: "M", isOn: Binding(get: { engine.groups[g.id].mute }, set: { engine.groups[g.id].mute = $0 }),
                                  onColor: Theme.meterOrange, width: 20, help: "Mute \(g.name) (\(members) channel\(members == 1 ? "" : "s"))")
                    ConsoleButton(title: "S", isOn: Binding(get: { engine.groups[g.id].solo }, set: { engine.groups[g.id].solo = $0 }),
                                  onColor: Theme.meterYellow, width: 20, help: "Solo \(g.name)")
                    ConsoleButton(title: "L", isOn: Binding(get: { engine.groups[g.id].linked }, set: { engine.groups[g.id].linked = $0 }),
                                  width: 20, help: "Link: moving one channel's fader moves every channel in \(g.name) by the same amount")
                    ConsoleButton(title: "SP", isOn: Binding(get: { spill == g.id }, set: { spill = $0 ? g.id : nil }),
                                  width: 24, help: "Spill: show only the channels in \(g.name)")
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(spill == g.id ? Theme.accent : Theme.border))
            }
        }
    }
}
