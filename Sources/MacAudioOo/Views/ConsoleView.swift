import SwiftUI

/// The CONSOLE tab: horizontally scrolling channel strips, shared effects, master channel
/// and a detail panel for the selected channel's EQ and compressor.
struct ConsoleView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var hub = MeterHub()
    @State private var selection: Selection = .none
    @State private var showDetail = true
    @State private var toneCount = 0

    enum Selection: Equatable { case none, channel(UUID), master }

    var body: some View {
        let engine = state.engine
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 6) {
                    toolbar(engine)
                    if engine.channels.isEmpty { emptyState } else { strips(engine) }
                }
                EffectsPanelView(engine: engine)
                MasterChannelView(engine: engine, hub: hub, isSelected: selection == .master,
                                  onSelectEQ: { selection = selection == .master ? .none : .master })
            }
            if showDetail { detail(engine) }
        }
        .padding(10)
        .onAppear {
            hub.start(engine: engine)
            // Snapshot tool support (see SnapshotTool): preselect the first channel.
            if CommandLine.arguments.contains("--select-first") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if let c = engine.channels.first { selection = .channel(c.id) }
                }
            }
        }
        .onDisappear { hub.stop() }
    }

    private func toolbar(_ engine: AudioEngine) -> some View {
        HStack(spacing: 8) {
            Text("CHANNELS").font(Theme.label).foregroundColor(Theme.textSecondary)
            Text("\(engine.channels.count)").font(Theme.value).foregroundColor(Theme.textPrimary)
            Spacer()
            Menu {
                Button("Generated test tone (diagnostic)") { addTone() }
                    .disabled(!engine.status.isRunning)
                Divider()
                Text("Application channels appear automatically once a capture backend is active.")
            } label: {
                Label("Add Channel", systemImage: "plus")
            }.frame(width: 130)
            Button(showDetail ? "Hide detail" : "Show detail") { showDetail.toggle() }
        }
    }

    private func strips(_ engine: AudioEngine) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(engine.channels) { ch in
                    ChannelStripView(channel: ch, meter: hub.model(for: ch), isSelected: selection == .channel(ch.id),
                                     onSelect: { selection = selection == .channel(ch.id) ? .none : .channel(ch.id) },
                                     onRemove: { if selection == .channel(ch.id) { selection = .none }; engine.removeChannel(ch) })
                }
            }
            .padding(.bottom, 6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.vertical.3").font(.system(size: 28)).foregroundColor(Theme.textSecondary)
            Text("No channels yet").font(Theme.title).foregroundColor(Theme.textPrimary)
            Text(emptyExplanation).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panel()
    }

    private var emptyExplanation: String {
        if state.preferredBackend != nil {
            return "Applications appear here when they play audio. If an application does not show up, check Settings ▸ Audio."
        }
        return "This macOS version (\(OSVersion.current.description)) cannot capture individual applications without the optional MacAudioOo driver. See Settings ▸ Audio, or use Add Channel to try a generated test tone."
    }

    @ViewBuilder
    private func detail(_ engine: AudioEngine) -> some View {
        Group {
            switch selection {
            case .none:
                Text("Select a channel (click a strip, or its EQ button) to edit its EQ and compressor, or MASTER ▸ EQ for the master EQ.")
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            case .channel(let id):
                if let ch = engine.channels.first(where: { $0.id == id }) {
                    HStack(alignment: .top, spacing: 24) {
                        EQEditorView(title: "EQ — " + ch.name, gains: Binding(get: { ch.eqGains }, set: { ch.eqGains = $0 }),
                                     bypass: Binding(get: { ch.eqBypass }, set: { ch.eqBypass = $0 }),
                                     presetName: Binding(get: { ch.eqPresetName }, set: { ch.eqPresetName = $0 }),
                                     applyPreset: { ch.applyEQPreset($0) }, response: { ch.dsp.eq.responseDB(at: $0) })
                        Divider().overlay(Theme.border)
                        CompressorEditorView(channel: ch, meter: hub.model(for: ch))
                        Spacer(minLength: 0)
                    }
                    .id(ch.id)
                } else {
                    Text("Channel closed.").foregroundColor(Theme.textSecondary).frame(maxWidth: .infinity, minHeight: 60)
                }
            case .master:
                HStack(alignment: .top) {
                    EQEditorView(title: "MASTER EQ", gains: Binding(get: { engine.masterEQGains }, set: { engine.masterEQGains = $0 }),
                                 bypass: Binding(get: { engine.masterEQBypass }, set: { engine.masterEQBypass = $0 }),
                                 presetName: Binding(get: { engine.masterEQPresetName }, set: { engine.masterEQPresetName = $0 }),
                                 applyPreset: { engine.applyMasterEQPreset($0) }, response: { engine.masterEQ.responseDB(at: $0) })
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 190)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    private func addTone() {
        let freqs: [Float] = [220, 330, 440, 660, 880]
        let f = freqs[toneCount % freqs.count]; toneCount += 1
        let src = ToneSource(frequency: f, amplitude: 0.25, sampleRate: Float(state.engine.sampleRate))
        if let ch = state.engine.addChannel(name: "Test tone \(Int(f)) Hz", source: src) { selection = .channel(ch.id) }
    }
}
