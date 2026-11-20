import Foundation
import AppKit

struct RunningApp: Identifiable, Hashable {
    var id: pid_t { pid }
    let pid: pid_t
    let name: String
    let bundleID: String?
    let icon: NSImage?
    static func == (a: RunningApp, b: RunningApp) -> Bool { a.pid == b.pid }
    func hash(into h: inout Hasher) { h.combine(pid) }
}

/// Discovers user-facing applications and tracks launch/termination.
/// This lists candidates only; whether an app is actually producing audio is
/// determined by the capture backend (Core Audio process objects on macOS 14.2+).
final class AudioProcessManager: ObservableObject {
    @Published private(set) var apps: [RunningApp] = []
    /// Called on the main queue when an app terminates (used to tear down its channel).
    var onTerminate: ((pid_t) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.onTerminate?(app.processIdentifier)
            }
            self?.refresh()
        })
    }
    deinit { observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }

    func refresh() {
        let me = ProcessInfo.processInfo.processIdentifier
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated }
            .map { RunningApp(pid: $0.processIdentifier, name: $0.localizedName ?? "Unknown",
                              bundleID: $0.bundleIdentifier, icon: $0.icon) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
