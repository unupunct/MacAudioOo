import SwiftUI
import AppKit

/// The DJ page: header, waveform strips, two (or four) decks around a central mixer, and the library bar.
struct DJView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var dj: DJEngine
    @State private var showDisplay = false
    @State private var showWaves = true
    @State private var showPads = true
    @State private var showLibrary = true
    @State private var usbName: String? = nil

    var body: some View {
        let decks = dj.activeDecks
        VStack(spacing: 10) {
            header
            if showWaves { waveStrips(decks) }
            if decks.count == 2 {
                HStack(alignment: .top, spacing: 10) {
                    DeckView(deck: decks[0], dj: dj, library: state.library, accent: Theme.padColors[3], compact: false, showPads: showPads)
                    DJMixerPanel(dj: dj, decks: decks)
                    DeckView(deck: decks[1], dj: dj, library: state.library, accent: Theme.padColors[1], compact: false, showPads: showPads)
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 10) {
                        DeckView(deck: decks[0], dj: dj, library: state.library, accent: Theme.padColors[3], compact: true, showPads: showPads)
                        DeckView(deck: decks[2], dj: dj, library: state.library, accent: Theme.padColors[4], compact: true, showPads: showPads)
                    }
                    DJMixerPanel(dj: dj, decks: decks)
                    VStack(spacing: 10) {
                        DeckView(deck: decks[1], dj: dj, library: state.library, accent: Theme.padColors[1], compact: true, showPads: showPads)
                        DeckView(deck: decks[3], dj: dj, library: state.library, accent: Theme.padColors[5], compact: true, showPads: showPads)
                    }
                }
            }
            Spacer(minLength: 0)
            if showLibrary { libraryBar }
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            LogoMark(size: 30).padding(.leading, 70)
            Text("DJ").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(Theme.textPrimary)
            HStack(spacing: 0) {
                seg("2 CHANNELS", on: !dj.fourDecks) { dj.fourDecks = false; settings.djFourDecks = false }
                seg("4 CHANNELS", on: dj.fourDecks) { dj.fourDecks = true; settings.djFourDecks = true }
            }
            .background(Capsule().fill(Theme.well)).overlay(Capsule().stroke(Theme.border))
            Spacer()
            if let e = dj.error { Text(e).font(.system(size: 11)).foregroundColor(Theme.meterOrange).lineLimit(1) }
            PlainButton(title: "Display", systemImage: "rectangle.3.group", height: 30) { showDisplay.toggle() }
                .popover(isPresented: $showDisplay, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Display").font(Theme.title).foregroundColor(Theme.textPrimary)
                        SwitchRow(title: "Waveforms", isOn: $showWaves)
                        SwitchRow(title: "Performance pads", isOn: $showPads)
                        SwitchRow(title: "Library bar", isOn: $showLibrary)
                    }.padding(16).frame(width: 240).background(Theme.panel)
                }
            PlainButton(title: "Full Screen", systemImage: "arrow.up.left.and.arrow.down.right", height: 30) {
                (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
            }
            PlainButton(title: "Back to Console", systemImage: "chevron.left", height: 30, tint: Theme.sidebarActive) { settings.selectedTab = .console }
        }
        .frame(height: 40)
    }

    private func seg(_ t: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 10, weight: .bold, design: .rounded)).lineLimit(1).fixedSize()
                .foregroundColor(on ? Color(hex: 0x06101C) : Theme.textSecondary)
                .padding(.horizontal, 14).frame(height: 28)
                .background(Capsule().fill(on ? Theme.cyan : Color.clear))
        }.buttonStyle(.plain)
    }

    // MARK: Waveform strips

    private func waveStrips(_ decks: [DJDeck]) -> some View {
        VStack(spacing: 6) {
            ForEach(decks) { d in
                HStack(spacing: 8) {
                    Text(d.name.suffix(1)).font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundColor(Theme.textPrimary)
                        .frame(width: 26, height: 26).background(Circle().fill(Theme.panelRaised))
                    WaveformDetailView(deck: d).frame(height: decks.count == 2 ? 50 : 34)
                }
            }
        }
        .padding(10).glassCard(radius: 14)
    }

    // MARK: Library bar

    private var libraryBar: some View {
        HStack(spacing: 10) {
            Text("LIBRARY").font(.system(size: 12, weight: .bold, design: .rounded)).kerning(1.5).foregroundColor(Theme.textPrimary)
            Text("\(state.library.tracks.count) tracks").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(Theme.textSecondary)
            if state.library.importing { Text("Importing…").font(.system(size: 11)).foregroundColor(Theme.meterYellow) }
            Spacer()
            PlainButton(title: "Add Folder", systemImage: "folder.badge.plus", height: 30) { addFolder(usb: false) }
            PlainButton(title: "Add USB", systemImage: "externaldrive.badge.plus", height: 30) { addFolder(usb: true) }
            Text(usbName.map { "USB: " + $0 } ?? "NO USB ADDED")
                .font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(usbName == nil ? Theme.textSecondary : Theme.meterGreen)
                .padding(.horizontal, 12).frame(height: 26).background(Capsule().fill(Theme.well)).overlay(Capsule().stroke(Theme.border))
        }
        .padding(.horizontal, 14).padding(.vertical, 8).glassCard(radius: 14)
    }

    private func addFolder(usb: Bool) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        if usb { p.directoryURL = URL(fileURLWithPath: "/Volumes"); p.message = "Choose a USB drive or a folder on it" }
        if p.runModal() == .OK, let u = p.url {
            state.library.importURLs([u])
            if usb { usbName = u.lastPathComponent }
        }
    }
}

// MARK: - Deck

struct DeckView: View {
    @ObservedObject var deck: DJDeck
    let dj: DJEngine
    @ObservedObject var library: MusicLibrary
    var accent: Color
    let compact: Bool
    var showPads = true
    @EnvironmentObject var settings: AppSettings
    @State private var dropTargeted = false
    @State private var showPicker = false
    @State private var padMode = 0          // 0 Hot Cue, 1 Loop

    private let loopSizes: [Double] = [0.25, 0.5, 1, 2, 4, 8, 16, 32]

    var body: some View {
        VStack(spacing: 8) {
            header
            HStack(alignment: .top, spacing: 10) {
                if !compact { JogWheelView(deck: deck, size: 170, accent: accent) }
                VStack(spacing: 8) {
                    transportRow
                    loopRow
                    bpmBlock
                }
                tempoColumn
            }
            if showPads { padSection }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(LinearGradient(colors: [Theme.panelTop, Theme.panelBottom], startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(dropTargeted ? Theme.cyan : accent.opacity(0.45), lineWidth: dropTargeted ? 2 : 1.2))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in loadDropped(providers) }
        .popover(isPresented: $showPicker) { TrackPicker(library: library) { t in deck.load(t); showPicker = false } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(deck.name.suffix(1)).font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundColor(.white)
                .frame(width: 28, height: 28).background(Circle().fill(accent))
            VStack(alignment: .leading, spacing: 1) {
                Text(deck.track?.title ?? "No track loaded").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(Theme.textPrimary).lineLimit(1)
                Text(deck.track?.artist ?? "Drop an audio file here, or press Load").font(.system(size: 10)).foregroundColor(Theme.textSecondary).lineLimit(1)
            }
            Spacer()
            PlainButton(title: "Load…", height: 26) { showPicker = true }.help("Choose a track from the library")
            PlainButton(systemImage: "eject.fill", width: 30, height: 26) { deck.eject() }.disabled(!deck.isLoaded).help("Eject")
        }
        .overlay(alignment: .bottomLeading) {
            if let e = deck.loadError { Text(e).font(.system(size: 9)).foregroundColor(Theme.meterOrange).offset(y: 12) }
        }
    }

    private var transportRow: some View {
        HStack(spacing: 6) {
            PlainButton(title: "CUE", width: 52, height: 36) { deck.cue() }
                .disabled(!deck.isLoaded).help("Playing: return to the cue point. Paused: set the cue point here.")
            Button(action: { deck.togglePlay() }) {
                Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                    .frame(width: 56, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [Color(hex: 0x3CD068), Color(hex: 0x1E9E48)], startPoint: .top, endPoint: .bottom)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.black.opacity(0.4)))
                    .shadow(color: Theme.meterGreen.opacity(deck.isPlaying ? 0.6 : 0), radius: 6)
            }.buttonStyle(.plain).disabled(!deck.isLoaded).opacity(deck.isLoaded ? 1 : 0.45).help("Play / pause")
            PlainButton(systemImage: "stop.fill", width: 40, height: 36) { deck.stop() }.disabled(!deck.isLoaded).help("Stop and rewind")
            ConsoleButton(title: "SLIP", isOn: $deck.slip, onColor: Theme.meterYellow, width: 46,
                          help: "Slip: while a loop runs, the track keeps moving underneath and playback jumps there when the loop ends")
        }
    }

    private var loopRow: some View {
        HStack(spacing: 6) {
            PlainButton(title: "−", width: 28, height: 26) { deck.scaleLoop(by: 0.5) }.disabled(deck.grid == nil).help("Halve the loop")
            Button(action: { deck.toggleAutoLoop(beats: deck.loopBeats) }) {
                Text(beatsText).font(.system(size: 10, weight: .heavy, design: .rounded)).lineLimit(1).fixedSize()
                    .foregroundColor(deck.loopActive ? Color(hex: 0x06101C) : Theme.textPrimary)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 8).fill(deck.loopActive ? AnyShapeStyle(Theme.meterYellow) : AnyShapeStyle(Theme.well)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.borderStrong))
            }.buttonStyle(.plain).disabled(deck.grid == nil).opacity(deck.grid == nil ? 0.45 : 1).help("Loop this many beats on/off (needs a beat grid)")
            PlainButton(title: "+", width: 28, height: 26) { deck.scaleLoop(by: 2) }.disabled(deck.grid == nil).help("Double the loop")
            PlainButton(title: "IN", width: 34, height: 26) { deck.setLoopIn() }.disabled(!deck.isLoaded).help("Set the loop start at the playhead")
            PlainButton(title: "OUT", width: 38, height: 26) { deck.setLoopOut() }.disabled(!deck.isLoaded).help("Set the loop end and start looping")
        }
    }

    private var beatsText: String {
        let b = deck.loopBeats
        let n = b < 1 ? (b == 0.5 ? "1/2" : "1/4") : String(Int(b))
        return n + (b == 1 ? " BEAT" : " BEATS")
    }

    private var bpmBlock: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("ORIGINAL BPM").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundColor(Theme.textSecondary)
                    Text(deck.grid.map { String(format: "%.1f", $0.bpm) } ?? (deck.analyzing ? "…" : "—"))
                        .font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundColor(Theme.textPrimary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(deck.analyzing ? "ANALYZING" : "CURRENT BPM").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundColor(Theme.textSecondary)
                    Text(deck.effectiveBPM.map { String(format: "%.1f", $0) } ?? "—")
                        .font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundColor(Theme.cyan)
                }
            }
            HStack(spacing: 4) {
                PlainButton(title: "SYNC", width: 44, height: 26) { dj.sync(deck) }
                    .disabled(deck.grid == nil || dj.syncMaster(excluding: deck) == nil).help("Match tempo and beat phase to the other deck")
                PlainButton(title: "TAP", width: 36, height: 26) { deck.tapTempo() }.disabled(!deck.isLoaded)
                    .help("Tap at least three times in rhythm to set this track's BPM")
                PlainButton(title: "½", width: 30, height: 26) { deck.scaleBPM(by: 0.5) }.disabled(deck.grid == nil).help("Detected tempo is double: halve it")
                PlainButton(title: "×2", width: 32, height: 26) { deck.scaleBPM(by: 2) }.disabled(deck.grid == nil).help("Detected tempo is half: double it")
                PlainButton(title: "MATCH", width: 50, height: 26) { if let m = dj.syncMaster(excluding: deck) { deck.matchTempo(to: m) } }
                    .disabled(deck.grid == nil || dj.syncMaster(excluding: deck) == nil).help("Match tempo to the other deck (no beat alignment)")
            }
        }
    }

    private var tempoColumn: some View {
        VStack(spacing: 6) {
            DropdownField(label: "±\(Int(settings.djTempoRange))%", items: [("8", "±8%"), ("16", "±16%"), ("50", "±50%")], width: 84, height: 26) { id in
                if let v = Double(id) { settings.djTempoRange = v; dj.tempoRange = v }
            }
            Text(String(format: "%+.1f%%", deck.tempoPercent)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(Theme.textPrimary)
            VerticalSlider(value: Binding(get: { Float(deck.tempoPercent) }, set: { deck.tempoPercent = Double($0) }),
                           range: Float(-settings.djTempoRange)...Float(settings.djTempoRange), height: compact ? 90 : 142, defaultValue: 0, step: 0.1)
                .help("Tempo (double-click to reset)")
            ConsoleButton(title: "KEY", isOn: $deck.keyLock, onColor: Theme.cyan, width: 40,
                          help: "Key lock: tempo changes keep the original pitch (time-stretch)")
        }
        .frame(width: 84)
    }

    private var padSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("PAD MODE").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(Theme.textSecondary)
                modeButton("Hot Cue", 0)
                modeButton("Loop", 1)
                disabledMode("Slicer")
                disabledMode("Sampler")
                Spacer()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(0..<8, id: \.self) { i in pad(i) }
            }
        }
    }

    private func modeButton(_ t: String, _ m: Int) -> some View {
        Button(action: { padMode = m }) {
            Text(t).font(.system(size: 10, weight: .bold, design: .rounded)).lineLimit(1).fixedSize()
                .foregroundColor(padMode == m ? .white : Theme.textSecondary)
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(padMode == m ? Theme.sidebarActive : Theme.well))
                .overlay(Capsule().stroke(padMode == m ? Theme.cyan.opacity(0.6) : Theme.border))
        }.buttonStyle(.plain)
    }

    private func disabledMode(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(Theme.textMuted)
            .padding(.horizontal, 10).frame(height: 24).background(Capsule().fill(Theme.well.opacity(0.6)))
            .overlay(Capsule().stroke(Theme.border)).opacity(0.5)
            .help("\(t) pads are not implemented in this version")
    }

    @ViewBuilder
    private func pad(_ i: Int) -> some View {
        if padMode == 0 { hotCuePad(i) } else { loopPad(i) }
    }

    private func hotCuePad(_ i: Int) -> some View {
        let color = Theme.padColors[i % Theme.padColors.count]
        let set = deck.hotCues[i] != nil
        let sub: String = deck.hotCues[i].map { timeString($0) } ?? "SET"
        return Button(action: { deck.hotCue(i) }) {
            PadFace(color: color, on: set, big: String(i + 1), small: sub, compact: compact)
        }
        .buttonStyle(.plain).disabled(!deck.isLoaded)
        .contextMenu { Button("Clear hot cue \(i + 1)") { deck.clearHotCue(i) } }
        .help(set ? "Jump to hot cue \(i + 1) (right-click to clear)" : "Set hot cue \(i + 1) at the playhead")
    }

    private func loopPad(_ i: Int) -> some View {
        let color = Theme.padColors[i % Theme.padColors.count]
        let beats = loopSizes[i]
        let on = deck.loopActive && abs(deck.loopBeats - beats) < 0.001
        let big: String = beats < 1 ? (beats == 0.5 ? "1/2" : "1/4") : String(Int(beats))
        let small: String = beats == 1 ? "BEAT" : "BEATS"
        return Button(action: { deck.toggleAutoLoop(beats: beats) }) {
            PadFace(color: color, on: on, big: big, small: small, compact: compact)
        }
        .buttonStyle(.plain).disabled(deck.grid == nil).opacity(deck.grid == nil ? 0.5 : 1)
        .help("Loop from the nearest beat (needs a beat grid)")
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

struct PadFace: View {
    var color: Color
    var on: Bool
    var big: String
    var small: String
    var compact: Bool
    var body: some View {
        VStack(spacing: 1) {
            Text(big).font(.system(size: 13, weight: .heavy, design: .rounded))
            Text(small).font(.system(size: 8, weight: .bold, design: .monospaced))
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 30 : 44)
        .foregroundColor(on ? Color.white : Theme.textSecondary)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(on ? 1 : 0.22)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.8)))
        .shadow(color: on ? color.opacity(0.55) : Color.clear, radius: 5)
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
            if library.tracks.isEmpty { Text("The library is empty. Add a folder in the bar below, or import music in the Library tab.").font(.system(size: 11)).foregroundColor(.secondary) }
        }.padding(10)
    }
}

// MARK: - Jog wheel

/// Circular jog wheel: silver outer ring, dark inner disc with radial ticks turning with the track, title and remaining time.
/// Dragging while playing bends the pitch (nudge); dragging while paused scrubs.
struct JogWheelView: View {
    @ObservedObject var deck: DJDeck
    var size: CGFloat
    var accent: Color = Theme.cyan
    @State private var lastAngle: Double?

    var body: some View {
        let angle = deck.isLoaded ? (deck.position / 1.8) * 360 : 0         // one revolution per 1.8 s of audio
        ZStack {
            Circle().fill(Color.black.opacity(0.5)).frame(width: size + 6, height: size + 6).blur(radius: 5).offset(y: 3)
            Circle().fill(AngularGradient(colors: [Color(hex: 0xF2F5FA), Color(hex: 0x8D96A8), Color(hex: 0xE6EAF2), Color(hex: 0x7A8398), Color(hex: 0xF2F5FA)], center: .center))
                .frame(width: size, height: size)
            Circle().stroke(Color.black.opacity(0.5), lineWidth: 1.5).frame(width: size, height: size)
            Circle().fill(RadialGradient(colors: [Color(hex: 0x1A2234), Color(hex: 0x0B111C)], center: .center, startRadius: 2, endRadius: size * 0.4))
                .frame(width: size * 0.74, height: size * 0.74)
            Canvas { ctx, s in
                let c = CGPoint(x: s.width / 2, y: s.height / 2), r = min(s.width, s.height) / 2
                for i in 0..<60 {
                    let a = Double(i) / 60 * 2 * .pi - .pi / 2
                    let long = i % 5 == 0
                    var p = Path()
                    p.move(to: CGPoint(x: c.x + CGFloat(cos(a)) * (r - (long ? 9 : 5)), y: c.y + CGFloat(sin(a)) * (r - (long ? 9 : 5))))
                    p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * (r - 1), y: c.y + CGFloat(sin(a)) * (r - 1)))
                    ctx.stroke(p, with: .color(.white.opacity(long ? 0.55 : 0.25)), lineWidth: long ? 1.5 : 1)
                }
            }
            .frame(width: size * 0.74, height: size * 0.74).rotationEffect(.degrees(angle))
            Capsule().fill(accent).frame(width: 4, height: size * 0.11).shadow(color: accent, radius: 3)
                .offset(y: -size * 0.32).rotationEffect(.degrees(angle))
            VStack(spacing: 3) {
                Text(deck.track?.title ?? "No track").font(.system(size: size * 0.065, weight: .bold, design: .rounded)).foregroundColor(Theme.textPrimary)
                    .lineLimit(2).multilineTextAlignment(.center).frame(width: size * 0.42)
                Text("-" + timeString(deck.remaining)).font(.system(size: size * 0.065, weight: .semibold, design: .monospaced)).foregroundColor(Theme.cyan)
                    .lineLimit(1).fixedSize()
            }
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

// MARK: - Mixer

struct DJMixerPanel: View {
    @ObservedObject var dj: DJEngine
    let decks: [DJDeck]

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(decks) { d in DJChannelStrip(deck: d, compact: decks.count > 2) }
            }
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text("CROSSFADER").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(Theme.textSecondary).lineLimit(1).fixedSize()
                    Spacer()
                    ConsoleButton(title: "SMOOTH", isOn: Binding(get: { dj.curve == .smooth }, set: { _ in dj.curve = .smooth }), width: 54, help: "Constant-power blend")
                    ConsoleButton(title: "SHARP", isOn: Binding(get: { dj.curve == .sharp }, set: { _ in dj.curve = .sharp }), width: 46, help: "Both decks at full level until the ends (cut)")
                }
                HStack(spacing: 8) {
                    Text("A").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundColor(Theme.textPrimary)
                    LinearHSlider(value: Binding(get: { Double(dj.crossfader) }, set: { dj.crossfader = Float($0) }), range: -1...1, width: 170, defaultValue: 0)
                        .help("Crossfader: decks assigned to A fade out to the right, B fade in (double-click to centre)")
                    Text("B").font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundColor(Theme.textPrimary)
                }
            }
            HStack(spacing: 8) {
                Text("MASTER").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(Theme.textSecondary).lineLimit(1).fixedSize()
                HorizontalFaderView(db: Binding(get: { dj.masterDB }, set: { dj.masterDB = $0 }), width: 96)
                Text(dbText(dj.masterDB)).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(Theme.textPrimary).frame(width: 36)
            }
            DJHMeter(db: dj.masterLevelDB, width: 190)
        }
        .padding(12).frame(width: decks.count == 2 ? 340 : 380)
        .glassCard(radius: 16)
    }
}

struct DJChannelStrip: View {
    @ObservedObject var deck: DJDeck
    var compact: Bool

    var body: some View {
        if compact { compactBody } else { wideBody }
    }

    /// Two-deck layout: knobs in two columns, then the meter and the channel fader side by side (keeps the mixer short).
    private var wideBody: some View {
        VStack(spacing: 6) {
            Text(deck.name.suffix(1)).font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundColor(Theme.cyan)
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 4) {
                    HStack(spacing: 2) {
                        knob("TRIM", Binding(get: { deck.gainDB }, set: { deck.gainDB = $0 }), -12...12)
                        knob("HIGH", Binding(get: { deck.highDB }, set: { deck.highDB = $0 }), -15...15)
                    }
                    HStack(spacing: 2) {
                        knob("MID", Binding(get: { deck.midDB }, set: { deck.midDB = $0 }), -15...15)
                        knob("LOW", Binding(get: { deck.lowDB }, set: { deck.lowDB = $0 }), -15...15)
                    }
                    KnobView(title: "FILTER", value: Binding(get: { deck.filter }, set: { deck.filter = $0 }), range: -1...1, defaultValue: 0,
                             format: { $0 < -0.02 ? "LP" : ($0 > 0.02 ? "HP" : "OFF") }, size: 24)
                }
                DJVMeter(db: deck.levelDB, height: 186)
                VerticalSlider(value: Binding(get: { deck.channelFader }, set: { deck.channelFader = $0 }),
                               range: 0...1, height: 186, defaultValue: 1, step: 0.01).help("Channel fader")
            }
            HStack(spacing: 6) { hpButton; xfButton }
        }
        .padding(8).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.well.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }

    private var hpButton: some View {
        Text("HP").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(Theme.textMuted)
            .frame(width: 38, height: 22).background(RoundedRectangle(cornerRadius: 6).fill(Theme.well.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border)).opacity(0.5)
            .help("Headphone cue is not implemented: it would need a genuine second output path")
    }

    private var xfButton: some View {
        PlainButton(title: "XF " + deck.side.rawValue, width: 56, height: 22) {
            let all = DeckSide.allCases
            deck.side = all[((all.firstIndex(of: deck.side) ?? 0) + 1) % all.count]
        }.help("Crossfader assignment (click to cycle A / B / THRU)")
    }

    private var compactBody: some View {
        VStack(spacing: 6) {
            Text(deck.name.suffix(1)).font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundColor(Theme.cyan)
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 4) {
                    knob("TRIM", Binding(get: { deck.gainDB }, set: { deck.gainDB = $0 }), -12...12)
                    knob("HIGH", Binding(get: { deck.highDB }, set: { deck.highDB = $0 }), -15...15)
                    knob("MID", Binding(get: { deck.midDB }, set: { deck.midDB = $0 }), -15...15)
                    knob("LOW", Binding(get: { deck.lowDB }, set: { deck.lowDB = $0 }), -15...15)
                    KnobView(title: "FILTER", value: Binding(get: { deck.filter }, set: { deck.filter = $0 }), range: -1...1, defaultValue: 0,
                             format: { $0 < -0.02 ? "LP" : ($0 > 0.02 ? "HP" : "OFF") }, size: 24)
                }
                DJVMeter(db: deck.levelDB, height: compact ? 200 : 258)
            }
            VerticalSlider(value: Binding(get: { deck.channelFader }, set: { deck.channelFader = $0 }),
                           range: 0...1, height: 56, defaultValue: 1, step: 0.01).help("Channel fader")
            Text("HP").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(Theme.textMuted)
                .frame(width: 38, height: 22).background(RoundedRectangle(cornerRadius: 6).fill(Theme.well.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border)).opacity(0.5)
                .help("Headphone cue is not implemented: it would need a genuine second output path")
            PlainButton(title: "XF " + deck.side.rawValue, width: 56, height: 20) {
                let all = DeckSide.allCases
                deck.side = all[((all.firstIndex(of: deck.side) ?? 0) + 1) % all.count]
            }.help("Crossfader assignment (click to cycle A / B / THRU)")
        }
        .padding(8).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.well.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }

    private func knob(_ t: String, _ v: Binding<Float>, _ r: ClosedRange<Float>) -> some View {
        KnobView(title: t, value: v, range: r, defaultValue: 0, format: { String(format: "%+.0f", $0) }, size: 24)
    }
}

/// Vertical segmented meter with a dBFS scale.
struct DJVMeter: View {
    var db: Float
    var height: CGFloat
    private let segments = 24, minDB: Float = -48, maxDB: Float = 0

    var body: some View {
        HStack(alignment: .top, spacing: 3) {
            ZStack(alignment: .topTrailing) {
                ForEach([0, -6, -12, -24, -48], id: \.self) { t in
                    Text(t == -48 ? "-48" : String(t)).font(.system(size: 7, weight: .medium, design: .rounded)).foregroundColor(Theme.textSecondary)
                        .offset(y: CGFloat((maxDB - Float(t)) / (maxDB - minDB)) * (height - 8))
                }
            }.frame(width: 16, height: height, alignment: .topTrailing)
            Canvas { ctx, size in
                let segH = size.height / CGFloat(segments)
                for i in 0..<segments {
                    let sdb = minDB + (maxDB - minDB) * Float(i) / Float(segments - 1)
                    let color: Color = sdb > -3 ? Theme.meterOrange : (sdb > -12 ? Theme.meterYellow : Theme.meterGreen)
                    let y = size.height - CGFloat(i + 1) * segH
                    ctx.fill(Path(roundedRect: CGRect(x: 0, y: y + 0.6, width: size.width, height: max(1, segH - 1.4)), cornerRadius: 1),
                             with: .color(db >= sdb ? color : color.opacity(0.10)))
                }
            }
            .frame(width: 10, height: height).padding(2).background(RoundedRectangle(cornerRadius: 3).fill(Theme.well))
        }
    }
}

/// Horizontal segmented master meter.
struct DJHMeter: View {
    var db: Float
    var width: CGFloat
    private let segments = 32, minDB: Float = -48, maxDB: Float = 0
    var body: some View {
        Canvas { ctx, size in
            let segW = size.width / CGFloat(segments)
            for i in 0..<segments {
                let sdb = minDB + (maxDB - minDB) * Float(i) / Float(segments - 1)
                let color: Color = sdb > -3 ? Theme.meterOrange : (sdb > -12 ? Theme.meterYellow : Theme.meterGreen)
                ctx.fill(Path(roundedRect: CGRect(x: CGFloat(i) * segW + 0.7, y: 0, width: segW - 1.4, height: size.height), cornerRadius: 1),
                         with: .color(db >= sdb ? color : color.opacity(0.10)))
            }
        }
        .frame(width: width, height: 8).padding(3)
        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.well))
    }
}
