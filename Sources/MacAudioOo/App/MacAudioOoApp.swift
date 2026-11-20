import SwiftUI
import AppKit

@main
struct MacAudioOoApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(state.settings)
                .preferredColorScheme(state.settings.theme.colorScheme)
                .frame(minWidth: 980, minHeight: 620)
        }
        .commands {
            CommandMenu("View") {
                ForEach(AppTab.allCases) { tab in
                    Button(tab.rawValue.capitalized) { state.settings.selectedTab = tab }
                        .keyboardShortcut(tab.shortcut, modifiers: .command)
                }
            }
        }
    }
}
