import SwiftUI
import AppKit

// MARK: - Window chrome

/// Dark, full-size-content window: transparent title bar so the app's own navigation runs under the traffic lights.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { Self.configure(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { DispatchQueue.main.async { Self.configure(v.window) } }
    static func configure(_ w: NSWindow?) {
        guard let w = w else { return }
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.styleMask.insert(.fullSizeContentView)
        w.isMovableByWindowBackground = true
        w.backgroundColor = NSColor(srgbRed: 10 / 255, green: 16 / 255, blue: 26 / 255, alpha: 1)
        w.appearance = NSAppearance(named: .darkAqua)
        // First appearance: open at a roomy size (the reference layout needs ~1440 x 900), clamped to the screen.
        if !sized, let screen = w.screen ?? NSScreen.main {
            sized = true
            let vis = screen.visibleFrame
            let size = NSSize(width: min(1440, vis.width), height: min(900, vis.height))
            if w.frame.width < size.width - 1 || w.frame.height < size.height - 1 {
                w.setContentSize(NSSize(width: size.width, height: size.height - 28))
                w.setFrameOrigin(NSPoint(x: vis.minX + (vis.width - size.width) / 2, y: vis.minY + (vis.height - size.height) / 2))
            }
        }
    }
    private static var sized = false
}

// MARK: - MacAudioOo logo (original mark: LED meter columns with a fader cap)

struct LogoMark: View {
    var size: CGFloat = 36
    var body: some View {
        Canvas { ctx, s in
            let u = s.width / 100
            let body = Path(roundedRect: CGRect(x: 4 * u, y: 4 * u, width: 92 * u, height: 92 * u), cornerRadius: 22 * u)
            ctx.fill(body, with: .linearGradient(Gradient(colors: [Color(hex: 0x3A465E), Color(hex: 0x141B2A)]),
                                                 startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: s.height)))
            ctx.stroke(body, with: .color(.white.opacity(0.18)), lineWidth: max(1, u))
            let heights = [9, 14, 11, 16, 7]
            let colW = 11 * u, gap = 4.5 * u, segH = 3.1 * u, segGap = 1.1 * u
            let totalW = 5 * colW + 4 * gap
            let x0 = (s.width - totalW) / 2, yBase = 82 * u
            for c in 0..<5 {
                let x = x0 + CGFloat(c) * (colW + gap)
                for i in 0..<18 {
                    let lit = i < heights[c]
                    let col: Color = i >= 15 ? Theme.meterOrange : (i >= 11 ? Theme.meterYellow : Theme.meterGreen)
                    let y = yBase - CGFloat(i + 1) * (segH + segGap)
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: colW, height: segH), cornerRadius: u),
                             with: .color(lit ? col : col.opacity(0.14)))
                }
            }
            let cx = x0 + 2 * (colW + gap) + colW / 2
            let cap = Path(roundedRect: CGRect(x: cx - 12 * u, y: 46 * u, width: 24 * u, height: 11 * u), cornerRadius: 3 * u)
            ctx.fill(cap, with: .linearGradient(Gradient(colors: [Color(hex: 0xF1F4F9), Color(hex: 0x717B8E)]),
                                                startPoint: CGPoint(x: 0, y: 46 * u), endPoint: CGPoint(x: 0, y: 57 * u)))
            ctx.fill(Path(CGRect(x: cx - 8 * u, y: 51 * u, width: 16 * u, height: 1.6 * u)), with: .color(Theme.cyan))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Dropdown (popover list instead of NSPopUpButton: cheap to lay out)

struct DropdownField: View {
    var label: String
    var items: [(id: String, title: String)]
    var width: CGFloat? = nil
    var systemImage: String? = nil
    var height: CGFloat = 32
    var onSelect: (String) -> Void
    @State private var open = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: { open.toggle() }) {
            HStack(spacing: 8) {
                if let i = systemImage { Image(systemName: i).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textSecondary) }
                Text(label).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 12).frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [Theme.buttonTop, Theme.buttonBottom], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.borderStrong, lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(items, id: \.id) { item in
                    Button(action: { open = false; onSelect(item.id) }) {
                        HStack {
                            Text(item.title).font(.system(size: 12, weight: .medium)).foregroundColor(Theme.textPrimary)
                            Spacer(minLength: 12)
                            if item.title == label { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.cyan) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6).frame(minWidth: max(180, width ?? 0))
            .background(Theme.panel)
        }
    }
}

// MARK: - Top navigation bar

struct NavBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var recorder: RecordingEngine
    var tabs: [AppTab] = AppTab.allCases.filter { $0 != .settings } + [.settings]

    var body: some View {
        HStack(spacing: 6) {
            LogoMark(size: 34).padding(.leading, 78).padding(.trailing, 6)
            ForEach(tabs) { tab in
                Button(action: { settings.selectedTab = tab }) {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon).font(.system(size: 12, weight: .semibold))
                        Text(tab.title).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1).fixedSize()
                    }
                    .foregroundColor(settings.selectedTab == tab ? Theme.cyan : Theme.textSecondary)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(settings.selectedTab == tab ? Theme.cyan.opacity(0.10) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(settings.selectedTab == tab ? Theme.cyan : Color.clear, lineWidth: 1.5))
                    .shadow(color: settings.selectedTab == tab ? Theme.cyan.opacity(0.5) : .clear, radius: 5)
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 8)
            if recorder.state != .idle {
                HStack(spacing: 6) {
                    Circle().fill(Theme.record).frame(width: 8, height: 8)
                    Text((recorder.state == .paused ? "PAUSED " : "REC ") + String(timeString(recorder.elapsed).prefix(8)))
                        .font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(Theme.record).lineLimit(1).fixedSize()
                }
                .padding(.horizontal, 12).frame(height: 28)
                .overlay(Capsule().stroke(Theme.record, lineWidth: 1.5))
                .padding(.trailing, 4)
            }
            EngineStatusPill()
            OutputPicker()
        }
        .padding(.horizontal, 16).padding(.trailing, 4)
        .frame(height: 56)
        .background(LinearGradient(colors: [Color(hex: 0x16213A), Color(hex: 0x0E1626)], startPoint: .top, endPoint: .bottom))
        .overlay(Rectangle().fill(Theme.border).frame(height: 1), alignment: .bottom)
    }
}

// MARK: - Sidebar (logo + quick navigation)

struct SidebarView: View {
    @EnvironmentObject var settings: AppSettings
    let quick: [AppTab] = [.eq, .recording, .presets]

    var body: some View {
        VStack(spacing: 14) {
            LogoMark(size: 118).padding(.top, 14).shadow(color: Theme.cyan.opacity(0.25), radius: 14)
            VStack(spacing: 4) {
                Text("MacAudioOo").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundColor(Theme.textPrimary)
                Text("macOS AUDIO MIXER").font(.system(size: 9, weight: .bold, design: .rounded)).kerning(2.2).foregroundColor(Theme.textSecondary)
            }
            .padding(.bottom, 8)
            ForEach(quick) { tab in
                let active = settings.selectedTab == tab
                Button(action: { settings.selectedTab = active ? .console : tab }) {
                    HStack(spacing: 10) {
                        Image(systemName: tab.icon).font(.system(size: 14, weight: .semibold))
                        Text(tab.title).font(.system(size: 15, weight: .bold, design: .rounded))
                        Spacer()
                    }
                    .foregroundColor(.white).padding(.horizontal, 16).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(active ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x3B82FF), Theme.sidebarActive], startPoint: .top, endPoint: .bottom))
                                     : AnyShapeStyle(LinearGradient(colors: [Theme.buttonTop, Theme.buttonBottom], startPoint: .top, endPoint: .bottom))))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(active ? Theme.cyan.opacity(0.6) : Theme.borderStrong, lineWidth: 1))
                    .shadow(color: active ? Theme.blue.opacity(0.5) : .clear, radius: 6)
                }.buttonStyle(.plain).padding(.horizontal, 14)
            }
            Spacer()
        }
        .frame(width: 236)
    }
}
