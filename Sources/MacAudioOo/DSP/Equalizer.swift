import Foundation

/// 10-band graphic EQ (31.5 Hz … 16 kHz, peaking, Q ≈ 1.41 = one octave) plus a 3-band
/// tone section (LOW shelf 100 Hz, MID peak 1 kHz, HIGH shelf 8 kHz) used by the channel
/// strip knobs. All 13 filters are cascaded stereo biquads (transposed direct form II).
///
/// Threading: the UI calls `set(...)`, which computes coefficients on the UI thread into a
/// pending block and flips a flag; the real-time `process` copies the block at the start of
/// its next call. No allocation, no locks on the real-time path. Filters at 0 dB are skipped.
final class EQProcessor {
    static let graphicFrequencies: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let graphicQ = 1.41
    static let toneCount = 3
    static let bandCount = 10 + 3
    static let gainRange: ClosedRange<Float> = -12...12

    private let coef = UnsafeMutablePointer<Float>.allocate(capacity: EQProcessor.bandCount * 5)
    private let pending = UnsafeMutablePointer<Float>.allocate(capacity: EQProcessor.bandCount * 5)
    private let state = UnsafeMutablePointer<Float>.allocate(capacity: EQProcessor.bandCount * 4)
    private let active = UnsafeMutablePointer<Bool>.allocate(capacity: EQProcessor.bandCount)
    private let pendingActive = UnsafeMutablePointer<Bool>.allocate(capacity: EQProcessor.bandCount)
    private let dirty = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let bypass = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

    private(set) var sampleRate: Double
    /// UI-side copy: 10 graphic gains then LOW, MID, HIGH tone gains (dB).
    private(set) var gains = [Float](repeating: 0, count: EQProcessor.bandCount)

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        for i in 0..<Self.bandCount { setIdentity(coef, i); setIdentity(pending, i); active[i] = false; pendingActive[i] = false }
        state.initialize(repeating: 0, count: Self.bandCount * 4)
        dirty.initialize(to: 0); bypass.initialize(to: 0)
    }
    deinit { coef.deallocate(); pending.deallocate(); state.deallocate(); active.deallocate(); pendingActive.deallocate(); dirty.deallocate(); bypass.deallocate() }

    private func setIdentity(_ p: UnsafeMutablePointer<Float>, _ i: Int) {
        p[i * 5] = 1; p[i * 5 + 1] = 0; p[i * 5 + 2] = 0; p[i * 5 + 3] = 0; p[i * 5 + 4] = 0
    }

    var isBypassed: Bool {
        get { bypass.pointee != 0 }
        set { bypass.pointee = newValue ? 1 : 0 }
    }

    static func design(band: Int, gainDB: Float, sampleRate: Double) -> BiquadCoefficients {
        let g = Double(gainDB)
        switch band {
        case 0..<10: return .peaking(frequency: graphicFrequencies[band], gainDB: g, q: graphicQ, sampleRate: sampleRate)
        case 10: return .lowShelf(frequency: 100, gainDB: g, sampleRate: sampleRate)
        case 11: return .peaking(frequency: 1000, gainDB: g, q: 0.7, sampleRate: sampleRate)
        default: return .highShelf(frequency: 8000, gainDB: g, sampleRate: sampleRate)
        }
    }

    /// Sets all 13 gains (10 graphic + 3 tone). Values are clamped to ±12 dB.
    func set(gains newGains: [Float], sampleRate newRate: Double? = nil) {
        if let r = newRate { sampleRate = r }
        var g = newGains
        if g.count < Self.bandCount { g += [Float](repeating: 0, count: Self.bandCount - g.count) }
        g = g.prefix(Self.bandCount).map { min(max($0, Self.gainRange.lowerBound), Self.gainRange.upperBound) }
        gains = g
        for i in 0..<Self.bandCount {
            let on = abs(g[i]) > 0.01
            pendingActive[i] = on
            let c = on ? Self.design(band: i, gainDB: g[i], sampleRate: sampleRate) : .identity
            pending[i * 5] = c.b0; pending[i * 5 + 1] = c.b1; pending[i * 5 + 2] = c.b2; pending[i * 5 + 3] = c.a1; pending[i * 5 + 4] = c.a2
        }
        OSMemoryBarrier()
        dirty.pointee = 1
    }

    func setGraphic(_ graphic: [Float]) {
        var g = gains
        for i in 0..<min(10, graphic.count) { g[i] = graphic[i] }
        set(gains: g)
    }

    /// Combined magnitude response (dB) for drawing the curve.
    func responseDB(at frequency: Double) -> Double {
        var total = 0.0
        for i in 0..<Self.bandCount where abs(gains[i]) > 0.01 {
            total += Self.design(band: i, gainDB: gains[i], sampleRate: sampleRate).magnitudeDB(at: frequency, sampleRate: sampleRate)
        }
        return total
    }

    /// Real-time safe.
    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        if dirty.pointee == 1 {
            dirty.pointee = 0
            OSMemoryBarrier()
            for i in 0..<(Self.bandCount * 5) { coef[i] = pending[i] }
            for i in 0..<Self.bandCount { active[i] = pendingActive[i] }
        }
        if bypass.pointee != 0 { return }
        for band in 0..<Self.bandCount where active[band] {
            let b0 = coef[band * 5], b1 = coef[band * 5 + 1], b2 = coef[band * 5 + 2], a1 = coef[band * 5 + 3], a2 = coef[band * 5 + 4]
            var z1l = state[band * 4], z2l = state[band * 4 + 1], z1r = state[band * 4 + 2], z2r = state[band * 4 + 3]
            for i in 0..<frames {
                let xl = l[i], yl = b0 * xl + z1l
                z1l = b1 * xl - a1 * yl + z2l; z2l = b2 * xl - a2 * yl; l[i] = yl
                let xr = r[i], yr = b0 * xr + z1r
                z1r = b1 * xr - a1 * yr + z2r; z2r = b2 * xr - a2 * yr; r[i] = yr
            }
            state[band * 4] = z1l; state[band * 4 + 1] = z2l; state[band * 4 + 2] = z1r; state[band * 4 + 3] = z2r
        }
    }
}

/// Built-in EQ presets (10 graphic bands, dB) and user presets persisted in UserDefaults.
enum EQPresets {
    static let builtIn: [(name: String, gains: [Float])] = [
        ("Flat",          [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass Boost",    [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("Voice Clarity", [-4, -3, -2, 0, 1, 3, 4, 3, 1, 0]),
        ("Podcast",       [-6, -4, -1, 1, 2, 3, 3, 2, 0, -2]),
        ("Night",         [3, 2, 1, 0, -1, -2, -3, -4, -5, -6]),
        ("Music",         [4, 3, 1, 0, -1, 0, 1, 3, 4, 3]),
        ("Cinema",        [5, 4, 2, 0, -1, 0, 2, 3, 3, 2]),
    ]
    static var builtInNames: [String] { builtIn.map { $0.name } }
    private static let key = "userEQPresets"

    static func userPresets(_ defaults: UserDefaults = .standard) -> [String: [Float]] {
        guard let data = defaults.data(forKey: key),
              let d = try? JSONDecoder().decode([String: [Float]].self, from: data) else { return [:] }
        return d
    }
    static func save(name: String, gains: [Float], defaults: UserDefaults = .standard) {
        var d = userPresets(defaults); d[name] = Array(gains.prefix(10))
        if let data = try? JSONEncoder().encode(d) { defaults.set(data, forKey: key) }
    }
    static func delete(name: String, defaults: UserDefaults = .standard) {
        var d = userPresets(defaults); d[name] = nil
        if let data = try? JSONEncoder().encode(d) { defaults.set(data, forKey: key) }
    }
    static func gains(named name: String, defaults: UserDefaults = .standard) -> [Float]? {
        builtIn.first { $0.name == name }?.gains ?? userPresets(defaults)[name]
    }
}
