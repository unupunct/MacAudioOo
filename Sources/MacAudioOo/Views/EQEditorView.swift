import SwiftUI

/// 10-band graphic EQ editor with a live frequency-response curve, presets and bypass.
/// Used for both a channel EQ and the master EQ.
struct EQEditorView: View {
    var title: String
    @Binding var gains: [Float]
    @Binding var bypass: Bool
    @Binding var presetName: String
    var applyPreset: (String) -> Void
    var response: (Double) -> Double

    @State private var userPresets = EQPresets.userPresets()
    @State private var newPresetName = ""

    private let labels = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(Theme.title).foregroundColor(Theme.textPrimary)
                Menu(presetName) {
                    ForEach(EQPresets.builtInNames, id: \.self) { n in Button(n) { applyPreset(n) } }
                    if !userPresets.isEmpty {
                        Divider()
                        ForEach(userPresets.keys.sorted(), id: \.self) { n in Button(n) { applyPreset(n); userPresets = EQPresets.userPresets() } }
                        Menu("Delete preset") {
                            ForEach(userPresets.keys.sorted(), id: \.self) { n in
                                Button(n, role: .destructive) { EQPresets.delete(name: n); userPresets = EQPresets.userPresets() }
                            }
                        }
                    }
                }.frame(width: 120)
                ConsoleButton(title: "BYPASS", isOn: $bypass, onColor: Theme.meterOrange, width: 54, help: "Bypass this EQ")
                Spacer()
                TextField("Save preset as…", text: $newPresetName).textFieldStyle(.roundedBorder).frame(width: 130)
                Button("Save") {
                    let n = newPresetName.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty, !EQPresets.builtInNames.contains(n) else { return }
                    EQPresets.save(name: n, gains: Array(gains.prefix(10)))
                    userPresets = EQPresets.userPresets(); presetName = n; newPresetName = ""
                }.disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(alignment: .top, spacing: 10) {
                EQCurveView(response: response, dimmed: bypass).frame(width: 260, height: 112)
                HStack(spacing: 4) {
                    ForEach(0..<10, id: \.self) { i in
                        VStack(spacing: 2) {
                            Text(String(format: "%+.0f", gains[i])).font(.system(size: 8, design: .monospaced)).foregroundColor(Theme.textSecondary)
                            VerticalSlider(value: Binding(get: { gains[i] }, set: { gains[i] = $0 }),
                                           range: EQProcessor.gainRange, height: 82, onEdit: { presetName = "Custom" })
                            Text(labels[i]).font(.system(size: 8, weight: .semibold)).foregroundColor(Theme.textSecondary)
                        }
                    }
                }
                .opacity(bypass ? 0.45 : 1)
            }
        }
    }
}

struct EQCurveView: View {
    var response: (Double) -> Double
    var dimmed: Bool
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(Theme.well))
            let lo = log10(20.0), hi = log10(20000.0)
            func x(_ f: Double) -> CGFloat { CGFloat((log10(f) - lo) / (hi - lo)) * size.width }
            func y(_ db: Double) -> CGFloat { size.height / 2 - CGFloat(db / 15) * size.height / 2 }
            for db in stride(from: -12.0, through: 12.0, by: 6.0) {
                var p = Path(); p.move(to: CGPoint(x: 0, y: y(db))); p.addLine(to: CGPoint(x: size.width, y: y(db)))
                ctx.stroke(p, with: .color(.white.opacity(db == 0 ? 0.25 : 0.08)), lineWidth: 1)
            }
            for f in [100.0, 1000.0, 10000.0] {
                var p = Path(); p.move(to: CGPoint(x: x(f), y: 0)); p.addLine(to: CGPoint(x: x(f), y: size.height))
                ctx.stroke(p, with: .color(.white.opacity(0.08)), lineWidth: 1)
            }
            var curve = Path()
            for i in 0...160 {
                let f = pow(10, lo + (hi - lo) * Double(i) / 160)
                let pt = CGPoint(x: x(f), y: y(max(-15, min(15, dimmed ? 0 : response(f)))))
                if i == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
            }
            ctx.stroke(curve, with: .color(Theme.accent.opacity(dimmed ? 0.3 : 1)), lineWidth: 2)
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
    }
}

/// Compressor editor: enable, five knobs, presets and a live gain-reduction meter.
struct CompressorEditorView: View {
    @ObservedObject var channel: AudioChannel
    @ObservedObject var meter: MeterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("COMPRESSOR").font(Theme.title).foregroundColor(Theme.textPrimary)
                ConsoleButton(title: "ON", isOn: Binding(get: { channel.comp.enabled != 0 }, set: { channel.comp.enabled = $0 ? 1 : 0 }),
                              onColor: Theme.meterYellow, width: 30, help: "Enable the compressor")
                Menu("Preset") {
                    ForEach(CompressorParams.presets, id: \.name) { p in Button(p.name) { channel.comp = p.p } }
                }.frame(width: 80)
            }
            HStack(spacing: 8) {
                knob("THRESH", Binding(get: { channel.comp.thresholdDB }, set: { channel.comp.thresholdDB = $0 }), -60...0, -18, { String(format: "%.0f dB", $0) })
                knob("RATIO", Binding(get: { channel.comp.ratio }, set: { channel.comp.ratio = $0 }), 1...20, 3, { String(format: "%.1f:1", $0) })
                knob("ATTACK", Binding(get: { channel.comp.attackMs }, set: { channel.comp.attackMs = $0 }), 0.5...100, 10, { String(format: "%.1f ms", $0) })
                knob("RELEASE", Binding(get: { channel.comp.releaseMs }, set: { channel.comp.releaseMs = $0 }), 20...1000, 120, { String(format: "%.0f ms", $0) })
                knob("MAKEUP", Binding(get: { channel.comp.makeupDB }, set: { channel.comp.makeupDB = $0 }), 0...24, 0, { String(format: "+%.1f dB", $0) })
            }
            .opacity(channel.comp.enabled != 0 ? 1 : 0.5)
            HStack(spacing: 6) {
                Text("GR").font(Theme.label).foregroundColor(Theme.textSecondary)
                GainReductionBar(model: meter)
            }
        }
    }

    private func knob(_ t: String, _ v: Binding<Float>, _ r: ClosedRange<Float>, _ d: Float, _ f: @escaping (Float) -> String) -> some View {
        KnobView(title: t, value: v, range: r, defaultValue: d, format: f, size: 28)
    }
}

struct GainReductionBar: View {
    @ObservedObject var model: MeterModel
    var body: some View {
        let frac = CGFloat(min(1, max(0, model.grDB / 24)))
        HStack(spacing: 6) {
            ZStack(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.well)
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 2).fill(Theme.meterOrange)
                        .frame(width: g.size.width * frac).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(width: 160, height: 8).overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.border))
            Text(String(format: "-%.1f dB", model.grDB)).font(Theme.value).foregroundColor(Theme.textSecondary)
        }
    }
}
