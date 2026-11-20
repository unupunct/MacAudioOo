import AppKit
import Combine

/// Native menu bar item: master volume (slider + readout), mute, engine status, open and quit.
final class MenuBarController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let volumeLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let muteItem = NSMenuItem(title: "Mute", action: nil, keyEquivalent: "m")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private weak var engine: AudioEngine?
    private var bag = Set<AnyCancellable>()

    init(engine: AudioEngine) {
        self.engine = engine
        super.init()
        menu.delegate = self
        let title = NSMenuItem(title: "MacAudioOo", action: nil, keyEquivalent: ""); title.isEnabled = false
        menu.addItem(title)
        statusLine.isEnabled = false; menu.addItem(statusLine)
        menu.addItem(.separator())
        volumeLine.isEnabled = false; menu.addItem(volumeLine)
        slider.target = self; slider.action = #selector(sliderChanged(_:)); slider.isContinuous = true
        slider.frame = NSRect(x: 16, y: 4, width: 190, height: 22)
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 222, height: 30)); holder.addSubview(slider)
        let sliderItem = NSMenuItem(); sliderItem.view = holder; menu.addItem(sliderItem)
        muteItem.target = self; muteItem.action = #selector(toggleMute); muteItem.keyEquivalentModifierMask = []
        menu.addItem(muteItem)
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open MacAudioOo", action: #selector(openApp), keyEquivalent: "o"); open.target = self; menu.addItem(open)
        let quit = NSMenuItem(title: "Quit MacAudioOo", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        engine.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &bag)
    }

    /// Shows or hides the status item (Settings ▸ General ▸ Menu bar integration).
    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            i.menu = menu
            item = i
            refresh()
        } else if !visible, let i = item {
            NSStatusBar.system.removeStatusItem(i); item = nil
        }
    }

    func refresh() {
        guard let e = engine else { return }
        let db = e.masterVolumeDB
        volumeLine.title = "Master volume: " + (db <= -59.9 ? "-∞ dB" : String(format: "%+.1f dB", db)) + (e.masterMute ? " (muted)" : "")
        slider.doubleValue = Double(FaderTaper.position(forDB: db))
        muteItem.title = e.masterMute ? "Unmute" : "Mute"
        switch e.status {
        case .running(let d, let r): statusLine.title = "Engine running · \(d) · \(Int(r)) Hz"
        case .stopped: statusLine.title = "Engine stopped"
        case .failed(let m): statusLine.title = "Engine error: \(m)"
        }
        if let button = item?.button {
            let name = e.masterMute ? "speaker.slash.fill" : (e.status.isRunning ? "speaker.wave.2.fill" : "speaker.badge.exclamationmark.fill")
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: "MacAudioOo")
            button.toolTip = statusLine.title
        }
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    @objc private func sliderChanged(_ s: NSSlider) {
        engine?.masterVolumeDB = FaderTaper.db(forPosition: Float(s.doubleValue))
        volumeLine.title = "Master volume: " + (engine.map { $0.masterVolumeDB <= -59.9 ? "-∞ dB" : String(format: "%+.1f dB", $0.masterVolumeDB) } ?? "")
    }
    @objc private func toggleMute() { engine?.masterMute.toggle(); refresh() }
    @objc private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.canBecomeMain }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            NSWorkspace.shared.open(Bundle.main.bundleURL)          // relaunch request re-opens the main window
        }
    }
    @objc private func quitApp() { NSApp.terminate(nil) }
}
