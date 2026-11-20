import SwiftUI

/// Master section: stereo meter, fader, MUTE / DIM / MONO, limiter threshold with
/// gain-reduction readout, and access to the master EQ.
struct MasterChannelView: View {
    @ObservedObject var engine: AudioEngine
    @ObservedObject var hub: MeterHub
    var isSelected: Bool
    var onSelectEQ: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("MASTER").font(Theme.title).foregroundColor(Theme.textPrimary)

            ConsoleButton(title: "EQ", isOn: Binding(get: { isSelected && !engine.masterEQBypass }, set: { _ in onSelectEQ() }),
                          width: 60, help: "Open the master 10-band EQ")

            HStack(spacing: 8) {
                KnobView(title: "LIMIT", value: Binding(get: { engine.limiterThresholdDB }, set: { engine.limiterThresholdDB = $0 }),
                         range: -24...0, defaultValue: -1, format: { String(format: "%.1f dB", $0) }, size: 26)
                VStack(spacing: 2) {
                    Text("GR").font(Theme.label).foregroundColor(Theme.textSecondary)
                    LimiterGRView(model: hub.masterL)
                }
            }

            HStack(alignment: .top, spacing: 3) {
                LevelMeterView(model: hub.masterL, width: 14, height: 132)
                LevelMeterView(model: hub.masterR, width: 14, height: 132)
                FaderView(db: Binding(get: { engine.masterVolumeDB }, set: { engine.masterVolumeDB = $0 }), height: 150)
            }
            Text(dbText(engine.masterVolumeDB) + " dB").font(Theme.value)
                .foregroundColor(Theme.textPrimary).frame(width: 90)
                .padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 3).fill(Theme.well))

            HStack(spacing: 4) {
                ConsoleButton(title: "MUTE", isOn: Binding(get: { engine.masterMute }, set: { engine.masterMute = $0 }),
                              onColor: Theme.meterOrange, width: 42, help: "Mute the master output")
                ConsoleButton(title: "DIM", isOn: Binding(get: { engine.dim }, set: { engine.dim = $0 }),
                              onColor: Theme.meterYellow, width: 42, help: "Reduce output by 20 dB")
            }
            ConsoleButton(title: "MONO", isOn: Binding(get: { engine.mono }, set: { engine.mono = $0 }),
                          width: 88, help: "Sum left and right for mono monitoring")
        }
        .padding(.vertical, 10).padding(.horizontal, 8)
        .frame(width: 130)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelRaised))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Theme.accent : Theme.border, lineWidth: isSelected ? 1.5 : 1))
    }
}

/// Limiter gain reduction readout (the model's grDB is the limiter's reduction, in dB >= 0).
struct LimiterGRView: View {
    @ObservedObject var model: MeterModel
    var body: some View {
        Text(String(format: "%.1f", model.grDB)).font(Theme.value)
            .foregroundColor(model.grDB > 0.5 ? Theme.meterOrange : Theme.textSecondary)
            .frame(width: 34).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.well))
            .help("Limiter gain reduction in dB")
    }
}
