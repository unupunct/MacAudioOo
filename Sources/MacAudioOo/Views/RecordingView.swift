import SwiftUI
import AppKit

/// The RECORDING page: transport card, timeline with one track per source, mixer-settings panel and session history.
struct RecordingView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var recorder: RecordingEngine
    @StateObject private var hub = MeterHub()
    @StateObject private var player = RecordingPlayer()
    @State private var sessionToDelete: RecordingSession?
    @State private var selectedSession: String?
    @State private var showHistory = false

    var body: some View {
        let engine = state.engine
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 12) {
                transport(engine)
                timeline(engine)
                if showHistory { history(engine) }
                else {
                    HStack {
                        Spacer()
                        PlainButton(title: "Session history (\(recorder.library.sessions.count))", height: 28) { showHistory = true }
                    }
                }
            }
            settingsPanel(engine).frame(width: 250)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .onAppear { hub.start(engine: engine); recorder.library.refresh(); recorder.refreshFreeSpace() }
        .onDisappear { hub.stop() }
        .confirmationDialog("Move this recording to the Trash?", isPresented: Binding(get: { sessionToDelete != nil }, set: { if !$0 { sessionToDelete = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let s = sessionToDelete { try? recorder.library.delete(s) }
                sessionToDelete = nil
            }
            Button("Cancel", role: .cancel) { sessionToDelete = nil }
        } message: { Text(sessionToDelete?.info.name ?? "") }
    }

    // MARK: Transport card

    private func transport(_ engine: AudioEngine) -> some View {
        let rec = recorder.state
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                CardTitle(text: "Recording")
                Spacer()
                if rec != .idle {
                    HStack(spacing: 6) {
                        Circle().fill(rec == .paused ? Theme.meterYellow : Theme.record).frame(width: 8, height: 8)
                        Text(rec == .paused ? "PAUSED" : "RECORDING").font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(rec == .paused ? Theme.meterYellow : Theme.record)
                    }
                }
            }
            HStack(alignment: .center, spacing: 16) {
                HStack(spacing: 10) {
                    roundButton(icon: "circle.fill", color: Theme.record, enabled: rec == .idle && engine.status.isRunning,
                                help: "Start recording the stereo mix and all armed channels") { recorder.start() }
                    roundButton(icon: "stop.fill", color: Theme.textPrimary, enabled: rec != .idle, help: "Stop and save the recording") { recorder.stop() }
                    roundButton(icon: rec == .paused ? "play.fill" : "pause.fill", color: Theme.meterGreen, enabled: rec != .idle,
                                help: rec == .paused ? "Resume" : "Pause (audio during the pause is not recorded)") {
                        rec == .paused ? recorder.resume() : recorder.pause()
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    labelled("Session Name") {
                        TextField("Session 1", text: $recorder.sessionName).textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, 10).frame(height: 30).frame(minWidth: 180)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                            .disabled(rec != .idle)
                    }
                    labelled("Destination Folder") {
                        HStack(spacing: 6) {
                            Text(settings.recordingDirectory).font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundColor(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                                .padding(.horizontal, 10).frame(height: 30, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.well))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                            PlainButton(title: "Choose…", height: 30) { chooseFolder() }.disabled(rec != .idle)
                            PlainButton(systemImage: "folder", width: 34, height: 30) { NSWorkspace.shared.open(URL(fileURLWithPath: settings.recordingDirectory)) }
                                .help("Show in Finder")
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 8) {
                    Text(timeString(recorder.elapsed)).font(.system(size: 40, weight: .semibold, design: .monospaced))
                        .foregroundColor(rec == .recording ? Theme.record : Theme.textPrimary).lineLimit(1).fixedSize()
                    HStack(spacing: 8) {
                        ValuePill(text: "48 kHz / 24-bit WAV", color: Theme.cyan).fixedSize()
                        ValuePill(text: diskText).fixedSize()
                    }
                }
            }
            if let e = recorder.lastError {
                Text(e).font(.system(size: 11)).foregroundColor(Theme.meterOrange).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let m = recorder.library.lastRecoveryMessage {
                Text(m).font(.system(size: 11)).foregroundColor(Theme.meterYellow).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14).glassCard(radius: 16)
    }

    private func labelled<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(Theme.textSecondary)
            c()
        }
    }

    private func roundButton(icon: String, color: Color, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18, weight: .bold)).foregroundColor(color)
                .frame(width: 50, height: 50)
                .background(Circle().fill(LinearGradient(colors: [Theme.buttonTop, Theme.buttonBottom], startPoint: .top, endPoint: .bottom)))
                .overlay(Circle().stroke(Theme.borderStrong, lineWidth: 1))
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain).disabled(!enabled).help(help)
    }

    private var diskText: String {
        guard let s = recorder.remainingSeconds else {
            return recorder.freeBytes.map { "Free " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Disk unknown"
        }
        return "Disk Time Remaining: " + durationString(s)
    }

    // MARK: Timeline

    private func timeline(_ engine: AudioEngine) -> some View {
        let recording = recorder.state != .idle
        let windowSeconds = 20.0
        let end = max(windowSeconds, recorder.elapsed), start = end - windowSeconds
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                CardTitle(text: "Timeline", subtitle: recording ? "Live waveforms of what is being written" : "Arm tracks, then press record")
                Spacer()
                ValuePill(text: "last 20 s")
            }
            .padding(.bottom, 8)
            HStack(spacing: 0) {
                Color.clear.frame(width: 232, height: 20)
                Canvas { ctx, size in
                    for sec in Int(ceil(start))...Int(floor(end)) where sec % 5 == 0 {
                        let x = CGFloat((Double(sec) - start) / windowSeconds) * size.width
                        var p = Path(); p.move(to: CGPoint(x: x, y: size.height - 8)); p.addLine(to: CGPoint(x: x, y: size.height))
                        ctx.stroke(p, with: .color(Theme.textMuted), lineWidth: 1)
                        let t = Text(String(format: "%d:%02d", sec / 60, sec % 60)).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(Theme.textSecondary)
                        ctx.draw(t, at: CGPoint(x: x + 3, y: 6), anchor: .leading)
                    }
                }.frame(height: 20)
            }
            ScrollView(.vertical) {
                VStack(spacing: 6) {
                    RecTrackRow(index: 1, title: "Mix", icon: nil, color: Theme.padColors[3],
                             armed: Binding(get: { recorder.recordMix }, set: { recorder.recordMix = $0 }),
                             meter: hub.masterL, live: recorder.liveTracks.first { $0.isMix }, recording: recording)
                    ForEach(Array(engine.channels.enumerated()), id: \.element.id) { pair in
                        ChannelTrack(index: pair.offset + 2, channel: pair.element, meter: hub.model(for: pair.element), recorder: recorder)
                    }
                    if engine.channels.isEmpty {
                        Text("No application channels yet. Channels appear once a capture backend is active; arm them to record separate stems.")
                            .font(.system(size: 11)).foregroundColor(Theme.textSecondary).padding(10)
                    }
                }
                .overlay(alignment: .trailing) {
                    // Playhead: the newest audio is always at the right edge.
                    if recording { Rectangle().fill(Theme.cyan).frame(width: 2).shadow(color: Theme.cyan, radius: 4) }
                }
            }
            .frame(minHeight: 140, maxHeight: .infinity)
        }
        .padding(14).glassCard(radius: 16)
        .frame(maxHeight: .infinity)
    }

    // MARK: Settings panel

    private func settingsPanel(_ engine: AudioEngine) -> some View {
        let locked = recorder.state != .idle
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                CardTitle(text: "Mixer Settings")
                Spacer()
                Text("Linked").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(Theme.cyan)
                    .padding(.horizontal, 8).frame(height: 20).background(Capsule().stroke(Theme.cyan.opacity(0.7)))
            }
            Text("What each individual track captures from its mixer channel").font(.system(size: 10)).foregroundColor(Theme.textSecondary)
            checkRow("EQ", isOn: $recorder.stemsIncludeEQ, enabled: !locked, help: "Apply the channel's EQ and compressor to its track")
            checkRow("Fader", isOn: $recorder.stemsIncludeFader, enabled: !locked, help: "Apply the channel's fader, mute, solo, group and ducking to its track")
            checkRow("FX", isOn: .constant(false), enabled: false, help: "Reverb and delay are shared effects: they are only ever recorded in the stereo mix, never duplicated in tracks")
            Text("FX (reverb, delay) are recorded in the stereo mix only.").font(.system(size: 10)).foregroundColor(Theme.textMuted)
            Divider().overlay(Theme.border)
            VStack(alignment: .leading, spacing: 14) {
                CardTitle(text: "Recording Options")
                checkRow("Stereo mix", isOn: $recorder.recordMix, enabled: !locked, help: "Record the final stereo output after master processing")
                checkRow("Individual tracks", isOn: Binding(get: { engine.channels.contains { $0.recArm } },
                                                            set: { v in engine.channels.forEach { $0.recArm = v } }),
                         enabled: !locked && !engine.channels.isEmpty, help: "Arm every application channel to record its own file")
            }
            Spacer(minLength: 0)
        }
        .padding(14).frame(maxHeight: .infinity, alignment: .top).glassCard(radius: 16)
    }

    private func checkRow(_ title: String, isOn: Binding<Bool>, enabled: Bool, help: String) -> some View {
        Button(action: { isOn.wrappedValue.toggle() }) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 5).fill(isOn.wrappedValue ? Theme.blue : Theme.well)
                    .frame(width: 20, height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(isOn.wrappedValue ? Theme.cyan.opacity(0.7) : Theme.borderStrong))
                    .overlay(Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundColor(.white).opacity(isOn.wrappedValue ? 1 : 0))
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(Theme.textPrimary)
                Spacer()
            }.contentShape(Rectangle()).opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain).disabled(!enabled).help(help)
    }

    // MARK: History

    private func history(_ engine: AudioEngine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CardTitle(text: "Session history", subtitle: "\(recorder.library.sessions.count) recordings in this folder")
                Spacer()
                if let e = player.error { Text(e).font(.system(size: 11)).foregroundColor(Theme.meterOrange) }
                PlainButton(title: "Hide", height: 26) { showHistory = false }
            }
            if recorder.library.sessions.isEmpty {
                Text("No recordings in this folder yet.").font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 50)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 6) {
                        ForEach(recorder.library.sessions) { s in
                            SessionRow(session: s, expanded: selectedSession == s.id, player: player,
                                       deviceUID: engine.currentDeviceUID,
                                       onToggle: { selectedSession = selectedSession == s.id ? nil : s.id },
                                       onDelete: { sessionToDelete = s })
                        }
                    }
                }.frame(maxHeight: 220)
            }
        }
        .padding(14).glassCard(radius: 16)
    }

    private func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { settings.recordingDirectory = u.path; recorder.library.setRoot(u); recorder.refreshFreeSpace() }
    }
}

func timeString(_ s: TimeInterval) -> String {
    let t = Int(s * 10), h = t / 36000, m = (t / 600) % 60, sec = (t / 10) % 60, d = t % 10
    return String(format: "%02d:%02d:%02d.%d", h, m, sec, d)
}
func durationString(_ s: Double) -> String {
    let m = Int(s / 60); return m >= 120 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
}

// MARK: - Tracks

struct ChannelTrack: View {
    let index: Int
    @ObservedObject var channel: AudioChannel
    @ObservedObject var meter: MeterModel
    @ObservedObject var recorder: RecordingEngine
    var body: some View {
        RecTrackRow(index: index, title: channel.name, icon: channel.icon,
                 color: Theme.padColors[(index - 1) % Theme.padColors.count], armed: $channel.recArm, meter: meter,
                 live: recorder.liveTracks.first { $0.id == channel.id.uuidString }, recording: recorder.state != .idle)
    }
}

/// One timeline track: number, name, R / S / M buttons, level meter and the coloured waveform bar.
struct RecTrackRow: View {
    var index: Int
    var title: String
    var icon: NSImage?
    var color: Color
    @Binding var armed: Bool
    @ObservedObject var meter: MeterModel
    var live: LiveTrack?
    var recording: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("\(index)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(Theme.textPrimary)
                    .frame(width: 18, height: 18).background(Circle().fill(Theme.panelRaised))
                Group {
                    if let icon = icon { Image(nsImage: icon).resizable().interpolation(.high) }
                    else { Image(systemName: "slider.horizontal.3").resizable().scaledToFit().padding(4).foregroundColor(Theme.cyan) }
                }.frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(Theme.textPrimary).lineLimit(1)
                    HorizontalMeterView(model: meter, width: 70, height: 5)
                }.frame(width: 76, alignment: .leading)
            }
            .frame(width: 130, alignment: .leading)
            HStack(spacing: 4) {
                ConsoleButton(title: "R", isOn: $armed, onColor: Theme.record, width: 24, help: recording ? "Arming is locked while recording" : "Arm this track for recording").disabled(recording)
                ConsoleButton(title: "S", isOn: .constant(false), width: 24, help: "Not available while recording: use solo on the Mixer").disabled(true).opacity(0.4)
                ConsoleButton(title: "M", isOn: .constant(false), width: 24, help: "Not available while recording: use mute on the Mixer").disabled(true).opacity(0.4)
            }
            WaveformLiveView(peaks: live?.peaks ?? [], recording: recording && live != nil, color: color, armed: armed)
                .frame(height: 44)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.well.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(armed ? Theme.record.opacity(0.6) : Theme.border))
    }
}

/// Live waveform of the audio actually being written to the track's file (last ~20 s).
struct WaveformLiveView: View {
    var peaks: [WaveformPeak]
    var recording: Bool
    var color: Color = Theme.cyan
    var armed = false
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(color.opacity(armed ? 0.16 : 0.07)))
            let mid = size.height / 2
            var line = Path(); line.move(to: CGPoint(x: 0, y: mid)); line.addLine(to: CGPoint(x: size.width, y: mid))
            ctx.stroke(line, with: .color(.white.opacity(0.08)), lineWidth: 1)
            guard !peaks.isEmpty else { return }
            let step = max(1, peaks.count / max(1, Int(size.width)))
            var path = Path()
            var x = size.width - CGFloat(peaks.count) / CGFloat(step)
            var i = 0
            while i < peaks.count {
                let slice = peaks[i..<min(peaks.count, i + step)]
                let hi = slice.map { $0.max }.max() ?? 0, lo = slice.map { $0.min }.min() ?? 0
                path.move(to: CGPoint(x: x, y: mid - CGFloat(min(1, hi)) * mid))
                path.addLine(to: CGPoint(x: x, y: mid - CGFloat(max(-1, lo)) * mid))
                x += 1; i += step
            }
            ctx.stroke(path, with: .color(color), lineWidth: 1)
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.35)))
    }
}

// MARK: - History rows

struct SessionRow: View {
    let session: RecordingSession
    let expanded: Bool
    @ObservedObject var player: RecordingPlayer
    let deviceUID: String?
    var onToggle: () -> Void
    var onDelete: () -> Void
    @State private var overviews: [String: [Float]] = [:]

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Button(action: onToggle) { Image(systemName: expanded ? "chevron.down" : "chevron.right") }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(session.info.name).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textPrimary)
                        if session.info.recovered {
                            Text("RECOVERED").font(.system(size: 8, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.meterYellow)).foregroundColor(.black)
                                .help("This recording was interrupted and was repaired automatically.")
                        }
                    }
                    Text("\(session.info.tracks.count) track\(session.info.tracks.count == 1 ? "" : "s") · \(timeString(session.info.durationSeconds)) · \(ByteCountFormatter.string(fromByteCount: session.bytes, countStyle: .file)) · \(session.info.sampleRate / 1000) kHz / \(session.info.bitDepth)-bit")
                        .font(.system(size: 10)).foregroundColor(Theme.textSecondary)
                }
                Spacer()
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([session.folder]) }
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.help("Move to Trash")
            }
            if expanded {
                ForEach(session.info.tracks) { t in
                    let url = session.folder.appendingPathComponent(t.fileName)
                    HStack(spacing: 10) {
                        Button(action: { player.toggle(url: url, deviceUID: deviceUID) }) {
                            Image(systemName: player.playingURL == url ? "stop.fill" : "play.fill").frame(width: 22)
                        }.help("Play / stop this track")
                        Text(t.name).font(.system(size: 11)).foregroundColor(Theme.textPrimary).frame(width: 150, alignment: .leading).lineLimit(1)
                        Text(timeString(t.seconds)).font(Theme.value).foregroundColor(Theme.textSecondary).frame(width: 90, alignment: .leading)
                        ZStack(alignment: .leading) {
                            OverviewView(values: overviews[t.id] ?? []).frame(height: 30)
                            if player.playingURL == url {
                                GeometryReader { g in Rectangle().fill(Theme.accent).frame(width: 2).offset(x: g.size.width * player.progress) }
                            }
                        }
                        if t.droppedFrames > 0 {
                            Text("\(t.droppedFrames) dropped").font(.system(size: 9)).foregroundColor(Theme.meterOrange)
                        }
                    }
                    .onAppear {
                        guard overviews[t.id] == nil else { return }
                        DispatchQueue.global(qos: .utility).async {
                            let o = WaveformOverview.compute(url: url, buckets: 400)
                            DispatchQueue.main.async { overviews[t.id] = o }
                        }
                    }
                }
            }
        }
        .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Theme.well.opacity(0.5)))
    }
}

struct OverviewView: View {
    var values: [Float]
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(Theme.well))
            guard !values.isEmpty else { return }
            let mid = size.height / 2, w = size.width / CGFloat(values.count)
            var p = Path()
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * w + w / 2, h = CGFloat(min(1, v)) * mid
                p.move(to: CGPoint(x: x, y: mid - h)); p.addLine(to: CGPoint(x: x, y: mid + h))
            }
            ctx.stroke(p, with: .color(Theme.accent), lineWidth: max(1, w * 0.8))
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
    }
}
