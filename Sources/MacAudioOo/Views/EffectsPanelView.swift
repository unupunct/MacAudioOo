import SwiftUI

/// Shared REVERB and DELAY effects. Both feed the master bus; each channel's REV / DLY knob
/// sets how much of that channel is sent to them.
struct EffectsPanelView: View {
    @ObservedObject var engine: AudioEngine

    var body: some View {
        VStack(spacing: 10) {
            Text("EFFECTS").font(Theme.label).foregroundColor(Theme.textSecondary)
            effectBox(title: "REVERB",
                      enabled: Binding(get: { engine.reverb.enabled != 0 }, set: { engine.reverb.enabled = $0 ? 1 : 0 })) {
                knob("RETURN", Binding(get: { engine.reverb.returnLevel }, set: { engine.reverb.returnLevel = $0 }), 0...1, 0.5, { String(format: "%.0f%%", $0 * 100) })
                knob("ROOM", Binding(get: { engine.reverb.roomSize }, set: { engine.reverb.roomSize = $0 }), 0...1, 0.5, { String(format: "%.0f%%", $0 * 100) })
                knob("DECAY", Binding(get: { engine.reverb.decaySeconds }, set: { engine.reverb.decaySeconds = $0 }), 0.2...8, 1.8, { String(format: "%.1f s", $0) })
                knob("TONE", Binding(get: { engine.reverb.tone }, set: { engine.reverb.tone = $0 }), 0...1, 0.6, { String(format: "%.0f%%", $0 * 100) })
            }
            effectBox(title: "DELAY",
                      enabled: Binding(get: { engine.delay.enabled != 0 }, set: { engine.delay.enabled = $0 ? 1 : 0 })) {
                knob("RETURN", Binding(get: { engine.delay.returnLevel }, set: { engine.delay.returnLevel = $0 }), 0...1, 0.5, { String(format: "%.0f%%", $0 * 100) })
                knob("TIME", Binding(get: { engine.delay.timeMs }, set: { engine.delay.timeMs = $0 }), 10...1500, 350, { String(format: "%.0f ms", $0) })
                knob("FDBK", Binding(get: { engine.delay.feedback }, set: { engine.delay.feedback = $0 }), 0...0.85, 0.35, { String(format: "%.0f%%", $0 * 100) })
                knob("TONE", Binding(get: { engine.delay.tone }, set: { engine.delay.tone = $0 }), 0...1, 0.6, { String(format: "%.0f%%", $0 * 100) })
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 190)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    private func knob(_ title: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, _ def: Float,
                      _ fmt: @escaping (Float) -> String) -> some View {
        KnobView(title: title, value: value, range: range, defaultValue: def, format: fmt, size: 26)
    }

    private func effectBox<C: View>(title: String, enabled: Binding<Bool>, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(Theme.title).foregroundColor(Theme.textPrimary)
                Spacer()
                ConsoleButton(title: "ON", isOn: enabled, width: 30, help: "Enable \(title.lowercased())")
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) { content() }
                .opacity(enabled.wrappedValue ? 1 : 0.45)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.well.opacity(0.6)))
    }
}
