import Foundation

enum WifiHostIdentityDecision: Equatable {
    case trusted
    case requiresFirstPairingConfirmation
    case rejected
}

enum WifiHostIdentityPolicy {
    static func decide(
        presentedFingerprint: String,
        pinnedFingerprint: String?
    ) -> WifiHostIdentityDecision {
        guard let presented = normalizedFingerprint(presentedFingerprint) else {
            return .rejected
        }
        guard let pinnedFingerprint else {
            return .requiresFirstPairingConfirmation
        }
        guard let pinned = normalizedFingerprint(pinnedFingerprint) else {
            return .rejected
        }
        return presented == pinned ? .trusted : .rejected
    }

    static func identityCode(for fingerprint: String) -> String? {
        guard let normalized = normalizedFingerprint(fingerprint) else { return nil }
        let prefix = normalized.prefix(16)
        return stride(from: 0, to: prefix.count, by: 4)
            .map { offset in
                let start = prefix.index(prefix.startIndex, offsetBy: offset)
                let end = prefix.index(start, offsetBy: 4)
                return String(prefix[start..<end])
            }
            .joined(separator: "-")
    }

    private static func normalizedFingerprint(_ fingerprint: String) -> String? {
        let normalized = fingerprint
            .filter { $0.isHexDigit }
            .uppercased()
        guard normalized.count == 64 else { return nil }
        return normalized
    }
}

enum RealtimeTransportMode {
    static let none: UInt8 = 0
    static let legacyTLS: UInt8 = 1
    static let wifiRTP: UInt8 = 2
    static let usbSplitTLS: UInt8 = 4
    static let knownMask: UInt8 = legacyTLS | wifiRTP | usbSplitTLS
}

enum VideoCodecCapabilities {
    static let none: UInt8 = 0
    static let hevc: UInt8 = 1
    static let h264: UInt8 = 2
    static let knownMask: UInt8 = hevc | h264
}

enum AudioCodecCapabilities {
    static let none: UInt8 = 0
    static let pcm: UInt8 = 1
    static let opus: UInt8 = 2
    static let knownMask: UInt8 = pcm | opus
}

enum TransportReadyStatus {
    static let ready: UInt8 = 0
    static let rejected: UInt8 = 1
}

struct ClientCapabilities: Equatable {
    static let encodedSize = 12

    let version: UInt8
    let modes: UInt8
    let videoCodecs: UInt8
    let audioCodecs: UInt8
    let preferredMTU: UInt16
    let feedbackIntervalMs: UInt16
    let clientUDPPort: UInt16

    func encode() -> Data {
        var result = Data(count: Self.encodedSize)
        result[0] = version
        result[1] = modes
        result[2] = videoCodecs
        result[3] = audioCodecs
        result.storeLittleEndian(preferredMTU, at: 4)
        result.storeLittleEndian(feedbackIntervalMs, at: 6)
        result.storeLittleEndian(clientUDPPort, at: 8)
        result.storeLittleEndian(UInt16(0), at: 10)
        return result
    }

    static func decode(_ data: Data) -> ClientCapabilities? {
        guard data.count == encodedSize,
              data[10] == 0,
              data[11] == 0 else { return nil }
        let result = ClientCapabilities(
            version: data[0],
            modes: data[1],
            videoCodecs: data[2],
            audioCodecs: data[3],
            preferredMTU: data.loadLittleEndian(UInt16.self, at: 4),
            feedbackIntervalMs: data.loadLittleEndian(UInt16.self, at: 6),
            clientUDPPort: data.loadLittleEndian(UInt16.self, at: 8))
        return result.isValid ? result : nil
    }

    private var isValid: Bool {
        guard version == 1,
              modes != RealtimeTransportMode.none,
              modes & RealtimeTransportMode.legacyTLS != 0,
              modes & ~RealtimeTransportMode.knownMask == 0,
              videoCodecs != VideoCodecCapabilities.none,
              videoCodecs & ~VideoCodecCapabilities.knownMask == 0,
              audioCodecs & ~AudioCodecCapabilities.knownMask == 0,
              (576...1200).contains(preferredMTU),
              (25...200).contains(feedbackIntervalMs) else { return false }
        return ((modes & RealtimeTransportMode.wifiRTP) != 0) ==
            (clientUDPPort != 0)
    }
}

struct SessionID: Equatable {
    static let encodedSize = 16
    private let bytes: Data

    init?(bytes: Data) {
        guard bytes.count == Self.encodedSize else { return nil }
        self.bytes = Data(bytes)
    }

    init?(hex: String) {
        guard hex.count == Self.encodedSize * 2 else { return nil }
        var result = Data()
        result.reserveCapacity(Self.encodedSize)
        var index = hex.startIndex
        for _ in 0..<Self.encodedSize {
            let next = hex.index(index, offsetBy: 2)
            guard let value = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            result.append(value)
            index = next
        }
        self.bytes = result
    }

    func write(to data: inout Data, at offset: Int) {
        data.replaceSubrange(
            offset..<(offset + Self.encodedSize),
            with: bytes)
    }

    func dataCopy() -> Data {
        Data(bytes)
    }

    static func == (lhs: SessionID, rhs: SessionID) -> Bool {
        var difference: UInt8 = 0
        for index in 0..<encodedSize {
            difference |= lhs.bytes[index] ^ rhs.bytes[index]
        }
        return difference == 0
    }
}

struct TransportOffer: Equatable {
    static let encodedSize = 116

    let version: UInt8
    let mode: UInt8
    let videoCodec: UInt8
    let audioCodec: UInt8
    let mtu: UInt16
    let feedbackIntervalMs: UInt16
    let hostUDPPort: UInt16
    let sessionID: SessionID
    private(set) var mediaKey: Data
    private(set) var mediaSalt: Data
    private(set) var feedbackKey: Data
    private(set) var feedbackSalt: Data
    private(set) var usbBindingSecret: Data

    func encode() -> Data? {
        guard isValid else { return nil }
        var result = Data(count: Self.encodedSize)
        result[0] = version
        result[1] = mode
        result[2] = videoCodec
        result[3] = audioCodec
        result.storeLittleEndian(mtu, at: 4)
        result.storeLittleEndian(feedbackIntervalMs, at: 6)
        result.storeLittleEndian(hostUDPPort, at: 8)
        result.storeLittleEndian(UInt16(0), at: 10)
        sessionID.write(to: &result, at: 12)
        result.replaceSubrange(28..<44, with: mediaKey)
        result.replaceSubrange(44..<56, with: mediaSalt)
        result.replaceSubrange(56..<72, with: feedbackKey)
        result.replaceSubrange(72..<84, with: feedbackSalt)
        result.replaceSubrange(84..<116, with: usbBindingSecret)
        return result
    }

    static func decode(_ data: Data) -> TransportOffer? {
        guard data.count == encodedSize,
              data[10] == 0,
              data[11] == 0,
              let sessionID = SessionID(bytes: data.subdata(in: 12..<28))
        else { return nil }
        let result = TransportOffer(
            version: data[0],
            mode: data[1],
            videoCodec: data[2],
            audioCodec: data[3],
            mtu: data.loadLittleEndian(UInt16.self, at: 4),
            feedbackIntervalMs: data.loadLittleEndian(UInt16.self, at: 6),
            hostUDPPort: data.loadLittleEndian(UInt16.self, at: 8),
            sessionID: sessionID,
            mediaKey: data.subdata(in: 28..<44),
            mediaSalt: data.subdata(in: 44..<56),
            feedbackKey: data.subdata(in: 56..<72),
            feedbackSalt: data.subdata(in: 72..<84),
            usbBindingSecret: data.subdata(in: 84..<116))
        return result.isValid ? result : nil
    }

    mutating func zeroSecrets() {
        mediaKey.resetBytes(in: 0..<mediaKey.count)
        mediaSalt.resetBytes(in: 0..<mediaSalt.count)
        feedbackKey.resetBytes(in: 0..<feedbackKey.count)
        feedbackSalt.resetBytes(in: 0..<feedbackSalt.count)
        usbBindingSecret.resetBytes(in: 0..<usbBindingSecret.count)
    }

    var secretsAreZero: Bool {
        mediaKey.allSatisfy { $0 == 0 } &&
        mediaSalt.allSatisfy { $0 == 0 } &&
        feedbackKey.allSatisfy { $0 == 0 } &&
        feedbackSalt.allSatisfy { $0 == 0 } &&
        usbBindingSecret.allSatisfy { $0 == 0 }
    }

    private var isValid: Bool {
        version == 1 &&
        isSingleTransportMode(mode) &&
        videoCodec == VideoCodecCapabilities.hevc &&
        isValidAudioSelection(mode: mode, audioCodec: audioCodec) &&
        (576...1200).contains(mtu) &&
        (25...200).contains(feedbackIntervalMs) &&
        (((mode & RealtimeTransportMode.wifiRTP) != 0) ==
         (hostUDPPort != 0)) &&
        mediaKey.count == 16 &&
        mediaSalt.count == 12 &&
        feedbackKey.count == 16 &&
        feedbackSalt.count == 12 &&
        usbBindingSecret.count == 32
    }
}

struct TransportReady: Equatable {
    static let encodedSize = 20

    let version: UInt8
    let mode: UInt8
    let status: UInt8
    let sessionID: SessionID
    let audioCodec: UInt8

    func encode() -> Data? {
        guard version == 1,
              isSingleTransportMode(mode),
              status == TransportReadyStatus.ready ||
              status == TransportReadyStatus.rejected,
              isValidReadyAudio else { return nil }
        var result = Data(count: Self.encodedSize)
        result[0] = version
        result[1] = mode
        result[2] = status
        result[3] = audioCodec
        sessionID.write(to: &result, at: 4)
        return result
    }

    static func decode(_ data: Data) -> TransportReady? {
        guard data.count == encodedSize,
              let sessionID = SessionID(bytes: data.subdata(in: 4..<20))
        else { return nil }
        let result = TransportReady(
            version: data[0],
            mode: data[1],
            status: data[2],
            sessionID: sessionID,
            audioCodec: data[3])
        guard result.version == 1,
              isSingleTransportMode(result.mode),
              result.status == TransportReadyStatus.ready ||
              result.status == TransportReadyStatus.rejected,
              result.isValidReadyAudio else {
            return nil
        }
        return result
    }

    private var isValidReadyAudio: Bool {
        status == TransportReadyStatus.rejected
            ? audioCodec == AudioCodecCapabilities.none
            : isValidAudioSelection(mode: mode, audioCodec: audioCodec)
    }
}

struct TransportCommit: Equatable {
    static let encodedSize = 20

    let version: UInt8
    let mode: UInt8
    let sessionID: SessionID
    let audioCodec: UInt8

    func encode() -> Data? {
        guard version == 1,
              isSingleTransportMode(mode),
              isValidAudioSelection(mode: mode, audioCodec: audioCodec)
        else { return nil }
        var result = Data(count: Self.encodedSize)
        result[0] = version
        result[1] = mode
        result[2] = audioCodec
        sessionID.write(to: &result, at: 4)
        return result
    }

    static func decode(_ data: Data) -> TransportCommit? {
        guard data.count == encodedSize,
              data[3] == 0,
              let sessionID = SessionID(bytes: data.subdata(in: 4..<20))
        else { return nil }
        let result = TransportCommit(
            version: data[0],
            mode: data[1],
            sessionID: sessionID,
            audioCodec: data[2])
        return result.version == 1 &&
            isSingleTransportMode(result.mode) &&
            isValidAudioSelection(
                mode: result.mode,
                audioCodec: result.audioCodec)
            ? result
            : nil
    }
}

enum UsbSplitCommitDecision: Equatable {
    case split
    case legacyFallback
    case reject
}

/// Pure negotiation gate used by NetworkManager and deterministic tests.
/// A provisional split never becomes active through elapsed time alone.
struct UsbSplitCommitGate {
    private(set) var provisionalSessionID: SessionID?

    mutating func begin(sessionID: SessionID) {
        provisionalSessionID = sessionID
    }

    mutating func resolve(
        _ commit: TransportCommit,
        videoLaneBound: Bool,
        audioLaneBound: Bool
    ) -> UsbSplitCommitDecision {
        guard commit.sessionID == provisionalSessionID else {
            return .reject
        }
        if commit.mode == RealtimeTransportMode.legacyTLS {
            provisionalSessionID = nil
            return .legacyFallback
        }
        guard commit.mode == RealtimeTransportMode.usbSplitTLS,
              videoLaneBound,
              (commit.audioCodec == AudioCodecCapabilities.none ||
               (commit.audioCodec == AudioCodecCapabilities.opus &&
                audioLaneBound)) else {
            return .reject
        }
        provisionalSessionID = nil
        return .split
    }

    @discardableResult
    mutating func abort(sessionID: SessionID? = nil) -> Bool {
        guard let provisionalSessionID,
              sessionID == nil || sessionID == provisionalSessionID else {
            return false
        }
        self.provisionalSessionID = nil
        return true
    }
}

private func isSingleTransportMode(_ mode: UInt8) -> Bool {
    mode == RealtimeTransportMode.legacyTLS ||
    mode == RealtimeTransportMode.wifiRTP ||
    mode == RealtimeTransportMode.usbSplitTLS
}

private func isValidAudioSelection(mode: UInt8, audioCodec: UInt8) -> Bool {
    (mode == RealtimeTransportMode.legacyTLS &&
     audioCodec == AudioCodecCapabilities.pcm) ||
    (mode == RealtimeTransportMode.wifiRTP &&
     (audioCodec == AudioCodecCapabilities.opus ||
      audioCodec == AudioCodecCapabilities.none)) ||
    (mode == RealtimeTransportMode.usbSplitTLS &&
     (audioCodec == AudioCodecCapabilities.opus ||
      audioCodec == AudioCodecCapabilities.none))
}

extension Data {
    mutating func storeLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        at offset: Int
    ) {
        withUnsafeMutableBytes { bytes in
            bytes.storeBytes(
                of: value.littleEndian,
                toByteOffset: offset,
                as: T.self)
        }
    }

    func loadLittleEndian<T: FixedWidthInteger>(
        _ type: T.Type,
        at offset: Int
    ) -> T {
        withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: T.self).littleEndian
        }
    }
}
