import Foundation
import AppKit

/// UI-side handle for one mixer channel. Property changes are written straight
/// into the mixer's pre-allocated slot, where the render thread picks them up.
final class AudioChannel: ObservableObject, Identifiable {
    let id = UUID()
    let slotIndex: Int
    let name: String
    let pid: pid_t?
    let icon: NSImage?
    private let slot: UnsafeMutablePointer<ChannelState>

    @Published var volumeDB: Float = 0 { didSet { slot.pointee.volumeTarget = dbToLinear(volumeDB) } }
    @Published var balance: Float = 0 { didSet { slot.pointee.balance = balance } }
    @Published var mute = false { didSet { slot.pointee.mute = mute } }
    @Published var solo = false { didSet { slot.pointee.solo = solo } }

    init(slotIndex: Int, slot: UnsafeMutablePointer<ChannelState>, name: String, pid: pid_t?, icon: NSImage?) {
        self.slotIndex = slotIndex; self.slot = slot
        self.name = name; self.pid = pid; self.icon = icon
    }

    struct Meter { var peakDB: Float; var rmsDB: Float }

    /// Reads (and resets) the peak accumulator. Call from the UI at display rate.
    func readMeter() -> Meter {
        let p = slot.pointee.peak
        slot.pointee.peak = 0
        let rms = slot.pointee.rmsCount > 0 ? sqrtf(slot.pointee.rmsSquares / slot.pointee.rmsCount) : 0
        return Meter(peakDB: linearToDB(p), rmsDB: linearToDB(rms))
    }
}
