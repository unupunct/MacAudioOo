import Foundation
import AppKit
import Combine

struct DuckingConfig: Codable, Equatable {
    var enabled = false
    /// A trigger app is "active" when its pre-fader level is above this (dB RMS). This is audio-activity detection:
    /// a process merely existing, or an idle call window, never ducks anything.
    var triggerThresholdDB: Float = -45
    var reductionDB: Float = 12
    var attackMs: Float = 60
    var releaseMs: Float = 700
    /// Matched case-insensitively against the channel's name or bundle ID.
    var triggerApps: [String] = ["FaceTime", "zoom.us", "Zoom", "Microsoft Teams", "Discord", "Slack"]
    var excludedApps: [String] = []
    var manualDuck = false
    static let defaultTriggerApps = DuckingConfig().triggerApps
}

enum DuckingLogic {
    static func matches(_ list: [String], name: String, bundleID: String?) -> Bool {
        let n = name.lowercased(), b = (bundleID ?? "").lowercased()
        return list.contains { e in
            let k = e.trimmingCharacters(in: .whitespaces).lowercased()
            return !k.isEmpty && (n.contains(k) || b.contains(k))
        }
    }

    /// One smoothing step of the applied reduction (dB, >= 0) toward `target` with attack (reduction rising)
    /// or release (reduction falling) time constants.
    static func step(current: Float, target: Float, dt: Float, attackMs: Float, releaseMs: Float) -> Float {
        let tau = max(1, target > current ? attackMs : releaseMs) / 1000
        let c = current + (target - current) * (1 - expf(-dt / tau))
        return abs(c - target) < 0.01 ? target : c
    }
}

/// Lowers selected background applications while a communication application is actually producing audio,
/// plus a manual "duck now" switch. Runs a 30 Hz timer only while ducking is enabled (no idle polling).
final class DuckingController: ObservableObject {
    @Published var config: DuckingConfig { didSet { save(); updateTimer() } }
    @Published private(set) var reductionDB: Float = 0
    @Published private(set) var triggerActive = false

    private let engine: AudioEngine
    private let defaults: UserDefaults
    private var timer: Timer?
    private var last = Date()
    /// Overridable for tests.
    var levelProvider: (AudioChannel) -> Float = { $0.inputRMSdB() }
    var bundleIDProvider: (AudioChannel) -> String? = { ch in ch.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier } }

    init(engine: AudioEngine, defaults: UserDefaults = .standard) {
        self.engine = engine; self.defaults = defaults
        if let d = defaults.data(forKey: "duckingConfig"), let c = try? JSONDecoder().decode(DuckingConfig.self, from: d) { config = c }
        else { config = DuckingConfig() }
        updateTimer()
    }

    private func save() { if let d = try? JSONEncoder().encode(config) { defaults.set(d, forKey: "duckingConfig") } }

    private func updateTimer() {
        let need = config.enabled || config.manualDuck || reductionDB > 0
        if need, timer == nil {
            last = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                let now = Date(); let dt = Float(now.timeIntervalSince(self.last)); self.last = now
                self.tick(dt: dt)
            }
        } else if !need { timer?.invalidate(); timer = nil }
    }

    func isTrigger(_ ch: AudioChannel) -> Bool {
        DuckingLogic.matches(config.triggerApps, name: ch.name, bundleID: bundleIDProvider(ch))
    }
    func isExcluded(_ ch: AudioChannel) -> Bool {
        DuckingLogic.matches(config.excludedApps, name: ch.name, bundleID: bundleIDProvider(ch))
    }

    /// One control step. Public so tests can drive it with a synthetic clock.
    func tick(dt: Float) {
        var active = config.manualDuck
        if config.enabled {
            for ch in engine.channels where isTrigger(ch) && levelProvider(ch) > config.triggerThresholdDB { active = true; break }
        }
        triggerActive = active
        let target: Float = active ? config.reductionDB : 0
        let next = DuckingLogic.step(current: reductionDB, target: target, dt: dt, attackMs: config.attackMs, releaseMs: config.releaseMs)
        if next != reductionDB { reductionDB = next }
        let gain = reductionDB < 0.05 ? 1 : dbToLinear(-reductionDB)
        for ch in engine.channels {
            let ducked = !isTrigger(ch) && !isExcluded(ch)
            let g = ducked ? gain : 1
            if abs(ch.duckGain - g) > 1e-4 { ch.duckGain = g }
        }
        if !config.enabled && !config.manualDuck && reductionDB == 0 { updateTimer() }
    }
}
