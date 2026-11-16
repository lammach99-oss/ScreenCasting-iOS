import Foundation

struct IPadPointerV2Command: Equatable {
    static let capability: UInt16 = 0x0020
    let kind: UInt8, button: UInt8
    let a: Int32, b: Int32
    let transaction: UInt32
    init(kind: UInt8, button: UInt8, a: Int32, b: Int32, transaction: UInt32 = 0) {
        self.kind = kind; self.button = button; self.a = a; self.b = b; self.transaction = transaction
    }
    func encode() -> Data? {
        var d = Data(count: 24); d[0] = 1; d[1] = kind; d[3] = button
        d.storeLittleEndian(transaction, at: 4)
        d.storeLittleEndian(a, at: 12); d.storeLittleEndian(b, at: 16)
        return Self.decode(d) == nil ? nil : d
    }
    static func valid(kind: UInt8, button: UInt8, a: Int32, b: Int32) -> Bool {
        switch kind {
        case 0: return button == 0 && (0...65535).contains(a) && (0...65535).contains(b)
        case 1, 3: return button == 0 && (-32767...32767).contains(a) && (-32767...32767).contains(b)
        case 2: return (1...5).contains(button) && (0...1).contains(a) && b == 0
        case 4: return button == 0 && a != 0 && (-32767...32767).contains(a)
        default: return false
        }
    }
    static func decode(_ payload: Data) -> Self? {
        let d = Data(payload)
        guard d.count == 24, d[0] == 1, d[2] == 0, d[8..<12].allSatisfy({ $0 == 0 }),
              d[20..<24].allSatisfy({ $0 == 0 }) else { return nil }
        let a = d.loadLittleEndian(Int32.self, at: 12), b = d.loadLittleEndian(Int32.self, at: 16)
        let transaction = d.loadLittleEndian(UInt32.self, at: 4)
        guard d[1] == 2 ? transaction != 0 : transaction == 0,
              valid(kind: d[1], button: d[3], a: a, b: b) else { return nil }
        return Self(kind: d[1], button: d[3], a: a, b: b, transaction: transaction)
    }
    var terminal: Bool { kind == 2 && a == 1 }
}

struct RemoteDirectTouchCommand: Equatable {
    let phase: DirectTouchPhase
    let token: UInt64, contactID: UInt64
    let x: UInt16, y: UInt16
    func encode() -> Data? {
        guard token != 0, contactID != 0 else { return nil }
        var d = Data(count: 24); d[0] = 1; d[1] = phase.rawValue; d[2] = 255
        d.storeLittleEndian(token, at: 4); d.storeLittleEndian(contactID, at: 12)
        d.storeLittleEndian(x, at: 20); d.storeLittleEndian(y, at: 22); return d
    }
    static func decode(_ payload: Data) -> Self? {
        let d = Data(payload)
        guard d.count == 24, d[0] == 1, d[2] == 255, d[3] == 0,
              let phase = DirectTouchPhase(rawValue: d[1]) else { return nil }
        let result = Self(phase: phase, token: d.loadLittleEndian(UInt64.self, at: 4),
            contactID: d.loadLittleEndian(UInt64.self, at: 12), x: d.loadLittleEndian(UInt16.self, at: 20),
            y: d.loadLittleEndian(UInt16.self, at: 22))
        return result.token != 0 && result.contactID != 0 ? result : nil
    }
    var terminal: Bool { phase == .up || phase == .cancel }
}
