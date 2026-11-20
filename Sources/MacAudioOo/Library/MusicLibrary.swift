import Foundation
import Combine

enum LibrarySort: String, CaseIterable, Identifiable {
    case title = "Title", artist = "Artist", album = "Album", duration = "Duration", bpm = "BPM", added = "Date Added", played = "Last Played"
    var id: String { rawValue }
}

enum LibraryScope: Hashable {
    case all, favorites, recent, playlist(UUID)
}

/// The central media library: imports local audio (formats decided by AVFoundation), keeps metadata,
/// BPM/beat-grid results, favorites, play history and playlists, and persists them as JSON.
final class MusicLibrary: ObservableObject {
    @Published private(set) var tracks: [TrackMetadata] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var importing = false
    @Published private(set) var lastImportMessage: String?
    private let storeURL: URL
    private let queue = DispatchQueue(label: "MacAudioOo.library", qos: .utility)

    init(storeURL: URL = MusicLibrary.defaultStoreURL) {
        self.storeURL = storeURL
        load()
    }

    static var defaultStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("MacAudioOo", isDirectory: true).appendingPathComponent("library.json")
    }

    // MARK: Import

    /// Imports files and (recursively) folders. Unsupported files are skipped and counted.
    func importURLs(_ urls: [URL], completion: (() -> Void)? = nil) {
        importing = true
        queue.async { [weak self] in
            guard let self = self else { return }
            var files: [URL] = []
            let fm = FileManager.default
            for u in urls {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    if let e = fm.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                        for case let f as URL in e where TrackMetadata.candidateExtensions.contains(f.pathExtension.lowercased()) { files.append(f) }
                    }
                } else { files.append(u) }
            }
            let known = Set(DispatchQueue.main.sync { self.tracks.map { $0.path } })
            var added: [TrackMetadata] = [], skipped = 0, dupes = 0
            for f in files {
                let path = Self.normalize(f.path)                  // /var vs /private/var, "..", symlinks
                if known.contains(path) || added.contains(where: { $0.path == path }) { dupes += 1; continue }
                if let t = TrackMetadata.read(url: URL(fileURLWithPath: path)) { added.append(t) } else { skipped += 1 }
            }
            DispatchQueue.main.async {
                self.tracks.append(contentsOf: added)
                self.importing = false
                var msg = "Imported \(added.count) track\(added.count == 1 ? "" : "s")."
                if dupes > 0 { msg += " \(dupes) already in the library." }
                if skipped > 0 { msg += " \(skipped) file\(skipped == 1 ? "" : "s") could not be played by this system." }
                self.lastImportMessage = msg
                self.save()
                completion?()
            }
        }
    }

    /// Returns the existing library entry for `url`, or nil.
    func track(forPath path: String) -> TrackMetadata? { let p = Self.normalize(path); return tracks.first { $0.path == p } }

    /// Canonical form of a file path used as the library key.
    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
    func track(id: UUID) -> TrackMetadata? { tracks.first { $0.id == id } }

    func remove(_ ids: Set<UUID>) {
        tracks.removeAll { ids.contains($0.id) }
        for i in playlists.indices { playlists[i].trackIDs.removeAll { ids.contains($0) } }
        save()
    }

    // MARK: Per-track state

    func toggleFavorite(_ id: UUID) { mutate(id) { $0.favorite.toggle() } }
    func markPlayed(_ id: UUID, at date: Date = Date()) { mutate(id) { $0.lastPlayed = date; $0.playCount += 1 } }
    func setAnalysis(_ id: UUID, bpm: Double, firstBeat: Double) { mutate(id) { $0.bpm = bpm; $0.firstBeat = firstBeat } }

    private func mutate(_ id: UUID, _ f: (inout TrackMetadata) -> Void) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        f(&tracks[i]); save()
    }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(name: String) -> Playlist {
        let p = Playlist(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Playlist" : name)
        playlists.append(p); save(); return p
    }
    func renamePlaylist(_ id: UUID, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        playlists[i].name = name; save()
    }
    func deletePlaylist(_ id: UUID) { playlists.removeAll { $0.id == id }; save() }
    func add(_ trackIDs: [UUID], to playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        for t in trackIDs where !playlists[i].trackIDs.contains(t) && tracks.contains(where: { $0.id == t }) { playlists[i].trackIDs.append(t) }
        save()
    }
    func remove(_ trackIDs: Set<UUID>, from playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.removeAll { trackIDs.contains($0) }; save()
    }

    // MARK: Search / sort / scopes (pure, testable)

    static func filter(_ tracks: [TrackMetadata], query: String) -> [TrackMetadata] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return tracks }
        return tracks.filter { t in
            let hay = (t.title + " " + t.artist + " " + t.album).lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }

    static func sort(_ tracks: [TrackMetadata], by key: LibrarySort, ascending: Bool) -> [TrackMetadata] {
        func less(_ a: TrackMetadata, _ b: TrackMetadata) -> Bool {
            switch key {
            case .title: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .artist: return a.artist.localizedCaseInsensitiveCompare(b.artist) == .orderedAscending
            case .album: return a.album.localizedCaseInsensitiveCompare(b.album) == .orderedAscending
            case .duration: return a.duration < b.duration
            case .bpm: return (a.bpm ?? -1) < (b.bpm ?? -1)
            case .added: return a.addedAt < b.addedAt
            case .played: return (a.lastPlayed ?? .distantPast) < (b.lastPlayed ?? .distantPast)
            }
        }
        return tracks.sorted { ascending ? less($0, $1) : less($1, $0) }
    }

    func tracks(in scope: LibraryScope) -> [TrackMetadata] {
        switch scope {
        case .all: return tracks
        case .favorites: return tracks.filter { $0.favorite }
        case .recent: return tracks.filter { $0.lastPlayed != nil }.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }.prefix(50).map { $0 }
        case .playlist(let id):
            guard let p = playlists.first(where: { $0.id == id }) else { return [] }
            return p.trackIDs.compactMap { tid in tracks.first { $0.id == tid } }
        }
    }

    // MARK: Persistence

    private struct Store: Codable { var tracks: [TrackMetadata]; var playlists: [Playlist] }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL), let s = try? JSONDecoder().decode(Store.self, from: data) else { return }
        // Drop entries whose files are gone.
        tracks = s.tracks.filter { FileManager.default.fileExists(atPath: $0.path) }
        playlists = s.playlists
    }

    func save() {
        let snapshot = Store(tracks: tracks, playlists: playlists)
        queue.async { [storeURL] in
            do {
                try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: storeURL, options: .atomic)
            } catch { NSLog("MacAudioOo: could not save library: \(error)") }
        }
    }
}
