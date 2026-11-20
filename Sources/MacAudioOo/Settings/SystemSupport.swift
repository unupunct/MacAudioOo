import Foundation
import AppKit

/// Launch at login via a per-user LaunchAgent (works on every supported macOS version, needs no helper app,
/// and can be removed by switching the setting off or deleting the plist).
enum LoginItem {
    static let label = "com.unupunct.MacAudioOo.login"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func plist(bundlePath: String) -> Data {
        let d: [String: Any] = ["Label": label, "ProgramArguments": ["/usr/bin/open", "-g", "-a", bundlePath],
                                "RunAtLoad": true, "ProcessType": "Interactive"]
        return (try? PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)) ?? Data()
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    @discardableResult
    static func set(_ on: Bool, bundlePath: String = Bundle.main.bundlePath, url: URL = LoginItem.plistURL) -> String? {
        let fm = FileManager.default
        do {
            if on {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try plist(bundlePath: bundlePath).write(to: url, options: .atomic)
            } else if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            return nil
        } catch { return "Could not \(on ? "enable" : "disable") launch at login: \(error.localizedDescription)" }
    }
}

/// Diagnostics log: appended to ~/Library/Logs/MacAudioOo/MacAudioOo.log (rotated at 1 MB) and kept in memory
/// (last 500 lines) for the Settings ▸ Advanced viewer.
final class AppLog: ObservableObject {
    static let shared = AppLog()
    @Published private(set) var lines: [String] = []
    private let fileURL: URL
    private let queue = DispatchQueue(label: "MacAudioOo.log", qos: .utility)
    private let maxBytes = 1_000_000

    init(fileURL: URL = AppLog.defaultURL) { self.fileURL = fileURL }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacAudioOo/MacAudioOo.log")
    }
    var url: URL { fileURL }

    func log(_ message: String) {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let line = "\(f.string(from: Date())) \(message)"
        DispatchQueue.main.async { self.lines.append(line); if self.lines.count > 500 { self.lines.removeFirst(self.lines.count - 500) } }
        queue.async { [fileURL, maxBytes] in
            let fm = FileManager.default
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int), size > maxBytes {
                let old = fileURL.appendingPathExtension("1")
                try? fm.removeItem(at: old); try? fm.moveItem(at: fileURL, to: old)
            }
            if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
            if let h = try? FileHandle(forWritingTo: fileURL) {
                _ = try? h.seekToEnd(); try? h.write(contentsOf: Data((line + "\n").utf8)); try? h.close()
            }
        }
    }

    func clear() {
        lines.removeAll()
        queue.async { [fileURL] in try? Data().write(to: fileURL) }
    }
}

/// Export / import of the whole configuration: settings, scenes, user EQ presets, ducking.
enum ConfigBackup {
    static let version = 1

    static func export(settings: AppSettings, scenes: [MixerScene], ducking: DuckingConfig, defaults: UserDefaults = .standard) throws -> Data {
        let enc = JSONEncoder()
        let scenesData = try enc.encode(scenes)
        let duck = try enc.encode(ducking)
        let eq = try enc.encode(EQPresets.userPresets(defaults))
        let doc: [String: Any] = [
            "version": version, "app": "MacAudioOo",
            "settings": settings.exportDictionary(),
            "scenes": scenesData.base64EncodedString(),
            "ducking": duck.base64EncodedString(),
            "userEQPresets": eq.base64EncodedString(),
        ]
        return try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    }

    struct Imported { var scenes: [MixerScene]; var ducking: DuckingConfig?; var userEQPresets: [String: [Float]] }

    /// Parses and validates a backup, applies the settings, and returns the other parts for the caller to install.
    static func importData(_ data: Data, into settings: AppSettings) throws -> Imported {
        guard let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any], doc["app"] as? String == "MacAudioOo",
              let v = doc["version"] as? Int, v <= version else {
            throw NSError(domain: "MacAudioOo", code: 1, userInfo: [NSLocalizedDescriptionKey: "This is not a MacAudioOo configuration file (or it was made by a newer version)."])
        }
        func part<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
            (doc[key] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
        if let s = doc["settings"] as? [String: Any] { settings.importDictionary(s) }
        return Imported(scenes: part("scenes", [MixerScene].self) ?? [], ducking: part("ducking", DuckingConfig.self),
                        userEQPresets: part("userEQPresets", [String: [Float]].self) ?? [:])
    }
}
