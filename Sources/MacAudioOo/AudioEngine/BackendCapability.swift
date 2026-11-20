import Foundation

/// The audio capture/routing strategies MacAudioOo can use. Which one is
/// usable depends on the running macOS version (and, for the driver, on
/// whether the user installed it).
enum BackendKind: String, CaseIterable, Identifiable {
    case coreAudioTap = "Core Audio Process Taps"
    case screenCaptureKit = "ScreenCaptureKit"
    case virtualDriver = "Virtual Audio Driver"
    var id: String { rawValue }
}

enum FeatureSupport: String {
    case full = "Supported"
    case captureOnly = "Capture only"
    case unavailable = "Unavailable"
}

struct BackendCapability: Identifiable, Equatable {
    var kind: BackendKind
    /// True when the OS (and installed components) allow this backend to run.
    var usable: Bool
    var perAppCapture: FeatureSupport
    var independentVolume: FeatureSupport
    /// Human-readable, honest explanation shown in the UI.
    var note: String
    var id: String { kind.id }
}

struct OSVersion: Comparable, Equatable, CustomStringConvertible {
    var major: Int, minor: Int, patch: Int
    static var current: OSVersion {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return OSVersion(major: v.majorVersion, minor: v.minorVersion, patch: v.patchVersion)
    }
    static func < (a: OSVersion, b: OSVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
    var description: String { "\(major).\(minor).\(patch)" }
}

enum CapabilityDetector {
    static let driverPath = "/Library/Audio/Plug-Ins/HAL/MacAudioOo.driver"

    /// Pure function of OS version + driver presence so it can be unit tested.
    static func detect(os: OSVersion, driverInstalled: Bool) -> [BackendCapability] {
        let tapOK = os >= OSVersion(major: 14, minor: 2, patch: 0)
        let sckOK = os >= OSVersion(major: 13, minor: 0, patch: 0)
        let driverApplicable = os.major < 14 || (os.major == 14 && os.minor < 2)

        let tap = BackendCapability(
            kind: .coreAudioTap, usable: tapOK,
            perAppCapture: tapOK ? .full : .unavailable,
            independentVolume: tapOK ? .full : .unavailable,
            note: tapOK
                ? "Per-process taps with muted original output allow real independent volume and processing."
                : "Requires macOS 14.2 or newer (running \(os)).")
        let sck = BackendCapability(
            kind: .screenCaptureKit, usable: sckOK,
            perAppCapture: sckOK ? .captureOnly : .unavailable,
            independentVolume: .unavailable,
            note: sckOK
                ? "Can capture an application's audio (for recording/metering) but cannot silence the original output, so it cannot provide independent volume control."
                : "Requires macOS 13 or newer (running \(os)).")
        let drvUsable = driverInstalled && driverApplicable
        let drv = BackendCapability(
            kind: .virtualDriver, usable: drvUsable,
            perAppCapture: .unavailable,
            independentVolume: drvUsable ? .full : .unavailable,
            note: !driverApplicable
                ? "Not needed on this macOS version; native process taps are used."
                : driverInstalled
                    ? "Driver installed. Applications must be routed to the MacAudioOo virtual device to be mixed."
                    : "Optional driver is not installed. Without it, Monterey cannot provide per-application volume.")
        return [tap, sck, drv]
    }

    static func detectCurrent() -> [BackendCapability] {
        detect(os: .current, driverInstalled: FileManager.default.fileExists(atPath: driverPath))
    }

    /// Preferred backend for per-app mixing, or nil if none can do it.
    static func preferred(from caps: [BackendCapability]) -> BackendCapability? {
        caps.first { $0.usable && $0.independentVolume == .full }
    }
}
