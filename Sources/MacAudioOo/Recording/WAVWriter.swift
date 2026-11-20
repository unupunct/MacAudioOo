import Foundation

enum WAVError: Error, CustomStringConvertible {
    case cannotCreate(String)
    case notAWAV(String)
    var description: String {
        switch self { case .cannotCreate(let p): return "Cannot create \(p)"; case .notAWAV(let p): return "Not a WAV file: \(p)" }
    }
}

/// Streaming writer for 24-bit PCM stereo WAV (RIFF/WAVE). The header is rewritten about once
/// per second of audio, so a file left behind by a crash or power loss is still valid up to the last
/// update, and `repairHeader` can restore the exact length from the file size.
final class WAVWriter {
    static let channels = 2
    static let bytesPerFrame = 6            // 2 channels x 3 bytes
    static let headerSize = 44

    let url: URL
    let sampleRate: Int
    private let handle: FileHandle
    private(set) var framesWritten: Int64 = 0
    private var framesAtLastHeader: Int64 = 0
    private var scratch = Data()

    init(url: URL, sampleRate: Int) throws {
        self.url = url; self.sampleRate = sampleRate
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(dataBytes: 0, sampleRate: sampleRate)),
              let h = FileHandle(forWritingAtPath: url.path) else { throw WAVError.cannotCreate(url.path) }
        handle = h
        try handle.seekToEnd()
    }

    static func header(dataBytes: UInt32, sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 &+ dataBytes)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16)
        u16(1)                                               // PCM
        u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * bytesPerFrame))              // byte rate
        u16(UInt16(bytesPerFrame))                           // block align
        u16(24)                                              // bits per sample
        d.append("data".data(using: .ascii)!); u32(dataBytes)
        return d
    }

    /// Encodes floats (clamped to ±1.0) as 24-bit little-endian and appends them.
    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) throws {
        guard frames > 0 else { return }
        scratch.removeAll(keepingCapacity: true)
        scratch.reserveCapacity(frames * Self.bytesPerFrame)
        @inline(__always) func put(_ s: Float) {
            let v = Int32((max(-1, min(1, s)) * 8_388_607).rounded())
            scratch.append(UInt8(truncatingIfNeeded: v))
            scratch.append(UInt8(truncatingIfNeeded: v >> 8))
            scratch.append(UInt8(truncatingIfNeeded: v >> 16))
        }
        for i in 0..<frames { put(left[i]); put(right[i]) }
        try handle.write(contentsOf: scratch)
        framesWritten += Int64(frames)
        if framesWritten - framesAtLastHeader >= Int64(sampleRate) { try updateHeader() }
    }

    func updateHeader() throws {
        let bytes = UInt32(truncatingIfNeeded: framesWritten * Int64(Self.bytesPerFrame))
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataBytes: bytes, sampleRate: sampleRate))
        try handle.seekToEnd()
        framesAtLastHeader = framesWritten
    }

    func finalize() throws {
        try updateHeader()
        try handle.synchronize()
        try handle.close()
    }

    /// Restores a valid header for a file whose writer never finished. Drops any trailing partial
    /// frame. Returns the number of frames in the repaired file.
    @discardableResult
    static func repairHeader(at url: URL) throws -> Int64 {
        guard let h = FileHandle(forUpdatingAtPath: url.path) else { throw WAVError.notAWAV(url.path) }
        defer { try? h.close() }
        let head = try h.read(upToCount: headerSize) ?? Data()
        guard head.count == headerSize, head.prefix(4) == "RIFF".data(using: .ascii),
              head[8..<12] == "WAVE".data(using: .ascii) else { throw WAVError.notAWAV(url.path) }
        let rate = Int(head[24]) | Int(head[25]) << 8 | Int(head[26]) << 16 | Int(head[27]) << 24
        let size = try h.seekToEnd()
        let frames = (Int64(size) - Int64(headerSize)) / Int64(bytesPerFrame)
        let dataBytes = UInt32(truncatingIfNeeded: frames * Int64(bytesPerFrame))
        try h.truncate(atOffset: UInt64(headerSize) + UInt64(dataBytes))
        try h.seek(toOffset: 0)
        try h.write(contentsOf: header(dataBytes: dataBytes, sampleRate: rate))
        return frames
    }
}
