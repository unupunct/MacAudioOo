import SwiftUI

func dbString(_ db: Float) -> String { db <= -59.9 ? "-∞ dB" : String(format: "%+.1f dB", db) }

/// Live engine diagnostics plus generated test tones that exercise the real mixer
/// and output path (volume, mute, solo, balance, master, limiter).
struct DiagnosticsView: View {
    @EnvironmentObject var state: AppState
    @State private var toneCount = 0

    var body: some View {
        let engine = state.engine
        VStack(alignment: .leading, spacing: 10) {
            Text("AUDIO ENGINE DIAGNOSTICS").font(Theme.label).foregroundColor(Theme.textSecondary)
            TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                Text(statusLine(engine)).font(Theme.value).foregroundColor(Theme.textPrimary)
            }
            Text("Running applications discovered: \(state.processes.apps.count)")
                .font(.system(size: 11)).foregroundColor(Theme.textSecondary)

            HStack {
                Button("Add test tone channel") { addTone() }
                    .disabled(!engine.status.isRunning)
                Text("Generated sine tones play through the real mixer so you can verify volume, mute, solo and balance by ear.")
                    .font(.system(size: 11)).foregroundColor(Theme.textSecondary)
            }
            ForEach(engine.channels) { ch in ChannelDiagRow(channel: ch) { engine.removeChannel(ch) } }

            Divider().overlay(Theme.border)
            MasterDiagRow()
        }
    }

    private func statusLine(_ e: AudioEngine) -> String {
        switch e.status {
        case .running(let d, let r):
            return "\(d) · \(Int(r)) Hz · buffer \(e.bufferFrames) fr · latency ≈ \(String(format: "%.1f", e.latencyMs)) ms · callbacks \(e.callbackCount)"
        case .stopped: return "Engine stopped"
        case .failed(let m): return "ERROR: \(m)"
        }
    }

    private func addTone() {
        let freqs: [Float] = [440, 660, 880, 1100]
        let f = freqs[toneCount % freqs.count]
        toneCount += 1
        let src = ToneSource(frequency: f, amplitude: 0.25, sampleRate: Float(state.engine.sampleRate))
        state.engine.addChannel(name: "Test tone \(Int(f)) Hz", source: src)
    }
}

struct ChannelDiagRow: View {
    @ObservedObject var channel: AudioChannel
    var onRemove: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Text(channel.name).font(.system(size: 12)).frame(width: 130, alignment: .leading)
            Slider(value: Binding(get: { Double(channel.volumeDB) }, set: { channel.volumeDB = Float($0) }), in: -60...6)
                .frame(width: 140)
            Text(dbString(channel.volumeDB)).font(Theme.value).frame(width: 62, alignment: .trailing)
            Toggle("M", isOn: $channel.mute).toggleStyle(.button)
            Toggle("S", isOn: $channel.solo).toggleStyle(.button)
            Text("BAL").font(Theme.label).foregroundColor(Theme.textSecondary)
            Slider(value: Binding(get: { Double(channel.balance) }, set: { channel.balance = Float($0) }), in: -1...1)
                .frame(width: 70)
            TimelineView(.periodic(from: .now, by: 1.0 / 20)) { _ in
                MeterBar(db: channel.readMeter().peakDB)
            }
            Button(action: onRemove) { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
        }
    }
}

struct MasterDiagRow: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        let e = state.engine
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("MASTER").font(Theme.label).frame(width: 60, alignment: .leading)
                Toggle("MUTE", isOn: Binding(get: { e.masterMute }, set: { e.masterMute = $0 })).toggleStyle(.button)
                Toggle("DIM", isOn: Binding(get: { e.dim }, set: { e.dim = $0 })).toggleStyle(.button)
                Toggle("MONO", isOn: Binding(get: { e.mono }, set: { e.mono = $0 })).toggleStyle(.button)
                Text("LIMIT").font(Theme.label).foregroundColor(Theme.textSecondary)
                Slider(value: Binding(get: { Double(e.limiterThresholdDB) }, set: { e.limiterThresholdDB = Float($0) }), in: -24...0)
                    .frame(width: 100)
                Text(String(format: "%.1f dB", e.limiterThresholdDB)).font(Theme.value)
            }
            TimelineView(.periodic(from: .now, by: 1.0 / 20)) { _ in
                let m = e.masterMeter()
                HStack(spacing: 8) {
                    Text("L").font(Theme.label); MeterBar(db: m.peakL)
                    Text("R").font(Theme.label); MeterBar(db: m.peakR)
                    Text("GR " + String(format: "%.1f dB", m.grDB)).font(Theme.value).foregroundColor(Theme.textSecondary)
                }
            }
        }
    }
}

/// Simple horizontal level bar: green below -12 dB, yellow to -3 dB, orange above.
struct MeterBar: View {
    let db: Float
    var body: some View {
        let frac = CGFloat(max(0, min(1, (db + 60) / 60)))
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.well)
            GeometryReader { g in
                RoundedRectangle(cornerRadius: 2)
                    .fill(db > -3 ? Theme.meterOrange : (db > -12 ? Theme.meterYellow : Theme.meterGreen))
                    .frame(width: g.size.width * frac)
            }
        }
        .frame(width: 120, height: 8)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.border))
    }
}
