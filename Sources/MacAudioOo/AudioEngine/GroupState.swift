import Foundation

/// UI-side state of one channel group (A–D). The group fader multiplies the volume of every
/// member channel in the mixer; mute/solo act on the whole group. When `linked`, moving one
/// member's fader moves all members by the same dB amount.
struct GroupState: Codable, Equatable, Identifiable {
    var id: Int
    var name: String
    var volumeDB: Float = 0
    var mute = false
    var solo = false
    var linked = false

    static let letters = ["A", "B", "C", "D"]
    static func defaults() -> [GroupState] { (0..<4).map { GroupState(id: $0, name: "GROUP " + letters[$0]) } }
}
