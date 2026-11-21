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

/// Reads the engine's real meters at 30 Hz, only while a meter view is on screen.
final class MeterHub: ObservableObject {
    private var models: [UUID: MeterModel] = [:]
    let masterL = MeterModel(), masterR = MeterModel()
    private var timer: Timer?
    private weak var engine: AudioEngine?
    private var last = Date()
    private var users = 0

    func model(for channel: AudioChannel) -> MeterModel {
        if let m = models[channel.id] { return m }
        let m = MeterModel(); models[channel.id] = m; return m
    }

    func start(engine: AudioEngine) {
        self.engine = engine
        users += 1
        guard timer == nil else { return }
        last = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
    }
    func stop() {
        users = max(0, users - 1)
        if users == 0 { timer?.invalidate(); timer = nil }
    }

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

/// Slim segmented meter (green / yellow / orange) in a recessed well; the top segment turns red after a clip.
struct LevelMeterView: View {
    @ObservedObject var model: MeterModel
    var width: CGFloat = 8
    var height: CGFloat = 170
    var segments = 28
    private let minDB: Float = -60, maxDB: Float = 3

    var body: some View {
        Canvas { ctx, size in
            let segH = size.height / CGFloat(segments)
            for i in 0..<segments {
                let db = minDB + (maxDB - minDB) * Float(i) / Float(segments - 1)
                let lit = model.levelDB >= db
                var color: Color = db > -3 ? Theme.meterOrange : (db > -12 ? Theme.meterYellow : Theme.meterGreen)
                if i == segments - 1 && model.clipped { color = Theme.record }
                let y = size.height - CGFloat(i + 1) * segH
                let r = CGRect(x: 0, y: y + 0.6, width: size.width, height: max(1, segH - 1.4))
                ctx.fill(Path(roundedRect: r, cornerRadius: 1), with: .color(lit || (i == segments - 1 && model.clipped) ? color : color.opacity(0.10)))
            }
        }
        .frame(width: width, height: height)
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.well))
        .onTapGesture { model.resetClip() }
        .help(model.clipped ? "Clipping occurred. Click to reset." : "Level meter")
    }
}

// MARK: - Vertical fader (volume)

/// Vertical fader core: a scale on the left, a recessed groove with a glowing blue fill below the cap, and a silver cap.
/// `position` is 0 (bottom) ... 1 (top); `ticks` are (position, label).
struct FaderCore: View {
    @Binding var position: Float
    var height: CGFloat = 170
    var ticks: [(Float, String)]
    var resetPosition: Float
    var showScale = true
    var capW: CGFloat = 36
    private let capH: CGFloat = 22

    var body: some View {
        let travel = height - capH
        let capY = travel * (1 - CGFloat(position))
        let scaleW: CGFloat = showScale ? 36 : 0
        ZStack(alignment: .topLeading) {
            if showScale {
                ForEach(ticks, id: \.0) { t in
                    let y = capH / 2 + travel * (1 - CGFloat(t.0))
                    HStack(spacing: 3) {
                        Text(t.1).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(Theme.textSecondary)
                            .frame(width: 24, alignment: .trailing)
                        Rectangle().fill(Theme.textMuted).frame(width: 6, height: 1)
                    }
                    .offset(x: 0, y: y - 6)
                }
            }
            let gx = scaleW + capW / 2 - 3
            RoundedRectangle(cornerRadius: 3).fill(Theme.well)
                .frame(width: 6, height: height - 8).offset(x: gx, y: 4)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border).frame(width: 6, height: height - 8).offset(x: gx, y: 4))
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: [Theme.blue, Theme.blueDeep], startPoint: .top, endPoint: .bottom))
                .frame(width: 4, height: max(0, height - 8 - capY - capH / 2)).offset(x: gx + 1, y: capY + capH / 2)
                .shadow(color: Theme.blue.opacity(0.85), radius: 4)
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(colors: [Color(hex: 0xF1F4F9), Color(hex: 0xA9B2C1), Color(hex: 0x717B8E)], startPoint: .top, endPoint: .bottom))
                .frame(width: capW, height: capH)
                .overlay(Capsule().fill(Theme.cyan).frame(width: capW - 12, height: 3).shadow(color: Theme.cyan.opacity(0.9), radius: 3))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.black.opacity(0.55), lineWidth: 1))
                .shadow(color: .black.opacity(0.55), radius: 3, y: 2)
                .offset(x: scaleW, y: capY)
        }
        .frame(width: scaleW + capW, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            position = Float(min(1, max(0, 1 - (v.location.y - capH / 2) / travel)))
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded { position = resetPosition })
    }
}

/// Channel volume fader in dB (taper: -∞ ... +6 dB, unity near the top). Double-click resets to 0 dB.
struct FaderView: View {
    @Binding var db: Float
    var height: CGFloat = 170
    var showScale = true
    var ticks: [(Float, String)] = [(0, "0"), (-6, "-6"), (-12, "-12"), (-24, "-24"), (-60, "-∞")]
    var capW: CGFloat = 36

    var body: some View {
        FaderCore(position: Binding(get: { FaderTaper.position(forDB: db) }, set: { db = FaderTaper.db(forPosition: $0) }),
                  height: height, ticks: ticks.map { (FaderTaper.position(forDB: $0.0), $0.1) },
                  resetPosition: FaderTaper.position(forDB: 0), showScale: showScale, capW: capW)
            .help("Drag to set volume. Double-click to reset to 0 dB.")
    }
}

/// Master volume fader in percent of full scale (100 % = 0 dB). Linear in amplitude, like a system volume slider.
struct PercentFaderView: View {
    @Binding var percent: Float
    var height: CGFloat = 170
    var ticks: [(Float, String)] = [(1, "100"), (0.8, "80"), (0.6, "60"), (0.4, "40"), (0.2, "20"), (0, "0")]

    var body: some View {
        FaderCore(position: Binding(get: { percent / 100 }, set: { percent = ($0 * 100).rounded() }),
                  height: height, ticks: ticks, resetPosition: 1, capW: 40)
            .help("Drag to set the master volume. Double-click for 100 %.")
    }
}

// MARK: - Simple vertical slider (tempo faders etc.)

struct VerticalSlider: View {
    @Binding var value: Float
    var range: ClosedRange<Float>
    var height: CGFloat = 90
    var defaultValue: Float = 0
    var step: Float = 0.5
    var onEdit: () -> Void = {}

    var body: some View {
        let frac = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
        let capH: CGFloat = 20
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.well).frame(width: 5, height: height)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.border))
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(colors: [Color(hex: 0xF1F4F9), Color(hex: 0xA9B2C1), Color(hex: 0x717B8E)], startPoint: .top, endPoint: .bottom))
                .frame(width: 34, height: capH)
                .overlay(Capsule().fill(Theme.cyan).frame(width: 22, height: 3).shadow(color: Theme.cyan.opacity(0.9), radius: 3))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.black.opacity(0.55)))
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .offset(y: (1 - frac) * (height - capH))
        }
        .frame(width: 36, height: height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            let f = 1 - min(1, max(0, (v.location.y - capH / 2) / (height - capH)))
            let nv = range.lowerBound + Float(f) * (range.upperBound - range.lowerBound)
            value = (nv / step).rounded() * step
            onEdit()
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded { value = defaultValue; onEdit() })
    }
}

// MARK: - Rotary knob

/// Metallic knob with a cyan pointer. Title above, value below (always shown). Drag up/down; double-click resets.
struct KnobView: View {
    var title: String
    @Binding var value: Float
    var range: ClosedRange<Float>
    var defaultValue: Float
    var format: (Float) -> String = { String(format: "%.1f", $0) }
    var size: CGFloat = 38
    var showTitle = true
    var dimmed = false
    @State private var dragStart: Float? = nil

    var body: some View {
        let frac = Double((value - range.lowerBound) / (range.upperBound - range.lowerBound))
        let angle = Angle(degrees: -135 + 270 * frac)
        VStack(spacing: 4) {
            if showTitle {
                Text(title).font(.system(size: 9, weight: .bold, design: .rounded)).kerning(0.6)
                    .foregroundColor(Theme.textSecondary).lineLimit(1).fixedSize()
            }
            ZStack {
                Circle().fill(Color.black.opacity(0.55)).frame(width: size + 4, height: size + 4).blur(radius: 2).offset(y: 2)
                Circle().fill(RadialGradient(colors: [Color(hex: 0xF6F8FB), Color(hex: 0xBDC4D0), Color(hex: 0x6C7588)],
                                             center: UnitPoint(x: 0.36, y: 0.28), startRadius: 1, endRadius: size * 0.85))
                    .frame(width: size, height: size)
                Circle().stroke(Color.black.opacity(0.5), lineWidth: 1).frame(width: size, height: size)
                Circle().stroke(Color.white.opacity(0.35), lineWidth: 1).frame(width: size - 3, height: size - 3)
                Capsule().fill(Theme.cyan).frame(width: 3, height: size * 0.30).shadow(color: Theme.cyan.opacity(0.9), radius: 2.5)
                    .offset(y: -size * 0.29).rotationEffect(angle)
            }
            .frame(width: size + 6, height: size + 6)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                if dragStart == nil { dragStart = value }
                let span = range.upperBound - range.lowerBound
                let nv = (dragStart ?? value) - Float(v.translation.height) / 140 * span
                value = min(range.upperBound, max(range.lowerBound, nv))
            }.onEnded { _ in dragStart = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = defaultValue })
            Text(format(value)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.textPrimary).lineLimit(1).fixedSize().frame(height: 12)
        }
        .opacity(dimmed ? 0.4 : 1)
        .help("\(title): \(format(value)). Drag up/down to change, double-click to reset.")
    }
}

// MARK: - Buttons and switches

struct ConsoleButton: View {
    var title: String
    @Binding var isOn: Bool
    var onColor: Color = Theme.cyan
    var width: CGFloat = 36
    var help: String = ""

    var body: some View {
        Button(action: { isOn.toggle() }) {
            Text(title).font(.system(size: 10, weight: .heavy, design: .rounded))
                .frame(width: width, height: 22)
                .foregroundColor(isOn ? Color(hex: 0x06101C) : Theme.textSecondary)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isOn ? AnyShapeStyle(onColor) : AnyShapeStyle(LinearGradient(colors: [Theme.buttonTop, Theme.buttonBottom], startPoint: .top, endPoint: .bottom))))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(isOn ? onColor.opacity(0.9) : Theme.borderStrong, lineWidth: 1))
                .shadow(color: isOn ? onColor.opacity(0.45) : .clear, radius: 4)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Lightweight push button (plain style, no AppKit button measurement): used where many buttons are nested in deep
/// stacks, where standard NSButton-backed controls made SwiftUI layout take minutes.
struct PlainButton: View {
    var title: String? = nil
    var systemImage: String? = nil
    var width: CGFloat? = nil
    var height: CGFloat = 26
    var tint: Color? = nil
    var cornerRadius: CGFloat = 8
    var action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let i = systemImage { Image(systemName: i).font(.system(size: 12, weight: .bold)) }
                if let t = title { Text(t).font(.system(size: 11, weight: .bold, design: .rounded)).lineLimit(1) }
            }
            .foregroundColor(Theme.textPrimary)
            .padding(.horizontal, width == nil ? 12 : 0)
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(LinearGradient(colors: [Theme.buttonTop, Theme.buttonBottom], startPoint: .top, endPoint: .bottom))))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Theme.borderStrong, lineWidth: 1))
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }
}

/// Capsule on/off switch (white knob), as used for On/Off, EQ ON, Mono, Recall safe, Ducks others.
struct ToggleSwitch: View {
    @Binding var isOn: Bool
    var onColor: Color = Color(hex: 0x4A6A86)
    var body: some View {
        Button(action: { withAnimation(.easeOut(duration: 0.12)) { isOn.toggle() } }) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? onColor : Color(hex: 0x1E2738)).frame(width: 40, height: 22)
                    .overlay(Capsule().stroke(Theme.borderStrong, lineWidth: 1))
                Circle().fill(LinearGradient(colors: [.white, Color(hex: 0xC7CEDA)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 18, height: 18).padding(2).shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Custom-drawn linear horizontal slider (no NSSlider): drag to set, double-click to reset. Blue glowing fill.
struct LinearHSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var width: CGFloat = 90
    var defaultValue: Double? = nil
    private let capW: CGFloat = 26, capH: CGFloat = 20

    var body: some View {
        let travel = width - capW
        let frac = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.well).frame(width: width, height: 5)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.border))
            Capsule().fill(LinearGradient(colors: [Theme.blueDeep, Theme.blue], startPoint: .leading, endPoint: .trailing))
                .frame(width: travel * frac + capW / 2, height: 3).offset(x: 1).shadow(color: Theme.blue.opacity(0.8), radius: 3)
            RoundedRectangle(cornerRadius: 5)
                .fill(LinearGradient(colors: [Color(hex: 0xF1F4F9), Color(hex: 0xA9B2C1), Color(hex: 0x717B8E)], startPoint: .top, endPoint: .bottom))
                .frame(width: capW, height: capH)
                .overlay(Capsule().fill(Theme.cyan).frame(width: 3, height: capH - 8).shadow(color: Theme.cyan.opacity(0.9), radius: 3))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.black.opacity(0.55)))
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .offset(x: travel * frac)
        }
        .frame(width: width, height: capH)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            let f = Double(min(1, max(0, (v.location.x - capW / 2) / travel)))
            value = range.lowerBound + f * (range.upperBound - range.lowerBound)
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded { if let d = defaultValue { value = d } })
    }
}

func dbText(_ db: Float) -> String { db <= -59.9 ? "-∞" : String(format: "%+.1f", db) }
