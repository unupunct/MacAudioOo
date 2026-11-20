import Foundation
import Darwin

/// Read-only view of the shared-memory segment published by the MacAudioOo virtual
/// audio driver. Layout mirrors Driver/MAOShared.h — keep both in sync.
final class DriverSharedMemory {
    static let name = "/MacAudioOo.mix"
    static let magic: UInt32 = 0x4D41_4F6F
    static let headerSize = 64, slotHeaderSize = 128, maxSlots = 32, ringFrames = 16384
    static var slotSize: Int { slotHeaderSize + ringFrames * 2 * 4 }
    static var totalSize: Int { headerSize + maxSlots * slotSize }

    private let base: UnsafeMutableRawPointer
    private let size: Int

    /// Returns nil if the driver has not created the segment (driver not installed / not loaded).
    init?(name: String = DriverSharedMemory.name, expectedSize: Int = DriverSharedMemory.totalSize) {
        // shm_open is variadic and unavailable to Swift. With O_RDONLY the mode argument is
        // never read, so calling it through a two-argument prototype is safe on x86_64 and arm64.
        typealias ShmOpen = @convention(c) (UnsafePointer<CChar>, Int32) -> Int32
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open") else { return nil }   // RTLD_DEFAULT
        let fd = unsafeBitCast(sym, to: ShmOpen.self)(name, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, Int(st.st_size) >= expectedSize else { return nil }
        guard let p = mmap(nil, expectedSize, PROT_READ, MAP_SHARED, fd, 0), p != MAP_FAILED else { return nil }
        base = p; size = expectedSize
        guard u32(0) == Self.magic, u32(4) == 1 else { munmap(p, expectedSize); return nil }
    }
    deinit { munmap(base, size) }

    private func u32(_ off: Int) -> UInt32 { base.load(fromByteOffset: off, as: UInt32.self) }

    var sampleRate: Double { Double(u32(8)) }
    var deviceRunning: Bool { u32(20) != 0 }

    func slotOffset(_ i: Int) -> Int { Self.headerSize + i * Self.slotSize }

    struct SlotInfo: Equatable {
        var index: Int, pid: Int32, clientID: UInt32, generation: UInt32, bundleID: String
    }

    /// Currently connected clients. macOS system helpers connect to every audio device they can see without ever
    /// playing anything, so `requireAudio` keeps only clients that have written at least one frame (real playback).
    func activeSlots(requireAudio: Bool = false) -> [SlotInfo] {
        var out: [SlotInfo] = []
        for i in 0..<Self.maxSlots {
            let o = slotOffset(i)
            OSMemoryBarrier()
            guard u32(o) != 0 else { continue }
            if requireAudio, writeIndex(slot: i) == 0 { continue }
            let pid = base.load(fromByteOffset: o + 4, as: Int32.self)
            let bundle = (base + o + 32).withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
            out.append(SlotInfo(index: i, pid: pid, clientID: u32(o + 8), generation: u32(o + 12), bundleID: bundle))
        }
        return out
    }

    func writeIndex(slot: Int) -> UInt64 {
        OSMemoryBarrier()
        return base.load(fromByteOffset: slotOffset(slot) + 16, as: UInt64.self)
    }
    func ring(slot: Int) -> UnsafePointer<Float> {
        UnsafePointer((base + slotOffset(slot) + Self.slotHeaderSize).assumingMemoryBound(to: Float.self))
    }
}

/// Real-time reader for one driver client's ring. Resamples with linear interpolation:
/// the ratio is srcRate/dstRate, trimmed ±1% by a proportional controller that holds the
/// ring fill near `targetFill`, which absorbs clock drift between the virtual device
/// (host clock) and the real output device.
final class DriverSlotSource: ChannelSource {
    private let shm: DriverSharedMemory
    private let slot: Int
    private let dstRate: Double
    private let targetFill: Double
    private var readPos: Double = 0
    private var primed = false
    private(set) var underruns = 0
    private let mask = DriverSharedMemory.ringFrames - 1

    init(shm: DriverSharedMemory, slot: Int, outputRate: Double, targetFillFrames: Double = 3072) {
        self.shm = shm; self.slot = slot; self.dstRate = outputRate; self.targetFill = targetFillFrames
    }

    override func pull(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        let ring = shm.ring(slot: slot)
        let write = Double(shm.writeIndex(slot: slot))
        let cap = Double(DriverSharedMemory.ringFrames)
        var fill = write - readPos

        if !primed {
            if fill >= targetFill { primed = true } else { zero(l, r, frames); return }
        }
        if fill > cap * 0.75 || fill < 0 { readPos = write - targetFill; fill = targetFill }   // overrun / restart

        let err = max(-1, min(1, (fill - targetFill) / targetFill))
        let ratio = (shm.sampleRate / dstRate) * (1 + 0.01 * err)
        var pos = readPos
        for i in 0..<frames {
            if pos + 1 >= write { // starved: hold silence and re-prime
                for j in i..<frames { l[j] = 0; r[j] = 0 }
                underruns += 1; primed = false
                readPos = pos
                return
            }
            let idx = Int(pos), frac = Float(pos - Double(idx))
            let a = (idx & mask) * 2, b = ((idx + 1) & mask) * 2
            l[i] = ring[a] + (ring[b] - ring[a]) * frac
            r[i] = ring[a + 1] + (ring[b + 1] - ring[a + 1]) * frac
            pos += ratio
        }
        readPos = pos
    }

    private func zero(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<n { l[i] = 0; r[i] = 0 }
    }
}
