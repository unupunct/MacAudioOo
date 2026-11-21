import SwiftUI

extension Color {
    /// 0xRRGGBB
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// Visual tokens: deep navy glass panels, cyan accents, blue glow faders, metallic knobs.
enum Theme {
    // Backgrounds
    static let bg = Color(hex: 0x0A101A)
    static let bgTop = Color(hex: 0x111C30)
    static let panel = Color(hex: 0x172134)
    static let panelTop = Color(hex: 0x213049)
    static let panelBottom = Color(hex: 0x121A2A)
    static let panelRaised = Color(hex: 0x24324B)
    static let well = Color(hex: 0x070C14)
    static let border = Color(hex: 0x86A8E6, opacity: 0.18)
    static let borderStrong = Color(hex: 0x86A8E6, opacity: 0.32)

    // Text
    static let textPrimary = Color(hex: 0xEAF2FF)
    static let textSecondary = Color(hex: 0x8DA1BF)
    static let textMuted = Color(hex: 0x5C6E8A)

    // Accents
    static let cyan = Color(hex: 0x2BD4F3)
    static let accent = cyan
    static let blue = Color(hex: 0x2F8CFF)
    static let blueDeep = Color(hex: 0x1D5FD6)
    static let sidebarActive = Color(hex: 0x2F6FEA)

    // Meters and states
    static let meterGreen = Color(hex: 0x35D45A)
    static let meterYellow = Color(hex: 0xF3D23A)
    static let meterOrange = Color(hex: 0xFF8A2A)
    static let record = Color(hex: 0xE5484D)

    // Buttons
    static let buttonTop = Color(hex: 0x2D384D)
    static let buttonBottom = Color(hex: 0x1B2435)

    // Type
    static let label = Font.system(size: 10, weight: .bold, design: .rounded)
    static let value = Font.system(size: 12, weight: .semibold, design: .monospaced)
    static let title = Font.system(size: 14, weight: .bold, design: .rounded)
    static let heading = Font.system(size: 19, weight: .bold, design: .rounded)

    /// Pad / track colours (hot-cue pads, recording tracks).
    static let padColors: [Color] = [Color(hex: 0xE5484D), Color(hex: 0xF08A2E), Color(hex: 0xE5C03A), Color(hex: 0x3A78F0),
                                     Color(hex: 0x2FBF6F), Color(hex: 0x8B5CF6), Color(hex: 0x22B5C9), Color(hex: 0xB04FE0)]
}

/// Glass card: vertical navy gradient, hairline border, optional cyan glow when highlighted.
struct GlassCard: ViewModifier {
    var radius: CGFloat = 16
    var highlighted = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [Theme.panelTop, Theme.panelBottom], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(highlighted ? Theme.cyan : Theme.border, lineWidth: highlighted ? 1.6 : 1))
            .shadow(color: highlighted ? Theme.cyan.opacity(0.35) : Color.black.opacity(0.35), radius: highlighted ? 8 : 4, y: 1)
    }
}

struct PanelStyle: ViewModifier {
    var recessed = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(recessed ? Theme.well : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

extension View {
    func glassCard(radius: CGFloat = 16, highlighted: Bool = false) -> some View { modifier(GlassCard(radius: radius, highlighted: highlighted)) }
    func panel(recessed: Bool = false) -> some View { modifier(PanelStyle(recessed: recessed)) }
}
