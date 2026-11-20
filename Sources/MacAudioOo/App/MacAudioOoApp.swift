import SwiftUI
import AppKit

/// Edit ▸ Undo / Redo for mixer changes (⌘Z / ⇧⌘Z).
struct MixerUndoCommands: Commands {
    @ObservedObject var history: MixerHistory
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo Mixer Change") { history.undo() }.keyboardShortcut("z", modifiers: .command).disabled(!history.canUndo)
            Button("Redo Mixer Change") { history.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!history.canRedo)
        }
    }
}

@main
struct MacAudioOoApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(state.settings)
                .preferredColorScheme(state.settings.theme.colorScheme)
                .frame(minWidth: 1180, minHeight: 790)
                .onAppear {
                    SnapshotTool.runIfRequested(state: state)
                    SnapshotTool.runSwitchTestIfRequested(state: state)
                    SnapshotTool.runRecordTestIfRequested(state: state)
                    SnapshotTool.runOutputToolsIfRequested(state: state)
                    SnapshotTool.runDriverTestIfRequested(state: state)
                    let devTool = CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--switch-test")
                        || CommandLine.arguments.contains("--record-test") || CommandLine.arguments.contains("--driver-test")
                        || CommandLine.arguments.contains("--query-output") || CommandLine.arguments.contains("--set-output")
                    if state.settings.startMinimized && !devTool {
                        DispatchQueue.main.async { NSApp.windows.first(where: { $0.canBecomeMain })?.miniaturize(nil) }
                    }
                }
        }
        .commands {
            MixerUndoCommands(history: state.history)
            CommandMenu("View") {
                ForEach(AppTab.allCases) { tab in
                    Button(tab.rawValue.capitalized) { state.settings.selectedTab = tab }
                        .keyboardShortcut(tab.shortcut, modifiers: .command)
                }
            }
        }
    }
}
