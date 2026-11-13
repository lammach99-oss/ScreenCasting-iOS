import UIKit

enum RemoteHardwareKeyboard {
    enum Phase { case began, ended, cancelled }

    static func key(for usage: UIKeyboardHIDUsage) -> RemotePhysicalKey? {
        key(forUsage: usage.rawValue)
    }

    /// HID page 0x07 only. Never translate characters or infer a keyboard layout.
    static func key(forUsage usage: Int) -> RemotePhysicalKey? { table[usage] }

    /// Repeated began events produce repeat only after this source acquired ownership.
    @discardableResult
    static func handle(usage: Int, phase: Phase, state: inout RemoteKeyboardState,
                       send: (RemoteScanKeyCommand) -> Void) -> Bool {
        guard key(forUsage: usage) != nil else { return false }
        let commands: [RemoteScanKeyCommand]
        switch phase {
        case .began:
            commands = state.isHardwareHeld(usage: usage)
                ? state.hardwareRepeat(usage: usage) : state.hardwareDown(usage: usage)
        case .ended, .cancelled:
            commands = state.hardwareUp(usage: usage)
        }
        commands.forEach(send)
        return true
    }

    /// Invoke from pressesBegan/Ended/Cancelled with the callback's explicit phase.
    /// Return unhandled presses for super; Globe/Fn and unknown usages stay local.
    /// RI-F must bypass physical forwarding while committed-text/IME owns input.
    @MainActor
    static func handle(_ presses: Set<UIPress>, phase: Phase, state: inout RemoteKeyboardState,
                       send: (RemoteScanKeyCommand) -> Void) -> Set<UIPress> {
        let ordered = presses.sorted {
            let a = $0.key.flatMap { key(for: $0.keyCode) }?.isModifier ?? false
            let b = $1.key.flatMap { key(for: $0.keyCode) }?.isModifier ?? false
            if a != b { return phase == .began ? a : !a }
            return ($0.key?.keyCode.rawValue ?? 0) < ($1.key?.keyCode.rawValue ?? 0)
        }
        var unhandled: Set<UIPress> = []
        for press in ordered {
            guard let usage = press.key?.keyCode,
                  handle(usage: usage.rawValue, phase: phase, state: &state, send: send) else {
                unhandled.insert(press)
                continue
            }
        }
        return unhandled
    }

    // Set-1 make codes; flags 1 = E0, 2 = E1/Pause (RI-A contract).
    // ISO/JIS entries reviewed against Chromium's USB/Windows dom_code_data.inc:
    // https://github.com/chromium/chromium/blob/main/ui/events/keycodes/dom/dom_code_data.inc
    // Intentional omissions: 00-03 errors; 66 Power; 68-84 F13-F24, editing,
    // media and locking variants; 86 AS/400 equals; 8C-8F International6-9;
    // 94-98 LANG5-9 (no unambiguous supported Windows mapping); 99-DF extended
    // editing/keypad functions; E8 and above reserved/vendor usages. Globe/Fn
    // is outside page 07 and stays local. Every unlisted usage returns nil.
    private static let table: [Int: RemotePhysicalKey] = [
        0x04: .init(scan: 0x1e), 0x05: .init(scan: 0x30), 0x06: .init(scan: 0x2e),
        0x07: .init(scan: 0x20), 0x08: .init(scan: 0x12), 0x09: .init(scan: 0x21),
        0x0a: .init(scan: 0x22), 0x0b: .init(scan: 0x23), 0x0c: .init(scan: 0x17),
        0x0d: .init(scan: 0x24), 0x0e: .init(scan: 0x25), 0x0f: .init(scan: 0x26),
        0x10: .init(scan: 0x32), 0x11: .init(scan: 0x31), 0x12: .init(scan: 0x18),
        0x13: .init(scan: 0x19), 0x14: .init(scan: 0x10), 0x15: .init(scan: 0x13),
        0x16: .init(scan: 0x1f), 0x17: .init(scan: 0x14), 0x18: .init(scan: 0x16),
        0x19: .init(scan: 0x2f), 0x1a: .init(scan: 0x11), 0x1b: .init(scan: 0x2d),
        0x1c: .init(scan: 0x15), 0x1d: .init(scan: 0x2c),
        0x1e: .init(scan: 0x02), 0x1f: .init(scan: 0x03), 0x20: .init(scan: 0x04),
        0x21: .init(scan: 0x05), 0x22: .init(scan: 0x06), 0x23: .init(scan: 0x07),
        0x24: .init(scan: 0x08), 0x25: .init(scan: 0x09), 0x26: .init(scan: 0x0a),
        0x27: .init(scan: 0x0b), 0x28: .init(scan: 0x1c), 0x29: .init(scan: 0x01),
        0x2a: .init(scan: 0x0e), 0x2b: .init(scan: 0x0f), 0x2c: .init(scan: 0x39),
        0x2d: .init(scan: 0x0c), 0x2e: .init(scan: 0x0d), 0x2f: .init(scan: 0x1a),
        0x30: .init(scan: 0x1b), 0x31: .init(scan: 0x2b), 0x32: .init(scan: 0x2b),
        0x33: .init(scan: 0x27), 0x34: .init(scan: 0x28), 0x35: .init(scan: 0x29),
        0x36: .init(scan: 0x33), 0x37: .init(scan: 0x34), 0x38: .init(scan: 0x35),
        0x39: .init(scan: 0x3a),
        0x3a: .init(scan: 0x3b), 0x3b: .init(scan: 0x3c), 0x3c: .init(scan: 0x3d),
        0x3d: .init(scan: 0x3e), 0x3e: .init(scan: 0x3f), 0x3f: .init(scan: 0x40),
        0x40: .init(scan: 0x41), 0x41: .init(scan: 0x42), 0x42: .init(scan: 0x43),
        0x43: .init(scan: 0x44), 0x44: .init(scan: 0x57), 0x45: .init(scan: 0x58),
        0x46: .init(scan: 0x37, flags: 1), 0x47: .init(scan: 0x46),
        0x48: .init(scan: 0x45, flags: 2),
        0x49: .init(scan: 0x52, flags: 1), 0x4a: .init(scan: 0x47, flags: 1),
        0x4b: .init(scan: 0x49, flags: 1), 0x4c: .init(scan: 0x53, flags: 1),
        0x4d: .init(scan: 0x4f, flags: 1), 0x4e: .init(scan: 0x51, flags: 1),
        0x4f: .init(scan: 0x4d, flags: 1), 0x50: .init(scan: 0x4b, flags: 1),
        0x51: .init(scan: 0x50, flags: 1), 0x52: .init(scan: 0x48, flags: 1),
        0x53: .init(scan: 0x45), 0x54: .init(scan: 0x35, flags: 1),
        0x55: .init(scan: 0x37), 0x56: .init(scan: 0x4a), 0x57: .init(scan: 0x4e),
        0x58: .init(scan: 0x1c, flags: 1),
        0x59: .init(scan: 0x4f), 0x5a: .init(scan: 0x50), 0x5b: .init(scan: 0x51),
        0x5c: .init(scan: 0x4b), 0x5d: .init(scan: 0x4c), 0x5e: .init(scan: 0x4d),
        0x5f: .init(scan: 0x47), 0x60: .init(scan: 0x48), 0x61: .init(scan: 0x49),
        0x62: .init(scan: 0x52), 0x63: .init(scan: 0x53),
        0x64: .init(scan: 0x56), 0x65: .init(scan: 0x5d, flags: 1),
        0x67: .init(scan: 0x59), 0x85: .init(scan: 0x7e),
        0x87: .init(scan: 0x73), 0x88: .init(scan: 0x70), 0x89: .init(scan: 0x7d),
        0x8a: .init(scan: 0x79), 0x8b: .init(scan: 0x7b),
        0x90: .init(scan: 0x72), 0x91: .init(scan: 0x71),
        0x92: .init(scan: 0x78), 0x93: .init(scan: 0x77),
        0xe0: .init(scan: 0x1d), 0xe1: .init(scan: 0x2a), 0xe2: .init(scan: 0x38),
        0xe3: .init(scan: 0x5b, flags: 1), 0xe4: .init(scan: 0x1d, flags: 1),
        0xe5: .init(scan: 0x36), 0xe6: .init(scan: 0x38, flags: 1),
        0xe7: .init(scan: 0x5c, flags: 1)
    ]
}
