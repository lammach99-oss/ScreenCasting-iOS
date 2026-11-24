import XCTest
@testable import iPadCasting

final class SettingsViewTests: XCTestCase {
    func testTroubleshootingPCSettingsValue() {
        XCTAssertEqual(SettingsCopy.pcSettingsValue(adaptive: true, mbps: 24, audio: false),
                       "Auto, 24 Mbps, audio off")
    }

    func testAutomaticQualityHidesManualBitrate() {
        XCTAssertFalse(SettingsCopy.showsBitrateSlider(autoQuality: true, automaticBitrate: false))
    }

    func testAutomaticBitrateHidesManualBitrate() {
        XCTAssertFalse(SettingsCopy.showsBitrateSlider(autoQuality: false, automaticBitrate: true))
    }

    func testManualSessionShowsBitrate() {
        XCTAssertTrue(SettingsCopy.showsBitrateSlider(autoQuality: false, automaticBitrate: false))
    }
}
