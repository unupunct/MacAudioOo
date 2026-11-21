import SwiftUI

/// The Mixer page: optional EQ card on top, then one strip per application channel and a highlighted MASTER strip.
struct MixerView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var eqSelection: EQSelection
    @StateObject private var hub = MeterHub()
    @State private var showEQ = true
    @State private var showGroups = false
    @State private var spill: Int? = nil
    @State private var toneCount = 0

    var body: some View {
        let engine = state.engine
        VStack(spacing: 10) {
            toolbar(engine)
            if showGroups { GroupBarView(engine: engine, spill: $spill).frame(maxWidth: .infinity, alignment: .leading) }
            if showEQ { EQTargetCard(plotHeight: 120, onHide: { showEQ = false }) }
            else {
                HStack { Spacer(); PlainButton(title: "Show EQ", width: 92, height: 28) { showEQ = true } }
            }
            GeometryReader { geo in
                let fh = max(110, min(380, geo.size.height - 172))
                HStack(alignment: .top, spacing: 12) {
                    if engine.channels.isEmpty { emptyState } else { strips(engine, faderHeight: fh) }
                    MasterStrip(engine: engine, hub: hub, selected: eqSelection.channelID == nil,
                                faderHeight: fh) { eqSelection.channelID = nil }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .onAppear { hub.start(engine: engine) }
        .onDisappear { hub.stop() }
    }

    private func toolbar(_ engine: AudioEngine) -> some View {
        HStack(spacing: 10) {
            Text("\(engine.channels.count) channel" + (engine.channels.count == 1 ? "" : "s"))
                .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(Theme.textSecondary).fixedSize()
            SceneBarView(scenes: state.scenes, history: state.history)
            Spacer(minLength: 4)
            ConsoleButton(title: "GROUPS", isOn: $showGroups, width: 62, help: "Show group A–D faders, mute, solo, link and spill")
            ConsoleButton(title: "DUCK", isOn: Binding(get: { state.ducking.config.manualDuck }, set: { state.ducking.config.manualDuck = $0 }),
                          onColor: Theme.meterYellow, width: 48,
                          help: "Manual duck: lower all background applications now (automatic ducking is in the EQ page and Settings)")
            Menu {
                Button("Generated test tone (diagnostic)") { addTone() }.disabled(!engine.status.isRunning)
                Divider()
                Text("Application channels appear automatically once a capture backend is active.")
            } label: { Label("Add Channel", systemImage: "plus") }
                .frame(width: 118)
        }
    }

    private func strips(_ engine: AudioEngine, faderHeight: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(engine.channels.enumerated()).filter { spill == nil || $0.element.group == spill }, id: \.element.id) { pair in
                    let ch = pair.element
                    MixerStrip(channel: ch, meter: hub.model(for: ch), index: pair.offset + 1,
                               selected: eqSelection.channelID == ch.id, faderHeight: faderHeight,
                               onSelect: { eqSelection.channelID = eqSelection.channelID == ch.id ? nil : ch.id },
                               onRemove: { if eqSelection.channelID == ch.id { eqSelection.channelID = nil }; engine.removeChannel(ch) })
                }
            }
            .padding(.bottom, 8).padding(.top, 2).padding(.horizontal, 2)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.vertical.3").font(.system(size: 28)).foregroundColor(Theme.textSecondary)
            Text("No channels yet").font(Theme.title).foregroundColor(Theme.textPrimary)
            Text(emptyExplanation).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(radius: 16)
    }

    private var emptyExplanation: String {
        if state.preferredBackend != nil {
            return "Applications appear here when they play audio. If an application does not show up, check Settings ▸ Audio."
        }
        return "This macOS version (\(OSVersion.current.description)) cannot capture individual applications without the optional MacAudioOo driver. See Settings ▸ Audio, or use Add Channel to try a generated test tone."
    }

    private func addTone() {
        let freqs: [Float] = [220, 330, 440, 660, 880]
        let f = freqs[toneCount % freqs.count]; toneCount += 1
        let src = ToneSource(frequency: f, amplitude: 0.25, sampleRate: Float(state.engine.sampleRate))
        if let ch = state.engine.addChannel(name: "Test tone \(Int(f)) Hz", source: src) { eqSelection.channelID = ch.id }
    }
}

/// EQ card bound to the selected channel (or the master bus).
struct EQTargetCard: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var eqSelection: EQSelection
    var plotHeight: CGFloat = 150
    var onHide: (() -> Void)? = nil

    var body: some View {
        let engine = state.engine
        if let id = eqSelection.channelID, let ch = engine.channels.first(where: { $0.id == id }) {
            EQCardView(title: "Equalizer", subtitle: "10-Band Graphic EQ · " + ch.name,
                       gains: Binding(get: { ch.eqGains }, set: { ch.eqGains = $0 }),
                       bypass: Binding(get: { ch.eqBypass }, set: { ch.eqBypass = $0 }),
                       presetName: Binding(get: { ch.eqPresetName }, set: { ch.eqPresetName = $0 }),
                       applyPreset: { ch.applyEQPreset($0) }, response: { ch.dsp.eq.responseDB(at: $0) },
                       plotHeight: plotHeight, onHide: onHide)
                .id(ch.id)
        } else {
            EQCardView(title: "Equalizer", subtitle: "10-Band Graphic EQ · Master",
                       gains: Binding(get: { engine.masterEQGains }, set: { engine.masterEQGains = $0 }),
                       bypass: Binding(get: { engine.masterEQBypass }, set: { engine.masterEQBypass = $0 }),
                       presetName: Binding(get: { engine.masterEQPresetName }, set: { engine.masterEQPresetName = $0 }),
                       applyPreset: { engine.applyMasterEQPreset($0) }, response: { engine.masterEQ.responseDB(at: $0) },
                       plotHeight: plotHeight, onHide: onHide)
        }
    }
}

// MARK: - Strips

struct MixerStrip: View {
    @ObservedObject var channel: AudioChannel
    @ObservedObject var meter: MeterModel
    var index: Int
    var selected: Bool
    var faderHeight: CGFloat
    var onSelect: () -> Void
    var onRemove: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text("\(index)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(Theme.textPrimary)
                    .frame(width: 18, height: 18).background(Circle().fill(Theme.panelRaised))
                Text(channel.name).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .help(channel.name + (channel.pid.map { " (PID \($0))" } ?? ""))
            HStack(spacing: 6) {
                ConsoleButton(title: "S", isOn: $channel.solo, onColor: Theme.meterYellow, width: 34, help: "Solo: hear only soloed channels")
                ConsoleButton(title: "M", isOn: $channel.mute, onColor: Theme.meterOrange, width: 34, help: "Mute this channel")
            }
            HStack(alignment: .top, spacing: 5) {
                FaderView(db: $channel.volumeDB, height: faderHeight, capW: 30)
                LevelMeterView(model: meter, width: 10, height: faderHeight - 4, segments: 22)
            }
            ValuePill(text: dbText(channel.volumeDB) + " dB", width: 74)
            Group {
                if let icon = channel.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "waveform").resizable().scaledToFit().padding(6).foregroundColor(Theme.cyan)
                }
            }.frame(width: 32, height: 32)
        }
        .padding(.vertical, 10).padding(.horizontal, 8)
        .frame(width: 118)
        .glassCard(radius: 14, highlighted: selected)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { onSelect() }
        .contextMenu {
            Button("Edit EQ / compressor") { onSelect() }
            Button("Reset channel") { reset() }
            Divider()
            Button("Remove channel", role: .destructive) { onRemove() }
        }
    }

    private func reset() {
        channel.volumeDB = 0; channel.balance = 0; channel.mute = false; channel.solo = false
        channel.eqGains = [Float](repeating: 0, count: EQProcessor.bandCount); channel.eqPresetName = "Flat"
        channel.comp = CompressorParams(); channel.reverbSend = 0; channel.delaySend = 0; channel.group = -1
    }
}

struct MasterStrip: View {
    @ObservedObject var engine: AudioEngine
    @ObservedObject var hub: MeterHub
    @EnvironmentObject var state: AppState
    var selected: Bool
    var faderHeight: CGFloat
    var onSelect: () -> Void

    private var percent: Binding<Float> {
        Binding(get: { min(100, (dbToLinear(engine.masterVolumeDB) * 100).rounded()) },
                set: { p in engine.masterVolumeDB = p <= 0 ? -60 : 20 * log10f(p / 100) })
    }
    private var deviceName: String {
        if case .running(let d, _) = engine.status { return d }
        return "Output stopped"
    }

    var body: some View {
        VStack(spacing: 8) {
            Text("MASTER").font(.system(size: 13, weight: .bold, design: .rounded)).kerning(1).foregroundColor(Theme.cyan)
                .frame(height: 18)
            HStack(spacing: 6) {
                ConsoleButton(title: "M", isOn: Binding(get: { engine.masterMute }, set: { engine.masterMute = $0 }),
                              onColor: Theme.meterOrange, width: 34, help: "Mute the master output")
            }
            HStack(alignment: .top, spacing: 4) {
                PercentFaderView(percent: percent, height: faderHeight)
                LevelMeterView(model: hub.masterL, width: 10, height: faderHeight - 4, segments: 22)
                LevelMeterView(model: hub.masterR, width: 10, height: faderHeight - 4, segments: 22)
            }
            ValuePill(text: String(format: "%.0f%%", percent.wrappedValue), width: 74)
            Text(deviceName).font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundColor(Theme.textSecondary)
                .lineLimit(2).multilineTextAlignment(.center).frame(width: 130, height: 26)
        }
        .padding(.vertical, 10).padding(.horizontal, 8)
        .frame(width: 168)
        .glassCard(radius: 14, highlighted: true)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { onSelect() }
        .help("Master output. Click to edit the master EQ.")
    }
}
