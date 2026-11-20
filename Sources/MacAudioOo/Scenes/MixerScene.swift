import Foundation

struct MixerScene: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var snapshot: MixerSnapshot
}
