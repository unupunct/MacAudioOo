import SwiftUI

/// The CLASSIC tab: a compact vertical list of applications with volume, meter and mute,
/// plus master volume/EQ and the output device. It drives exactly the same engine channels
/// as the Console, so switching views never interrupts audio.
struct ClassicView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var hub = MeterHub()
    @State private var showEQ = false

    var body: some View {
        let engine = state.engine
        VStack(spacing: 10) {
            HStack {
                Text("APPLICATIONS").font(Theme.label).foregroundColor(Theme.textSecondary)
                Text("\(engine.channels.count)").font(Theme.value).foregroundColor(Theme.textPrimary)
                Spacer()
            }
            if engine.channels.isEmpty { emptyState } else { list(engine) }
            masterPanel(engine)
            if showEQ {
                EQCardView(title: "Master EQ", gains: Binding(get: { engine.masterEQGains }, set: { engine.masterEQGains = $0 }),
                             bypass: Binding(get: { engine.masterEQBypass }, set: { engine.masterEQBypass = $0 }),
                             presetName: Binding(get: { engine.masterEQPresetName }, set: { engine.masterEQPresetName = $0 }),
                             applyPreset: { engine.applyMasterEQPreset($0) }, response: { engine.masterEQ.responseDB(at: $0) },
                             plotHeight: 130)
            }
        }
        .padding(14)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .onAppear { hub.start(engine: engine) }
        .onDisappear { hub.stop() }
    }

    private func list(_ engine: AudioEngine) -> some View {
        ScrollView(.vertical) {
            VStack(spacing: 6) {
                ForEach(engine.channels) { ch in
                    ClassicRow(channel: ch, meter: hub.model(for: ch), onRemove: { engine.removeChannel(ch) })
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet").font(.system(size: 26)).foregroundColor(Theme.textSecondary)
            Text("No applications yet").font(Theme.title).foregroundColor(Theme.textPrimary)
            Text(state.preferredBackend != nil
                 ? "Applications appear here when they play audio."
                 : "This macOS version (\(OSVersion.current.description)) cannot capture individual applications without the optional MacAudioOo driver. See Settings ▸ Audio.")
                .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).panel()
    }

    private func masterPanel(_ engine: AudioEngine) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text("MASTER").font(Theme.title).foregroundColor(Theme.textPrimary).frame(width: 74, alignment: .leading)
                HorizontalFaderView(db: Binding(get: { engine.masterVolumeDB }, set: { engine.masterVolumeDB = $0 }), width: 300)
                Text(dbText(engine.masterVolumeDB) + " dB").font(Theme.value).foregroundColor(Theme.textPrimary).frame(width: 70, alignment: .trailing)
                Spacer()
                ConsoleButton(title: "MUTE", isOn: Binding(get: { engine.masterMute }, set: { engine.masterMute = $0 }),
                              onColor: Theme.meterOrange, width: 42, help: "Mute the master output")
                ConsoleButton(title: "DIM", isOn: Binding(get: { engine.dim }, set: { engine.dim = $0 }),
                              onColor: Theme.meterYellow, width: 36, help: "Reduce output by 20 dB")
                ConsoleButton(title: "MONO", isOn: Binding(get: { engine.mono }, set: { engine.mono = $0 }), width: 40,
                              help: "Sum left and right for mono monitoring")
                ConsoleButton(title: "EQ", isOn: $showEQ, width: 34, help: "Show the master 10-band EQ")
            }
            HStack(spacing: 10) {
                Text("OUTPUT").font(Theme.label).foregroundColor(Theme.textSecondary).frame(width: 74, alignment: .leading)
                HorizontalMeterView(model: hub.masterL, width: 300, height: 8)
                Spacer()
                HorizontalMeterView(model: hub.masterR, width: 300, height: 8)
            }
            HStack {
                Text("Output device").font(Theme.label).foregroundColor(Theme.textSecondary).frame(width: 90, alignment: .leading)
                OutputPicker()
                Spacer()
                Text("Applications share one output device.").font(.system(size: 10)).foregroundColor(Theme.textSecondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelRaised))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }
}

struct ClassicRow: View {
    @ObservedObject var channel: AudioChannel
    @ObservedObject var meter: MeterModel
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = channel.icon { Image(nsImage: icon).resizable().interpolation(.high) }
                else { Image(systemName: "waveform").resizable().scaledToFit().padding(6).foregroundColor(Theme.accent) }
            }
            .frame(width: 30, height: 30)
            Text(channel.name).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(Theme.textPrimary)
                .lineLimit(1).frame(width: 150, alignment: .leading)
            HorizontalFaderView(db: $channel.volumeDB, width: 220)
            Text(dbText(channel.volumeDB)).font(Theme.value).foregroundColor(Theme.textPrimary).frame(width: 46, alignment: .trailing)
            HorizontalMeterView(model: meter, width: 110, height: 8)
            ConsoleButton(title: "MUTE", isOn: $channel.mute, onColor: Theme.meterOrange, width: 42, help: "Mute this application")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        .opacity(channel.mute ? 0.65 : 1)
        .contextMenu {
            Button("Reset volume") { channel.volumeDB = 0 }
            Divider()
            Button("Remove channel", role: .destructive) { onRemove() }
        }
    }
}

// MARK: - Horizontal controls

/// Horizontal volume slider using the same dB taper as the Console fader.
struct HorizontalFaderView: View {
    @Binding var db: Float
    var width: CGFloat = 220
    private let capW: CGFloat = 16, capH: CGFloat = 22

    var body: some View {
        let travel = width - capW
        let pos = CGFloat(FaderTaper.position(forDB: db))
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.well).frame(width: width, height: 5)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.border))
            Rectangle().fill(Theme.textSecondary.opacity(0.5)).frame(width: 1, height: 11)
                .offset(x: capW / 2 + travel * CGFloat(FaderTaper.position(forDB: 0)))        // 0 dB mark
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.25)], startPoint: .top, endPoint: .bottom))
                .frame(width: capW, height: capH)
                .overlay(Rectangle().fill(Theme.accent).frame(width: 2, height: capH - 8))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.6)))
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .offset(x: travel * pos)
        }
        .frame(width: width, height: capH)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            db = FaderTaper.db(forPosition: Float((v.location.x - capW / 2) / travel))
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded { db = 0 })
        .help("Drag to set volume. Double-click to reset to 0 dB.")
    }
}

/// Horizontal segmented level meter (same colours and ballistics as the vertical one).
struct HorizontalMeterView: View {
    @ObservedObject var model: MeterModel
    var width: CGFloat = 110
    var height: CGFloat = 8
    private let segments = 30
    private let minDB: Float = -60, maxDB: Float = 3

    var body: some View {
        HStack(spacing: 4) {
            Canvas { ctx, size in
                let segW = size.width / CGFloat(segments)
                for i in 0..<segments {
                    let db = minDB + (maxDB - minDB) * Float(i) / Float(segments - 1)
                    let color: Color = db > -3 ? Theme.meterOrange : (db > -12 ? Theme.meterYellow : Theme.meterGreen)
                    let r = CGRect(x: CGFloat(i) * segW + 0.75, y: 0, width: segW - 1.5, height: size.height)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(model.levelDB >= db ? color : color.opacity(0.12)))
                }
                if model.holdDB > minDB {
                    let x = CGFloat((min(model.holdDB, maxDB) - minDB) / (maxDB - minDB)) * size.width
                    ctx.fill(Path(CGRect(x: max(0, x - 1), y: 0, width: 2, height: size.height)), with: .color(.white.opacity(0.85)))
                }
            }
            .frame(width: width, height: height)
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border))
            Circle().fill(model.clipped ? Theme.record : Theme.well).frame(width: 7, height: 7)
                .overlay(Circle().stroke(Theme.border))
                .onTapGesture { model.resetClip() }
                .help(model.clipped ? "Clipping occurred. Click to reset." : "Clip indicator")
        }
    }
}
