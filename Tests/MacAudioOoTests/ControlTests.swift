import XCTest
@testable import MacAudioOo

final class ControlTests: XCTestCase {
    func testFaderTaperEndpointsAndUnityPosition() {
        XCTAssertEqual(FaderTaper.db(forPosition: 0), -60, accuracy: 0.001)
        XCTAssertEqual(FaderTaper.db(forPosition: 1), 6, accuracy: 0.001)
        XCTAssertEqual(FaderTaper.db(forPosition: FaderTaper.position(forDB: 0)), 0, accuracy: 0.001)
        XCTAssertEqual(FaderTaper.db(forPosition: -3), -60, accuracy: 0.001)    // clamped
        XCTAssertEqual(FaderTaper.db(forPosition: 9), 6, accuracy: 0.001)
    }

    func testFaderTaperRoundTripAndMonotonic() {
        var last: Float = -1
        for i in 0...100 {
            let db = -60 + 66 * Float(i) / 100
            let p = FaderTaper.position(forDB: db)
            XCTAssertGreaterThan(p, last - 0.000001)
            last = p
            XCTAssertEqual(FaderTaper.db(forPosition: p), db, accuracy: 0.01)
        }
    }

    func testMeterBallisticsHoldAndClip() {
        let m = MeterModel()
        m.update(peakDB: -6, rmsDB: -12, grDB: 0, dt: 0.033)
        XCTAssertEqual(m.levelDB, -6, accuracy: 0.01)
        XCTAssertEqual(m.holdDB, -6, accuracy: 0.01)
        XCTAssertFalse(m.clipped)
        m.update(peakDB: -120, rmsDB: -120, grDB: 0, dt: 0.1)               // level falls at 24 dB/s
        XCTAssertEqual(m.levelDB, -8.4, accuracy: 0.05)
        XCTAssertEqual(m.holdDB, -6, accuracy: 0.01)                          // hold marker stays for 1.5 s
        m.update(peakDB: 0, rmsDB: -3, grDB: 0, dt: 0.033)
        XCTAssertTrue(m.clipped)
        m.resetClip()
        XCTAssertFalse(m.clipped)
    }
}
