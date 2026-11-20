import Foundation

/// Decides when the system output may be switched back from the MacAudioOo virtual device to the device the user
/// was using before. The driver device is silent when MacAudioOo is not running, so leaving it selected after the
/// app quits means no sound at all. Switching is OPT-IN (a setting) or an explicit button press: MacAudioOo never
/// changes the system output on its own initiative.
enum OutputRestorePolicy {
    /// The UID to switch to when the app quits, or nil if nothing should change.
    static func target(enabled: Bool, defaultIsDriver: Bool, previousUID: String?, availableUIDs: [String]) -> String? {
        guard enabled, defaultIsDriver, let p = previousUID, availableUIDs.contains(p) else { return nil }
        return p
    }

    /// Updates the remembered "previous real output" after the system default changes: only real devices are remembered,
    /// never the MacAudioOo driver device itself.
    static func remembered(current: String?, newDefaultUID: String?, driverUID: String) -> String? {
        guard let d = newDefaultUID, d != driverUID else { return current }
        return d
    }
}
