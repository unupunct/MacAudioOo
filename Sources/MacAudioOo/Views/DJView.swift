import SwiftUI
import AppKit

/// Developer switch used to bisect layout cost: `--dj-hide=pads` etc. (no effect in normal use).
func djHide(_ part: String) -> Bool { CommandLine.arguments.contains("--dj-hide=" + part) }

/// The DJ tab: two- or four-deck layout, central mixer (gain, EQ, filter, meters, crossfader, master).
struct DJView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var dj: DJEngine

    var body: some View {
        let decks = dj.activeDecks
        VStack(spacing: 8) {
            HStack {
                ConsoleButton(title: "2 DECKS", isOn: Binding(get: { !dj.fourDecks }, set: { _ in dj.fourDecks = false; settings.djFourDecks = false }), width: 64)
                ConsoleButton(title: "4 DECKS", isOn: Binding(get: { dj.fourDecks }, set: { _ in dj.fourDecks = true; settings.djFourDecks = true }), width: 64)
                Spacer()
                if let e = dj.error { Text(e).font(.system(size: 11)).foregroundColor(Theme.meterOrange) }
                Text("Local files only · external apps keep their own playback controls").font(.system(size: 10)).foregroundColor(Theme.textSecondary)
            }
            if decks.count == 2 {
                HStack(alignment: .top, spacing: 8) {
                    DeckView(deck: decks[0], dj: dj, library: state.library, compact: false)
                    if !djHide("mixer") { MixerPanel(dj: dj, decks: decks) }
                    DeckView(deck: decks[1], dj: dj, library: state.library, compact: false)
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 8) {
                        DeckView(deck: decks[0], dj: dj, library: state.library, compact: true)
                        DeckView(deck: decks[2], dj: dj, library: state.library, compact: true)
                    }
                    MixerPanel(dj: dj, decks: decks)
                    VStack(spacing: 8) {
                        DeckView(deck: decks[1], dj: dj, library: state.library, compact: true)
                        DeckView(deck: decks[3], dj: dj, library: state.library, compact: true)
                    }
                }
            }
        }
        .padding(10)
    }
}

struct DeckView: View {
    @ObservedObject var deck: DJDeck
    let dj: DJEngine
    @ObservedObject var library: MusicLibrary
    let compact: Bool
    @State private var dropTargeted = false
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 6) {
            if !djHide("header") { header }
            if !djHide("waveform") {
                WaveformDetailView(deck: deck).frame(height: compact ? 54 : 78)
                WaveformOverviewView(deck: deck).frame(height: 26)
            }
            HStack(alignment: .top, spacing: 10) {
                if !compact && !djHide("jog") { JogWheelView(deck: deck, size: 120) }
                VStack(spacing: 6) {
                    if !djHide("transport") { transport }
                    if !djHide("loops") { loopControls }
                }
                if !djHide("tempo") { tempoSection }
            }
            if !djHide("pads") { padGrid }
        }
        .padding(10)
        .frame(minWidth: compact ? 340 : 380)
        .background(RoundedRectangle(cornerRadius: 10).fill(dropTargeted ? Theme.panelRaised : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(dropTargeted ? Theme.accent : Theme.border, lineWidth: dropTargeted ? 2 : 1))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in loadDropped(providers) }
        .popover(isPresented: $showPicker) { TrackPicker(library: library) { t in deck.load(t); showPicker = false } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(deck.name).font(Theme.title).foregroundColor(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(deck.track?.title ?? "No track loaded").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textPrimary).lineLimit(1)
                Text(deck.track?.artist ?? "Drop an audio file here, or choose from the library").font(.system(size: 10)).foregroundColor(Theme.textSecondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(deck.effectiveBPM.map { String(format: "%.1f", $0) } ?? (deck.analyzing ? "…" : "—"))
                    .font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundColor(Theme.textPrimary)
                Text(deck.analyzing ? "ANALYZING" : "BPM").font(.system(size: 8, weight: .bold)).foregroundColor(Theme.textSecondary)
            }
            PlainButton(title: "Load…", width: 56) { showPicker = true }.help("Choose a track from the library")
            PlainButton(systemImage: "eject.fill", width: 30) { deck.eject() }.disabled(!deck.isLoaded).help("Eject")
        }
        .overlay(alignment: .bottomLeading) {
            if let e = deck.loadError { Text(e).font(.system(size: 9)).foregroundColor(Theme.meterOrange).offset(y: 12) }
        }
    }

    private var transport: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                PlainButton(title: "CUE", width: 52, height: 30) { deck.cue() }
                    .disabled(!deck.isLoaded).help("Playing: return to the cue point. Paused: set the cue point here.")
                PlainButton(systemImage: deck.isPlaying ? "pause.fill" : "play.fill", width: 52, height: 30, tint: deck.isPlaying ? Theme.accent.opacity(0.5) : Theme.panelRaised) { deck.togglePlay() }
                    .disabled(!deck.isLoaded).help("Play / pause")
                PlainButton(systemImage: "stop.fill", width: 36, height: 30) { deck.stop() }
                    .disabled(!deck.isLoaded).help("Stop and rewind")
            }
            VStack(spacing: 1) {
                Text(timeString(deck.position)).font(Theme.value).foregroundColor(Theme.textPrimary).lineLimit(1).fixedSize()
                Text("-" + timeString(deck.remaining)).font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.textSecondary).lineLimit(1).fixedSize()
            }
        }
    }

    private var loopControls: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                small("IN") { deck.setLoopIn() }
                small("OUT") { deck.setLoopOut() }
                ConsoleButton(title: "LOOP", isOn: Binding(get: { deck.loopActive }, set: { _ in deck.toggleLoop() }), onColor: Theme.meterYellow, width: 38,
                              help: "Loop on/off")
            }
            HStack(spacing: 3) {
                ForEach([1.0, 2, 4, 8], id: \.self) { b in
                    small(b < 1 ? "1/2" : "\(Int(b))") { deck.autoLoop(beats: b) }.disabled(deck.grid == nil)
                }
            }
        }
    }

    private func small(_ t: String, _ a: @escaping () -> Void) -> some View {
        PlainButton(title: t, width: 26, height: 20, action: a).disabled(!deck.isLoaded)
    }

    private var tempoSection: some View {
        VStack(spacing: 6) {
            Text(String(format: "%+.1f%%", deck.tempoPercent)).font(Theme.value).foregroundColor(Theme.textPrimary)
            LinearHSlider(value: $deck.tempoPercent, range: -dj.tempoRange...dj.tempoRange, width: 90, defaultValue: 0)
                .help("Tempo (double-click to reset)")
            HStack(spacing: 4) {
                ConsoleButton(title: "KEY", isOn: $deck.keyLock, onColor: Theme.accent, width: 30,
                              help: "Key lock: tempo changes keep the original pitch (time-stretch)")
                PlainButton(title: "SYNC", width: 44) { dj.sync(deck) }.disabled(deck.grid == nil || dj.syncMaster(excluding: deck) == nil)
                    .help("Match tempo and beat phase to the other deck")
            }
            PlainButton(title: "0", width: 24, height: 18) { deck.tempoPercent = 0 }.help("Reset tempo")
        }
        .frame(width: 100)
    }

    private var padGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
            ForEach(0..<8, id: \.self) { i in
                let set = deck.hotCues[i] != nil
                Button(action: { deck.hotCue(i) }) {
                    VStack(spacing: 0) {
                        Text("\(i + 1)").font(.system(size: 11, weight: .heavy))
                        Text(deck.hotCues[i].map { timeString($0) } ?? "SET").font(.system(size: 7, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity, minHeight: compact ? 24 : 32)
                    .foregroundColor(set ? .black : Theme.textSecondary)
                    .background(RoundedRectangle(cornerRadius: 5).fill(set ? padColor(i) : Theme.panelRaised))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border))
                }
                .buttonStyle(.plain).disabled(!deck.isLoaded)
                .contextMenu { Button("Clear hot cue \(i + 1)") { deck.clearHotCue(i) } }
                .help(set ? "Jump to hot cue \(i + 1) (right-click to clear)" : "Set hot cue \(i + 1) at the playhead")
            }
        }
    }

    private func padColor(_ i: Int) -> Color {
        [Theme.meterGreen, Theme.meterYellow, Theme.meterOrange, Theme.record, .cyan, .purple, .pink, .white][i % 8]
    }

    private func loadDropped(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier("public.file-url") }) else { return false }
        p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            var url: URL?
            if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) } else if let u = item as? URL { url = u }
            guard let u = url else { return }
            DispatchQueue.main.async {
                if let t = library.track(forPath: u.path) { deck.load(t) }
                else { library.importURLs([u]) { if let t = library.track(forPath: u.path) { deck.load(t) } } }
            }
        }
        return true
    }
}

struct TrackPicker: View {
    @ObservedObject var library: MusicLibrary
    var onPick: (TrackMetadata) -> Void
    @State private var query = ""
    var body: some View {
        VStack(spacing: 6) {
            TextField("Search library", text: $query).textFieldStyle(.roundedBorder)
            List(MusicLibrary.sort(MusicLibrary.filter(library.tracks, query: query), by: .title, ascending: true)) { t in
                Button(action: { onPick(t) }) {
                    VStack(alignment: .leading) {
                        Text(t.title).font(.system(size: 12, weight: .semibold))
                        Text(t.artist + (t.bpm.map { String(format: " · %.0f BPM", $0) } ?? "")).font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }.buttonStyle(.plain)
            }.frame(width: 320, height: 300)
            if library.tracks.isEmpty { Text("The library is empty. Import music in the LIBRARY tab.").font(.system(size: 11)).foregroundColor(.secondary) }
        }.padding(10)
    }
}

/// Large circular jog wheel. Dragging while playing bends the pitch (nudge); dragging while paused scrubs.
struct JogWheelView: View {
    @ObservedObject var deck: DJDeck
    var size: CGFloat
    @State private var lastAngle: Double?

    var body: some View {
        let angle = deck.isLoaded ? (deck.position / 1.8) * 360 : 0         // one revolution per 1.8 s of audio
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(white: 0.20), Color(white: 0.09)], center: .center, startRadius: 4, endRadius: size / 2))
            Circle().stroke(Theme.border, lineWidth: 2)
            Circle().stroke(Theme.textSecondary.opacity(0.25), lineWidth: 1).padding(14)
            Capsule().fill(Theme.accent).frame(width: 4, height: size * 0.22).offset(y: -size * 0.36).rotationEffect(.degrees(angle))
            Circle().fill(Theme.well).frame(width: size * 0.3, height: size * 0.3)
            Text(deck.name.suffix(1)).font(.system(size: size * 0.14, weight: .heavy, design: .rounded)).foregroundColor(Theme.textSecondary)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            let c = CGPoint(x: size / 2, y: size / 2)
            let a = atan2(v.location.y - c.y, v.location.x - c.x) * 180 / .pi
            if let l = lastAngle {
                var d = a - l
                if d > 180 { d -= 360 } else if d < -180 { d += 360 }
                if deck.isPlaying { deck.nudge(d / 40) } else { deck.scrub(by: d / 360 * 1.8) }
            }
            lastAngle = a
        }.onEnded { _ in lastAngle = nil; deck.endNudge() })
        .help("Jog wheel: drag to nudge pitch while playing, or to scrub when paused")
    }
}

/// Mixer: per-deck trim, 3-band EQ, filter, channel fader and meter; crossfader and master section.
struct MixerPanel: View {
    @ObservedObject var dj: DJEngine
    let decks: [DJDeck]

    var body: some View {
        VStack(spacing: 8) {
            Text("MIXER").font(Theme.label).foregroundColor(Theme.textSecondary)
            HStack(alignment: .top, spacing: 6) {
                ForEach(decks) { d in DJChannelStrip(deck: d) }
            }
            VStack(spacing: 4) {
                Text("CROSSFADER").font(Theme.label).foregroundColor(Theme.textSecondary).lineLimit(1).fixedSize()
                HStack(spacing: 4) {
                    ConsoleButton(title: "SMOOTH", isOn: Binding(get: { dj.curve == .smooth }, set: { _ in dj.curve = .smooth }), width: 60, help: "Constant-power blend")
                    ConsoleButton(title: "SHARP", isOn: Binding(get: { dj.curve == .sharp }, set: { _ in dj.curve = .sharp }), width: 52, help: "Both decks at full level until the ends (cut)")
                }
                LinearHSlider(value: Binding(get: { Double(dj.crossfader) }, set: { dj.crossfader = Float($0) }), range: -1...1, width: 170, defaultValue: 0)
                    .help("Crossfader: decks assigned to A fade out to the right, B fade in (double-click to centre)")
                HStack { Text("A").font(Theme.label); Spacer(); PlainButton(title: "CENTER", width: 56, height: 18) { dj.crossfader = 0 }; Spacer(); Text("B").font(Theme.label) }
            }
            HStack(spacing: 8) {
                Text("MASTER").font(Theme.label).foregroundColor(Theme.textSecondary).lineLimit(1).fixedSize()
                HorizontalFaderView(db: Binding(get: { dj.masterDB }, set: { dj.masterDB = $0 }), width: 90)
                Text(dbText(dj.masterDB)).font(Theme.value).foregroundColor(Theme.textPrimary).frame(width: 40)
            }
            MeterBar(db: dj.masterLevelDB, width: 120)
        }
        .padding(10).frame(width: decks.count == 2 ? 200 : 340)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelRaised))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }
}

struct DJChannelStrip: View {
    @ObservedObject var deck: DJDeck
    var body: some View {
        VStack(spacing: 4) {
            Text(deck.name.suffix(1)).font(Theme.title).foregroundColor(Theme.accent)
            PlainButton(title: "XF " + deck.side.rawValue, width: 62, height: 20) {
                let all = DeckSide.allCases
                deck.side = all[((all.firstIndex(of: deck.side) ?? 0) + 1) % all.count]
            }.help("Crossfader assignment (click to cycle A / B / THRU)")
            knob("GAIN", Binding(get: { deck.gainDB }, set: { deck.gainDB = $0 }), -12...12, "%+.0f")
            knob("HIGH", Binding(get: { deck.highDB }, set: { deck.highDB = $0 }), -15...15, "%+.0f")
            knob("MID", Binding(get: { deck.midDB }, set: { deck.midDB = $0 }), -15...15, "%+.0f")
            knob("LOW", Binding(get: { deck.lowDB }, set: { deck.lowDB = $0 }), -15...15, "%+.0f")
            KnobView(title: "FILTER", value: Binding(get: { deck.filter }, set: { deck.filter = $0 }), range: -1...1, defaultValue: 0,
                     format: { $0 < -0.02 ? "LP" : ($0 > 0.02 ? "HP" : "OFF") }, size: 24)
            HStack(spacing: 3) {
                MeterBar(db: deck.levelDB, width: 40)
            }
            VerticalSlider(value: Binding(get: { deck.channelFader }, set: { deck.channelFader = $0 }),
                           range: 0...1, height: 80, defaultValue: 1, step: 0.01)
                .help("Channel fader")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.well.opacity(0.5)))
    }
    private func knob(_ t: String, _ v: Binding<Float>, _ r: ClosedRange<Float>, _ f: String) -> some View {
        KnobView(title: t, value: v, range: r, defaultValue: 0, format: { String(format: f + " dB", $0) }, size: 24)
    }
}
