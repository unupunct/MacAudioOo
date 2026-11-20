import SwiftUI

/// One mixer channel: icon, name, balance, tone knobs, effect sends, EQ/COMP buttons,
/// meter + fader with dB readout, MUTE / SOLO. Every control writes into the real mixer.
struct ChannelStripView: View {
    @ObservedObject var channel: AudioChannel
    @ObservedObject var meter: MeterModel
    var isSelected: Bool
    var onSelect: () -> Void
    var onRemove: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            // Header
            VStack(spacing: 3) {
                Group {
                    if let icon = channel.icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "waveform").resizable().scaledToFit().padding(5).foregroundColor(Theme.accent)
                    }
                }
                .frame(width: 28, height: 28)
                Text(channel.name).font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.textPrimary).lineLimit(1).truncationMode(.tail)
                    .frame(width: 84)
            }
            .help(channel.name + (channel.pid.map { " (PID \($0))" } ?? ""))

            KnobView(title: "BAL", value: $channel.balance, range: -1...1, defaultValue: 0,
                     format: { $0 == 0 ? "C" : String(format: "%@%.0f", $0 < 0 ? "L" : "R", abs($0) * 100) }, size: 24)

            HStack(spacing: 2) {
                KnobView(title: "HIGH", value: toneBinding(12), range: -12...12, defaultValue: 0,
                         format: { String(format: "%+.1f", $0) }, size: 24)
                KnobView(title: "MID", value: toneBinding(11), range: -12...12, defaultValue: 0,
                         format: { String(format: "%+.1f", $0) }, size: 24)
                KnobView(title: "LOW", value: toneBinding(10), range: -12...12, defaultValue: 0,
                         format: { String(format: "%+.1f", $0) }, size: 24)
            }
            HStack(spacing: 6) {
                KnobView(title: "REV", value: $channel.reverbSend, range: 0...1, defaultValue: 0,
                         format: { String(format: "%.0f%%", $0 * 100) }, size: 22)
                KnobView(title: "DLY", value: $channel.delaySend, range: 0...1, defaultValue: 0,
                         format: { String(format: "%.0f%%", $0 * 100) }, size: 22)
            }

            HStack(spacing: 4) {
                ConsoleButton(title: "EQ", isOn: Binding(get: { isSelected && !channel.eqBypass }, set: { _ in onSelect() }),
                              width: 36, help: "Open the 10-band EQ for this channel")
                ConsoleButton(title: "COMP", isOn: Binding(get: { channel.comp.enabled != 0 },
                                                           set: { channel.comp.enabled = $0 ? 1 : 0 }),
                              onColor: Theme.meterYellow, width: 36, help: "Compressor on/off (settings in the detail panel)")
            }

            // Meter + fader
            HStack(alignment: .top, spacing: 4) {
                LevelMeterView(model: meter, width: 12, height: 132)
                FaderView(db: $channel.volumeDB, height: 150)
            }
            Text(dbText(channel.volumeDB) + " dB").font(Theme.value)
                .foregroundColor(Theme.textPrimary).frame(width: 84)
                .padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 3).fill(Theme.well))

            HStack(spacing: 4) {
                ConsoleButton(title: "MUTE", isOn: $channel.mute, onColor: Theme.meterOrange, width: 38, help: "Mute this channel")
                ConsoleButton(title: "SOLO", isOn: $channel.solo, onColor: Theme.meterYellow, width: 38, help: "Solo: hear only soloed channels")
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
        .frame(width: 100)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Theme.accent : Theme.border, lineWidth: isSelected ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { onSelect() }
        .contextMenu {
            Button("Open EQ / Compressor") { onSelect() }
            Button("Reset channel") { reset() }
            Divider()
            Button("Remove channel", role: .destructive) { onRemove() }
        }
    }

    private func toneBinding(_ index: Int) -> Binding<Float> {
        Binding(get: { channel.eqGains[index] }, set: { channel.eqGains[index] = $0; channel.eqPresetName = "Custom" })
    }

    private func reset() {
        channel.volumeDB = 0; channel.balance = 0; channel.mute = false; channel.solo = false
        channel.eqGains = [Float](repeating: 0, count: EQProcessor.bandCount); channel.eqPresetName = "Flat"
        channel.comp = CompressorParams(); channel.reverbSend = 0; channel.delaySend = 0
    }
}
