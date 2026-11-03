import XCTest
@testable import iPadCasting

/// Settings speaks plainly: what the iPad shows, what the PC is using, and how the link is doing.
final class SettingsCopyTests: XCTestCase {
    func testNowShowingNamesTheRealMode() {
        XCTAssertEqual(SettingsCopy.nowShowing(width: 2388, height: 1668, refreshHz: 60, portrait: false),
                       "Now showing 2388 × 1668 at 60 Hz, landscape")
        XCTAssertEqual(SettingsCopy.nowShowing(width: 1668, height: 2388, refreshHz: 120, portrait: true),
                       "Now showing 1668 × 2388 at 120 Hz, portrait")
    }

    func testWhatThePCIsUsing() {
        XCTAssertEqual(SettingsCopy.pcUsing(adaptive: true, mbps: 20.4, audio: true), "The PC is using Auto, 20 Mbps, audio on")
        XCTAssertEqual(SettingsCopy.pcUsing(adaptive: false, mbps: 45, audio: false), "The PC is using 45 Mbps, audio off")
    }

    func testLatencyIsSaidInWordsNotOnlyColour() {
        XCTAssertEqual(SettingsCopy.latency(4.2).word, "Good")
        XCTAssertEqual(SettingsCopy.latency(4.2).level, .good)
        XCTAssertEqual(SettingsCopy.latency(14).word, "Fair")
        XCTAssertEqual(SettingsCopy.latency(31).level, .slow)
        XCTAssertEqual(SettingsCopy.latency(0).word, "No data yet")
        XCTAssertEqual(SettingsCopy.latency(0).level, .none)
    }
}
