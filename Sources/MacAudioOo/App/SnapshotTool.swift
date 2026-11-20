import AppKit
import SwiftUI

/// Developer/documentation aid: renders MacAudioOo's own main window to a PNG and quits.
/// Only the app's window is captured (never the screen).
///   MacAudioOo --snapshot out.png [--tab console|classic|recording|dj|library|settings] [--demo-channels]
/// `--demo-channels` adds clearly-labelled generated test tones so the console has content.
enum SnapshotTool {
    static func runIfRequested(state: AppState) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        let previousTab = state.settings.selectedTab
        if let t = args.firstIndex(of: "--tab"), t + 1 < args.count, let tab = AppTab(rawValue: args[t + 1].uppercased()) {
            state.settings.selectedTab = tab
        }
        if args.contains("--demo-channels") { addDemoChannels(state) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            defer {
                state.settings.selectedTab = previousTab
                NSApp.terminate(nil)
            }
            guard let view = NSApp.windows.first(where: { $0.contentView != nil })?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    private static func addDemoChannels(_ state: AppState) {
        let engine = state.engine
        let rate = Float(max(engine.sampleRate, 44100))
        let specs: [(Float, Float, Float)] = [(220, -6, -0.3), (330, -14, 0.0), (440, -3, 0.4), (660, -22, 0.0)]
        for (f, vol, bal) in specs {
            let src = ToneSource(frequency: f, amplitude: 0.25, sampleRate: rate)
            if let ch = engine.addChannel(name: "Test tone \(Int(f)) Hz", source: src) {
                ch.volumeDB = vol; ch.balance = bal
            }
        }
        if let c = engine.channels.first {
            var g = c.eqGains; g[10] = 3; g[12] = -2; c.eqGains = g
            c.comp.enabled = 1; c.reverbSend = 0.35
        }
        if engine.channels.count > 2 { engine.channels[2].solo = false; engine.channels[2].mute = true }
    }
}
