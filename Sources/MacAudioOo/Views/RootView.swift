import SwiftUI

/// Which target the EQ card edits: the master bus (nil) or one application channel.
final class EQSelection: ObservableObject {
    static let shared = EQSelection()
    @Published var channelID: UUID? = nil
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var eqSelection = EQSelection.shared

    private var showsSidebar: Bool {
        switch settings.selectedTab { case .console, .eq, .recording: return true; default: return false }
    }

    var body: some View {
        VStack(spacing: 0) {
            if settings.selectedTab != .dj { NavBar(recorder: state.recorder) }   // the DJ page has its own header
            HStack(spacing: 0) {
                if showsSidebar { SidebarView() }
                Group {
                    switch settings.selectedTab {
                    case .settings: SettingsView()
                    case .console: MixerView()
                    case .eq: EQPageView()
                    case .classic: ClassicView()
                    case .recording: RecordingView(recorder: state.recorder)
                    case .dj: DJView(dj: state.dj)
                    case .library: LibraryView(library: state.library, dj: state.dj)
                    case .presets: PresetsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            .clipped()
        }
        .background(LinearGradient(colors: [Theme.bgTop, Theme.bg], startPoint: .top, endPoint: .bottom))
        .background(WindowConfigurator())
        .environmentObject(eqSelection)
        .preferredColorScheme(.dark)
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
            Circle().fill(healthColor).frame(width: 8, height: 8).shadow(color: healthColor.opacity(0.8), radius: 3)
            Text(state.engineStatusText).font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(Theme.textPrimary).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 12).frame(height: 28)
        .background(Capsule().fill(Theme.well))
        .overlay(Capsule().stroke(Theme.border))
        .help(state.engineStatusDetail)
    }
}

struct OutputPicker: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    private var label: String {
        if let uid = settings.outputDeviceUID, let d = state.devices.outputDevices.first(where: { $0.uid == uid }) { return d.name }
        if state.selectedOutputMissing { return "Disconnected device" }
        return "System Default"
    }

    private var items: [(id: String, title: String)] {
        var list: [(id: String, title: String)] = [("", "System Default")]
        list += state.devices.outputDevices.map { ($0.uid, $0.name) }
        return list
    }

    var body: some View {
        DropdownField(label: label, items: items, width: 190,
                      systemImage: state.selectedOutputMissing ? "exclamationmark.triangle.fill" : "speaker.wave.2.fill",
                      height: 30) { id in settings.outputDeviceUID = id.isEmpty ? nil : id }
            .help(state.selectedOutputMissing
                  ? "The chosen output device is disconnected. MacAudioOo falls back to the system default and will not change it."
                  : "Output device used by MacAudioOo. The system default device is never changed.")
    }
}

/// Section title used on the page cards.
struct CardTitle: View {
    var text: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(Theme.textPrimary)
            if let s = subtitle { Text(s).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(Theme.textSecondary) }
        }
    }
}

/// Small rounded read-out pill (dB values, formats).
struct ValuePill: View {
    var text: String
    var width: CGFloat? = nil
    var color: Color = Theme.textPrimary
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(color)
            .lineLimit(1).frame(width: width).padding(.horizontal, 8).frame(height: 22)
            .background(Capsule().fill(Theme.well))
            .overlay(Capsule().stroke(Theme.border))
    }
}
