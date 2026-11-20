import XCTest
@testable import MacAudioOo

final class CompatibilityTests: XCTestCase {
    func testMontereyWithoutDriverHasNoMixingBackend() {
        let caps = CapabilityDetector.detect(os: OSVersion(major: 12, minor: 7, patch: 6), driverInstalled: false)
        XCTAssertNil(CapabilityDetector.preferred(from: caps))
        XCTAssertFalse(caps.first { $0.kind == .screenCaptureKit }!.usable)
        XCTAssertFalse(caps.first { $0.kind == .coreAudioTap }!.usable)
    }

    func testMontereyWithDriverUsesDriver() {
        let caps = CapabilityDetector.detect(os: OSVersion(major: 12, minor: 7, patch: 6), driverInstalled: true)
        XCTAssertEqual(CapabilityDetector.preferred(from: caps)?.kind, .virtualDriver)
    }

    func testVenturaScreenCaptureKitIsCaptureOnly() {
        let caps = CapabilityDetector.detect(os: OSVersion(major: 13, minor: 4, patch: 0), driverInstalled: false)
        let sck = caps.first { $0.kind == .screenCaptureKit }!
        XCTAssertTrue(sck.usable)
        XCTAssertEqual(sck.independentVolume, .unavailable)
        XCTAssertNil(CapabilityDetector.preferred(from: caps))
    }

    func testSonoma141HasNoTap_1422HasTap() {
        let old = CapabilityDetector.detect(os: OSVersion(major: 14, minor: 1, patch: 0), driverInstalled: false)
        XCTAssertFalse(old.first { $0.kind == .coreAudioTap }!.usable)
        let new = CapabilityDetector.detect(os: OSVersion(major: 14, minor: 2, patch: 0), driverInstalled: false)
        XCTAssertEqual(CapabilityDetector.preferred(from: new)?.kind, .coreAudioTap)
    }

    func testDriverNotApplicableOnSequoia() {
        let caps = CapabilityDetector.detect(os: OSVersion(major: 15, minor: 0, patch: 0), driverInstalled: true)
        XCTAssertFalse(caps.first { $0.kind == .virtualDriver }!.usable)
    }

    func testSettingsPersistAndReset() {
        let suite = UserDefaults(suiteName: "MacAudioOoTests-\(UUID().uuidString)")!
        let s = AppSettings(defaults: suite)
        s.selectedTab = .dj; s.theme = .light; s.djFourDecks = true
        let s2 = AppSettings(defaults: suite)
        XCTAssertEqual(s2.selectedTab, .dj)
        XCTAssertEqual(s2.theme, .light)
        XCTAssertTrue(s2.djFourDecks)
        s2.resetToDefaults()
        XCTAssertEqual(AppSettings(defaults: suite).selectedTab, .console)
    }

    func testDeviceEnumerationFindsAnOutputOrNone() {
        // Real Core Audio query; must not crash and names must be non-empty.
        for d in AudioDeviceManager.allDevices() { XCTAssertFalse(d.name.isEmpty) }
    }
}
