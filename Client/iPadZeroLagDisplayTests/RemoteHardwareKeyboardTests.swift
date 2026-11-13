import XCTest
import UIKit
@testable import iPadCasting

final class RemoteHardwareKeyboardTests: XCTestCase {
    private func check(_ usage: Int, _ scan: UInt16, _ flags: UInt8 = 0,
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(RemoteHardwareKeyboard.key(forUsage: usage),
                       RemotePhysicalKey(scan: scan, flags: flags), file: file, line: line)
    }

    func testLettersUsePhysicalPositions() {
        let scans: [UInt16] = [0x1e, 0x30, 0x2e, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17,
            0x24, 0x25, 0x26, 0x32, 0x31, 0x18, 0x19, 0x10, 0x13, 0x1f, 0x14,
            0x16, 0x2f, 0x11, 0x2d, 0x15, 0x2c]
        for (index, scan) in scans.enumerated() { check(0x04 + index, scan) }
        XCTAssertEqual(RemoteHardwareKeyboard.key(for: .keyboardA), RemotePhysicalKey(scan: 0x1e))
    }

    func testDigitsAndPunctuation() {
        let vectors: [(Int, UInt16)] = [(0x1e, 0x02), (0x27, 0x0b), (0x2c, 0x39),
            (0x2d, 0x0c), (0x2e, 0x0d), (0x2f, 0x1a), (0x30, 0x1b), (0x31, 0x2b),
            (0x32, 0x2b), (0x33, 0x27), (0x34, 0x28), (0x35, 0x29), (0x36, 0x33),
            (0x37, 0x34), (0x38, 0x35), (0x29, 0x01), (0x2a, 0x0e), (0x2b, 0x0f)]
        for (usage, scan) in vectors { check(usage, scan) }
        for index in 0..<9 { check(0x1e + index, UInt16(0x02 + index)) }
    }

    func testEveryFunctionKey() {
        let scans: [UInt16] = [0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40, 0x41, 0x42, 0x43, 0x44, 0x57, 0x58]
        for (index, scan) in scans.enumerated() { check(0x3a + index, scan) }
    }

    func testNavigationAndArrowsAreExtended() {
        let scans: [UInt16] = [0x52, 0x47, 0x49, 0x53, 0x4f, 0x51, 0x4d, 0x4b, 0x50, 0x48]
        for (index, scan) in scans.enumerated() { check(0x49 + index, scan, 1) }
    }

    func testNumpadIncludingDistinctEnter() {
        check(0x28, 0x1c); check(0x58, 0x1c, 1)
        check(0x53, 0x45); check(0x54, 0x35, 1)
        check(0x55, 0x37); check(0x56, 0x4a); check(0x57, 0x4e)
        let scans: [UInt16] = [0x4f, 0x50, 0x51, 0x4b, 0x4c, 0x4d, 0x47, 0x48, 0x49, 0x52, 0x53]
        for (index, scan) in scans.enumerated() { check(0x59 + index, scan) }
        check(0x67, 0x59); check(0x85, 0x7e)
    }

    func testSidedModifiersAndCommandIsWindows() {
        check(0xe0, 0x1d); check(0xe4, 0x1d, 1)
        check(0xe1, 0x2a); check(0xe5, 0x36)
        check(0xe2, 0x38); check(0xe6, 0x38, 1)
        check(0xe3, 0x5b, 1); check(0xe7, 0x5c, 1)
        for usage in 0xe0...0xe7 {
            XCTAssertTrue(RemoteHardwareKeyboard.key(forUsage: usage)!.isModifier)
        }
    }

    func testCapsLockPrintScreenAndPause() {
        check(0x39, 0x3a); check(0x46, 0x37, 1); check(0x47, 0x46); check(0x48, 0x45, 2)
        XCTAssertFalse(RemoteHardwareKeyboard.key(forUsage: 0x39)!.isModifier)
        XCTAssertFalse(RemoteHardwareKeyboard.key(forUsage: 0x48)!.isModifier)
    }

    func testISOAndJISExtras() {
        check(0x64, 0x56); check(0x65, 0x5d, 1)
        check(0x87, 0x73); check(0x88, 0x70); check(0x89, 0x7d)
        check(0x8a, 0x79); check(0x8b, 0x7b)
        check(0x90, 0x72); check(0x91, 0x71); check(0x92, 0x78); check(0x93, 0x77)
    }

    func testGlobeUnknownAndDocumentedOmissionsSendNothing() {
        for usage in [-1, 0, 1, 2, 3, 0x66, 0x68, 0x86, 0x8c, 0x8d, 0x8e, 0x8f,
                      0x94, 0x95, 0x96, 0x97, 0x98, 0xffff, 0x010097] {
            XCTAssertNil(RemoteHardwareKeyboard.key(forUsage: usage))
        }
    }

    func testAdapterDownRepeatUpAndCancellation() {
        var state = RemoteKeyboardState(token: 9)
        var commands: [RemoteScanKeyCommand] = []
        for phase in [RemoteHardwareKeyboard.Phase.began, .began, .ended, .cancelled] {
            XCTAssertTrue(RemoteHardwareKeyboard.handle(usage: 0x04, phase: phase, state: &state) { commands.append($0) })
        }
        XCTAssertEqual(commands.map(\.action), [0, 2, 1])
        XCTAssertTrue(commands.allSatisfy { $0.scan == 0x1e && $0.flags == 0 && $0.token == 9 })
        XCTAssertTrue(RemoteHardwareKeyboard.handle(usage: 0x58, phase: .began, state: &state) { commands.append($0) })
        XCTAssertTrue(RemoteHardwareKeyboard.handle(usage: 0x58, phase: .cancelled, state: &state) { commands.append($0) })
        XCTAssertEqual(commands.suffix(2).map(\.action), [0, 1])
        XCTAssertTrue(commands.suffix(2).allSatisfy { $0.scan == 0x1c && $0.flags == 1 })
        XCTAssertFalse(RemoteHardwareKeyboard.handle(usage: 0xffff, phase: .began, state: &state) { commands.append($0) })
        XCTAssertEqual(commands.count, 5)
    }
}
