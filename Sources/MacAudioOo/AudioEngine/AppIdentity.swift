import Foundation
import AppKit
import Darwin

/// Which user-facing application a (possibly helper) audio process belongs to.
struct AppIdentity: Equatable {
    /// Grouping key: all processes with the same key share one mixer channel.
    var key: String
    var name: String
    var bundleID: String?
    /// PID of the main application (used to clean up the channel when the app quits), if known.
    var mainPID: pid_t?
    var icon: NSImage? = nil

    static func == (a: AppIdentity, b: AppIdentity) -> Bool { a.key == b.key && a.name == b.name && a.bundleID == b.bundleID && a.mainPID == b.mainPID }
}

/// Maps an audio-producing process to its application. Browsers and Electron apps play sound from helper processes
/// (e.g. "Google Chrome Helper", "Discord Helper (Renderer)", WebKit GPU service) that would otherwise show up as odd
/// bundle IDs or "Process 1234", one channel each. Resolution order:
///   1. the process is itself a regular application;
///   2. an ancestor process is (parent chain walk, e.g. Chrome helper -> Chrome);
///   3. the bundle ID names a helper ("<app>.helper...") of a running regular application;
///   4. known service families (WebKit services -> Safari);
///   5. a readable fallback from the bundle ID, else "Process <pid>".
enum AppIdentityResolver {
    struct Env {
        var parent: (pid_t) -> pid_t?
        var regularApp: (pid_t) -> (name: String, bundleID: String?)?
        var runningApp: (String) -> (name: String, bundleID: String?, pid: pid_t)?
        var icon: (pid_t?) -> NSImage? = { _ in nil }
    }

    /// Bundle-ID prefixes of system service families and the application they are attributed to when it is running.
    static let serviceFamilies: [(prefix: String, app: String)] = [
        ("com.apple.WebKit.", "com.apple.Safari"),
        ("com.apple.Safari.", "com.apple.Safari"),
    ]

    static func resolve(pid: pid_t, bundleHint: String?, env: Env = .system) -> AppIdentity {
        func identity(name: String, bundleID: String?, mainPID: pid_t?) -> AppIdentity {
            AppIdentity(key: bundleID ?? "pid:\(mainPID ?? pid)", name: name, bundleID: bundleID, mainPID: mainPID, icon: env.icon(mainPID))
        }
        // 1. the process itself
        if let app = env.regularApp(pid) { return identity(name: app.name, bundleID: app.bundleID, mainPID: pid) }
        // 2. ancestors (bounded: a parent cycle can never loop forever)
        var cur = pid
        for _ in 0..<8 {
            guard let p = env.parent(cur), p > 1, p != cur else { break }
            if let app = env.regularApp(p) { return identity(name: app.name, bundleID: app.bundleID, mainPID: p) }
            cur = p
        }
        if let hint = bundleHint, !hint.isEmpty {
            // 3. "<app bundle id>.helper[.something]"
            if let main = mainBundleID(fromHelper: hint), let app = env.runningApp(main) {
                return identity(name: app.name, bundleID: app.bundleID ?? main, mainPID: app.pid)
            }
            // 4. service families
            for fam in serviceFamilies where hint.hasPrefix(fam.prefix) {
                if let app = env.runningApp(fam.app) { return identity(name: app.name, bundleID: app.bundleID ?? fam.app, mainPID: app.pid) }
            }
            // 5. readable fallback; helpers of an app that is not running are still grouped under the main bundle ID
            let base = mainBundleID(fromHelper: hint) ?? hint
            return AppIdentity(key: base, name: prettyName(base), bundleID: base, mainPID: nil, icon: nil)
        }
        return AppIdentity(key: "pid:\(pid)", name: "Process \(pid)", bundleID: nil, mainPID: nil, icon: nil)
    }

    /// "com.hnc.Discord.helper.Renderer" -> "com.hnc.Discord"; "com.google.Chrome.helper" -> "com.google.Chrome"; otherwise nil.
    static func mainBundleID(fromHelper id: String) -> String? {
        let parts = id.split(separator: ".").map(String.init)
        guard let i = parts.firstIndex(where: { $0.lowercased().hasPrefix("helper") }), i >= 2 else { return nil }
        return parts[..<i].joined(separator: ".")
    }

    /// "com.apple.WebKit.GPU" -> "WebKit GPU" (last two components when they look like a product name, else the last one).
    static func prettyName(_ bundleID: String) -> String {
        let parts = bundleID.split(separator: ".").map(String.init)
        guard let last = parts.last else { return bundleID }
        if parts.count >= 3, ["apple", "microsoft", "google"].contains(parts[1].lowercased()) { return parts.suffix(2).joined(separator: " ") }
        return last
    }
}

extension AppIdentityResolver.Env {
    /// Real system lookups: NSRunningApplication and the BSD process table (sysctl KERN_PROC_PID).
    static let system = AppIdentityResolver.Env(
        parent: { pid in
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
            let ppid = info.kp_eproc.e_ppid
            return ppid > 1 ? ppid : nil
        },
        regularApp: { pid in
            guard let a = NSRunningApplication(processIdentifier: pid), a.activationPolicy == .regular else { return nil }
            return (a.localizedName ?? a.bundleIdentifier ?? "Application", a.bundleIdentifier)
        },
        runningApp: { bid in
            NSRunningApplication.runningApplications(withBundleIdentifier: bid).first { $0.activationPolicy == .regular }
                .map { ($0.localizedName ?? bid, $0.bundleIdentifier, $0.processIdentifier) }
        },
        icon: { pid in pid.flatMap { NSRunningApplication(processIdentifier: $0)?.icon } })
}
