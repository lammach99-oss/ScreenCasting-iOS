import XCTest
@testable import iPadCasting

final class RemoteKeyboardStateTests: XCTestCase {
    private let a = RemotePhysicalKey(scan: 0x1e)
    private let control = RemotePhysicalKey(scan: 0x1d)

    func testOneShotAppliesThroughNextKeyRelease() {
        var state = RemoteKeyboardState(token: 7)
        XCTAssertEqual(state.tapModifier(.control, at: 1).map(\.scan), [0x1d])
        XCTAssertEqual(state.modifierState(.control), .oneShot)
        XCTAssertEqual(state.hardwareDown(usage: 0x04).map(\.scan), [0x1e])
        XCTAssertEqual(state.modifierState(.control), .off)
        let releases = state.hardwareUp(usage: 0x04)
        XCTAssertEqual(releases.map(\.scan), [0x1e, 0x1d])
        XCTAssertEqual(releases.map(\.action), [1, 1])
        XCTAssertEqual(state.hardwareDown(usage: 0x05).map(\.scan), [0x30])
    }

    func testDoubleTapLocksUntilTappedAgain() {
        var state = RemoteKeyboardState(token: 7)
        _ = state.tapModifier(.alt, at: 1)
        XCTAssertTrue(state.tapModifier(.alt, at: 1.2).isEmpty)
        XCTAssertEqual(state.modifierState(.alt), .locked)
        _ = state.hardwareDown(usage: 0x04)
        XCTAssertEqual(state.hardwareUp(usage: 0x04).map(\.scan), [0x1e])
        XCTAssertEqual(state.tapModifier(.alt, at: 2).map(\.scan), [0x38])
        XCTAssertEqual(state.modifierState(.alt), .off)
    }

    func testAccessibleLockNeedsNoTimedGestureOrDuplicateDown() {
        var state = RemoteKeyboardState(token: 7)
        XCTAssertEqual(state.lockModifier(.control).map(\.action), [0])
        XCTAssertTrue(state.lockModifier(.control).isEmpty)
        XCTAssertEqual(state.modifierState(.control), .locked)
        XCTAssertEqual(state.tapModifier(.control, at: 1).map(\.action), [1])
        _ = state.tapModifier(.control, at: 2)
        XCTAssertTrue(state.lockModifier(.control).isEmpty)
        XCTAssertEqual(state.modifierState(.control), .locked)
    }

    func testOutsideDoubleTapWindowAndClockRegressionDoNotLock() {
        for time in [1.301, 0.9] {
            var state = RemoteKeyboardState(token: 7)
            _ = state.tapModifier(.shift, at: 1)
            XCTAssertEqual(state.tapModifier(.shift, at: time).map(\.action), [1])
            XCTAssertEqual(state.modifierState(.shift), .off)
        }
    }

    func testDoubleTapIncludesThreeHundredMillisecondBoundary() {
        var state = RemoteKeyboardState(token: 7)
        _ = state.tapModifier(.shift, at: 1)
        XCTAssertTrue(state.tapModifier(.shift, at: 1.3).isEmpty)
        XCTAssertEqual(state.modifierState(.shift), .locked)
    }

    func testBarFirstOwnershipAndRetapDuringConsumedChord() {
        var state = RemoteKeyboardState(token: 7)
        _ = state.barKeyDown(a)
        XCTAssertTrue(state.hardwareDown(usage: 0x04).isEmpty)
        XCTAssertTrue(state.barKeyUp(a).isEmpty)
        XCTAssertEqual(state.hardwareUp(usage: 0x04).map(\.action), [1])
        _ = state.tapModifier(.control, at: 1)
        _ = state.hardwareDown(usage: 0x04)
        XCTAssertTrue(state.tapModifier(.control, at: 2).isEmpty)
        _ = state.hardwareDown(usage: 0x05)
        XCTAssertEqual(state.hardwareUp(usage: 0x04).map(\.scan), [0x1e])
        XCTAssertEqual(state.hardwareUp(usage: 0x05).map(\.scan), [0x30, 0x1d])
    }

    func testModifiersDoNotConsumeOneShot() {
        var state = RemoteKeyboardState(token: 7)
        _ = state.tapModifier(.control, at: 1)
        _ = state.hardwareDown(usage: 0xe5)
        _ = state.hardwareUp(usage: 0xe5)
        XCTAssertEqual(state.modifierState(.control), .oneShot)
    }

    func testHardwareKeepsModifierWhenBarUnlocks() {
        var state = RemoteKeyboardState(token: 7)
        XCTAssertEqual(state.hardwareDown(usage: 0xe0).map(\.action), [0])
        XCTAssertTrue(state.tapModifier(.control, at: 1).isEmpty)
        XCTAssertTrue(state.tapModifier(.control, at: 1.1).isEmpty)
        XCTAssertTrue(state.tapModifier(.control, at: 2).isEmpty)
        XCTAssertEqual(state.hardwareUp(usage: 0xe0).map(\.action), [1])
    }

    func testBarKeepsModifierWhenHardwareReleases() {
        var state = RemoteKeyboardState(token: 7)
        _ = state.tapModifier(.control, at: 1)
        XCTAssertTrue(state.hardwareDown(usage: 0xe0).isEmpty)
        XCTAssertTrue(state.hardwareUp(usage: 0xe0).isEmpty)
        XCTAssertEqual(state.reset().map(\.scan), [0x1d])
    }

    func testOneShotReleaseDoesNotReleaseHardwareModifier() {
        var state = RemoteKeyboardState(token: 7)
        _ = state.hardwareDown(usage: 0xe0)
        _ = state.tapModifier(.control, at: 1)
        _ = state.hardwareDown(usage: 0x04)
        XCTAssertEqual(state.hardwareUp(usage: 0x04).map(\.scan), [0x1e])
        XCTAssertEqual(state.hardwareUp(usage: 0xe0).map(\.scan), [0x1d])
    }

    func testSidedModifiersRemainIndependent() {
        var state = RemoteKeyboardState(token: 7)
        _ = state.tapModifier(.alt, at: 1)
        let rightAlt = state.hardwareDown(usage: 0xe6)
        XCTAssertEqual(rightAlt.map(\.flags), [1])
        XCTAssertEqual(state.hardwareUp(usage: 0xe6).map(\.flags), [1])
        XCTAssertEqual(state.reset().map(\.flags), [0])
    }

    func testDuplicateDownUpAndRepeatHaveSingleOwnership() {
        var state = RemoteKeyboardState(token: 7)
        XCTAssertTrue(state.hardwareRepeat(usage: 0x04).isEmpty)
        XCTAssertEqual(state.hardwareDown(usage: 0x04).map(\.action), [0])
        XCTAssertTrue(state.hardwareDown(usage: 0x04).isEmpty)
        XCTAssertEqual(state.hardwareRepeat(usage: 0x04).map(\.action), [2])
        XCTAssertEqual(state.hardwareUp(usage: 0x04).map(\.action), [1])
        XCTAssertTrue(state.hardwareUp(usage: 0x04).isEmpty)
        XCTAssertTrue(state.hardwareRepeat(usage: 0x04).isEmpty)
        _ = state.hardwareDown(usage: 0xe0)
        XCTAssertTrue(state.hardwareRepeat(usage: 0xe0).isEmpty)
    }

    func testBarAndHardwareOrdinaryKeyShareOwnership() {
        var state = RemoteKeyboardState(token: 7)
        _ = state.hardwareDown(usage: 0x04)
        XCTAssertTrue(state.barKeyDown(a).isEmpty)
        XCTAssertTrue(state.hardwareUp(usage: 0x04).isEmpty)
        XCTAssertEqual(state.barKeyUp(a).map(\.action), [1])
        XCTAssertTrue(state.barKeyUp(a).isEmpty)
    }

    func testAliasedHIDUsagesHaveIndependentOwnership() {
        var state = RemoteKeyboardState(token: 7)
        XCTAssertEqual(state.hardwareDown(usage: 0x31).map(\.action), [0])
        XCTAssertTrue(state.hardwareDown(usage: 0x32).isEmpty)
        XCTAssertTrue(state.hardwareUp(usage: 0x31).isEmpty)
        XCTAssertEqual(state.hardwareUp(usage: 0x32).map(\.action), [1])
    }

    func testResetReleasesOrdinaryKeysBeforeModifiersAndClearsStickyState() {
        var state = RemoteKeyboardState(token: 7)
        _ = state.tapModifier(.win, at: 1)
        _ = state.tapModifier(.win, at: 1.1)
        _ = state.hardwareDown(usage: 0xe4)
        _ = state.hardwareDown(usage: 0x58)
        _ = state.hardwareDown(usage: 0x04)
        let releases = state.reset()
        XCTAssertEqual(releases.map(\.scan), [0x1e, 0x1c, 0x1d, 0x5b])
        XCTAssertTrue(releases.allSatisfy { $0.action == 1 && $0.token == 7 })
        XCTAssertTrue(state.heldKeys.isEmpty)
        XCTAssertEqual(state.modifierState(.win), .off)
        XCTAssertTrue(state.reset().isEmpty)
        XCTAssertTrue(state.hardwareUp(usage: 0x04).isEmpty)
        XCTAssertEqual(state.hardwareDown(usage: 0x04).map(\.scan), [0x1e])
    }

    func testMultipleOneShotsReleaseOnlyAfterTheirTarget() {
        var state = RemoteKeyboardState(token: 7)
        _ = state.tapModifier(.control, at: 1)
        _ = state.tapModifier(.alt, at: 1)
        _ = state.hardwareDown(usage: 0x04)
        _ = state.hardwareDown(usage: 0x05)
        XCTAssertEqual(state.hardwareUp(usage: 0x05).map(\.scan), [0x30])
        XCTAssertEqual(state.hardwareUp(usage: 0x04).map(\.scan), [0x1e, 0x1d, 0x38])
    }

    func testBarTapConsumesOneShotAndPreservesHeldKey() {
        var state = RemoteKeyboardState(token: 7)
        _ = state.tapModifier(.shift, at: 1)
        XCTAssertEqual(state.tapKey(a).map(\.action), [0, 1, 1])
        _ = state.hardwareDown(usage: 0x04)
        XCTAssertEqual(state.tapKey(a).map(\.action), [2])
        XCTAssertEqual(state.heldKeys, Set([a]))
    }

    func testZeroTokenAndUnknownUsageNeverAcquireOwnership() {
        var state = RemoteKeyboardState(token: 0)
        XCTAssertTrue(state.hardwareDown(usage: 0x04).isEmpty)
        XCTAssertTrue(state.tapModifier(.control, at: 1).isEmpty)
        XCTAssertTrue(state.tapKey(a).isEmpty)
        XCTAssertTrue(state.heldKeys.isEmpty)
        state = RemoteKeyboardState(token: 7)
        XCTAssertTrue(state.hardwareDown(usage: 0xffff).isEmpty)
        XCTAssertTrue(state.hardwareUp(usage: 0xffff).isEmpty)
        XCTAssertTrue(state.barKeyDown(control).isEmpty)
    }
}
