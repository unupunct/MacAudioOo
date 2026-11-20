import SwiftUI
import AppKit

/// Shows the real state of the optional Monterey virtual audio driver and explains the
/// steps the user must take. MacAudioOo never installs the driver or changes the system
/// output device by itself.
struct DriverStatusView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let installed = FileManager.default.fileExists(atPath: CapabilityDetector.driverPath)
        let loaded = state.devices.driverDeviceLoaded
        let isDefault = state.devices.systemDefaultIsDriver
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Theme.border)
            Text("VIRTUAL AUDIO DRIVER (macOS 12 – 14.1)").font(Theme.label).foregroundColor(Theme.textSecondary)
            row("Driver installed", installed)
            row("\"MacAudioOo Mixer\" device loaded by macOS", loaded)
            row("System output is set to \"MacAudioOo Mixer\"", isDefault)
            Text(backendLine).font(.system(size: 11)).foregroundColor(Theme.textSecondary)
            if !installed {
                Text("Install with:  sudo scripts/install-driver.sh   (asks before restarting audio). See Documentation/DRIVER.md.")
                    .font(Theme.value).foregroundColor(Theme.textSecondary)
            } else if loaded && !isDefault {
                Text("To mix applications, choose \"MacAudioOo Mixer\" as the system output in Sound settings. MacAudioOo will not change this for you. Applications that keep their own output device selection are not captured.")
                    .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
            }
            HStack {
                Button("Open Sound Settings") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.sound") { NSWorkspace.shared.open(u) }
                }
                Button("Re-check") { state.devices.refresh(); state.refreshBackends() }
            }
        }
    }

    private var backendLine: String {
        guard let b = state.driverBackend else { return "Backend: not running." }
        switch b.state {
        case .stopped: return "Backend: stopped."
        case .driverNotLoaded(let why): return "Backend: " + why
        case .running(let n): return "Backend: running, \(n) application client\(n == 1 ? "" : "s") connected."
        }
    }

    private func row(_ title: String, _ ok: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Theme.meterGreen : Theme.textSecondary).frame(width: 8, height: 8)
            Text(title).font(.system(size: 12))
            Spacer()
            Text(ok ? "Yes" : "No").font(Theme.value).foregroundColor(Theme.textSecondary)
        }
    }
}
