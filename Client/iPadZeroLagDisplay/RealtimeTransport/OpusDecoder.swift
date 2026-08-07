import Foundation

typealias NativeOpusDecoderHandle = OpaquePointer

@_silgen_name("CreateOpusDecoder")
private func nativeCreateOpusDecoder(
    _ handle: UnsafeMutablePointer<NativeOpusDecoderHandle?>
) -> Int32

@_silgen_name("DecodeOpus")
private func nativeDecodeOpus(
    _ handle: NativeOpusDecoderHandle,
    _ packet: UnsafePointer<UInt8>?, _ length: UInt32,
    _ pcm: UnsafeMutablePointer<Int16>, _ capacityFramesPerChannel: UInt32,
    _ decodedFramesPerChannel: UnsafeMutablePointer<UInt32>
) -> Int32

@_silgen_name("DestroyOpusDecoder")
private func nativeDestroyOpusDecoder(_ handle: NativeOpusDecoderHandle)

struct OpusDecoderNativeAPI {
    let create: (UnsafeMutablePointer<NativeOpusDecoderHandle?>) -> Int32
    let decode: (
        NativeOpusDecoderHandle, UnsafePointer<UInt8>?, UInt32,
        UnsafeMutablePointer<Int16>, UInt32, UnsafeMutablePointer<UInt32>
    ) -> Int32
    let destroy: (NativeOpusDecoderHandle) -> Void

    static let live = OpusDecoderNativeAPI(
        create: nativeCreateOpusDecoder,
        decode: nativeDecodeOpus,
        destroy: nativeDestroyOpusDecoder)
}

enum RealtimeOpusError: Error, Equatable {
    case nativeFailure(Int32)
    case invalidPacket
}

/// Fixed-format 48 kHz stereo, 480-frame Opus decoder.
final class RealtimeOpusDecoder {
    static let framesPerChannel = 480
    static let channels = 2
    private let handle: NativeOpusDecoderHandle
    private let native: OpusDecoderNativeAPI

    init(native: OpusDecoderNativeAPI = .live) throws {
        var staged: NativeOpusDecoderHandle?
        let result = native.create(&staged)
        guard result >= 0, let staged else {
            if let staged {
                native.destroy(staged)
            }
            throw RealtimeOpusError.nativeFailure(result)
        }
        handle = staged
        self.native = native
    }

    deinit {
        native.destroy(handle)
    }

    func decode(_ packet: Data?) throws -> [Int16] {
        if let packet, packet.isEmpty {
            throw RealtimeOpusError.invalidPacket
        }
        if let packet, UInt32(exactly: packet.count) == nil {
            throw RealtimeOpusError.invalidPacket
        }
        var pcm = [Int16](
            repeating: 0,
            count: Self.framesPerChannel * Self.channels)
        var frames: UInt32 = 0
        let result = try pcm.withUnsafeMutableBufferPointer { pcmBuffer -> Int32 in
            guard let pcmPointer = pcmBuffer.baseAddress else {
                throw RealtimeOpusError.invalidPacket
            }
            if let packet {
                return try packet.withUnsafeBytes { packetBytes -> Int32 in
                    guard
                        let packetPointer =
                            packetBytes.bindMemory(to: UInt8.self).baseAddress,
                        let packetLength = UInt32(exactly: packet.count)
                    else {
                        throw RealtimeOpusError.invalidPacket
                    }
                    return native.decode(
                        handle, packetPointer, packetLength, pcmPointer,
                        UInt32(Self.framesPerChannel), &frames)
                }
            }
            return native.decode(
                handle, nil, 0, pcmPointer,
                UInt32(Self.framesPerChannel), &frames)
        }
        guard result >= 0 else { throw RealtimeOpusError.nativeFailure(result) }
        guard frames == Self.framesPerChannel else {
            throw RealtimeOpusError.nativeFailure(-1)
        }
        return pcm
    }
}
