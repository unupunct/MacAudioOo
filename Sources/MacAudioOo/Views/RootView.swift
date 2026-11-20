import SwiftUI

struct RootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider().overlay(Theme.border)
            Group {
                switch settings.selectedTab {
                case .settings: SettingsView()
                case .console: NotImplementedView(tab: "CONSOLE", phase: "Phase 3",
                    detail: "Channel strips, meters, EQ and compressor need the Phase 2 capture engine first.")
                case .classic: NotImplementedView(tab: "CLASSIC", phase: "Phase 4",
                    detail: "The simplified mixer shares the Console engine and is built after it.")
                case .recording: NotImplementedView(tab: "RECORDING", phase: "Phase 5",
                    detail: "Recording will write real captured audio to 48 kHz / 24-bit WAV files.")
                case .dj: NotImplementedView(tab: "DJ", phase: "Phase 6",
                    detail: "Decks, waveforms, BPM analysis and the crossfader are planned for Phase 6.")
                case .library: NotImplementedView(tab: "LIBRARY", phase: "Phase 6",
                    detail: "The media library is built alongside the DJ decks.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
    }
}

struct TopBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 20)).foregroundColor(Theme.accent)
                Text("MacAudioOo").font(Theme.title).foregroundColor(Theme.textPrimary)
            }
            HStack(spacing: 2) {
                ForEach(AppTab.allCases) { tab in
                    Button(action: { settings.selectedTab = tab }) {
                        Text(tab.rawValue).font(Theme.label)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .foregroundColor(settings.selectedTab == tab ? .black : Theme.textSecondary)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(settings.selectedTab == tab ? Theme.accent : Color.clear))
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            EngineStatusPill()
            OutputPicker()
            HStack(spacing: 6) {
                Text("MASTER").font(Theme.label).foregroundColor(Theme.textSecondary)
                Slider(value: Binding(get: { Double(state.engine.masterVolumeDB) },
                                      set: { state.engine.masterVolumeDB = Float($0) }), in: -60...6)
                    .frame(width: 110)
                Text(dbString(state.engine.masterVolumeDB)).font(Theme.value)
                    .foregroundColor(Theme.textPrimary).frame(width: 58, alignment: .trailing)
            }
            .help("Master output volume (-∞ to +6 dB). Smoothed in the real-time mixer.")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.panel)
    }
}

struct EngineStatusPill: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(state.engine.status.isRunning ? Theme.meterGreen : Theme.meterOrange).frame(width: 8, height: 8)
            Text(state.engineStatusText).font(Theme.label).foregroundColor(Theme.textPrimary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Theme.well))
        .overlay(Capsule().stroke(Theme.border))
        .help(state.engineStatusDetail)
    }
}

struct OutputPicker: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.selectedOutputMissing ? "exclamationmark.triangle.fill" : "speaker.wave.2.fill")
                .foregroundColor(state.selectedOutputMissing ? Theme.meterYellow : Theme.textSecondary)
            Picker("", selection: Binding(
                get: { settings.outputDeviceUID ?? "" },
                set: { settings.outputDeviceUID = $0.isEmpty ? nil : $0 })) {
                Text("System Default").tag("")
                ForEach(state.devices.outputDevices) { d in Text(d.name).tag(d.uid) }
                if state.selectedOutputMissing, let uid = settings.outputDeviceUID {
                    Text("Disconnected device").tag(uid)
                }
            }
            .labelsHidden().frame(width: 190)
        }
        .help(state.selectedOutputMissing
              ? "The chosen output device is disconnected. MacAudioOo falls back to the system default and will not change it."
              : "Output device used by MacAudioOo. The system default device is never changed.")
    }
}

struct NotImplementedView: View {
    let tab: String, phase: String, detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "hammer").font(.system(size: 30)).foregroundColor(Theme.textSecondary)
            Text("\(tab) is not implemented yet").font(Theme.title).foregroundColor(Theme.textPrimary)
            Text("Planned for \(phase)").font(Theme.label).foregroundColor(Theme.accent)
            Text(detail).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
    }
}
