import SwiftUI
import Combine

// MARK: - Fader taper (dB <-> position)

enum FaderTaper {
    /// Piecewise-linear taper: finer resolution around 0 dB, -60 dB at the bottom reads as -∞.
    static let points: [(pos: Float, db: Float)] = [(0, -60), (0.2, -40), (0.45, -20), (0.6, -10), (0.78, 0), (1, 6)]

    static func db(forPosition p: Float) -> Float {
        let x = min(1, max(0, p))
        for i in 1..<points.count where x <= points[i].pos {
            let a = points[i - 1], b = points[i]
            return a.db + (b.db - a.db) * (x - a.pos) / (b.pos - a.pos)
        }
        return points.last!.db
    }

    static func position(forDB d: Float) -> Float {
        let x = min(6, max(-60, d))
        for i in 1..<points.count where x <= points[i].db {
            let a = points[i - 1], b = points[i]
            return a.pos + (b.pos - a.pos) * (x - a.db) / (b.db - a.db)
        }
        return 1
    }
}

// MARK: - Meter model + hub

final class MeterModel: ObservableObject {
    @Published var levelDB: Float = -120      // displayed (smoothed) peak level
    @Published var holdDB: Float = -120       // peak-hold marker
    @Published var rmsDB: Float = -120
    @Published var grDB: Float = 0            // compressor gain reduction
    @Published var clipped = false            // latched until clicked
    private var holdUntil = Date.distantPast

    func update(peakDB: Float, rmsDB: Float, grDB: Float, dt: Float) {
        // Fast attack, 24 dB/s release.
        let fallen = levelDB - 24 * dt
        let newLevel = max(peakDB, fallen)
        if abs(newLevel - levelDB) > 0.05 { levelDB = newLevel }
        if peakDB >= holdDB {
            holdDB = peakDB; holdUntil = Date().addingTimeInterval(1.5)
        } else if Date() > holdUntil {
            let h = max(peakDB, holdDB - 20 * dt)
            if abs(h - holdDB) > 0.05 { holdDB = h }
        }
        if abs(rmsDB - self.rmsDB) > 0.1 { self.rmsDB = rmsDB }
        if abs(grDB - self.grDB) > 0.05 { self.grDB = grDB }
        if peakDB >= -0.1 && !clipped { clipped = true }
    }
    func resetClip() { clipped = false; holdDB = -120 }
}

/// Reads the engine's real meters at 30 Hz, only while the console is on screen.
final class MeterHub: ObservableObject {
    private var models: [UUID: MeterModel] = [:]
    let masterL = MeterModel(), masterR = MeterModel()
    private var timer: Timer?
    private weak var engine: AudioEngine?
    private var last = Date()

    func model(for channel: AudioChannel) -> MeterModel {
        if let m = models[channel.id] { return m }
        let m = MeterModel(); models[channel.id] = m; return m
    }

    func start(engine: AudioEngine) {
        self.engine = engine
        stop()
        last = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard let engine = engine else { return }
        let now = Date(); let dt = Float(now.timeIntervalSince(last)); last = now
        let alive = Set(engine.channels.map { $0.id })
        for k in models.keys where !alive.contains(k) { models[k] = nil }
        for ch in engine.channels {
            let m = ch.readMeter()
            model(for: ch).update(peakDB: m.peakDB, rmsDB: m.rmsDB, grDB: ch.readGainReduction(), dt: dt)
        }
        let mm = engine.masterMeter()
        masterL.update(peakDB: mm.peakL, rmsDB: mm.rmsDB, grDB: -mm.grDB, dt: dt)
        masterR.update(peakDB: mm.peakR, rmsDB: mm.rmsDB, grDB: -mm.grDB, dt: dt)
    }
}

// MARK: - Level meter

/// Recessed well with segmented green / yellow / orange LEDs, a peak-hold marker and a clip lamp.
struct LevelMeterView: View {
    @ObservedObject var model: MeterModel
    var width: CGFloat = 12
    var height: CGFloat = 170
    private let segments = 34
    private let minDB: Float = -60, maxDB: Float = 3

    var body: some View {
        VStack(spacing: 3) {
            Circle().fill(model.clipped ? Theme.record : Theme.well)
                .frame(width: width, height: 6)
                .overlay(Capsule().stroke(Theme.border))
                .onTapGesture { model.resetClip() }
                .help(model.clipped ? "Clipping occurred. Click to reset." : "Clip indicator")
            Canvas { ctx, size in
                let segH = size.height / CGFloat(segments)
                for i in 0..<segments {
                    let db = minDB + (maxDB - minDB) * Float(i) / Float(segments - 1)
                    let lit = model.levelDB >= db
                    let color: Color = db > -3 ? Theme.meterOrange : (db > -12 ? Theme.meterYellow : Theme.meterGreen)
                    let y = size.height - CGFloat(i + 1) * segH
                    let r = CGRect(x: 1, y: y + 0.75, width: size.width - 2, height: segH - 1.5)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(lit ? color : color.opacity(0.12)))
                }
                if model.holdDB > minDB {
                    let frac = CGFloat((min(model.holdDB, maxDB) - minDB) / (maxDB - minDB))
                    let y = size.height - frac * size.height
                    ctx.fill(Path(CGRect(x: 0, y: max(0, y - 1), width: size.width, height: 2)), with: .color(.white.opacity(0.85)))
                }
            }
            .frame(width: width, height: height)
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border))
        }
    }
}

// MARK: - Vertical fader (volume)

struct FaderView: View {
    @Binding var db: Float
    var height: CGFloat = 170
    private let capH: CGFloat = 30, capW: CGFloat = 30
    private let ticks: [(Float, String)] = [(6, "+6"), (0, "0"), (-10, "10"), (-20, "20"), (-30, "30"), (-40, "40"), (-60, "∞")]

    var body: some View {
        let travel = height - capH
        let pos = CGFloat(FaderTaper.position(forDB: db))
        ZStack(alignment: .top) {
            // Scale
            ForEach(ticks, id: \.0) { t in
                let y = capH / 2 + travel * (1 - CGFloat(FaderTaper.position(forDB: t.0)))
                HStack(spacing: 2) {
                    Text(t.1).font(.system(size: 8, design: .monospaced)).foregroundColor(Theme.textSecondary)
                        .frame(width: 16, alignment: .trailing)
                    Rectangle().fill(Theme.textSecondary.opacity(0.5)).frame(width: 5, height: 1)
                }
                .offset(x: -18, y: y - 5)
            }
            // Groove
            RoundedRectangle(cornerRadius: 2).fill(Theme.well)
                .frame(width: 5, height: height - 6).offset(y: 3)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.border).frame(width: 5, height: height - 6).offset(y: 3))
            // Cap
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.25)], startPoint: .top, endPoint: .bottom))
                .frame(width: capW, height: capH)
                .overlay(Rectangle().fill(Theme.accent).frame(width: capW - 8, height: 2))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.6)))
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .offset(y: travel * (1 - pos))
        }
        .frame(width: capW + 24, height: height, alignment: .top)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            let p = 1 - (v.location.y - capH / 2) / travel
            db = FaderTaper.db(forPosition: Float(p))
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded { db = 0 })
        .help("Drag to set volume. Double-click to reset to 0 dB.")
    }
}

// MARK: - Simple vertical slider (EQ bands)

struct VerticalSlider: View {
    @Binding var value: Float
    var range: ClosedRange<Float>
    var height: CGFloat = 90
    var defaultValue: Float = 0
    var onEdit: () -> Void = {}

    var body: some View {
        let frac = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.well).frame(width: 4, height: height)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.border))
            Rectangle().fill(Theme.border).frame(width: 12, height: 1).offset(y: height / 2)    // center tick
            RoundedRectangle(cornerRadius: 2).fill(Theme.accent)
                .frame(width: 14, height: 8)
                .offset(y: (1 - frac) * (height - 8))
        }
        .frame(width: 22, height: height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            let f = 1 - min(1, max(0, (v.location.y - 4) / (height - 8)))
            let nv = range.lowerBound + Float(f) * (range.upperBound - range.lowerBound)
            value = (nv * 2).rounded() / 2          // 0.5 dB steps
            onEdit()
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded { value = defaultValue; onEdit() })
    }
}

// MARK: - Rotary knob

struct KnobView: View {
    var title: String
    @Binding var value: Float
    var range: ClosedRange<Float>
    var defaultValue: Float
    var format: (Float) -> String = { String(format: "%.1f", $0) }
    var size: CGFloat = 32
    @State private var dragStart: Float? = nil
    @State private var showValue = false

    var body: some View {
        let frac = Double((value - range.lowerBound) / (range.upperBound - range.lowerBound))
        let angle = Angle(degrees: -135 + 270 * frac)
        VStack(spacing: 2) {
            ZStack {
                Circle().trim(from: 0, to: 0.75).stroke(Theme.well, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135)).frame(width: size + 6, height: size + 6)
                Circle().trim(from: 0, to: 0.75 * CGFloat(frac)).stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135)).frame(width: size + 6, height: size + 6)
                Circle().fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.18)], startPoint: .top, endPoint: .bottom))
                    .frame(width: size, height: size)
                    .overlay(Circle().stroke(Color.black.opacity(0.6)))
                Capsule().fill(Color.white.opacity(0.9)).frame(width: 2, height: size * 0.32)
                    .offset(y: -size * 0.27).rotationEffect(angle)
            }
            .frame(width: size + 8, height: size + 8)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                if dragStart == nil { dragStart = value }
                showValue = true
                let span = range.upperBound - range.lowerBound
                let nv = (dragStart ?? value) - Float(v.translation.height) / 140 * span
                value = min(range.upperBound, max(range.lowerBound, nv))
            }.onEnded { _ in dragStart = nil; showValue = false })
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = defaultValue })
            Text(showValue ? format(value) : title)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundColor(showValue ? Theme.accent : Theme.textSecondary)
                .frame(height: 10)
        }
        .help("\(title): \(format(value)). Drag up/down to change, double-click to reset.")
    }
}

// MARK: - Buttons

struct ConsoleButton: View {
    var title: String
    @Binding var isOn: Bool
    var onColor: Color = Theme.accent
    var width: CGFloat = 36
    var help: String = ""

    var body: some View {
        Button(action: { isOn.toggle() }) {
            Text(title).font(.system(size: 9, weight: .heavy, design: .rounded))
                .frame(width: width, height: 20)
                .foregroundColor(isOn ? .black : Theme.textSecondary)
                .background(RoundedRectangle(cornerRadius: 4).fill(isOn ? onColor : Theme.panelRaised))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

func dbText(_ db: Float) -> String { db <= -59.9 ? "-∞" : String(format: "%+.1f", db) }
