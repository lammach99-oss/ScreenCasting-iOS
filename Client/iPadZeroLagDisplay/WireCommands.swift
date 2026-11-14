import Foundation
import Network
import CryptoKit
import QuartzCore
import AVFoundation
import Security
import UIKit

enum WireMessageType: UInt8 {
    case authResult = 1
    case video = 2
    case audio = 3
    case bitrate = 4
    case protocolError = 5
    case ping = 6
    case pong = 7
    case videoFeedback = 8
    case clientCapabilities = 9
    case transportOffer = 10
    case transportReady = 11
    case transportCommit = 12
    case usbLaneBind = 13
    case usbLaneBindResult = 14
    case videoConfiguration = 15
    case videoConfigurationAck = 16
    case displayCapabilities = 17
    case displayConfigurationRequest = 18
    case displayReady = 19
    case displayConfigurationFailed = 20
    case clientHello = 21
    case pairingRequired = 22
    case trustedDeviceChallenge = 23
    case trustedDeviceProof = 24
    case pairingSuccess = 25
    case trustedAuthResult = 26
    case sessionResumeResult = 27
    case settingsGet = 28
    case settingsState = 29
    case settingsUpdate = 30
    case settingsApplied = 31
    case settingsRejected = 32
    case forgetDevice = 33
    case forgetDeviceResult = 34
    case presentationActivity = 35
    case pipelineMode = 36
    case pointerInput = 37
    case keyboardInput = 38
    case clientPerformanceFeedback = 39
    case textCommit = 40
    case directTouchContact = 41
    case cursorOwnership = 42
    case transferOffer = 43, transferResponse, transferChunk, transferFileEnd, transferFileAck, transferCancel, transferEnd, transferAck
    case mirrorHello = 51, mirrorState = 52, mirrorInput = 53, mirrorAction = 54
    case mirrorCatalogue = 55, mirrorSwitchRequest = 56
    // Remote control service (port 27020) only: requests go up, replies only answer them.
    case remoteCommand = 57, remoteCommandResult = 58, sessionInfoRequest = 59, sessionInfo = 60
    case remoteFeaturesRequest = 61, remoteFeaturesResult = 62, remoteInputContext = 63
    case remoteScanKey = 64, remotePointer = 65, remoteInputReset = 66, remoteCommittedText = 67
    case remoteMonitorCatalogueRequest = 68
    case remoteMonitorCatalogue = 69
    case remoteMonitorSelectRequest = 70
    case remoteMonitorSelectResult = 71
    case sourceHello = 72, sourceCatalogue = 73, sourceSwitchRequest = 74, sourceSwitchResult = 75
}

/// Toolbar actions the remote host runs on the PC. Payload: [version 1, command, flags(bit0 confirm)].
public enum RemoteHostCommand: UInt8 {
    case secureAttention = 1, lock = 2, restart = 3

    func encode(confirmed: Bool) -> Data { Data([1, rawValue, confirmed ? 1 : 0]) }
}

public enum DirectTouchPhase: UInt8 { case down = 0, update = 1, up = 2, cancel = 3 }

public struct DirectTouchContactCommand: Equatable {
    static let encodedSize = 16
    public let phase: DirectTouchPhase
    public let pressure: UInt8
    public let contactID: UInt64
    public let x: UInt16
    public let y: UInt16

    func encode() -> Data {
        precondition(contactID != 0)
        var data = Data(count: Self.encodedSize)
        data.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: UInt8(1), toByteOffset: 0, as: UInt8.self)
            bytes.storeBytes(of: phase.rawValue, toByteOffset: 1, as: UInt8.self)
            bytes.storeBytes(of: pressure, toByteOffset: 2, as: UInt8.self)
            bytes.storeBytes(of: contactID.littleEndian, toByteOffset: 4, as: UInt64.self)
            bytes.storeBytes(of: x.littleEndian, toByteOffset: 12, as: UInt16.self)
            bytes.storeBytes(of: y.littleEndian, toByteOffset: 14, as: UInt16.self)
        }
        return data
    }
    static func decode(_ data: Data) -> Self? {
        guard data.count == encodedSize, data[0] == 1, data[3] == 0,
              let phase = DirectTouchPhase(rawValue: data[1]) else { return nil }
        return data.withUnsafeBytes { bytes in
            let id = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt64.self))
            guard id != 0 else { return nil }
            return Self(phase: phase, pressure: data[2], contactID: id,
                x: UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 12, as: UInt16.self)),
                y: UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 14, as: UInt16.self)))
        }
    }
}

enum CursorOwnershipState: UInt8 { case clientActive = 0, hostActive = 1 }
struct CursorOwnershipCommand: Equatable {
    static let encodedSize = 2
    let state: CursorOwnershipState
    func encode() -> Data { Data([1, state.rawValue]) }
    static func decode(_ data: Data) -> Self? {
        guard data.count == encodedSize, data[0] == 1,
              let state = CursorOwnershipState(rawValue: data[1]) else { return nil }
        return Self(state: state)
    }
}

public struct TextCommitCommand: Equatable {
    static let version: UInt8 = 1
    static let maxUTF8Bytes = 4096
    public let text: String
    func encode() -> Data? {
        let body = Array(text.utf8)
        guard !body.isEmpty, body.count <= Self.maxUTF8Bytes,
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        return Data([Self.version, UInt8(truncatingIfNeeded: body.count), UInt8(body.count >> 8)] + body)
    }
    static func decode(_ payload: Data) -> TextCommitCommand? {
        guard payload.count >= 4, payload.count <= 4099 else { return nil }
        let bytes = Array(payload)
        let count = Int(bytes[1]) | Int(bytes[2]) << 8
        guard bytes[0] == version, count > 0, count <= maxUTF8Bytes, bytes.count == count + 3,
              let text = String(bytes: bytes.dropFirst(3), encoding: .utf8) else { return nil }
        let command = TextCommitCommand(text: text)
        return command.encode() == payload ? command : nil
    }
    static func chunks(_ text: String) -> [TextCommitCommand] {
        guard !text.isEmpty,
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return [] }
        var result: [TextCommitCommand] = []
        var buffer = ""
        var byteCount = 0
        for character in text {
            let part = String(character)
            let count = part.utf8.count
            guard count <= maxUTF8Bytes else { return [] }
            if byteCount + count > maxUTF8Bytes {
                result.append(TextCommitCommand(text: buffer)); buffer = ""; byteCount = 0
            }
            buffer += part; byteCount += count
        }
        if !buffer.isEmpty { result.append(TextCommitCommand(text: buffer)) }
        return result
    }
}

enum TextCommitDeliveryPolicy {
    static func maySend(inputSuppressed: Bool) -> Bool { !inputSuppressed }
}

public enum KeyboardInputAction: UInt8, CaseIterable {
    case keyDown = 0
    case keyUp = 1
}

public struct KeyboardInputCommand: Equatable {
    static let version: UInt8 = 1
    static let encodedSize = 4
    public let action: KeyboardInputAction
    public let virtualKey: UInt16

    public init(action: KeyboardInputAction, virtualKey: UInt16) {
        self.action = action
        self.virtualKey = virtualKey
    }

    func encode() -> Data {
        Data([Self.version, action.rawValue,
              UInt8(truncatingIfNeeded: virtualKey), UInt8(virtualKey >> 8)])
    }

    static func decode(_ payload: Data) -> KeyboardInputCommand? {
        guard payload.count == encodedSize, payload[0] == version,
              let action = KeyboardInputAction(rawValue: payload[1]) else { return nil }
        let virtualKey = UInt16(payload[2]) | UInt16(payload[3]) << 8
        guard virtualKey != 0 else { return nil }
        return KeyboardInputCommand(action: action, virtualKey: virtualKey)
    }
}

public enum PointerInputAction: UInt8, CaseIterable {
    case move = 0
    case leftClick = 1
    case leftDown = 2
    case leftUp = 3
    case rightClick = 4
    case verticalWheel = 5
    case horizontalWheel = 6
    case zoomWheel = 7
}

public struct PointerInputCommand: Equatable {
    static let version: UInt8 = 1
    static let encodedSize = 8

    public let action: PointerInputAction
    public let x: UInt16
    public let y: UInt16
    public let value: Int16

    public init(action: PointerInputAction, x: UInt16, y: UInt16, value: Int16 = 0) {
        self.action = action
        self.x = x
        self.y = y
        self.value = value
    }

    func encode() -> Data {
        var payload = Data(count: Self.encodedSize)
        payload.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: Self.version, toByteOffset: 0, as: UInt8.self)
            bytes.storeBytes(of: action.rawValue, toByteOffset: 1, as: UInt8.self)
            bytes.storeBytes(of: x.littleEndian, toByteOffset: 2, as: UInt16.self)
            bytes.storeBytes(of: y.littleEndian, toByteOffset: 4, as: UInt16.self)
            bytes.storeBytes(of: value.littleEndian, toByteOffset: 6, as: Int16.self)
        }
        return payload
    }

    static func decode(_ payload: Data) -> PointerInputCommand? {
        guard payload.count == encodedSize,
              payload[0] == version,
              let action = PointerInputAction(rawValue: payload[1]) else {
            return nil
        }
        return payload.withUnsafeBytes { bytes in
            PointerInputCommand(
                action: action,
                x: UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 2, as: UInt16.self)),
                y: UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt16.self)),
                value: Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: 6, as: Int16.self)))
        }
    }
}

public enum PipelineMode: UInt8 {
    case office = 0
    case game = 1

    static func decode(_ payload: Data) -> PipelineMode? {
        guard payload.count == 1 else { return nil }
        return PipelineMode(rawValue: payload[0])
    }

    func encode() -> Data { Data([rawValue]) }
    var targetFps: UInt16 { self == .game ? 120 : 60 }
}

struct CommittedPipelineModeState {
    private(set) var desired: PipelineMode = .office
    private(set) var active: PipelineMode?
    private var acknowledgedAt: TimeInterval?
    mutating func request(_ mode: PipelineMode) { desired = mode; reset() }
    mutating func acknowledge(_ mode: PipelineMode, at now: TimeInterval = CACurrentMediaTime()) -> Bool {
        guard mode == desired else { return false }
        active = mode
        acknowledgedAt = now
        return true
    }
    func readyForFeedback(at now: TimeInterval) -> Bool {
        guard active == desired, let start = acknowledgedAt else { return false }
        return now >= start + 2
    }
    mutating func reset() { active = nil; acknowledgedAt = nil }
}

struct ClientPerformanceFeedback: Equatable {
    let mode: PipelineMode
    let flags: UInt8
    let generation: UInt64
    let targetFps: UInt16
    let decodedFpsX10: UInt16
    let freshPresentedFpsX10: UInt16
    let windowMs: UInt16
    let droppedFrames: UInt32

    func encode() -> Data {
        var data = Data(count: 24)
        data[0] = 1; data[1] = mode.rawValue; data[2] = flags
        data.storeLittleEndian(generation, at: 4)
        data.storeLittleEndian(targetFps, at: 12)
        data.storeLittleEndian(decodedFpsX10, at: 14)
        data.storeLittleEndian(freshPresentedFpsX10, at: 16)
        data.storeLittleEndian(windowMs, at: 18)
        data.storeLittleEndian(droppedFrames, at: 20)
        return data
    }

    static func decode(_ data: Data) -> ClientPerformanceFeedback? {
        guard data.count == 24, data[0] == 1, let mode = PipelineMode(rawValue: data[1]),
              data[2] & ~3 == 0, data[3] == 0 else { return nil }
        let result = ClientPerformanceFeedback(mode: mode, flags: data[2],
            generation: data.loadLittleEndian(UInt64.self, at: 4),
            targetFps: data.loadLittleEndian(UInt16.self, at: 12),
            decodedFpsX10: data.loadLittleEndian(UInt16.self, at: 14),
            freshPresentedFpsX10: data.loadLittleEndian(UInt16.self, at: 16),
            windowMs: data.loadLittleEndian(UInt16.self, at: 18),
            droppedFrames: data.loadLittleEndian(UInt32.self, at: 20))
        guard result.generation != 0, result.targetFps == mode.targetFps,
              (500...2500).contains(result.windowMs),
              result.decodedFpsX10 <= 2400, result.freshPresentedFpsX10 <= 2400 else { return nil }
        return result
    }
}

enum WireProtocol {
    static let magic: UInt32 = 0x54534353
    static let version: UInt8 = 1
    static let headerSize = 16
    static let maxPayloadSize = 8 * 1024 * 1024
    static let drainChunkSize = 256
    static let receiveChunkSize = 64 * 1024
    static let videoFlagIDR: UInt16 = 0x0001
    static let videoFlagLengthPrefixed: UInt16 = 0x0002
    static let audioFlagOpus: UInt16 = 0x0001
    static let maximumOpusPayloadLength = 1_275
    static let realtimeNegotiationSupportedFlag: UInt16 = 0x8000
}
