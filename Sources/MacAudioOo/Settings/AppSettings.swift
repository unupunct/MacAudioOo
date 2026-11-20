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
    @Published var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin") } }
    @Published var bpmMin: Double { didSet { defaults.set(bpmMin, forKey: "bpmMin") } }
    @Published var bpmMax: Double { didSet { defaults.set(bpmMax, forKey: "bpmMax") } }
    /// Tempo fader range of the DJ decks in percent (±8 / ±16 / ±50).
    @Published var djTempoRange: Double { didSet { defaults.set(djTempoRange, forKey: "djTempoRange") } }
    @Published var libraryFolder: String? { didSet { defaults.set(libraryFolder, forKey: "libraryFolder") } }
    /// Only English is available; the setting exists so a language can be added without a settings migration.
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    /// Requested audio I/O buffer size in frames (0 = device default).
    @Published var bufferFrames: Int { didSet { defaults.set(bufferFrames, forKey: "bufferFrames") } }

    static let keys = ["selectedTab", "defaultTab", "rememberLastTab", "theme", "startMinimized",
                       "menuBarEnabled", "outputDeviceUID", "recordingDirectory", "djFourDecks",
                       "launchAtLogin", "bpmMin", "bpmMax", "djTempoRange", "libraryFolder", "language", "bufferFrames"]

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
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        bpmMin = defaults.object(forKey: "bpmMin") as? Double ?? 70
        bpmMax = defaults.object(forKey: "bpmMax") as? Double ?? 180
        djTempoRange = defaults.object(forKey: "djTempoRange") as? Double ?? 8
        libraryFolder = defaults.string(forKey: "libraryFolder")
        language = defaults.string(forKey: "language") ?? "en"
        bufferFrames = defaults.integer(forKey: "bufferFrames")
    }

    /// Settings as a JSON-friendly dictionary (for export).
    func exportDictionary() -> [String: Any] {
        var d: [String: Any] = [:]
        for k in Self.keys { if let v = defaults.object(forKey: k) { d[k] = v } }
        return d
    }

    /// Applies an exported dictionary (unknown keys are ignored) and reloads the published values.
    func importDictionary(_ d: [String: Any]) {
        for k in Self.keys { if let v = d[k] { defaults.set(v, forKey: k) } }
        let fresh = AppSettings(defaults: defaults)
        copy(from: fresh)
    }

    private func copy(from f: AppSettings) {
        selectedTab = f.selectedTab; defaultTab = f.defaultTab; rememberLastTab = f.rememberLastTab; theme = f.theme
        startMinimized = f.startMinimized; menuBarEnabled = f.menuBarEnabled; outputDeviceUID = f.outputDeviceUID
        recordingDirectory = f.recordingDirectory; djFourDecks = f.djFourDecks; launchAtLogin = f.launchAtLogin
        bpmMin = f.bpmMin; bpmMax = f.bpmMax; djTempoRange = f.djTempoRange; libraryFolder = f.libraryFolder; language = f.language
        bufferFrames = f.bufferFrames
    }

    func resetToDefaults() {
        for k in Self.keys { defaults.removeObject(forKey: k) }
        copy(from: AppSettings(defaults: defaults))
    }
}
