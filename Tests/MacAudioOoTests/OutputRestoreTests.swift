import XCTest
@testable import MacAudioOo

final class OutputRestoreTests: XCTestCase {
    let driver = AudioDeviceManager.driverDeviceUID

    func testNeverRestoresUnlessEnabled() {
        XCTAssertNil(OutputRestorePolicy.target(enabled: false, defaultIsDriver: true, previousUID: "BuiltIn", availableUIDs: ["BuiltIn"]))
    }

    func testRestoresOnlyWhenTheDriverDeviceIsTheSystemOutput() {
        XCTAssertEqual(OutputRestorePolicy.target(enabled: true, defaultIsDriver: true, previousUID: "BuiltIn", availableUIDs: ["BuiltIn", "BT"]), "BuiltIn")
        // The user already chose something else: leave their choice alone.
        XCTAssertNil(OutputRestorePolicy.target(enabled: true, defaultIsDriver: false, previousUID: "BuiltIn", availableUIDs: ["BuiltIn"]))
    }

    func testDoesNothingWhenThePreviousDeviceIsUnknownOrUnplugged() {
        XCTAssertNil(OutputRestorePolicy.target(enabled: true, defaultIsDriver: true, previousUID: nil, availableUIDs: ["BuiltIn"]))
        XCTAssertNil(OutputRestorePolicy.target(enabled: true, defaultIsDriver: true, previousUID: "AirPods", availableUIDs: ["BuiltIn"]))
    }

    func testOnlyRealDevicesAreRemembered() {
        XCTAssertEqual(OutputRestorePolicy.remembered(current: nil, newDefaultUID: "BuiltIn", driverUID: driver), "BuiltIn")
        XCTAssertEqual(OutputRestorePolicy.remembered(current: "BuiltIn", newDefaultUID: driver, driverUID: driver), "BuiltIn")   // driver never overwrites it
        XCTAssertEqual(OutputRestorePolicy.remembered(current: "BuiltIn", newDefaultUID: nil, driverUID: driver), "BuiltIn")
        XCTAssertEqual(OutputRestorePolicy.remembered(current: "BuiltIn", newDefaultUID: "BT", driverUID: driver), "BT")
    }

    func testSettingPersistsAndDefaultsToOff() {
        let suite = UserDefaults(suiteName: "MacAudioOoRestore-\(UUID().uuidString)")!
        let s = AppSettings(defaults: suite)
        XCTAssertFalse(s.restoreOutputOnQuit)
        s.restoreOutputOnQuit = true; s.previousOutputUID = "BuiltIn"
        let s2 = AppSettings(defaults: suite)
        XCTAssertTrue(s2.restoreOutputOnQuit); XCTAssertEqual(s2.previousOutputUID, "BuiltIn")
    }

    func testSettingTheDefaultToTheCurrentOutputIsHarmlessAndUnknownDevicesFail() {
        let m = AudioDeviceManager()
        XCTAssertFalse(m.setDefaultOutput(uid: "no-such-device-uid"))
        if let cur = m.defaultOutputUID, !m.systemDefaultIsDriver {
            XCTAssertTrue(m.setDefaultOutput(uid: cur))          // re-selecting the current default changes nothing
            XCTAssertEqual(m.defaultOutputUID, cur)
        }
    }
}
