import SwiftUI
import AppKit
import CoreGraphics
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var log = AppLog.shared
    @State private var confirmReset = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                general
                audio
                DuckingSettingsView(ducking: state.ducking)
                permissions
                recording
                dj
                advanced
            }.padding(20).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .confirmationDialog("Reset all settings to defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { settings.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Scenes, EQ presets and recordings are not affected.") }
    }

    // MARK: Sections

    private var general: some View {
        section("GENERAL") {
            Picker("Theme", selection: $settings.theme) { ForEach(ThemeChoice.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).frame(width: 260)
            Picker("Default interface", selection: $settings.defaultTab) { ForEach(AppTab.allCases) { Text($0.rawValue.capitalized).tag($0) } }.frame(width: 260)
            Toggle("Remember last selected interface", isOn: $settings.rememberLastTab)
            Toggle("Start minimized", isOn: $settings.startMinimized)
            Toggle("Menu bar integration", isOn: $settings.menuBarEnabled)
            Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            note("Launch at login adds a per-user LaunchAgent (~/Library/LaunchAgents). Switching it off removes it.")
            HStack {
                Text("Language"); Picker("", selection: $settings.language) { Text("English").tag("en") }.labelsHidden().frame(width: 140)
                Text("English is the only language available.").font(.system(size: 11)).foregroundColor(Theme.textSecondary)
            }
        }
    }

    private var audio: some View {
        section("AUDIO") {
            audioBackends
            audioOutput
            audioDevices
        }
    }

    private var audioBackends: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("macOS " + OSVersion.current.description).font(Theme.value).foregroundColor(Theme.textPrimary)
            ForEach(state.capabilities) { c in CapabilityRow(cap: c) }
            if state.preferredBackend == nil {
                note("⚠︎ No backend on this system can provide independent per-application volume. On macOS 12 – 14.1 install the optional virtual audio driver.")
            }
            if OSVersion.current < OSVersion(major: 14, minor: 2, patch: 0) { DriverStatusView() }
            if let t = state.tapBackend { note(tapStateText(t.state)) }
        }
    }

    private func tapStateText(_ s: CoreAudioTapBackend.State) -> String {
        switch s {
        case .stopped: return "Process-tap backend: stopped."
        case .running(let n): return "Process-tap backend: running, \(n) application\(n == 1 ? "" : "s") tapped."
        case .failed(let m): return "Process-tap backend problem: \(m)"
        case .unavailable(let m): return "Process-tap backend unavailable: \(m)"
        }
    }

    private var audioOutput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Theme.border)
            HStack { Text("Output device"); OutputPicker(); Spacer() }
            HStack {
                Text("Buffer size")
                Picker("", selection: $settings.bufferFrames) {
                    Text("Device default").tag(0)
                    ForEach([64, 128, 256, 512, 1024, 2048], id: \.self) { Text("\($0) frames").tag($0) }
                }.labelsHidden().frame(width: 150)
                Text("Smaller = lower latency, higher risk of glitches. Applied to the output device and clamped to its supported range.")
                    .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(engineLine(state.engine)).font(Theme.value).foregroundColor(Theme.textPrimary)
            }
            note("Sample rate follows the output device; recordings are always converted to 48 kHz / 24-bit WAV.")
        }
    }

    private var audioDevices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Theme.border)
            Text("Output devices").font(Theme.label).foregroundColor(Theme.textSecondary)
            ForEach(state.devices.outputDevices) { d in
                HStack {
                    Text(d.name).foregroundColor(Theme.textPrimary)
                    if d.uid == state.devices.defaultOutputUID { tag("DEFAULT") }
                    Spacer()
                    Text("\(d.outputChannels) ch · \(Int(d.nominalSampleRate)) Hz · \(d.transport)").font(Theme.value).foregroundColor(Theme.textSecondary)
                }.font(.system(size: 12))
            }
        }
    }

    private func engineLine(_ e: AudioEngine) -> String {
        switch e.status {
        case .running(let d, let r):
            return "RUNNING · \(d) · \(Int(r)) Hz · buffer \(e.bufferFrames) fr · latency ≈ \(String(format: "%.1f", e.latencyMs)) ms · callbacks \(e.callbackCount) · render load \(Int(e.cpuLoad * 100)) % (worst \(Int(e.worstBlockLoad * 100)) %)"
        case .stopped: return "STOPPED"
        case .failed(let m): return "ERROR: \(m)"
        }
    }

    private var permissions: some View {
        section("PERMISSIONS") {
            permRow("System audio capture",
                    OSVersion.current >= OSVersion(major: 14, minor: 2, patch: 0)
                    ? "macOS asks for permission the first time MacAudioOo captures an application's audio (Core Audio process taps)."
                    : "Not required on this macOS version. Application audio reaches MacAudioOo through the optional virtual audio driver instead.",
                    status: nil)
            permRow("Microphone",
                    "Not used. MacAudioOo does not record from any input device.", status: nil)
            let screen = CGPreflightScreenCaptureAccess()
            permRow("Screen recording",
                    OSVersion.current >= OSVersion(major: 13, minor: 0, patch: 0) && OSVersion.current < OSVersion(major: 14, minor: 2, patch: 0)
                    ? "Needed only by the ScreenCaptureKit capture-only fallback (macOS 13 – 14.1), which can record an application's audio but cannot change its volume. Not used yet."
                    : "Not required: MacAudioOo never captures the screen.", status: screen)
            HStack {
                Button("Open Privacy settings") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") { NSWorkspace.shared.open(u) }
                }
                Spacer()
            }
        }
    }

    private var recording: some View {
        section("RECORDING") {
            HStack {
                Text(settings.recordingDirectory).font(Theme.value).foregroundColor(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseDirectory { settings.recordingDirectory = $0; state.recordingLibrary.setRoot(URL(fileURLWithPath: $0)) } }
            }
            HStack(spacing: 16) {
                fixed("File format", "WAV"); fixed("Sample rate", "48 kHz"); fixed("Bit depth", "24-bit")
            }
            note("These three values are fixed: every recording is a 24-bit, 48 kHz stereo WAV. Stems are dry (after EQ and compressor, before the fader); the mix includes master processing.")
        }
    }

    private var dj: some View {
        section("DJ") {
            HStack {
                Text("Default deck configuration")
                Picker("", selection: $settings.djFourDecks) { Text("2 decks").tag(false); Text("4 decks").tag(true) }
                    .pickerStyle(.segmented).frame(width: 160).labelsHidden()
            }
            HStack {
                Text("Tempo fader range")
                Picker("", selection: $settings.djTempoRange) { Text("±8%").tag(8.0); Text("±16%").tag(16.0); Text("±50%").tag(50.0) }
                    .pickerStyle(.segmented).frame(width: 190).labelsHidden()
            }
            HStack(spacing: 14) {
                Text("BPM detection range")
                Stepper("min \(Int(settings.bpmMin))", value: $settings.bpmMin, in: 40...150, step: 5)
                Stepper("max \(Int(settings.bpmMax))", value: $settings.bpmMax, in: 100...240, step: 5)
            }
            note("Detection picks the most likely tempo inside this range; narrow it if a track is read at half or double tempo.")
            HStack {
                Text("Audio file library folder")
                Text(settings.libraryFolder ?? "not set").font(Theme.value).foregroundColor(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseDirectory { settings.libraryFolder = $0 } }
                Button("Scan now") { if let f = settings.libraryFolder { state.library.importURLs([URL(fileURLWithPath: f)]) } }
                    .disabled(settings.libraryFolder == nil)
            }
        }
    }

    private var advanced: some View {
        section("ADVANCED") {
            DiagnosticsView()
            Divider().overlay(Theme.border)
            HStack {
                Text("AUDIO ENGINE LOG").font(Theme.label).foregroundColor(Theme.textSecondary)
                Spacer()
                Button("Reveal file") { NSWorkspace.shared.activateFileViewerSelecting([log.url]) }
                Button("Copy diagnostics") { copyDiagnostics() }
                Button("Clear") { log.clear() }
            }
            ScrollView {
                Text(log.lines.suffix(80).joined(separator: "\n")).font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textPrimary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(height: 110).padding(6).background(RoundedRectangle(cornerRadius: 4).fill(Theme.well))
            Divider().overlay(Theme.border)
            HStack {
                Button("Export configuration…") { exportConfig() }
                Button("Import configuration…") { importConfig() }
                Spacer()
                Button("Reset all settings…") { confirmReset = true }
            }
            if let m = message { Text(m).font(.system(size: 11)).foregroundColor(Theme.meterYellow) }
        }
    }

    // MARK: Actions

    private func chooseDirectory(_ done: (String) -> Void) {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { done(u.path) }
    }

    private func copyDiagnostics() {
        let e = state.engine
        var t = "MacAudioOo diagnostics\nmacOS \(OSVersion.current.description) (\(ProcessInfo.processInfo.machineArchitecture))\n"
        t += "Engine: \(engineLine(e))\n"
        for c in state.capabilities { t += "Backend \(c.kind.rawValue): usable=\(c.usable) capture=\(c.perAppCapture.rawValue) volume=\(c.independentVolume.rawValue)\n" }
        t += "Driver device loaded: \(state.devices.driverDeviceLoaded)\nChannels: \(e.channels.count)\n"
        t += "Output devices: " + state.devices.outputDevices.map { "\($0.name) [\($0.transport), \(Int($0.nominalSampleRate)) Hz]" }.joined(separator: "; ") + "\n\nLog (last 40 lines):\n"
        t += log.lines.suffix(40).joined(separator: "\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
        message = "Diagnostics copied to the clipboard."
    }

    private func exportConfig() {
        let p = NSSavePanel(); p.nameFieldStringValue = "MacAudioOo Configuration.json"; p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let data = try ConfigBackup.export(settings: settings, scenes: state.scenes.scenes, ducking: state.ducking.config)
            try data.write(to: url, options: .atomic)
            message = "Configuration exported to \(url.lastPathComponent)."
        } catch { message = "Export failed: \(error.localizedDescription)" }
    }

    private func importConfig() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]; p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let imported = try ConfigBackup.importData(try Data(contentsOf: url), into: settings)
            state.scenes.replaceAll(imported.scenes)
            if let d = imported.ducking { state.ducking.config = d }
            for (n, g) in imported.userEQPresets { EQPresets.save(name: n, gains: g) }
            message = "Configuration imported (\(imported.scenes.count) scenes)."
        } catch { message = "Import failed: \(error.localizedDescription)" }
    }

    // MARK: Helpers

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.label).foregroundColor(Theme.accent)
            VStack(alignment: .leading, spacing: 8) { content() }
                .foregroundColor(Theme.textPrimary)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).panel()
        }
    }
    private func note(_ s: String) -> some View { Text(s).font(.system(size: 11)).foregroundColor(Theme.textSecondary) }
    private func tag(_ s: String) -> some View {
        Text(s).font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.accent.opacity(0.25))).foregroundColor(Theme.accent)
    }
    private func fixed(_ t: String, _ v: String) -> some View {
        HStack(spacing: 6) { Text(t).foregroundColor(Theme.textSecondary); Text(v).font(Theme.value) }.font(.system(size: 12))
    }
    private func permRow(_ title: String, _ text: String, status: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let s = status { tag(s ? "GRANTED" : "NOT GRANTED") }
            }
            note(text)
        }
    }
}

extension ProcessInfo {
    /// "arm64" or "x86_64".
    var machineArchitecture: String {
        var u = utsname(); uname(&u)
        let chars = Mirror(reflecting: u.machine).children.compactMap { $0.value as? Int8 }.prefix { $0 != 0 }
        return String(chars.map { Character(UnicodeScalar(UInt8(bitPattern: $0))) })
    }
}

struct DuckingSettingsView: View {
    @ObservedObject var ducking: DuckingController
    @State private var triggers = ""
    @State private var excluded = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DUCKING").font(Theme.label).foregroundColor(Theme.accent)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Automatic ducking: lower background applications while a communication application is speaking",
                       isOn: Binding(get: { ducking.config.enabled }, set: { ducking.config.enabled = $0 }))
                Toggle("Manual duck (always lower background applications)",
                       isOn: Binding(get: { ducking.config.manualDuck }, set: { ducking.config.manualDuck = $0 }))
                slider("Trigger threshold", Binding(get: { ducking.config.triggerThresholdDB }, set: { ducking.config.triggerThresholdDB = $0 }), -70...(-15), "%.0f dB")
                slider("Reduction", Binding(get: { ducking.config.reductionDB }, set: { ducking.config.reductionDB = $0 }), 3...30, "%.0f dB")
                slider("Attack", Binding(get: { ducking.config.attackMs }, set: { ducking.config.attackMs = $0 }), 5...500, "%.0f ms")
                slider("Release", Binding(get: { ducking.config.releaseMs }, set: { ducking.config.releaseMs = $0 }), 50...3000, "%.0f ms")
                HStack(alignment: .top) {
                    Text("Trigger apps").frame(width: 130, alignment: .leading)
                    TextField("FaceTime, Zoom, Teams…", text: $triggers, onCommit: { ducking.config.triggerApps = split(triggers) }).textFieldStyle(.roundedBorder)
                    Button("Defaults") { ducking.config.triggerApps = DuckingConfig.defaultTriggerApps; triggers = ducking.config.triggerApps.joined(separator: ", ") }
                }
                HStack(alignment: .top) {
                    Text("Excluded apps").frame(width: 130, alignment: .leading)
                    TextField("never lowered", text: $excluded, onCommit: { ducking.config.excludedApps = split(excluded) }).textFieldStyle(.roundedBorder)
                }
                Text(ducking.reductionDB > 0.05 ? String(format: "Ducking now: -%.1f dB", ducking.reductionDB) : "Not ducking.")
                    .font(Theme.value).foregroundColor(ducking.reductionDB > 0.05 ? Theme.meterYellow : Theme.textSecondary)
                Text("Detection is level-based: a trigger app counts as speaking only while its own audio is above the threshold. Names are matched against the channel name or bundle ID. It acts on channels the Console can see, so it needs a capture backend.")
                    .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
            }
            .foregroundColor(Theme.textPrimary).padding(12).frame(maxWidth: .infinity, alignment: .leading).panel()
        }
        .onAppear { triggers = ducking.config.triggerApps.joined(separator: ", "); excluded = ducking.config.excludedApps.joined(separator: ", ") }
    }

    private func split(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func slider(_ title: String, _ v: Binding<Float>, _ r: ClosedRange<Float>, _ f: String) -> some View {
        HStack {
            Text(title).frame(width: 130, alignment: .leading)
            Slider(value: v, in: r).frame(width: 220)
            Text(String(format: f, v.wrappedValue)).font(Theme.value).frame(width: 70, alignment: .trailing)
        }
    }
}

struct CapabilityRow: View {
    let cap: BackendCapability
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Circle().fill(cap.usable ? Theme.meterGreen : Theme.textSecondary).frame(width: 8, height: 8)
                Text(cap.kind.rawValue).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Per-app capture: \(cap.perAppCapture.rawValue)  ·  Independent volume: \(cap.independentVolume.rawValue)")
                    .font(.system(size: 10)).foregroundColor(Theme.textSecondary)
            }
            Text(cap.note).font(.system(size: 11)).foregroundColor(Theme.textSecondary)
        }
    }
}
