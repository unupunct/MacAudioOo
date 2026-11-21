import SwiftUI

/// EQ page: target selector, the EQ card, then the channel card, shared effects and ducking & monitor cards.
struct EQPageView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var eqSelection: EQSelection
    @StateObject private var hub = MeterHub()

    var body: some View {
        let engine = state.engine
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 12) {
                targetBar(engine)
                EQTargetCard(plotHeight: 170)
                HStack(alignment: .top, spacing: 12) {
                    if let id = eqSelection.channelID, let ch = engine.channels.first(where: { $0.id == id }) {
                        ChannelCard(channel: ch, meter: hub.model(for: ch), recordingLocked: state.recorder.state != .idle).id(ch.id)
                    } else {
                        MasterNoteCard()
                    }
                    EffectsCard(engine: engine)
                    DuckingCard(engine: engine, ducking: state.ducking)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .onAppear { hub.start(engine: engine) }
        .onDisappear { hub.stop() }
    }

    private func targetBar(_ engine: AudioEngine) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("EDITING").font(.system(size: 10, weight: .bold, design: .rounded)).kerning(1).foregroundColor(Theme.textSecondary)
                chip("Master", selected: eqSelection.channelID == nil) { eqSelection.channelID = nil }
                ForEach(engine.channels) { ch in
                    chip(ch.name, selected: eqSelection.channelID == ch.id) { eqSelection.channelID = ch.id }
                }
            }
            .padding(.horizontal, 2).padding(.vertical, 4)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                .foregroundColor(selected ? Theme.cyan : Theme.textSecondary)
                .padding(.horizontal, 14).frame(height: 28)
                .background(Capsule().fill(selected ? Theme.cyan.opacity(0.12) : Theme.well))
                .overlay(Capsule().stroke(selected ? Theme.cyan : Theme.border, lineWidth: selected ? 1.5 : 1))
        }.buttonStyle(.plain)
    }
}

/// Labelled knob with a unit read-out, shared by the three cards.
func panelKnob(_ title: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, _ def: Float, size: CGFloat = 36,
               _ fmt: @escaping (Float) -> String) -> some View {
    KnobView(title: title, value: value, range: range, defaultValue: def, format: fmt, size: size)
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .bold, design: .rounded)).kerning(1.2).foregroundColor(Theme.textSecondary)
    }
}

struct SwitchRow: View {
    var title: String
    @Binding var isOn: Bool
    var help: String = ""
    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(Theme.textPrimary)
            Spacer()
            ToggleSwitch(isOn: $isOn)
        }.help(help)
    }
}

// MARK: - Channel card

struct ChannelCard: View {
    @ObservedObject var channel: AudioChannel
    @ObservedObject var meter: MeterModel
    var recordingLocked: Bool

    private func tone(_ i: Int) -> Binding<Float> {
        Binding(get: { channel.eqGains[i] }, set: { channel.eqGains[i] = $0; channel.eqPresetName = "Custom" })
    }
    private func db(_ v: Float) -> String { String(format: "%+.1f dB", v) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(text: channel.name + " · channel", subtitle: "Tone, compressor, sends and channel options")
            SectionLabel(text: "EQ")
            HStack(spacing: 14) {
                panelKnob("LOW 100 Hz", tone(10), -12...12, 0, db)
                panelKnob("MID 1 kHz", tone(11), -12...12, 0, db)
                panelKnob("HIGH 8 kHz", tone(12), -12...12, 0, db)
                panelKnob("BALANCE", $channel.balance, -1...1, 0) { $0 == 0 ? "C" : String(format: "%@%.0f", $0 < 0 ? "L" : "R", abs($0) * 100) }
            }
            HStack {
                SectionLabel(text: "COMPRESSOR")
                Spacer()
                Text("On").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(Theme.textSecondary)
                ToggleSwitch(isOn: Binding(get: { channel.comp.enabled != 0 }, set: { channel.comp.enabled = $0 ? 1 : 0 }))
            }
            HStack(spacing: 10) {
                panelKnob("THRESH", Binding(get: { channel.comp.thresholdDB }, set: { channel.comp.thresholdDB = $0 }), -60...0, -18, size: 32) { String(format: "%.0f dB", $0) }
                panelKnob("RATIO", Binding(get: { channel.comp.ratio }, set: { channel.comp.ratio = $0 }), 1...20, 3, size: 32) { String(format: "%.1f:1", $0) }
                panelKnob("MAKEUP", Binding(get: { channel.comp.makeupDB }, set: { channel.comp.makeupDB = $0 }), 0...24, 0, size: 32) { String(format: "+%.1f dB", $0) }
                panelKnob("ATTACK", Binding(get: { channel.comp.attackMs }, set: { channel.comp.attackMs = $0 }), 0.5...100, 10, size: 32) { String(format: "%.1f ms", $0) }
                panelKnob("RELEASE", Binding(get: { channel.comp.releaseMs }, set: { channel.comp.releaseMs = $0 }), 20...1000, 120, size: 32) { String(format: "%.0f ms", $0) }
            }
            .opacity(channel.comp.enabled != 0 ? 1 : 0.5)
            HStack(spacing: 8) {
                Text("GR").font(Theme.label).foregroundColor(Theme.textSecondary)
                GainReductionBar(model: meter)
            }
            SectionLabel(text: "SENDS")
            HStack(spacing: 18) {
                panelKnob("REVERB", $channel.reverbSend, 0...1, 0) { String(format: "%.0f%%", $0 * 100) }
                panelKnob("DELAY", $channel.delaySend, 0...1, 0) { String(format: "%.0f%%", $0 * 100) }
            }
            VStack(spacing: 8) {
                SwitchRow(title: "Mono", isOn: $channel.mono, help: "Sum this channel's left and right to mono")
                SwitchRow(title: "Recall safe", isOn: $channel.recallSafe, help: "Loading a scene leaves this channel's settings alone")
                SwitchRow(title: "Ducks others", isOn: $channel.ducksOthers, help: "While this channel is playing, background applications are lowered (needs Ducking enabled)")
                SwitchRow(title: "Record stem", isOn: $channel.recArm, help: recordingLocked ? "Arming is locked while recording" : "Arm this channel's stem for recording")
                    .disabled(recordingLocked)
            }
            Text("Mono folds this channel to the centre. Recall safe keeps its settings when a preset loads. Ducks others lowers the rest while this one plays.")
                .font(.system(size: 10)).foregroundColor(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
        .glassCard(radius: 16)
    }
}

struct MasterNoteCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(text: "Master", subtitle: "Editing the master bus EQ")
            Text("Pick an application above (or click its strip on the Mixer) to edit its tone, compressor, sends and options here.")
                .font(.system(size: 12)).foregroundColor(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
        .glassCard(radius: 16)
    }
}

// MARK: - Shared effects

struct EffectsCard: View {
    @ObservedObject var engine: AudioEngine
    private func rdb(_ lin: Float) -> Float { lin <= 0.01 ? -40 : max(-40, min(6, linearToDB(lin))) }
    private func ldb(_ db: Float) -> Float { db <= -40 ? 0 : powf(10, db / 20) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(text: "Shared effects", subtitle: "Reverb and delay return into the master")
            effectHeader("REVERB", Binding(get: { engine.reverb.enabled != 0 }, set: { engine.reverb.enabled = $0 ? 1 : 0 }))
            HStack(spacing: 10) {
                panelKnob("RETURN", Binding(get: { rdb(engine.reverb.returnLevel) }, set: { engine.reverb.returnLevel = ldb($0) }), -40...6, 0, size: 32) { String(format: "%+.0f dB", $0) }
                panelKnob("SIZE", Binding(get: { engine.reverb.roomSize }, set: { engine.reverb.roomSize = $0 }), 0...1, 0.5, size: 32) { String(format: "%.0f ms", ReverbParams.sizeMilliseconds(roomSize: $0)) }
                panelKnob("DECAY", Binding(get: { engine.reverb.decaySeconds }, set: { engine.reverb.decaySeconds = $0 }), 0.2...8, 1.6, size: 32) { String(format: "%.1f s", $0) }
                panelKnob("TONE", Binding(get: { engine.reverb.toneHz }, set: { engine.reverb.toneHz = $0 }), 1000...16000, 8000, size: 32) { String(format: "%.1f kHz", $0 / 1000) }
            }
            .opacity(engine.reverb.enabled != 0 ? 1 : 0.5)
            effectHeader("DELAY", Binding(get: { engine.delay.enabled != 0 }, set: { engine.delay.enabled = $0 ? 1 : 0 }))
            HStack(spacing: 10) {
                panelKnob("RETURN", Binding(get: { rdb(engine.delay.returnLevel) }, set: { engine.delay.returnLevel = ldb($0) }), -40...6, 0, size: 32) { String(format: "%+.0f dB", $0) }
                panelKnob("TIME", Binding(get: { engine.delay.timeMs }, set: { engine.delay.timeMs = $0 }), 10...1500, 375, size: 32) { String(format: "%.0f ms", $0) }
                panelKnob("REPEATS", Binding(get: { engine.delay.feedback }, set: { engine.delay.feedback = $0 }), 0...0.85, 0.35, size: 32) { String(format: "%.0f%%", $0 * 100) }
                panelKnob("TONE", Binding(get: { engine.delay.toneHz }, set: { engine.delay.toneHz = $0 }), 1000...16000, 6000, size: 32) { String(format: "%.1f kHz", $0 / 1000) }
            }
            .opacity(engine.delay.enabled != 0 ? 1 : 0.5)
            Text("Each channel's REVERB and DELAY send knobs choose how much of that channel enters these effects.")
                .font(.system(size: 10)).foregroundColor(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
        .glassCard(radius: 16)
    }

    private func effectHeader(_ title: String, _ on: Binding<Bool>) -> some View {
        HStack {
            SectionLabel(text: title)
            Spacer()
            Text("On").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(Theme.textSecondary)
            ToggleSwitch(isOn: on)
        }
    }
}

// MARK: - Ducking & monitor

struct DuckingCard: View {
    @ObservedObject var engine: AudioEngine
    @ObservedObject var ducking: DuckingController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(text: "Ducking & monitor", subtitle: "Lower background apps while another one plays")
            HStack {
                SectionLabel(text: "DUCKING")
                Spacer()
                Text("On").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(Theme.textSecondary)
                ToggleSwitch(isOn: Binding(get: { ducking.config.enabled }, set: { ducking.config.enabled = $0 }))
            }
            HStack(spacing: 14) {
                panelKnob("AMOUNT", Binding(get: { ducking.config.reductionDB }, set: { ducking.config.reductionDB = $0 }), 0...40, 12, size: 34) { String(format: "-%.0f dB", $0) }
                panelKnob("THRESH", Binding(get: { ducking.config.triggerThresholdDB }, set: { ducking.config.triggerThresholdDB = $0 }), -70...(-10), -45, size: 34) { String(format: "%.0f dB", $0) }
                panelKnob("RELEASE", Binding(get: { ducking.config.releaseMs }, set: { ducking.config.releaseMs = $0 }), 50...3000, 700, size: 34) { String(format: "%.0f ms", $0) }
            }
            .opacity(ducking.config.enabled ? 1 : 0.5)
            Text(ducking.config.enabled
                 ? (ducking.triggerActive ? String(format: "Ducking now: -%.1f dB", ducking.reductionDB) : "Waiting for a trigger application (set in Settings).")
                 : "Off. Turn on, then mark channels with “Ducks others”, or list trigger apps in Settings.")
                .font(.system(size: 10)).foregroundColor(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Theme.border)
            SectionLabel(text: "MONITOR")
            VStack(spacing: 8) {
                SwitchRow(title: "DIM (−20 dB)", isOn: Binding(get: { engine.dim }, set: { engine.dim = $0 }), help: "Reduce the output by 20 dB")
                SwitchRow(title: "MONO", isOn: Binding(get: { engine.mono }, set: { engine.mono = $0 }), help: "Sum left and right for mono monitoring")
            }
            HStack(spacing: 14) {
                panelKnob("LIMIT", Binding(get: { engine.limiterThresholdDB }, set: { engine.limiterThresholdDB = $0 }), -24...0, -1, size: 34) { String(format: "%.1f dB", $0) }
            }
            Text("DIM and MONO affect only what you hear and what the mix recording captures from the output stage.")
                .font(.system(size: 10)).foregroundColor(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
        .glassCard(radius: 16)
    }
}

/// Gain-reduction bar for the compressor card.
struct GainReductionBar: View {
    @ObservedObject var model: MeterModel
    var body: some View {
        let frac = CGFloat(min(1, max(0, model.grDB / 24)))
        HStack(spacing: 8) {
            ZStack(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.well)
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 3).fill(Theme.meterOrange)
                        .frame(width: g.size.width * frac).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(height: 8).overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border))
            Text(String(format: "-%.1f dB", model.grDB)).font(Theme.value).foregroundColor(Theme.textSecondary).fixedSize()
        }
    }
}

// MARK: - Presets page (scenes + EQ presets)

struct PresetsView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(text: "Presets", subtitle: "Mixer scenes capture every fader, EQ, effect and option")
                SceneBarView(scenes: state.scenes, history: state.history)
                    .padding(12).glassCard(radius: 14)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(state.scenes.scenes) { s in
                        let current = state.scenes.currentID == s.id
                        Button(action: { state.scenes.load(s) }) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: "square.stack.3d.up").foregroundColor(current ? Theme.cyan : Theme.textSecondary)
                                    Text(s.name).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(Theme.textPrimary).lineLimit(1)
                                    Spacer()
                                }
                                Text("EQ " + s.snapshot.master.eqPreset + " · " + (current ? "loaded" : "tap to load"))
                                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(Theme.textSecondary)
                            }
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .glassCard(radius: 14, highlighted: current)
                        }.buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
        }
    }
}
