import SwiftUI

/// Scrolling waveform (8 s window around the playhead) with beat markers, loop region and hot-cue flags.
/// All data comes from the decoded file (WaveformData) and the deck's real position.
struct WaveformDetailView: View {
    @ObservedObject var deck: DJDeck
    private let window = 8.0

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(Theme.well))
            let mid = size.height / 2
            let start = deck.position - window / 2
            func x(_ t: Double) -> CGFloat { CGFloat((t - start) / window) * size.width }

            if let loop = deck.loop {
                let r = CGRect(x: x(loop.inTime), y: 0, width: max(2, x(loop.outTime) - x(loop.inTime)), height: size.height)
                ctx.fill(Path(r), with: .color((deck.loopActive ? Theme.meterYellow : Theme.textSecondary).opacity(0.18)))
            }
            if let w = deck.waveform {
                let cols = max(1, Int(size.width / 2))
                let data = w.columns(start: start, length: window, columns: cols)
                var p = Path()
                for (i, c) in data.enumerated() {
                    let px = CGFloat(i) * size.width / CGFloat(cols)
                    p.move(to: CGPoint(x: px, y: mid - CGFloat(min(1, c.max)) * mid))
                    p.addLine(to: CGPoint(x: px, y: mid - CGFloat(max(-1, c.min)) * mid))
                }
                ctx.stroke(p, with: .color(Theme.accent.opacity(0.9)), lineWidth: 1.6)
            } else if deck.isLoaded {
                ctx.draw(Text("Reading waveform…").font(.system(size: 10)).foregroundColor(Theme.textSecondary), at: CGPoint(x: size.width / 2, y: mid))
            }
            if let g = deck.grid {
                let first = Int(g.beatPosition(at: start).rounded(.up)), last = Int(g.beatPosition(at: start + window).rounded(.down))
                if first <= last {
                    for n in first...last {
                        let bx = x(g.time(ofBeat: n))
                        var l = Path(); l.move(to: CGPoint(x: bx, y: 0)); l.addLine(to: CGPoint(x: bx, y: size.height))
                        ctx.stroke(l, with: .color(.white.opacity(n % 4 == 0 ? 0.35 : 0.14)), lineWidth: 1)
                    }
                }
            }
            for (i, c) in deck.hotCues.enumerated() {
                guard let t = c, t >= start, t <= start + window else { continue }
                var f = Path(); f.move(to: CGPoint(x: x(t), y: 0)); f.addLine(to: CGPoint(x: x(t), y: size.height))
                ctx.stroke(f, with: .color(Theme.meterOrange), lineWidth: 1.5)
                ctx.draw(Text("\(i + 1)").font(.system(size: 8, weight: .bold)).foregroundColor(Theme.meterOrange), at: CGPoint(x: x(t) + 5, y: 6))
            }
            var head = Path(); head.move(to: CGPoint(x: size.width / 2, y: 0)); head.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            ctx.stroke(head, with: .color(.white), lineWidth: 2)
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
    }
}

/// Whole-track overview; click or drag to seek.
struct WaveformOverviewView: View {
    @ObservedObject var deck: DJDeck

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(Theme.well))
                let mid = size.height / 2
                if let w = deck.waveform, deck.duration > 0 {
                    let cols = max(1, Int(size.width))
                    let data = w.columns(start: 0, length: deck.duration, columns: cols)
                    var p = Path()
                    for (i, c) in data.enumerated() {
                        let px = CGFloat(i) * size.width / CGFloat(cols)
                        p.move(to: CGPoint(x: px, y: mid - CGFloat(min(1, c.max)) * mid))
                        p.addLine(to: CGPoint(x: px, y: mid - CGFloat(max(-1, c.min)) * mid))
                    }
                    ctx.stroke(p, with: .color(Theme.textSecondary.opacity(0.7)), lineWidth: 1)
                    let px = CGFloat(deck.position / deck.duration) * size.width
                    ctx.fill(Path(CGRect(x: 0, y: 0, width: px, height: size.height)), with: .color(Theme.accent.opacity(0.15)))
                    var head = Path(); head.move(to: CGPoint(x: px, y: 0)); head.addLine(to: CGPoint(x: px, y: size.height))
                    ctx.stroke(head, with: .color(.white), lineWidth: 2)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard deck.isLoaded, geo.size.width > 0 else { return }
                deck.seek(to: Double(v.location.x / geo.size.width) * deck.duration)
            })
        }
        .help("Click or drag to jump within the track")
    }
}
