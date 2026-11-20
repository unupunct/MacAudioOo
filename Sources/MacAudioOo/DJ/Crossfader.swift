import Foundation

enum CrossfaderCurve: String, CaseIterable, Identifiable {
    case smooth = "Smooth", sharp = "Sharp"
    var id: String { rawValue }
}

enum DeckSide: String, CaseIterable, Identifiable {
    case left = "A", right = "B", thru = "THRU"
    var id: String { rawValue }
}

enum Crossfader {
    /// Left/right channel gains for a fader position in -1 (all left) ... +1 (all right).
    /// smooth: constant-power blend. sharp: both sides at full level until the fader nears an end ("cut").
    static func gains(position x: Float, curve: CrossfaderCurve) -> (left: Float, right: Float) {
        let t = (min(1, max(-1, x)) + 1) / 2                      // 0...1
        switch curve {
        case .smooth: return (cosf(t * .pi / 2), sinf(t * .pi / 2))
        case .sharp:  return (min(1, 2 * (1 - t)), min(1, 2 * t))
        }
    }

    static func gain(for side: DeckSide, position: Float, curve: CrossfaderCurve) -> Float {
        let g = gains(position: position, curve: curve)
        switch side { case .left: return g.left; case .right: return g.right; case .thru: return 1 }
    }
}
