import Foundation
import AVFoundation
import AppKit

struct TrackMetadata: Codable, Equatable, Identifiable {
    var id = UUID()
    var path: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var bpm: Double?
    var firstBeat: Double?
    var addedAt = Date()
    var lastPlayed: Date?
    var playCount = 0
    var favorite = false

    var url: URL { URL(fileURLWithPath: path) }
    var grid: BeatGrid? { (bpm != nil && firstBeat != nil) ? BeatGrid(bpm: bpm!, firstBeat: firstBeat!) : nil }

    /// File extensions worth probing when scanning a folder. Whether a file is really playable is decided by
    /// AVFoundation (`isAudio(url:)`), so supported formats follow the system's capabilities.
    static let candidateExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "alac", "mp4", "m4b", "ac3", "eac3", "au", "snd", "adts"]

    /// True when AVFoundation can open the file and it contains an audio track.
    static func isAudio(url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        return asset.isPlayable && !asset.tracks(withMediaType: .audio).isEmpty
    }

    /// Reads tags and duration. Returns nil if AVFoundation cannot play the file. Blocking; call off the main thread.
    static func read(url: URL) -> TrackMetadata? {
        let asset = AVURLAsset(url: url)
        guard asset.isPlayable, !asset.tracks(withMediaType: .audio).isEmpty else { return nil }
        func common(_ id: AVMetadataIdentifier) -> String? {
            let s = AVMetadataItem.metadataItems(from: asset.commonMetadata, filteredByIdentifier: id).first?.stringValue
            return (s?.isEmpty ?? true) ? nil : s
        }
        let fileTitle = url.deletingPathExtension().lastPathComponent
        let title = common(.commonIdentifierTitle) ?? fileTitle
        let artist = common(.commonIdentifierArtist) ?? "Unknown Artist"
        let album = common(.commonIdentifierAlbumName) ?? "Unknown Album"
        let seconds = asset.duration.seconds
        return TrackMetadata(path: url.path, title: title, artist: artist, album: album, duration: seconds.isFinite ? seconds : 0)
    }

    /// Embedded artwork, if any (read on demand, not stored in the library file).
    static func artwork(for url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        for item in asset.commonMetadata where item.commonKey == .commonKeyArtwork {
            if let data = item.dataValue, let img = NSImage(data: data) { return img }
        }
        return nil
    }
}

struct Playlist: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var trackIDs: [UUID] = []
}
