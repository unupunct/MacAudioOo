import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("GENERAL") {
                    Picker("Theme", selection: $settings.theme) {
                        ForEach(ThemeChoice.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 260)
                    Picker("Default interface", selection: $settings.defaultTab) {
                        ForEach(AppTab.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }.frame(width: 260)
                    Toggle("Remember last selected interface", isOn: $settings.rememberLastTab)
                    Toggle("Start minimized", isOn: $settings.startMinimized)
                    Toggle("Menu bar integration", isOn: $settings.menuBarEnabled)
                    note("Start minimized, menu bar and launch at login are saved but not wired yet (Phase 7).")
                }
                section("AUDIO") {
                    Text("macOS " + OSVersion.current.description).font(Theme.value).foregroundColor(Theme.textPrimary)
                    ForEach(state.capabilities) { c in CapabilityRow(cap: c) }
                    if state.preferredBackend == nil {
                        note("⚠︎ No backend on this system can provide independent per-application volume. Install the optional virtual audio driver (Monterey) to enable mixing.")
                    }
                    if OSVersion.current < OSVersion(major: 14, minor: 2, patch: 0) { DriverStatusView() }
                    Divider().overlay(Theme.border)
                    Text("Output devices").font(Theme.label).foregroundColor(Theme.textSecondary)
                    ForEach(state.devices.outputDevices) { d in
                        HStack {
                            Text(d.name).foregroundColor(Theme.textPrimary)
                            if d.uid == state.devices.defaultOutputUID { tag("DEFAULT") }
                            Spacer()
                            Text("\(d.outputChannels) ch · \(Int(d.nominalSampleRate)) Hz · \(d.transport)")
                                .font(Theme.value).foregroundColor(Theme.textSecondary)
                        }.font(.system(size: 12))
                    }
                }
                section("RECORDING") {
                    HStack {
                        Text(settings.recordingDirectory).font(Theme.value)
                            .foregroundColor(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseDirectory() }
                    }
                    Text("Format: WAV · 48 kHz · 24-bit (fixed)").font(Theme.value).foregroundColor(Theme.textSecondary)
                }
                section("DJ") {
                    Toggle("Default to four-deck layout", isOn: $settings.djFourDecks)
                }
                section("ADVANCED") {
                    DiagnosticsView()
                    Divider().overlay(Theme.border)
                    Button("Reset all settings…") { confirmReset = true }
                    note("Diagnostics, logs and config import/export are planned.")
                }
            }.padding(20).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }
        .confirmationDialog("Reset all settings to defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { settings.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func chooseDirectory() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK, let url = p.url { settings.recordingDirectory = url.path }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.label).foregroundColor(Theme.accent)
            VStack(alignment: .leading, spacing: 8) { content() }
                .foregroundColor(Theme.textPrimary)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).panel()
        }
    }
    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundColor(Theme.textSecondary)
    }
    private func tag(_ s: String) -> some View {
        Text(s).font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.accent.opacity(0.25)))
            .foregroundColor(Theme.accent)
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
