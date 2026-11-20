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
                case .console: ConsoleView()
                case .classic: ClassicView()
                case .recording: RecordingView(recorder: state.recorder)
                case .dj: DJView(dj: state.dj)
                case .library: LibraryView(library: state.library, dj: state.dj)
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
                Text("MacAudioOo").font(Theme.title).foregroundColor(Theme.textPrimary).lineLimit(1).fixedSize()
            }
            HStack(spacing: 2) {
                ForEach(AppTab.allCases) { tab in
                    Button(action: { settings.selectedTab = tab }) {
                        Text(tab.rawValue).font(Theme.label).lineLimit(1).fixedSize()
                            .padding(.horizontal, 10).padding(.vertical, 6)
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
                Text("MASTER").font(Theme.label).foregroundColor(Theme.textSecondary).lineLimit(1).fixedSize()
                Slider(value: Binding(get: { Double(state.engine.masterVolumeDB) },
                                      set: { state.engine.masterVolumeDB = Float($0) }), in: -60...6)
                    .frame(width: 80)
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
    /// Green = running and keeping up, yellow = strained (render blocks used > 80 % of their time), orange = overloaded or not running.
    private var healthColor: Color {
        guard state.engine.status.isRunning else { return Theme.meterOrange }
        switch state.engine.health { case .good, .idle: return Theme.meterGreen; case .strained: return Theme.meterYellow; case .overloaded: return Theme.meterOrange }
    }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(healthColor).frame(width: 8, height: 8)
            Text(state.engineStatusText).font(Theme.label).foregroundColor(Theme.textPrimary).lineLimit(1).fixedSize()
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
            .labelsHidden().frame(width: 150)
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
