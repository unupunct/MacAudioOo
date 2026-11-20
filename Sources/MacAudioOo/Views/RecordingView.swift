import SwiftUI
import AppKit

/// The RECORDING tab: transport, one lane per track (MIX + every mixer channel with REC ARM),
/// live waveforms drawn from the bytes actually being written, destination/disk-space, and the
/// history of recording sessions with playback.
struct RecordingView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var recorder: RecordingEngine
    @StateObject private var hub = MeterHub()
    @StateObject private var player = RecordingPlayer()
    @State private var sessionToDelete: RecordingSession?
    @State private var selectedSession: String?

    var body: some View {
        let engine = state.engine
        VStack(spacing: 10) {
            transport(engine)
            lanes(engine)
            history(engine)
        }
        .padding(12)
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

    // MARK: Transport

    private func transport(_ engine: AudioEngine) -> some View {
        let rec = recorder.state
        return VStack(spacing: 8) {
            HStack(spacing: 14) {
                Button(action: { rec == .idle ? recorder.start() : recorder.stop() }) {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.record).frame(width: 12, height: 12).opacity(rec == .recording ? 1 : 0.85)
                        Text(rec == .idle ? "RECORD" : "STOP").font(Theme.title)
                    }.frame(width: 110, height: 30)
                }
                .buttonStyle(.borderedProminent).tint(rec == .idle ? Theme.record.opacity(0.9) : Theme.panelRaised)
                .disabled(!engine.status.isRunning)
                .help(rec == .idle ? "Start recording the MIX and all armed channels" : "Stop and save the recording")

                Button(action: { rec == .paused ? recorder.resume() : recorder.pause() }) {
                    Image(systemName: rec == .paused ? "play.fill" : "pause.fill").frame(width: 30, height: 30)
                }
                .disabled(rec == .idle).help(rec == .paused ? "Resume" : "Pause (audio during the pause is not recorded)")

                Text(timeString(recorder.elapsed)).font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundColor(rec == .recording ? Theme.record : Theme.textPrimary).frame(width: 190, alignment: .leading)

                statusChip(rec)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("48 kHz / 24-bit WAV · stereo").font(Theme.value).foregroundColor(Theme.textPrimary)
                    Text(freeSpaceText).font(.system(size: 10)).foregroundColor(Theme.textSecondary)
                }
            }
            HStack(spacing: 8) {
                Text("DESTINATION").font(Theme.label).foregroundColor(Theme.textSecondary)
                Text(settings.recordingDirectory).font(Theme.value).foregroundColor(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                Button("Choose…") { chooseFolder() }.disabled(rec != .idle)
                Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: settings.recordingDirectory)) }
                Spacer()
            }
            if let e = recorder.lastError {
                Text(e).font(.system(size: 11)).foregroundColor(Theme.meterOrange).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let m = recorder.library.lastRecoveryMessage {
                Text(m).font(.system(size: 11)).foregroundColor(Theme.meterYellow).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelRaised))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    private func statusChip(_ s: RecordingEngine.State) -> some View {
        let (text, color): (String, Color) = {
            switch s { case .idle: return ("READY", Theme.textSecondary); case .recording: return ("RECORDING", Theme.record); case .paused: return ("PAUSED", Theme.meterYellow) }
        }()
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(Theme.label).foregroundColor(Theme.textPrimary).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(Theme.well)).overlay(Capsule().stroke(Theme.border))
    }

    private var freeSpaceText: String {
        guard let free = recorder.freeBytes else { return "Free disk space unknown" }
        var t = "Free: " + ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        if let s = recorder.remainingSeconds { t += " (≈ \(durationString(s)) for \(recorder.plannedTrackCount) track\(recorder.plannedTrackCount == 1 ? "" : "s"))" }
        return t
    }

    // MARK: Lanes

    private func lanes(_ engine: AudioEngine) -> some View {
        ScrollView(.vertical) {
            VStack(spacing: 6) {
                laneRow(title: "MIX", subtitle: "Stereo mix · after master processing", icon: nil,
                        armed: Binding(get: { recorder.recordMix }, set: { recorder.recordMix = $0 }),
                        meter: hub.masterL, live: recorder.liveTracks.first { $0.isMix }, recording: recorder.state != .idle)
                ForEach(engine.channels) { ch in
                    ChannelLane(channel: ch, meter: hub.model(for: ch), recorder: recorder)
                }
                if engine.channels.isEmpty {
                    Text("No application channels. Channels appear here once a capture backend is active; arm them to record separate stems.")
                        .font(.system(size: 11)).foregroundColor(Theme.textSecondary).padding(10)
                }
            }
        }
        .frame(minHeight: 150, maxHeight: 300)
    }

    private func laneRow(title: String, subtitle: String, icon: NSImage?, armed: Binding<Bool>, meter: MeterModel,
                         live: LiveTrack?, recording: Bool) -> some View {
        LaneRow(title: title, subtitle: subtitle, icon: icon, armed: armed, meter: meter, live: live, recording: recording)
    }

    // MARK: History

    private func history(_ engine: AudioEngine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SESSION HISTORY").font(Theme.label).foregroundColor(Theme.textSecondary)
                Text("\(recorder.library.sessions.count)").font(Theme.value).foregroundColor(Theme.textPrimary)
                Spacer()
                if let e = player.error { Text(e).font(.system(size: 11)).foregroundColor(Theme.meterOrange) }
            }
            if recorder.library.sessions.isEmpty {
                Text("No recordings in this folder yet.").font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
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
                }
            }
        }
        .padding(12).frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
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

// MARK: - Lanes

struct ChannelLane: View {
    @ObservedObject var channel: AudioChannel
    @ObservedObject var meter: MeterModel
    @ObservedObject var recorder: RecordingEngine
    var body: some View {
        LaneRow(title: channel.name, subtitle: channel.pid.map { "PID \($0) · stem after EQ/compressor, before fader" } ?? "stem after EQ/compressor, before fader",
                icon: channel.icon, armed: $channel.recArm, meter: meter,
                live: recorder.liveTracks.first { $0.id == channel.id.uuidString }, recording: recorder.state != .idle)
    }
}

struct LaneRow: View {
    var title: String
    var subtitle: String
    var icon: NSImage?
    @Binding var armed: Bool
    @ObservedObject var meter: MeterModel
    var live: LiveTrack?
    var recording: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = icon { Image(nsImage: icon).resizable().interpolation(.high) }
                else { Image(systemName: title == "MIX" ? "slider.horizontal.3" : "waveform").resizable().scaledToFit().padding(5).foregroundColor(Theme.accent) }
            }.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(Theme.textPrimary).lineLimit(1)
                Text(subtitle).font(.system(size: 9)).foregroundColor(Theme.textSecondary).lineLimit(1)
            }.frame(width: 190, alignment: .leading)
            ConsoleButton(title: "REC", isOn: $armed, onColor: Theme.record, width: 40,
                          help: recording ? "Arming is locked while recording" : "Arm this track for recording")
                .disabled(recording)
            HorizontalMeterView(model: meter, width: 90, height: 8)
            WaveformLiveView(peaks: live?.peaks ?? [], recording: recording && live != nil)
                .frame(height: 38)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(armed ? Theme.record.opacity(0.7) : Theme.border))
    }
}

/// Live waveform of the audio actually being written to the track's file (last ~20 s).
struct WaveformLiveView: View {
    var peaks: [WaveformPeak]
    var recording: Bool
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(Theme.well))
            let mid = size.height / 2
            var line = Path(); line.move(to: CGPoint(x: 0, y: mid)); line.addLine(to: CGPoint(x: size.width, y: mid))
            ctx.stroke(line, with: .color(.white.opacity(0.08)), lineWidth: 1)
            guard !peaks.isEmpty else { return }
            let step = max(1, peaks.count / Int(size.width))
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
            ctx.stroke(path, with: .color(recording ? Theme.record : Theme.accent), lineWidth: 1)
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
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
