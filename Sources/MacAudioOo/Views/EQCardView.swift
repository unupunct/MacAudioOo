import SwiftUI

/// "Equalizer" card: 10 draggable nodes on a frequency-response curve, dB pills, EQ ON switch, presets, reset.
struct EQCardView: View {
    var title = "Equalizer"
    var subtitle = "10-Band Graphic EQ"
    @Binding var gains: [Float]
    @Binding var bypass: Bool
    @Binding var presetName: String
    var applyPreset: (String) -> Void
    var response: (Double) -> Double
    var plotHeight: CGFloat = 150
    var onHide: (() -> Void)? = nil

    @State private var userPresets = EQPresets.userPresets()
    @State private var saving = false
    @State private var newName = ""

    private let freqLabels = ["31 Hz", "63 Hz", "125 Hz", "250 Hz", "500 Hz", "1 kHz", "2 kHz", "4 kHz", "8 kHz", "16 kHz"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                CardTitle(text: title, subtitle: subtitle)
                Spacer()
                Text("EQ ON").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(Theme.textSecondary)
                ToggleSwitch(isOn: Binding(get: { !bypass }, set: { bypass = !$0 }), onColor: Theme.blue)
                DropdownField(label: "EQ Presets", items: presetItems, width: 140, height: 30) { id in choose(id) }
                PlainButton(title: "Reset", width: 70, height: 30) { reset() }
                if let hide = onHide { PlainButton(title: "Hide EQ", width: 84, height: 30) { hide() } }
            }
            EQPlot(gains: $gains, bypass: bypass, response: response, onEdit: { presetName = "Custom" })
                .frame(height: plotHeight)
            HStack(spacing: 0) {
                ForEach(0..<10, id: \.self) { i in
                    VStack(spacing: 3) {
                        ValuePill(text: String(format: "%+.0f dB", gains[i]), color: gains[i] == 0 ? Theme.textSecondary : Theme.cyan)
                        Text(freqLabels[i]).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.leading, 30).opacity(bypass ? 0.45 : 1)
        }
        .padding(14)
        .glassCard(radius: 16)
        .sheet(isPresented: $saving) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Save EQ preset").font(Theme.title)
                TextField("Preset name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 260)
                HStack {
                    Spacer()
                    Button("Cancel") { saving = false }
                    Button("Save") {
                        let n = newName.trimmingCharacters(in: .whitespaces)
                        if !n.isEmpty, !EQPresets.builtInNames.contains(n) {
                            EQPresets.save(name: n, gains: Array(gains.prefix(10)))
                            userPresets = EQPresets.userPresets(); presetName = n
                        }
                        saving = false
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(20)
        }
    }

    private var presetItems: [(id: String, title: String)] {
        var items: [(id: String, title: String)] = EQPresets.builtInNames.map { ("b:" + $0, $0) }
        items += userPresets.keys.sorted().map { ("u:" + $0, $0) }
        items.append(("save", "Save current as…"))
        items += userPresets.keys.sorted().map { ("d:" + $0, "Delete “" + $0 + "”") }
        return items
    }

    private func choose(_ id: String) {
        if id == "save" { newName = ""; saving = true; return }
        if id.hasPrefix("d:") { EQPresets.delete(name: String(id.dropFirst(2))); userPresets = EQPresets.userPresets(); return }
        applyPreset(String(id.dropFirst(2)))
    }

    private func reset() { applyPreset("Flat") }
}

/// The plot: node i sits at column (i + 0.5) / 10 so the dB pills below line up with the nodes.
struct EQPlot: View {
    @Binding var gains: [Float]
    var bypass: Bool
    var response: (Double) -> Double
    var onEdit: () -> Void
    @State private var dragging: Int? = nil
    private let range: Float = 12

    var body: some View {
        GeometryReader { geo in
            let left: CGFloat = 30
            let w = geo.size.width - left, h = geo.size.height
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    ctx.fill(Path(roundedRect: CGRect(x: left, y: 0, width: w, height: h), cornerRadius: 10), with: .color(Theme.well))
                    for db in stride(from: -12, through: 12, by: 6) {
                        let y = yFor(Float(db), h)
                        var p = Path(); p.move(to: CGPoint(x: left, y: y)); p.addLine(to: CGPoint(x: left + w, y: y))
                        ctx.stroke(p, with: .color(.white.opacity(db == 0 ? 0.22 : 0.07)), lineWidth: 1)
                        let t = Text(db == 0 ? "0" : String(format: "%+d", db)).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(Theme.textSecondary)
                        ctx.draw(t, at: CGPoint(x: left - 6, y: y), anchor: .trailing)
                    }
                    for i in 0..<10 {
                        let x = left + w * (CGFloat(i) + 0.5) / 10
                        var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                        ctx.stroke(p, with: .color(.white.opacity(0.05)), lineWidth: 1)
                    }
                    // Response curve, drawn over the same column mapping the nodes use.
                    var curve = Path()
                    let steps = 200
                    for s in 0...steps {
                        let pos = Double(s) / Double(steps)                 // 0...1 across the plot
                        let f = 31.5 * pow(2, pos * 10 - 0.5)               // inverse of (log2(f/31.5) + 0.5) / 10
                        let db = bypass ? 0 : response(min(20000, max(20, f)))
                        let pt = CGPoint(x: left + w * CGFloat(pos), y: yFor(Float(max(-range, min(range, Float(db)))), h))
                        if s == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
                    }
                    var fill = curve
                    fill.addLine(to: CGPoint(x: left + w, y: yFor(0, h))); fill.addLine(to: CGPoint(x: left, y: yFor(0, h))); fill.closeSubpath()
                    ctx.fill(fill, with: .color(Theme.cyan.opacity(bypass ? 0.03 : 0.10)))
                    ctx.stroke(curve, with: .color(Theme.cyan.opacity(bypass ? 0.3 : 1)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
                ForEach(0..<10, id: \.self) { i in
                    let x = left + w * (CGFloat(i) + 0.5) / 10
                    Circle().fill(Color.white).frame(width: dragging == i ? 16 : 13, height: dragging == i ? 16 : 13)
                        .overlay(Circle().stroke(Theme.cyan, lineWidth: 3))
                        .shadow(color: Theme.cyan.opacity(0.8), radius: 4)
                        .position(x: x, y: yFor(gains[i], h))
                        .opacity(bypass ? 0.4 : 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let idx: Int
                if let d = dragging { idx = d } else {
                    let col = Int(((v.startLocation.x - left) / max(1, w)) * 10)
                    idx = min(9, max(0, col)); dragging = idx
                }
                var g = gains
                let raw = Float((h / 2 - v.location.y) / (h / 2 - 6)) * range
                g[idx] = (min(range, max(-range, raw)) * 2).rounded() / 2
                gains = g; onEdit()
            }.onEnded { _ in dragging = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { _ in
                // Double-click flattens the whole curve.
                gains = gains.enumerated().map { $0.offset < 10 ? 0 : $0.element }; onEdit()
            })
        }
        .help("Drag a node up or down to boost or cut that band (±12 dB). Double-click to flatten.")
    }

    private func yFor(_ db: Float, _ h: CGFloat) -> CGFloat { h / 2 - CGFloat(db / range) * (h / 2 - 6) }
}
