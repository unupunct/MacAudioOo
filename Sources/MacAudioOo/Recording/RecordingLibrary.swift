import Foundation

struct RecordedTrackInfo: Codable, Equatable, Identifiable {
    var name: String
    var fileName: String
    var frames: Int64
    var droppedFrames: Int
    var isMix: Bool
    var id: String { fileName }
    var seconds: Double { Double(frames) / 48_000 }
}

struct RecordingSessionInfo: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var startedAt: Date
    var sampleRate: Int
    var bitDepth: Int
    var tracks: [RecordedTrackInfo]
    /// True when the session was found unfinished (crash / power loss) and repaired.
    var recovered: Bool
    var durationSeconds: Double { tracks.map { $0.seconds }.max() ?? 0 }
}

/// A session plus where it lives on disk.
struct RecordingSession: Identifiable, Equatable {
    var info: RecordingSessionInfo
    var folder: URL
    var id: String { info.id }
    var bytes: Int64
}

/// Finds, repairs and deletes recording sessions on disk, and reports free disk space.
/// Layout: <root>/<session folder>/{session.json, Mix.wav, <App>.wav ...}. While recording, a hidden
/// `.recording` marker file (containing the planned track list) exists in the folder; if it is still
/// there at the next launch the session was interrupted and is repaired.
final class RecordingLibrary: ObservableObject {
    static let markerName = ".recording"
    static let infoName = "session.json"

    @Published private(set) var sessions: [RecordingSession] = []
    @Published private(set) var lastRecoveryMessage: String?
    private(set) var root: URL

    init(root: URL) { self.root = root }

    func setRoot(_ url: URL) { root = url; refresh() }

    // MARK: Listing

    func refresh() {
        recoverInterrupted()
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var out: [RecordingSession] = []
        for d in dirs {
            let info = d.appendingPathComponent(Self.infoName)
            guard let data = try? Data(contentsOf: info),
                  let s = try? Self.decoder.decode(RecordingSessionInfo.self, from: data) else { continue }
            out.append(RecordingSession(info: s, folder: d, bytes: Self.folderBytes(d)))
        }
        sessions = out.sorted { $0.info.startedAt > $1.info.startedAt }
    }

    // MARK: Recovery

    /// Repairs every unfinished session under `root`. Returns the number repaired.
    @discardableResult
    func recoverInterrupted() -> Int {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var repaired = 0
        for d in dirs {
            let marker = d.appendingPathComponent(Self.markerName)
            guard fm.fileExists(atPath: marker.path) else { continue }
            if Self.recover(folder: d) { repaired += 1 }
        }
        if repaired > 0 { lastRecoveryMessage = "Recovered \(repaired) interrupted recording\(repaired == 1 ? "" : "s")." }
        return repaired
    }

    /// Repairs the WAV headers in `folder`, writes session.json and removes the marker.
    static func recover(folder: URL) -> Bool {
        let fm = FileManager.default
        let marker = folder.appendingPathComponent(markerName)
        var planned: [RecordedTrackInfo] = []
        var started = Date()
        var name = folder.lastPathComponent
        if let data = try? Data(contentsOf: marker), let s = try? decoder.decode(RecordingSessionInfo.self, from: data) {
            planned = s.tracks; started = s.startedAt; name = s.name
        }
        let wavs = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var tracks: [RecordedTrackInfo] = []
        for w in wavs {
            guard let frames = try? WAVWriter.repairHeader(at: w) else { continue }
            let plan = planned.first { $0.fileName == w.lastPathComponent }
            tracks.append(RecordedTrackInfo(name: plan?.name ?? w.deletingPathExtension().lastPathComponent,
                                            fileName: w.lastPathComponent, frames: frames, droppedFrames: 0,
                                            isMix: plan?.isMix ?? (w.lastPathComponent == "Mix.wav")))
        }
        let info = RecordingSessionInfo(id: folder.lastPathComponent, name: name, startedAt: started, sampleRate: 48_000,
                                        bitDepth: 24, tracks: tracks, recovered: true)
        guard let data = try? encoder.encode(info) else { return false }
        do {
            try data.write(to: folder.appendingPathComponent(infoName), options: .atomic)
            try fm.removeItem(at: marker)
            return true
        } catch { return false }
    }

    // MARK: Deleting

    func delete(_ session: RecordingSession) throws {
        // Move to the Trash rather than deleting permanently.
        try FileManager.default.trashItem(at: session.folder, resultingItemURL: nil)
        refresh()
    }

    // MARK: Disk space

    /// Free bytes available to the user on the volume containing `url` (or its nearest existing parent).
    static func availableBytes(at url: URL) -> Int64? {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.path != "/" { u.deleteLastPathComponent() }
        let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let b = v?.volumeAvailableCapacityForImportantUsage { return b }
        return v?.volumeAvailableCapacity.map { Int64($0) }
    }

    /// Bytes per second written for `tracks` simultaneous stereo 24-bit 48 kHz tracks.
    static func bytesPerSecond(tracks: Int) -> Int64 { Int64(tracks) * 48_000 * 6 }

    static func folderBytes(_ url: URL) -> Int64 {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    // MARK: Naming

    static func sessionFolderName(for date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Recording " + f.string(from: date)
    }

    /// File-system-safe, unique file name for a track.
    static func fileName(for track: String, existing: Set<String>) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?*\"<>|").union(.controlCharacters)
        var base = track.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "Track" }
        var candidate = base + ".wav", n = 2
        while existing.contains(candidate.lowercased()) { candidate = "\(base) \(n).wav"; n += 1 }
        return candidate
    }

    static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
