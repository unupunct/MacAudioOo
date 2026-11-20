import Foundation

/// A constant-tempo beat grid: beats fall at `firstBeat + n * 60 / bpm` seconds.
struct BeatGrid: Codable, Equatable {
    var bpm: Double
    var firstBeat: Double          // seconds from the start of the track to the first beat

    var beatDuration: Double { 60 / bpm }

    func time(ofBeat n: Int) -> Double { firstBeat + Double(n) * beatDuration }

    /// Fractional beat number at `t` (can be negative before the first beat).
    func beatPosition(at t: Double) -> Double { (t - firstBeat) / beatDuration }

    /// Position inside the current beat, 0..<1.
    func phase(at t: Double) -> Double {
        let p = beatPosition(at: t)
        return p - p.rounded(.down)
    }

    func nearestBeatTime(to t: Double) -> Double { time(ofBeat: Int(beatPosition(at: t).rounded())) }

    func loopLength(beats: Double) -> Double { beats * beatDuration }

    /// Playback-rate ratio that makes a track with grid `self` run at `targetBPM`.
    func rateToMatch(targetBPM: Double) -> Double { targetBPM / bpm }

    /// Seconds to move this deck so its beat phase equals `masterPhase` (shortest way, in beats of this deck).
    func phaseCorrection(from t: Double, toMasterPhase masterPhase: Double) -> Double {
        var d = masterPhase - phase(at: t)
        if d > 0.5 { d -= 1 } else if d < -0.5 { d += 1 }
        return d * beatDuration
    }
}
