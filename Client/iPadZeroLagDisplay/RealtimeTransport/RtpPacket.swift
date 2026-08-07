import Foundation

enum RtpAuthenticationSignal {
    case authenticated
    case failed
}

struct RtpPacketView {
    static let headerLength = 28

    let marker: Bool
    let payloadType: UInt8
    let sequence: UInt16
    let timestamp: UInt32
    let ssrc: UInt32
    let frameSequence: UInt32
    let captureTime90k: UInt32
    let payload: Data

    init?(
        data: Data,
        mtu: Int,
        authentication: RtpAuthenticationSignal
    ) {
        guard case .authenticated = authentication,
              data.count >= Self.headerLength,
              data.count <= mtu,
              data[0] >> 6 == 2,
              data[0] & 0x20 == 0,
              data[0] & 0x10 != 0,
              data[0] & 0x0F == 0,
              data[1] & 0x7F == 96,
              data.readBE16(at: 12) == 0xBEDE,
              data.readBE16(at: 14) == 3,
              data[16] == 0x17,
              data[25] == 0,
              data[26] == 0,
              data[27] == 0 else {
            return nil
        }
        marker = data[1] & 0x80 != 0
        payloadType = data[1] & 0x7F
        sequence = data.readBE16(at: 2)
        timestamp = data.readBE32(at: 4)
        ssrc = data.readBE32(at: 8)
        frameSequence = data.readBE32(at: 17)
        captureTime90k = data.readBE32(at: 21)
        payload = data.subdata(in: Self.headerLength..<data.count)
    }
}

private extension Data {
    func readBE16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func readBE32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 |
        UInt32(self[offset + 1]) << 16 |
        UInt32(self[offset + 2]) << 8 |
        UInt32(self[offset + 3])
    }
}
