import SwiftUI
import AppKit

/// The LIBRARY tab: import, search, sort, favorites, recently played, playlists, artwork, and drag into DJ decks.
struct LibraryView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var library: MusicLibrary
    @ObservedObject var dj: DJEngine
    @State private var scope: LibraryScope = .all
    @State private var query = ""
    @State private var sortKey: LibrarySort = .title
    @State private var ascending = true
    @State private var selection = Set<UUID>()
    @State private var newPlaylist = false
    @State private var playlistName = ""
    @State private var dropTargeted = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            sidebar
            VStack(spacing: 8) {
                toolbar
                list
                Text(library.lastImportMessage ?? " ").font(.system(size: 10)).foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .sheet(isPresented: $newPlaylist) {
            VStack(alignment: .leading, spacing: 12) {
                Text("New playlist").font(Theme.title)
                TextField("Name", text: $playlistName).textFieldStyle(.roundedBorder).frame(width: 240)
                HStack { Spacer(); Button("Cancel") { newPlaylist = false }
                    Button("Create") { let p = library.createPlaylist(name: playlistName); scope = .playlist(p.id); newPlaylist = false }
                        .keyboardShortcut(.defaultAction).disabled(playlistName.trimmingCharacters(in: .whitespaces).isEmpty) }
            }.padding(20)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LIBRARY").font(Theme.label).foregroundColor(Theme.textSecondary)
            navRow("All Tracks", "music.note.list", .all, count: library.tracks.count)
            navRow("Favorites", "star.fill", .favorites, count: library.tracks.filter { $0.favorite }.count)
            navRow("Recently Played", "clock", .recent, count: nil)
            HStack {
                Text("PLAYLISTS").font(Theme.label).foregroundColor(Theme.textSecondary)
                Spacer()
                Button(action: { playlistName = ""; newPlaylist = true }) { Image(systemName: "plus") }.buttonStyle(.plain).help("New playlist")
            }.padding(.top, 10)
            ForEach(library.playlists) { p in
                navRow(p.name, "music.note", .playlist(p.id), count: p.trackIDs.count)
                    .contextMenu { Button("Delete playlist", role: .destructive) { if scope == .playlist(p.id) { scope = .all }; library.deletePlaylist(p.id) } }
            }
            Spacer()
        }
        .padding(10).frame(width: 190)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    private func navRow(_ title: String, _ icon: String, _ s: LibraryScope, count: Int?) -> some View {
        Button(action: { scope = s }) {
            HStack { Image(systemName: icon).frame(width: 18); Text(title).lineLimit(1); Spacer()
                if let c = count { Text("\(c)").font(Theme.value).foregroundColor(Theme.textSecondary) } }
                .font(.system(size: 12)).padding(.vertical, 4).padding(.horizontal, 6)
                .foregroundColor(scope == s ? .black : Theme.textPrimary)
                .background(RoundedRectangle(cornerRadius: 5).fill(scope == s ? Theme.accent : Color.clear))
        }.buttonStyle(.plain)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button("Import Files…") { importPanel(folders: false) }
            Button("Import Folder…") { importPanel(folders: true) }
            if library.importing { ProgressView().controlSize(.small) }
            Spacer()
            TextField("Search title, artist, album", text: $query).textFieldStyle(.roundedBorder).frame(width: 220)
            Menu("Sort: \(sortKey.rawValue)") { ForEach(LibrarySort.allCases) { k in Button(k.rawValue) { sortKey = k } } }.frame(width: 140)
            Button(action: { ascending.toggle() }) { Image(systemName: ascending ? "arrow.up" : "arrow.down") }.help("Sort direction")
        }
    }

    // MARK: List

    private var shown: [TrackMetadata] {
        let base = library.tracks(in: scope)
        let filtered = MusicLibrary.filter(base, query: query)
        return scope == .recent && sortKey == .title && query.isEmpty ? filtered : MusicLibrary.sort(filtered, by: sortKey, ascending: ascending)
    }

    private var list: some View {
        Group {
            if shown.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list").font(.system(size: 28)).foregroundColor(Theme.textSecondary)
                    Text(library.tracks.isEmpty ? "Your library is empty" : "No tracks match").font(Theme.title).foregroundColor(Theme.textPrimary)
                    Text("Import audio files or a folder, or drop them here. Supported formats are whatever macOS (AVFoundation) can play.")
                        .font(.system(size: 12)).foregroundColor(Theme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown, selection: $selection) { t in
                    TrackRow(track: t, library: library)
                        .onDrag { NSItemProvider(object: t.url as NSURL) }
                        .contextMenu { menu(for: t) }
                        .onTapGesture(count: 2) { dj.decks.first { !$0.isLoaded }?.load(t) ?? dj.decks[0].load(t) }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(dropTargeted ? Theme.panelRaised : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(dropTargeted ? Theme.accent : Theme.border, lineWidth: dropTargeted ? 2 : 1))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in importDropped(providers) }
    }

    @ViewBuilder
    private func menu(for t: TrackMetadata) -> some View {
        ForEach(dj.activeDecks) { d in Button("Load to \(d.name.capitalized)") { d.load(t) } }
        Divider()
        Button(t.favorite ? "Remove from Favorites" : "Add to Favorites") { library.toggleFavorite(t.id) }
        Menu("Add to Playlist") {
            ForEach(library.playlists) { p in Button(p.name) { library.add(selection.contains(t.id) ? Array(selection) : [t.id], to: p.id) } }
            if library.playlists.isEmpty { Text("No playlists yet") }
        }
        if case .playlist(let pid) = scope { Button("Remove from this Playlist") { library.remove(selection.isEmpty ? [t.id] : selection, from: pid) } }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([t.url]) }
        Divider()
        Button("Remove from Library", role: .destructive) { library.remove(selection.contains(t.id) ? selection : [t.id]) }
    }

    private func importPanel(folders: Bool) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true; p.canChooseFiles = !folders; p.canChooseDirectories = folders
        if p.runModal() == .OK { library.importURLs(p.urls) }
    }

    private func importDropped(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers where p.hasItemConformingToTypeIdentifier("public.file-url") {
            group.enter()
            p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { urls.append(u) } else if let u = item as? URL { urls.append(u) }
                group.leave()
            }
        }
        group.notify(queue: .main) { if !urls.isEmpty { library.importURLs(urls) } }
        return true
    }
}

struct TrackRow: View {
    let track: TrackMetadata
    @ObservedObject var library: MusicLibrary
    @State private var art: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let a = art { Image(nsImage: a).resizable().interpolation(.high) }
                else { Image(systemName: "music.note").resizable().scaledToFit().padding(8).foregroundColor(Theme.textSecondary) }
            }
            .frame(width: 36, height: 36).background(Theme.well).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textPrimary).lineLimit(1)
                Text(track.artist).font(.system(size: 10)).foregroundColor(Theme.textSecondary).lineLimit(1)
            }.frame(minWidth: 180, alignment: .leading)
            Text(track.album).font(.system(size: 11)).foregroundColor(Theme.textSecondary).lineLimit(1).frame(minWidth: 120, alignment: .leading)
            Spacer()
            Text(track.bpm.map { String(format: "%.1f", $0) } ?? "—").font(Theme.value).foregroundColor(Theme.textPrimary).frame(width: 54, alignment: .trailing)
                .help("BPM (measured when the track is first loaded on a deck)")
            Text(timeString(track.duration).dropLast(2)).font(Theme.value).foregroundColor(Theme.textSecondary).frame(width: 64, alignment: .trailing)
            Button(action: { library.toggleFavorite(track.id) }) {
                Image(systemName: track.favorite ? "star.fill" : "star").foregroundColor(track.favorite ? Theme.meterYellow : Theme.textSecondary)
            }.buttonStyle(.plain).help("Favorite")
        }
        .padding(.vertical, 2)
        .onAppear {
            guard art == nil else { return }
            let url = track.url
            DispatchQueue.global(qos: .utility).async {
                let img = TrackMetadata.artwork(for: url)
                DispatchQueue.main.async { art = img }
            }
        }
    }
}
