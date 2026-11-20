import Foundation
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case console = "CONSOLE", classic = "CLASSIC", recording = "RECORDING"
    case dj = "DJ", library = "LIBRARY", settings = "SETTINGS"
    var id: String { rawValue }
    var shortcut: KeyEquivalent {
        switch self {
        case .console: return "1"; case .classic: return "2"; case .recording: return "3"
        case .dj: return "4"; case .library: return "5"; case .settings: return "6"
        }
    }
}

enum ThemeChoice: String, CaseIterable, Identifiable {
    case dark = "Dark", light = "Light", system = "System"
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self { case .dark: return .dark; case .light: return .light; case .system: return nil }
    }
}

/// Persistent preferences, backed by UserDefaults. Every property writes
/// through immediately so settings survive a crash or force-quit.
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var selectedTab: AppTab { didSet { defaults.set(selectedTab.rawValue, forKey: "selectedTab") } }
    @Published var defaultTab: AppTab { didSet { defaults.set(defaultTab.rawValue, forKey: "defaultTab") } }
    @Published var rememberLastTab: Bool { didSet { defaults.set(rememberLastTab, forKey: "rememberLastTab") } }
    @Published var theme: ThemeChoice { didSet { defaults.set(theme.rawValue, forKey: "theme") } }
    @Published var startMinimized: Bool { didSet { defaults.set(startMinimized, forKey: "startMinimized") } }
    @Published var menuBarEnabled: Bool { didSet { defaults.set(menuBarEnabled, forKey: "menuBarEnabled") } }
    @Published var outputDeviceUID: String? { didSet { defaults.set(outputDeviceUID, forKey: "outputDeviceUID") } }
    @Published var recordingDirectory: String { didSet { defaults.set(recordingDirectory, forKey: "recordingDirectory") } }
    @Published var djFourDecks: Bool { didSet { defaults.set(djFourDecks, forKey: "djFourDecks") } }

    static let keys = ["selectedTab", "defaultTab", "rememberLastTab", "theme", "startMinimized",
                       "menuBarEnabled", "outputDeviceUID", "recordingDirectory", "djFourDecks"]

    static var defaultRecordingDirectory: String {
        (FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MacAudioOo").path) ?? NSHomeDirectory()
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let def = AppTab(rawValue: defaults.string(forKey: "defaultTab") ?? "") ?? .console
        let remember = defaults.object(forKey: "rememberLastTab") as? Bool ?? true
        defaultTab = def
        rememberLastTab = remember
        selectedTab = remember ? (AppTab(rawValue: defaults.string(forKey: "selectedTab") ?? "") ?? def) : def
        theme = ThemeChoice(rawValue: defaults.string(forKey: "theme") ?? "") ?? .dark
        startMinimized = defaults.bool(forKey: "startMinimized")
        menuBarEnabled = defaults.object(forKey: "menuBarEnabled") as? Bool ?? true
        outputDeviceUID = defaults.string(forKey: "outputDeviceUID")
        recordingDirectory = defaults.string(forKey: "recordingDirectory") ?? Self.defaultRecordingDirectory
        djFourDecks = defaults.bool(forKey: "djFourDecks")
    }

    func resetToDefaults() {
        for k in Self.keys { defaults.removeObject(forKey: k) }
        let fresh = AppSettings(defaults: defaults)
        selectedTab = fresh.selectedTab; defaultTab = fresh.defaultTab
        rememberLastTab = fresh.rememberLastTab; theme = fresh.theme
        startMinimized = fresh.startMinimized; menuBarEnabled = fresh.menuBarEnabled
        outputDeviceUID = nil; recordingDirectory = fresh.recordingDirectory
        djFourDecks = fresh.djFourDecks
    }
}
