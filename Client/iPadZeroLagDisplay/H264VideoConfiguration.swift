import Foundation

/// Versioned, bounded control payload for the opt-in software H.264 TLS path.
struct VideoConfigurationV1 {
    static let version: UInt8 = 1
    static let fixedSize = 30
    let generation: UInt64
    let codec: VideoDecoderCodec
    let width: UInt16
    let height: UInt16
    let fpsNumerator: UInt32
    let fpsDenominator: UInt32
    let bitrateBps: UInt32
    let parameterSets: [Data]

    static func decode(_ data: Data) -> VideoConfigurationV1? {
        guard data.count >= fixedSize, data[0] == version,
              let codec = VideoDecoderCodec(rawValue: data[9]),
              data[26] == 4, data[27] == 1,
              data[10] != 0, data[12] != 0,
              data.loadLittleEndian(UInt32.self, at: 18) != 0 else { return nil }
        let count = Int(data[28])
        guard count > 0 && count <= 3 else { return nil }
        var offset = fixedSize
        var parameterSets: [Data] = []
        for _ in 0..<count {
            guard offset + 2 <= data.count else { return nil }
            let length = Int(data.loadLittleEndian(UInt16.self, at: offset))
            offset += 2
            guard length > 0, offset + length <= data.count else { return nil }
            parameterSets.append(Data(data[offset..<(offset + length)]))
            offset += length
        }
        guard offset == data.count else { return nil }
        return VideoConfigurationV1(
            generation: data.loadLittleEndian(UInt64.self, at: 1), codec: codec,
            width: data.loadLittleEndian(UInt16.self, at: 10),
            height: data.loadLittleEndian(UInt16.self, at: 12),
            fpsNumerator: data.loadLittleEndian(UInt32.self, at: 14),
            fpsDenominator: data.loadLittleEndian(UInt32.self, at: 18),
            bitrateBps: data.loadLittleEndian(UInt32.self, at: 22),
            parameterSets: parameterSets)
    }
}

struct VideoConfigurationAckV1 {
    static let version: UInt8 = 1
    let generation: UInt64
    let accepted: Bool
    let errorCode: UInt16
    let codec: VideoDecoderCodec
    let width: UInt16
    let height: UInt16

    func encode() -> Data {
        var data = Data(count: 19)
        data[0] = Self.version
        data.storeLittleEndian(generation, at: 1)
        data[9] = accepted ? 1 : 0
        data.storeLittleEndian(errorCode, at: 10)
        data[12] = codec.rawValue
        data.storeLittleEndian(width, at: 13)
        data.storeLittleEndian(height, at: 15)
        return data
    }
}
