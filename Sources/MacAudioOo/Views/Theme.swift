import SwiftUI

/// Visual tokens for the dark audio-console look.
enum Theme {
    static let bg = Color(red: 0.086, green: 0.090, blue: 0.098)
    static let panel = Color(red: 0.125, green: 0.130, blue: 0.141)
    static let panelRaised = Color(red: 0.165, green: 0.172, blue: 0.188)
    static let well = Color(red: 0.047, green: 0.050, blue: 0.055)
    static let border = Color.white.opacity(0.08)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let accent = Color(red: 0.20, green: 0.80, blue: 0.45)
    static let meterGreen = Color(red: 0.22, green: 0.85, blue: 0.40)
    static let meterYellow = Color(red: 0.97, green: 0.82, blue: 0.20)
    static let meterOrange = Color(red: 1.0, green: 0.50, blue: 0.12)
    static let record = Color(red: 0.95, green: 0.22, blue: 0.22)

    static let label = Font.system(size: 10, weight: .semibold, design: .rounded)
    static let value = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let title = Font.system(size: 13, weight: .bold, design: .rounded)
}

struct PanelStyle: ViewModifier {
    var recessed = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 8).fill(recessed ? Theme.well : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }
}

extension View {
    func panel(recessed: Bool = false) -> some View { modifier(PanelStyle(recessed: recessed)) }
}
