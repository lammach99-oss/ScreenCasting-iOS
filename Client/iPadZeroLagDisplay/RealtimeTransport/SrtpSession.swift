import Foundation

typealias NativeSrtpHandle = OpaquePointer

@_silgen_name("CreateSrtpSender")
private func nativeCreateSrtpSender(
    _ key: UnsafePointer<UInt8>, _ keyLength: UInt32,
    _ salt: UnsafePointer<UInt8>, _ saltLength: UInt32,
    _ ssrc: UInt32, _ handle: UnsafeMutablePointer<NativeSrtpHandle?>
) -> Int32

@_silgen_name("CreateSrtpReceiver")
private func nativeCreateSrtpReceiver(
    _ key: UnsafePointer<UInt8>, _ keyLength: UInt32,
    _ salt: UnsafePointer<UInt8>, _ saltLength: UInt32,
    _ ssrc: UInt32, _ handle: UnsafeMutablePointer<NativeSrtpHandle?>
) -> Int32

@_silgen_name("ProtectRtp")
private func nativeProtectRtp(
    _ handle: NativeSrtpHandle, _ packet: UnsafeMutablePointer<UInt8>,
    _ capacity: UInt32, _ length: UnsafeMutablePointer<UInt32>
) -> Int32

@_silgen_name("UnprotectRtp")
private func nativeUnprotectRtp(
    _ handle: NativeSrtpHandle, _ packet: UnsafeMutablePointer<UInt8>,
    _ length: UnsafeMutablePointer<UInt32>
) -> Int32

@_silgen_name("ProtectRtcp")
private func nativeProtectRtcp(
    _ handle: NativeSrtpHandle, _ packet: UnsafeMutablePointer<UInt8>,
    _ capacity: UInt32, _ length: UnsafeMutablePointer<UInt32>
) -> Int32

@_silgen_name("UnprotectRtcp")
private func nativeUnprotectRtcp(
    _ handle: NativeSrtpHandle, _ packet: UnsafeMutablePointer<UInt8>,
    _ length: UnsafeMutablePointer<UInt32>
) -> Int32

@_silgen_name("DestroySrtp")
private func nativeDestroySrtp(_ handle: NativeSrtpHandle)

struct SrtpNativeAPI {
    typealias Create = (
        UnsafePointer<UInt8>, UInt32, UnsafePointer<UInt8>, UInt32,
        UInt32, UnsafeMutablePointer<NativeSrtpHandle?>
    ) -> Int32
    typealias Protect = (
        NativeSrtpHandle, UnsafeMutablePointer<UInt8>, UInt32,
        UnsafeMutablePointer<UInt32>
    ) -> Int32
    typealias Unprotect = (
        NativeSrtpHandle, UnsafeMutablePointer<UInt8>,
        UnsafeMutablePointer<UInt32>
    ) -> Int32

    let createSender: Create
    let createReceiver: Create
    let protectRtp: Protect
    let unprotectRtp: Unprotect
    let protectRtcp: Protect
    let unprotectRtcp: Unprotect
    let destroy: (NativeSrtpHandle) -> Void

    static let live = SrtpNativeAPI(
        createSender: nativeCreateSrtpSender,
        createReceiver: nativeCreateSrtpReceiver,
        protectRtp: nativeProtectRtp,
        unprotectRtp: nativeUnprotectRtp,
        protectRtcp: nativeProtectRtcp,
        unprotectRtcp: nativeUnprotectRtcp,
        destroy: nativeDestroySrtp)
}

enum RealtimeCryptoError: Error, Equatable {
    case invalidKeyMaterial
    case nativeFailure(Int32)
    case invalidPacketLength
}

/// Owns a paired inbound/outbound SRTP AES-128-GCM context.
final class SrtpSession {
    private static let rtpHeaderLength = 12
    private static let rtpProtectionOverhead = 16
    private static let rtcpHeaderLength = 8
    private static let rtcpProtectionOverhead = 20

    private let sender: NativeSrtpHandle
    private let receiver: NativeSrtpHandle
    private let native: SrtpNativeAPI

    init(
        key: Data, salt: Data, ssrc: UInt32,
        native: SrtpNativeAPI = .live
    ) throws {
        guard key.count == 16, salt.count == 12 else {
            throw RealtimeCryptoError.invalidKeyMaterial
        }

        var stagedSender: NativeSrtpHandle?
        var stagedReceiver: NativeSrtpHandle?
        let senderResult = try key.withUnsafeBytes { keyBytes in
            try salt.withUnsafeBytes { saltBytes in
                guard
                    let keyPointer = keyBytes.bindMemory(to: UInt8.self).baseAddress,
                    let saltPointer = saltBytes.bindMemory(to: UInt8.self).baseAddress
                else {
                    throw RealtimeCryptoError.invalidKeyMaterial
                }
                return native.createSender(
                    keyPointer, 16, saltPointer, 12, ssrc, &stagedSender)
            }
        }
        guard senderResult >= 0, let stagedSender else {
            if let stagedSender {
                native.destroy(stagedSender)
            }
            throw RealtimeCryptoError.nativeFailure(senderResult)
        }

        let receiverResult = try key.withUnsafeBytes { keyBytes in
            try salt.withUnsafeBytes { saltBytes in
                guard
                    let keyPointer = keyBytes.bindMemory(to: UInt8.self).baseAddress,
                    let saltPointer = saltBytes.bindMemory(to: UInt8.self).baseAddress
                else {
                    throw RealtimeCryptoError.invalidKeyMaterial
                }
                return native.createReceiver(
                    keyPointer, 16, saltPointer, 12, ssrc, &stagedReceiver)
            }
        }
        guard receiverResult >= 0, let stagedReceiver else {
            if let stagedReceiver {
                native.destroy(stagedReceiver)
            }
            native.destroy(stagedSender)
            throw RealtimeCryptoError.nativeFailure(receiverResult)
        }

        sender = stagedSender
        receiver = stagedReceiver
        self.native = native
    }

    deinit {
        native.destroy(receiver)
        native.destroy(sender)
    }

    func protectRtp(_ packet: inout Data, plaintextLength: Int) throws -> Int {
        try protect(
            &packet, plaintextLength: plaintextLength,
            minimumPlaintextLength: Self.rtpHeaderLength,
            overhead: Self.rtpProtectionOverhead,
            operation: native.protectRtp)
    }

    func unprotectRtp(_ packet: inout Data, protectedLength: Int) throws -> Int {
        try unprotect(
            &packet, protectedLength: protectedLength,
            minimumProtectedLength:
                Self.rtpHeaderLength + Self.rtpProtectionOverhead,
            operation: native.unprotectRtp)
    }

    func protectRtcp(_ packet: inout Data, plaintextLength: Int) throws -> Int {
        try protect(
            &packet, plaintextLength: plaintextLength,
            minimumPlaintextLength: Self.rtcpHeaderLength,
            overhead: Self.rtcpProtectionOverhead,
            operation: native.protectRtcp)
    }

    func unprotectRtcp(_ packet: inout Data, protectedLength: Int) throws -> Int {
        try unprotect(
            &packet, protectedLength: protectedLength,
            minimumProtectedLength:
                Self.rtcpHeaderLength + Self.rtcpProtectionOverhead,
            operation: native.unprotectRtcp)
    }

    private func protect(
        _ packet: inout Data,
        plaintextLength: Int,
        minimumPlaintextLength: Int,
        overhead: Int,
        operation: SrtpNativeAPI.Protect
    ) throws -> Int {
        guard
            plaintextLength >= minimumPlaintextLength,
            packet.count >= overhead,
            plaintextLength <= packet.count - overhead,
            let capacity = UInt32(exactly: packet.count),
            var length = UInt32(exactly: plaintextLength)
        else {
            throw RealtimeCryptoError.invalidPacketLength
        }
        let result = try packet.withUnsafeMutableBytes { bytes -> Int32 in
            guard let pointer = bytes.bindMemory(to: UInt8.self).baseAddress else {
                throw RealtimeCryptoError.invalidPacketLength
            }
            return operation(sender, pointer, capacity, &length)
        }
        guard result >= 0 else { throw RealtimeCryptoError.nativeFailure(result) }
        return Int(length)
    }

    private func unprotect(
        _ packet: inout Data,
        protectedLength: Int,
        minimumProtectedLength: Int,
        operation: SrtpNativeAPI.Unprotect
    ) throws -> Int {
        guard
            protectedLength >= minimumProtectedLength,
            protectedLength <= packet.count,
            var length = UInt32(exactly: protectedLength)
        else {
            throw RealtimeCryptoError.invalidPacketLength
        }
        let result = try packet.withUnsafeMutableBytes { bytes -> Int32 in
            guard let pointer = bytes.bindMemory(to: UInt8.self).baseAddress else {
                throw RealtimeCryptoError.invalidPacketLength
            }
            return operation(receiver, pointer, &length)
        }
        guard result >= 0 else { throw RealtimeCryptoError.nativeFailure(result) }
        return Int(length)
    }
}
