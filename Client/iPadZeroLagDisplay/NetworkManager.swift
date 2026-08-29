import Foundation
import Network
import CryptoKit
import QuartzCore
import AVFoundation
import Security
import UIKit

// MARK: - Connection State Machine

/// Full lifecycle state for the secure NWConnection to the Windows host.
public enum ConnectionState: Equatable {
    case idle
    case listening
    case connecting
    case awaitingHostIdentity
    case awaitingPIN
    case authFailed(reason: String)
    case streaming
    case disconnected(reason: String)
}

// MARK: - Auth Packet (mirrors C# AuthPacketHeader)
// Layout: [uint32 magic (0x41555448)] [uint32 pinCode] — 8 bytes, little-endian

private enum AuthProtocol {
    static let magic: UInt32 = 0x41555448   // "AUTH" in ASCII
    static let successResponse = "AUTH_SUCCESS"
    static let failedResponse = "AUTH_FAILED"
    static let packetSize = 8               // 2 × UInt32
}

private enum USBListenerError: LocalizedError {
    case invalidPort
    case identityUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "USB listener port 12345 is invalid."
        case .identityUnavailable:
            return "The device-local USB TLS identity could not be loaded or created."
        }
    }
}

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

struct TrustedHostCredential: Codable, Equatable {
    let fingerprint: String
    let hostID: Data
    let deviceID: Data
    let secret: Data
    var sessionID: Data
}

protocol TrustedHostCredentialBacking {
    func load(fingerprint: String) -> Data?
    func save(_ data: Data, fingerprint: String) -> Bool
    func delete(fingerprint: String)
}

struct SecurityTrustedHostCredentialBacking: TrustedHostCredentialBacking {
    private let service = "com.screencasting.trusted-host.v1"

    func load(fingerprint: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: fingerprint,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return data
    }

    func save(_ data: Data, fingerprint: String) -> Bool {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: fingerprint,
        ]
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let update = SecItemUpdate(key as CFDictionary, values as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = key
        values.forEach { add[$0.key] = $0.value }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func delete(fingerprint: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: fingerprint,
        ] as CFDictionary)
    }
}

struct TrustedHostCredentialStore {
    private let backing: any TrustedHostCredentialBacking

    init(backing: any TrustedHostCredentialBacking = SecurityTrustedHostCredentialBacking()) {
        self.backing = backing
    }

    func load(fingerprint: String) -> TrustedHostCredential? {
        guard !fingerprint.isEmpty,
              let data = backing.load(fingerprint: fingerprint),
              let credential = try? JSONDecoder().decode(
                  TrustedHostCredential.self,
                  from: data),
              credential.fingerprint == fingerprint,
              credential.hostID.count == 16,
              credential.deviceID.count == 16,
              credential.secret.count == 32,
              credential.sessionID.count == 16 else { return nil }
        return credential
    }

    func save(_ credential: TrustedHostCredential) -> Bool {
        guard !credential.fingerprint.isEmpty,
              credential.hostID.count == 16,
              credential.deviceID.count == 16,
              credential.secret.count == 32,
              credential.sessionID.count == 16,
              let data = try? JSONEncoder().encode(credential) else { return false }
        return backing.save(data, fingerprint: credential.fingerprint)
    }

    func delete(fingerprint: String) {
        backing.delete(fingerprint: fingerprint)
    }
}

struct TrustedHostFingerprintStore {
    private let service = "com.screencasting.trusted-host-identity.v1"
    private let account = "selected-host"

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let fingerprint = String(data: data, encoding: .utf8) else {
            return nil
        }
        return fingerprint
    }

    func save(_ fingerprint: String) -> Bool {
        guard !fingerprint.isEmpty,
              let data = fingerprint.data(using: .utf8) else { return false }
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let update = SecItemUpdate(key as CFDictionary, values as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = key
        values.forEach { add[$0.key] = $0.value }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}

enum TrustedReconnectPolicy {
    private static let delays: [TimeInterval] = [0, 0.25, 1, 2, 5]

    static func delay(forAttempt attempt: Int) -> TimeInterval {
        delays[min(max(attempt, 0), delays.count - 1)]
    }

    static func shouldSchedule(
        isForegroundActive: Bool,
        reconnectEnabled: Bool,
        lastKnownHost: String?
    ) -> Bool {
        isForegroundActive && reconnectEnabled &&
            !(lastKnownHost?.isEmpty ?? true)
    }
}

struct TrustedSettingsState: Equatable {
    let requestID: UInt32
    let generation: UInt64
    let bitrateBps: UInt32
    let audioEnabled: Bool
    let rejectionReason: UInt8

    static func decode(_ payload: Data) -> TrustedSettingsState? {
        guard payload.count == 24, payload[0] == 1, payload[1] <= 1,
              payload[2] <= 4, payload[3] == 0,
              payload[20] == 0, payload[21] == 0,
              payload[22] == 0, payload[23] == 0 else { return nil }
        let requestID = payload.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
        }
        let generation = payload.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self).littleEndian
        }
        let bitrateBps = payload.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self).littleEndian
        }
        guard bitrateBps >= 3_000_000, bitrateBps <= 50_000_000,
              bitrateBps.isMultiple(of: 1_000_000) else { return nil }
        return TrustedSettingsState(
            requestID: requestID,
            generation: generation,
            bitrateBps: bitrateBps,
            audioEnabled: payload[1] == 1,
            rejectionReason: payload[2])
    }
}

private enum TrustedDeviceIdentity {
    private static let defaultsKey = "trustedDeviceId.v1"

    static func loadOrCreate() -> Data {
        if let stored = UserDefaults.standard.data(forKey: defaultsKey),
           stored.count == 16 { return stored }
        var uuid = UUID().uuid
        let data = withUnsafeBytes(of: &uuid) { Data($0) }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        return data
    }
}

enum ClientDisplayOrientation: UInt8, Equatable {
    case landscape = 0
    case portrait = 1
}

enum DisplayOrientationMode: String, CaseIterable, Hashable {
    case automatic
    case landscape
    case portrait

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .landscape: return "Landscape"
        case .portrait: return "Portrait"
        }
    }

    func resolved(using interfaceOrientation: ClientDisplayOrientation) -> ClientDisplayOrientation {
        switch self {
        case .automatic: return interfaceOrientation
        case .landscape: return .landscape
        case .portrait: return .portrait
        }
    }
}

struct DisplayResolution: Hashable, Identifiable {
    let width: UInt32
    let height: UInt32

    var id: String { "\(width)x\(height)" }
    var title: String { "\(width) × \(height)" }
}

struct DisplayMode: Hashable {
    let width: UInt32
    let height: UInt32
    let refreshHz: UInt32
    let isExperimental: Bool

    var resolution: DisplayResolution {
        DisplayResolution(width: width, height: height)
    }
}

struct DisplayCapabilities: Equatable {
    static let encodedSize = 52

    let modes: [DisplayMode]
    let preferred: DisplayMode

    var resolutions: [DisplayResolution] {
        var seen = Set<DisplayResolution>()
        return modes.compactMap { mode in
            let resolution = mode.resolution
            return seen.insert(resolution).inserted ? resolution : nil
        }
    }

    func refreshRates(for resolution: DisplayResolution) -> [UInt32] {
        modes.compactMap { mode in
            mode.resolution == resolution ? mode.refreshHz : nil
        }
    }

    func supports(_ preference: DisplayPreference) -> Bool {
        modes.contains {
            $0.width == preference.width &&
            $0.height == preference.height &&
            $0.refreshHz == preference.refreshHz
        }
    }

    static func decode(_ data: Data) -> DisplayCapabilities? {
        guard data.count == encodedSize,
              data[0] == 1,
              (1...4).contains(Int(data[1])) else {
            return nil
        }

        let modeCount = Int(data[1])
        var decodedModes: [DisplayMode] = []
        decodedModes.reserveCapacity(modeCount)
        for index in 0..<modeCount {
            let offset = 4 + (index * 12)
            let width = data.loadLittleEndian(UInt32.self, at: offset)
            let height = data.loadLittleEndian(UInt32.self, at: offset + 4)
            let refreshHz = UInt32(data.loadLittleEndian(UInt16.self, at: offset + 8))
            let flags = data.loadLittleEndian(UInt16.self, at: offset + 10)
            guard width > 0,
                  height > 0,
                  refreshHz > 0,
                  (flags & ~UInt16(1)) == 0 else {
                return nil
            }
            decodedModes.append(DisplayMode(
                width: width,
                height: height,
                refreshHz: refreshHz,
                isExperimental: (flags & 1) != 0))
        }
        let nativeModes = decodedModes.filter {
            $0.width == 2388 &&
            $0.height == 1668 &&
            $0.refreshHz == 60 &&
            !$0.isExperimental
        }
        guard decodedModes.count == 1,
              nativeModes.count == 1,
              let preferred = nativeModes.first else { return nil }
        return DisplayCapabilities(modes: nativeModes, preferred: preferred)
    }
}

struct DisplayConfigurationRequest: Equatable {
    let width: UInt32
    let height: UInt32
    let refreshHz: UInt32
    let orientation: ClientDisplayOrientation
    let requestId: UInt32

    func encode() -> Data {
        var data = Data(count: 20)
        data[0] = 1
        data[1] = orientation.rawValue
        data.storeLittleEndian(width, at: 4)
        data.storeLittleEndian(height, at: 8)
        data.storeLittleEndian(refreshHz, at: 12)
        data.storeLittleEndian(requestId, at: 16)
        return data
    }
}

struct DisplayReady: Equatable {
    let width: UInt32
    let height: UInt32
    let refreshHz: UInt32
    let orientation: ClientDisplayOrientation
    let requestId: UInt32
    let generation: UInt32

    static func decode(_ data: Data) -> DisplayReady? {
        guard data.count == 24,
              data[0] == 1,
              let orientation = ClientDisplayOrientation(rawValue: data[1]) else {
            return nil
        }
        let width = data.loadLittleEndian(UInt32.self, at: 4)
        let height = data.loadLittleEndian(UInt32.self, at: 8)
        let refreshHz = data.loadLittleEndian(UInt32.self, at: 12)
        guard width > 0, height > 0, refreshHz > 0 else { return nil }
        return DisplayReady(
            width: width,
            height: height,
            refreshHz: refreshHz,
            orientation: orientation,
            requestId: data.loadLittleEndian(UInt32.self, at: 16),
            generation: data.loadLittleEndian(UInt32.self, at: 20))
    }
}

enum DisplayConfigurationFailureReason: UInt8, Equatable {
    case unsupportedMode = 1
    case applyFailed = 2
}

struct DisplayConfigurationFailed: Equatable {
    let requestId: UInt32
    let reason: DisplayConfigurationFailureReason

    static func decode(_ data: Data) -> DisplayConfigurationFailed? {
        guard data.count == 8,
              data[0] == 1,
              let reason = DisplayConfigurationFailureReason(rawValue: data[1]) else {
            return nil
        }
        return DisplayConfigurationFailed(
            requestId: data.loadLittleEndian(UInt32.self, at: 4),
            reason: reason)
    }
}

struct DisplayPreference: Equatable {
    static let nativeLandscapeWidth: UInt32 = 2388
    static let nativeLandscapeHeight: UInt32 = 1668
    static let nativeRefreshHz: UInt32 = 60
    static let defaultValue = DisplayPreference(
        width: nativeLandscapeWidth,
        height: nativeLandscapeHeight,
        refreshHz: nativeRefreshHz,
        orientationMode: .automatic)

    let width: UInt32
    let height: UInt32
    let refreshHz: UInt32
    let orientationMode: DisplayOrientationMode

    var resolution: DisplayResolution {
        DisplayResolution(width: width, height: height)
    }

    func makeRequest(
        interfaceOrientation: ClientDisplayOrientation,
        requestId: UInt32
    ) -> DisplayConfigurationRequest {
        let orientation = orientationMode.resolved(using: interfaceOrientation)
        return DisplayConfigurationRequest(
            width: orientation == .portrait
                ? Self.nativeLandscapeHeight
                : Self.nativeLandscapeWidth,
            height: orientation == .portrait
                ? Self.nativeLandscapeWidth
                : Self.nativeLandscapeHeight,
            refreshHz: Self.nativeRefreshHz,
            orientation: orientation,
            requestId: requestId)
    }

    func reconciled(with capabilities: DisplayCapabilities) -> DisplayPreference {
        guard capabilities.supports(self) else {
            return DisplayPreference(
                width: capabilities.preferred.width,
                height: capabilities.preferred.height,
                refreshHz: capabilities.preferred.refreshHz,
                orientationMode: orientationMode)
        }
        return self
    }
}

struct DisplayRequestGate {
    private var nextRequestId: UInt32 = 0
    private(set) var pending: DisplayConfigurationRequest?
    private(set) var effective: DisplayReady?

    var isInputSuppressed: Bool { pending != nil }

    mutating func begin(_ requested: DisplayConfigurationRequest) -> DisplayConfigurationRequest? {
        let candidate = DisplayConfigurationRequest(
            width: requested.width,
            height: requested.height,
            refreshHz: requested.refreshHz,
            orientation: requested.orientation,
            requestId: 0)
        if let pending, sameConfiguration(pending, candidate) {
            return nil
        }
        if let effective,
           effective.width == candidate.width,
           effective.height == candidate.height,
           effective.refreshHz == candidate.refreshHz,
           effective.orientation == candidate.orientation {
            return nil
        }

        nextRequestId &+= 1
        if nextRequestId == 0 { nextRequestId = 1 }
        let issued = DisplayConfigurationRequest(
            width: candidate.width,
            height: candidate.height,
            refreshHz: candidate.refreshHz,
            orientation: candidate.orientation,
            requestId: nextRequestId)
        pending = issued
        return issued
    }

    mutating func accept(_ ready: DisplayReady) -> Bool {
        guard let pending,
              pending.requestId == ready.requestId,
              sameConfiguration(pending, ready) else {
            return false
        }
        effective = ready
        self.pending = nil
        return true
    }

    mutating func reject(_ failed: DisplayConfigurationFailed) -> Bool {
        guard pending?.requestId == failed.requestId else { return false }
        pending = nil
        return true
    }

    mutating func reset() {
        pending = nil
        effective = nil
    }

    private func sameConfiguration(
        _ request: DisplayConfigurationRequest,
        _ candidate: DisplayConfigurationRequest
    ) -> Bool {
        request.width == candidate.width &&
        request.height == candidate.height &&
        request.refreshHz == candidate.refreshHz &&
        request.orientation == candidate.orientation
    }

    private func sameConfiguration(
        _ request: DisplayConfigurationRequest,
        _ ready: DisplayReady
    ) -> Bool {
        request.width == ready.width &&
        request.height == ready.height &&
        request.refreshHz == ready.refreshHz &&
        request.orientation == ready.orientation
    }
}

private enum DisplayPreferenceStore {
    private static let widthKey = "ScreenCasting.display.preferredWidth"
    private static let heightKey = "ScreenCasting.display.preferredHeight"
    private static let refreshKey = "ScreenCasting.display.preferredRefreshHz"
    private static let orientationKey = "ScreenCasting.display.orientationMode"

    static func load() -> DisplayPreference {
        let defaults = UserDefaults.standard
        let width = (defaults.object(forKey: widthKey) as? NSNumber)?.uint32Value
        let height = (defaults.object(forKey: heightKey) as? NSNumber)?.uint32Value
        let refreshHz = (defaults.object(forKey: refreshKey) as? NSNumber)?.uint32Value
        let orientationMode = defaults.string(forKey: orientationKey)
            .flatMap(DisplayOrientationMode.init(rawValue:)) ?? .automatic
        guard let width, let height, let refreshHz,
              width > 0, height > 0, refreshHz > 0 else {
            return DisplayPreference.defaultValue
        }
        return DisplayPreference(
            width: width,
            height: height,
            refreshHz: refreshHz,
            orientationMode: orientationMode)
    }

    static func save(_ preference: DisplayPreference) {
        let defaults = UserDefaults.standard
        defaults.set(preference.width, forKey: widthKey)
        defaults.set(preference.height, forKey: heightKey)
        defaults.set(preference.refreshHz, forKey: refreshKey)
        defaults.set(preference.orientationMode.rawValue, forKey: orientationKey)
    }
}

enum RealtimeAudioNegotiationPolicy {
    static func advertisedCodecs(modes: UInt8) -> UInt8 {
        let realtimeModes = RealtimeTransportMode.wifiRTP |
            RealtimeTransportMode.usbSplitTLS
        return (modes & realtimeModes) == 0
            ? AudioCodecCapabilities.pcm
            : AudioCodecCapabilities.pcm | AudioCodecCapabilities.opus
    }

    static func isOfferCompatible(
        mode: UInt8,
        audioCodec: UInt8,
        advertisedModes: UInt8,
        advertisedCodecs: UInt8
    ) -> Bool {
        let exactPair =
            (mode == RealtimeTransportMode.legacyTLS &&
             audioCodec == AudioCodecCapabilities.pcm) ||
            (mode == RealtimeTransportMode.wifiRTP &&
             (audioCodec == AudioCodecCapabilities.opus ||
              audioCodec == AudioCodecCapabilities.none)) ||
            (mode == RealtimeTransportMode.usbSplitTLS &&
             audioCodec == AudioCodecCapabilities.opus)
        return exactPair &&
            (advertisedModes & mode) != 0 &&
            (advertisedCodecs & audioCodec) != 0
    }
}

enum ScstAudioPayloadKind: Equatable {
    case legacyPCM
    case opus
    case reject
}

enum ScstAudioPolicy {
    static func classify(
        mode: UInt8?,
        flags: UInt16,
        payloadLength: Int
    ) -> ScstAudioPayloadKind {
        guard payloadLength > 0 else { return .reject }
        if mode == RealtimeTransportMode.legacyTLS {
            return flags == 0 ? .legacyPCM : .reject
        }
        if mode == RealtimeTransportMode.usbSplitTLS {
            return flags == WireProtocol.audioFlagOpus &&
                payloadLength <= WireProtocol.maximumOpusPayloadLength
                ? .opus
                : .reject
        }
        return .reject
    }
}

struct WireHeader {
    let type: WireMessageType
    let flags: UInt16
    let payloadLength: Int
    let sequence: UInt32
}

struct WireMessage {
    let header: WireHeader
    let payload: Data
    let firstByteAt: TimeInterval
}

enum WireParserError: Error, Equatable {
    case invalidHeader
    case oversizedPayload(Int)
}

enum WireParserEvent {
    case message(WireMessage)
    case discardedFixedControl(WireHeader)
    case failure(WireParserError)
}

/// Incremental SCST parser with one fixed header buffer and one exactly-sized
/// payload allocation. Each receive chunk is consumed by cursor, so bytes
/// coalesced after a message remain available for the next header.
final class WireStreamParser {
    private enum State {
        case header
        case payload(WireHeader)
        case draining(WireHeader, remaining: Int)
        case failed
    }

    private var generation: UInt64
    private var state: State = .header
    private var headerBytes = Data(count: WireProtocol.headerSize)
    private var headerOffset = 0
    private var payload = Data()
    private var payloadOffset = 0
    private var messageFirstByteAt: TimeInterval = 0
    private(set) var maximumDrainChunkObserved = 0

    init(generation: UInt64) {
        self.generation = generation
    }

    var allocatedPayloadBytes: Int { payload.count }

    var suggestedReceiveLength: Int {
        switch state {
        case .header:
            return WireProtocol.receiveChunkSize
        case .payload(let header):
            return max(1, min(
                WireProtocol.receiveChunkSize,
                header.payloadLength - payloadOffset))
        case .draining(_, let remaining):
            return max(1, min(WireProtocol.drainChunkSize, remaining))
        case .failed:
            return 1
        }
    }

    func reset(generation: UInt64) {
        self.generation = generation
        state = .header
        headerOffset = 0
        payload = Data()
        payloadOffset = 0
        messageFirstByteAt = 0
        maximumDrainChunkObserved = 0
    }

    func consume(
        _ data: Data,
        generation: UInt64,
        receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
        onEvent: (WireParserEvent) -> Void
    ) {
        guard generation == self.generation, !data.isEmpty else { return }

        data.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            var sourceOffset = 0

            while sourceOffset < source.count {
                guard generation == self.generation else { break }
                switch state {
                case .header:
                    if headerOffset == 0 { messageFirstByteAt = receivedAt }
                    let copied = min(
                        WireProtocol.headerSize - headerOffset,
                        source.count - sourceOffset)
                    headerBytes.withUnsafeMutableBytes { destination in
                        destination.baseAddress!
                            .advanced(by: headerOffset)
                            .copyMemory(
                                from: sourceBase.advanced(by: sourceOffset),
                                byteCount: copied)
                    }
                    headerOffset += copied
                    sourceOffset += copied
                    if headerOffset == WireProtocol.headerSize {
                        preparePayload(onEvent: onEvent)
                    }

                case .payload(let header):
                    let copied = min(
                        header.payloadLength - payloadOffset,
                        source.count - sourceOffset)
                    payload.withUnsafeMutableBytes { destination in
                        destination.baseAddress!
                            .advanced(by: payloadOffset)
                            .copyMemory(
                                from: sourceBase.advanced(by: sourceOffset),
                                byteCount: copied)
                    }
                    payloadOffset += copied
                    sourceOffset += copied
                    if payloadOffset == header.payloadLength {
                        let completedPayload = payload
                        let firstByteAt = messageFirstByteAt
                        resetForNextHeader()
                        onEvent(.message(WireMessage(
                            header: header,
                            payload: completedPayload,
                            firstByteAt: firstByteAt)))
                    }

                case .draining(let header, let remaining):
                    let consumed = min(
                        WireProtocol.drainChunkSize,
                        remaining,
                        source.count - sourceOffset)
                    maximumDrainChunkObserved = max(maximumDrainChunkObserved, consumed)
                    sourceOffset += consumed
                    let nextRemaining = remaining - consumed
                    if nextRemaining == 0 {
                        resetForNextHeader()
                        onEvent(.discardedFixedControl(header))
                    } else {
                        state = .draining(header, remaining: nextRemaining)
                    }

                case .failed:
                    sourceOffset = source.count
                }
            }
        }
    }

    private func preparePayload(onEvent: (WireParserEvent) -> Void) {
        let magic = headerBytes.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
        }
        let version = headerBytes[4]
        guard magic == WireProtocol.magic,
              version == WireProtocol.version,
              let type = WireMessageType(rawValue: headerBytes[5]) else {
            state = .failed
            payload = Data()
            onEvent(.failure(.invalidHeader))
            return
        }

        let flags = headerBytes.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self).littleEndian
        }
        let payloadLength = Int(headerBytes.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian
        })
        let sequence = headerBytes.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian
        }
        guard payloadLength <= WireProtocol.maxPayloadSize else {
            state = .failed
            payload = Data()
            onEvent(.failure(.oversizedPayload(payloadLength)))
            return
        }

        let header = WireHeader(
            type: type,
            flags: flags,
            payloadLength: payloadLength,
            sequence: sequence)
        let fixedLength: Int?
        switch type {
        case .ping, .pong, .videoFeedback:
            fixedLength = 16
        case .displayCapabilities:
            fixedLength = DisplayCapabilities.encodedSize
        case .displayConfigurationRequest:
            fixedLength = 20
        case .displayReady:
            fixedLength = 24
        case .displayConfigurationFailed:
            fixedLength = 8
        case .trustedDeviceChallenge:
            fixedLength = 112
        case .trustedDeviceProof:
            fixedLength = 48
        case .pairingSuccess:
            fixedLength = 80
        case .sessionResumeResult:
            fixedLength = 17
        case .settingsGet, .settingsState, .settingsUpdate,
             .settingsApplied, .settingsRejected:
            fixedLength = 24
        case .forgetDevice:
            fixedLength = 17
        case .forgetDeviceResult:
            fixedLength = 2
        case .clientCapabilities:
            fixedLength = ClientCapabilities.encodedSize
        case .transportOffer:
            fixedLength = TransportOffer.encodedSize
        case .transportReady:
            fixedLength = TransportReady.encodedSize
        case .transportCommit:
            fixedLength = TransportCommit.encodedSize
        case .usbLaneBind:
            fixedLength = 60
        case .usbLaneBindResult:
            fixedLength = 28
        default:
            fixedLength = nil
        }

        if let fixedLength, payloadLength != fixedLength {
            payload = Data()
            payloadOffset = 0
            if payloadLength == 0 {
                resetForNextHeader()
                onEvent(.discardedFixedControl(header))
            } else {
                state = .draining(header, remaining: payloadLength)
            }
            return
        }

        if payloadLength == 0 {
            let firstByteAt = messageFirstByteAt
            resetForNextHeader()
            onEvent(.message(WireMessage(
                header: header,
                payload: Data(),
                firstByteAt: firstByteAt)))
            return
        }

        payload = Data(count: payloadLength)
        payloadOffset = 0
        state = .payload(header)
    }

    private func resetForNextHeader() {
        state = .header
        headerOffset = 0
        payload = Data()
        payloadOffset = 0
        messageFirstByteAt = 0
    }
}

/// Enforces the single executor used by production receive/reset operations.
/// Tests use the same seam to race caller threads while parser mutation remains
/// serialized on the supplied network queue.
final class WireParserQueueDomain {
    private let queue: DispatchQueue
    private let parser: WireStreamParser

    init(generation: UInt64, queue: DispatchQueue) {
        self.queue = queue
        parser = WireStreamParser(generation: generation)
    }

    var suggestedReceiveLength: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return parser.suggestedReceiveLength
    }

    var allocatedPayloadBytes: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return parser.allocatedPayloadBytes
    }

    var maximumDrainChunkObserved: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return parser.maximumDrainChunkObserved
    }

    func reset(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        parser.reset(generation: generation)
    }

    func consume(
        _ data: Data,
        generation: UInt64,
        receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
        onEvent: (WireParserEvent) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        parser.consume(data, generation: generation, receivedAt: receivedAt, onEvent: onEvent)
    }
}

private final class ConnectionGenerationClock {
    private let lock = NSLock()
    private var value: UInt64 = 0

    var current: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance() -> UInt64 {
        lock.lock()
        value &+= 1
        let result = value
        lock.unlock()
        return result
    }
}

// MARK: - Touch Input Wire Protocol
// Mirrors C# TouchInputPacket / TouchEventType exactly.
// Layout: 8 bytes, little-endian:
//   [0-1]  UInt16  Magic      0x5449  ('T','I')
//   [2]    UInt8   EventType  TouchEventType raw value
//   [3]    UInt8   Pressure   0–255  (mapped from 0.0–1.0)
//   [4-5]  UInt16  X          logical pixel column  (or 0–65535 normalised)
//   [6-7]  UInt16  Y          logical pixel row     (or 0–65535 normalised)

private enum TouchWireProtocol {
    static let magic: UInt16 = 0x5449   // 'T','I'
    static let packetSize    = 8
}

/// Touch event kinds — mirrors C# `TouchEventType` enum byte-for-byte.
public enum TouchEventType: UInt8 {
    case move  = 0
    case down  = 1
    case up    = 2
    case force = 3
}

enum InputDelivery: Equatable {
    case reliable
    case unreliableLatest
}

enum InputDeliveryPolicy {
    static func forEvent(_ eventType: TouchEventType) -> InputDelivery {
        eventType == .move ? .unreliableLatest : .reliable
    }
}

// MARK: - Telemetry Wire Protocol
// Telemetry (iPad → PC, 2×/sec)
// Layout: 8 bytes, little-endian:
//   [0-1]  UInt16  Magic      0x5445  ('T','E')
//   [2-3]  UInt16  Reserved   0
//   [4-5]  UInt16  NetworkLatencyMs
//   [6-7]  UInt16  DecodeLatencyMs

private enum TelemetryWireProtocol {
    static let magic: UInt16 = 0x5445   // 'T','E'
    static let packetSize    = 8
}

// MARK: - Bitrate Control Wire Protocol
// Bitrate Control (bidirectional sync)
// Layout: 8 bytes, little-endian:
//   [0-1]  UInt16  Magic           0x4243  ('B','C')
//   [2]    UInt8   IsAdaptive      0=manual, 1=adaptive
//   [3]    UInt8   Reserved        0
//   [4-5]  UInt16  TargetBitrateMbps
//   [6-7]  UInt16  Reserved        0

private enum BitrateWireProtocol {
    static let magic: UInt16 = 0x4243   // 'B','C'
    static let packetSize    = 8
}

// MARK: - Audio Wire Protocol
// Audio streaming: PC → iPad (variable-length)
// Layout: 4-byte header + N-byte PCM payload, little-endian:
//   [0-1]  UInt16  Magic        0x4155  ('A','U')
//   [2-3]  UInt16  PayloadSize  byte count of PCM data  (max 65535)
//   [4..N] byte[]  Raw PCM      16-bit / 48 kHz / Stereo / interleaved

private enum AudioWireProtocol {
    static let magic: UInt16 = 0x4155   // 'A','U'
    static let headerSize    = 4        // magic(2) + payloadSize(2)
}

// MARK: - NetworkManager

/// High-performance, TLS-secured outbound NWConnection to the ScreenCasting Windows host.
/// Implements:
///   1. TLS with custom self-signed certificate trust bypass (LAN-safe).
///   2. PIN authentication handshake phase before video payload begins.
///   3. Observable ConnectionState for SwiftUI bindings.
public class NetworkManager: ObservableObject {
    private static let lastKnownHostKey = "lastKnownScreenCastingHost.v1"
    private enum ActiveTransportKind: Equatable {
        case wifi
        case usb
    }

    // MARK: Published State
    @Published public var connectionState: ConnectionState = .idle
    public private(set) var bytesReceived: UInt64 = 0
    @Published public private(set) var hostFingerprint: String?
    @Published public private(set) var hostIdentityCode: String?
    @Published public private(set) var usbServerFingerprint: String?

    // The Host is the authority for selectable modes. These values only mirror
    // authenticated control responses for the connected settings surface.
    @Published private(set) var displayCapabilities: DisplayCapabilities?
    @Published private(set) var displayPreference = DisplayPreference.defaultValue
    @Published private(set) var effectiveDisplayState: DisplayReady?
    @Published private(set) var displayConfigurationFailureMessage: String?
    @Published private(set) var isDisplayConfigurationPending = false

    // MARK: Published Host-authoritative settings
    /// Retained for compatibility with the existing telemetry surface. The
    /// persistent client settings contract is manual-only.
    @Published public var isAdaptiveBitrate: Bool   = false
    /// Current target bitrate in Mbps (3–50). Reflects the latest Host state.
    @Published public var targetBitrateMbps: Double = 20.0
    @Published public private(set) var audioEnabled: Bool = true
    @Published public private(set) var settingsApplyStatus: String = ""
    @Published public private(set) var settingsGeneration: UInt64 = 0
    private var nextSettingsRequestID: UInt32 = 1
    private var committedBitrateMbps: Double = 20
    private var committedAudioEnabled = true
    private var latestSettingsRequestID: UInt32 = 0
    private var latestSettingsExpectedGeneration: UInt64 = 0

    // Convenience computed properties so existing views don't break
    public var isConnected:  Bool { connectionState == .streaming }
    public var isListening:  Bool { connectionState == .listening }

    // MARK: Private
    private var connection: NWConnection?
    private var lastEndpoint: NWEndpoint?
    private var verifiedHostFingerprint: String?
    private var verifiedHostIdentityCode: String?
    private var hostIdentityConfirmationRequired = false
    private var hostIdentityConfirmed = false
    private var trustedCredential: TrustedHostCredential?
    private let trustedCredentialStore = TrustedHostCredentialStore()
    private let trustedHostFingerprintStore = TrustedHostFingerprintStore()
    private let trustedDeviceID = TrustedDeviceIdentity.loadOrCreate()
    private var isForegroundActive = true
    private var reconnectEnabled = true
    private var reconnectAttempt = 0
    private var reconnectGeneration: UInt64 = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var usbListener: NWListener?
    private let connectionGenerationClock = ConnectionGenerationClock()
    private var connectionGeneration: UInt64 {
        connectionGenerationClock.current
    }
    private var listenerGeneration: UInt64 = 0
    private let networkQueue = DispatchQueue(label: "com.iPadCasting.network", qos: .userInteractive)
    private lazy var controlChannelWriter = ControlChannelWriter(
        queue: networkQueue,
        sender: { [weak self] data, completion in
            guard let connection = self?.connection else {
                completion(nil)
                return
            }
            connection.send(
                content: data,
                completion: .contentProcessed(completion))
        })
    private lazy var wireParser = WireParserQueueDomain(
        generation: connectionGeneration,
        queue: networkQueue)
    private var wireReceiveActiveGeneration: UInt64?
    private var wireAuthenticatedGeneration: UInt64?
    private var committedTransportGeneration: UInt64?
    private var pendingTransportOffer: TransportOffer?
    private var activeVideoCodec: VideoDecoderCodec = .hevc
    private var wifiCommitGate = WifiCommitGate()
    private var usbSplitCommitGate = UsbSplitCommitGate()
    private var advertisedClientCapabilities: ClientCapabilities?
    private var negotiationFallbackToken: UInt64 = 0
    private lazy var wifiMediaReceiver = WifiMediaReceiver(
        networkQueue: networkQueue,
        decoder: { [weak self] data, sequence, isIDR, receivedAt in
            self?.decoder.processInputData(
                data,
                sequence: sequence,
                isIDR: isIDR,
                isLengthPrefixed: true,
                receivedAt: receivedAt)
        },
        audioConsumer: { data, sequence, timestamp, generation in
            AudioManager.shared.playOpusData(
                data,
                sequence: sequence,
                timestamp: timestamp,
                generation: generation)
        },
        onProbeAuthenticated: { [weak self] generation, sessionID in
            self?.handleWifiProbeAuthenticated(
                generation: generation,
                sessionID: sessionID)
        },
        onCommittedFailure: { [weak self] generation, error in
            self?.handleWifiCommittedFailure(
                generation: generation,
                error: error)
        },
        framePacketObserver: {
            [weak self] generation, sequence, marker, isIDR, bytes, arrivalTime in
            guard let self else { return }
            self.transportTelemetry.recordWifiPacket(
                sequence: sequence,
                marker: marker,
                isIDR: isIDR,
                bytes: bytes,
                arrivalTime: arrivalTime,
                generation: generation)
        },
        timedOutcomeObserver: {
            [weak self] generation, outcome, observedAt in
            guard let self else { return }
            self.transportTelemetry.recordWifiReassembly(
                outcome: outcome,
                observedAt: observedAt,
                generation: generation)
        },
        securityDropObserver: { [weak self] counters in
            self?.transportTelemetry.recordWifiSecurityDrops(counters)
        },
        telemetryProvider: { [weak self] in
            guard let self else { return .zero }
            let feedback = self.transportTelemetry.makeFeedback()
            return WifiFeedbackTelemetry(
                lastDecoded: feedback.1,
                lastPresented: feedback.0,
                jitterMs: 0,
                rttP95Ms: feedback.2,
                queueAgeP95Ms: feedback.4,
                decodeP95Ms: feedback.3)
        })
    private var usbLaneConnections: [UsbLaneKind: NWConnection] = [:]
    private lazy var usbLaneServer = UsbLaneServer(
        networkQueue: networkQueue,
        parametersProvider: { [weak self] in
            guard let self else { throw USBListenerError.identityUnavailable }
            return try self.buildUSBListenerParameters()
        },
        onBound: { [weak self] lane, _, connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.usbLaneConnections[lane]?.cancel()
            self.usbLaneConnections[lane] = connection
            self.startUsbLaneReceiveLoop(connection, lane: lane)
        },
        onFailure: { [weak self] error in
            self?.handleStreamError(
                "USB media lane failed: \(error.localizedDescription)")
        })

    // Telemetry timer: fires 2× per second while streaming.
    private var telemetryTimer: DispatchSourceTimer?
    private var adaptiveTelemetryTimer: DispatchSourceTimer?
    private var committedRealtimeMode: UInt8?
    private var committedRealtimeSessionID: SessionID?
    private var wifiLegacyFallbackGeneration: UInt64?
    private var wifiLegacyFallbackRequestGeneration: UInt64?
    private let transportTelemetry = TransportTelemetry()
    private var lastHudSnapshotPublishedAt: TimeInterval = 0
    private var lastClientPingSentAt: TimeInterval = 0
    private var nextClientPingNonce: UInt64 = 1
    private var pendingClientPings: [UInt64: TimeInterval] = [:]
    private var activeDisplayCapabilities: DisplayCapabilities?
    private var activeDisplayPreference = DisplayPreference.defaultValue
    private var displayRequestGate = DisplayRequestGate()
    private var pendingDisplayPreference: DisplayPreference?
    private var observedInterfaceOrientation: ClientDisplayOrientation = .landscape
    private var orientationDebounceWorkItem: DispatchWorkItem?

    public init() {
        let savedDisplayPreference = DisplayPreferenceStore.load()
        displayPreference = savedDisplayPreference
        activeDisplayPreference = savedDisplayPreference
        decoder.onDecodeLatency = {
            [weak self] sequence, generation, decodeStartedAt, latencyMs in
            self?.transportTelemetry.recordDecodeCallback(
                sequence: sequence,
                generation: generation,
                decodeStartedAt: decodeStartedAt,
                durationMs: latencyMs)
        }
        decoder.onDecodeCompleted = {
            [weak self] sequence, generation, succeeded in
            guard let self else { return }
            self.networkQueue.async {
                self.wifiMediaReceiver.decoderDidComplete(
                    sequence: sequence,
                    generation: generation,
                    succeeded: succeeded)
            }
        }
        decoder.onFrameDropped = { [weak self] sequence, generation in
            self?.transportTelemetry.recordDropped(
                sequence: sequence,
                generation: generation)
        }
        decoder.onMailboxAge = { [weak self] sequence, ageMs in
            self?.transportTelemetry.recordMailboxAge(sequence: sequence, ageMs: ageMs)
        }
        decoder.onRecoveryNeeded = { [weak self] in
            guard let self else { return }
            self.networkQueue.async {
                guard self.wireAuthenticatedGeneration == self.connectionGeneration else { return }
                if self.committedRealtimeMode == RealtimeTransportMode.wifiRTP {
                    self.wifiMediaReceiver.requestImmediateRecoveryFeedback(
                        generation: self.connectionGeneration)
                } else {
                    self.sendVideoFeedback()
                }
            }
        }
    }

    // MARK: - Public API

    /// Connect to the Windows host over TLS using an NWEndpoint directly (e.g. from Bonjour discovery).
    /// - Parameter endpoint: The resolved NWEndpoint (service endpoint or hostPort)
    public func connect(to endpoint: NWEndpoint) {
        // Claim the socket before publishing state so discovery and lifecycle
        // callbacks cannot create two simultaneous reconnect attempts.
        guard connection == nil,
              connectionState == .idle || isDisconnected else { return }

        lastEndpoint = endpoint

        _ = connectionGenerationClock.advance()
        // Settings generations are scoped to the Host credential/session.
        // After Forget Host (or a fresh pairing), the Host may legitimately
        // start again at generation zero; retaining the old value would cause
        // the client to discard the authoritative state and send stale writes.
        settingsGeneration = 0
        settingsApplyStatus = ""
        verifiedHostFingerprint = nil
        verifiedHostIdentityCode = nil
        hostIdentityCode = nil
        hostIdentityConfirmationRequired = false
        hostIdentityConfirmed = false
        reconnectWorkItem?.cancel()
        networkQueue.async { [weak self] in
            self?.resetDisplaySession()
        }
        let parameters = buildTLSParameters(for: endpoint)
        connection = NWConnection(to: endpoint, using: parameters)

        setupStateHandler()
        setState(.connecting)
        print("[IPAD][TCP_CONNECT] endpoint=\(endpoint)")
        connectionTimeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.connectionState == .connecting else { return }
            print("[IPAD][TIMEOUT] stage=TCP/TLS timeout=8s")
            self.connection?.cancel()
            self.setState(.disconnected(reason: "Timed out connecting to Windows host."))
        }
        connectionTimeoutWorkItem = timeout
        networkQueue.asyncAfter(deadline: .now() + 8, execute: timeout)
        connection?.start(queue: networkQueue)
    }

    /// Connect to the Windows host over TLS using host String IP & port.
    /// - Parameters:
    ///   - host: Host IP or mDNS hostname (e.g. "192.168.1.10" or "LÂM-DESKTOP.local")
    ///   - port: TCP port the Windows NetworkManager listens on (default 27015)
    public func connect(to host: String, port: UInt16 = 27015) {
        UserDefaults.standard.set(host, forKey: Self.lastKnownHostKey)
        reconnectEnabled = true
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        connect(to: endpoint)
    }

    public func applicationDidBecomeActive() {
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.isForegroundActive = true
            print("[IPAD][APP_LIFECYCLE] state=active")
            self.scheduleAutoReconnect(reset: true)
        }
    }

    public func applicationDidEnterBackground() {
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.isForegroundActive = false
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            if self.connection != nil {
                // An authenticated NWConnection may remain non-nil while iOS
                // suspends its receive callbacks. Tear it down so the next
                // foreground transition cannot mistake a stale socket for a
                // live session and skip reconnect.
                self.handleStreamError(
                    "Application backgrounded; reconnecting on resume.")
            }
            print("[IPAD][APP_LIFECYCLE] state=background")
        }
    }

    public func connectDiscoveredHostIfNeeded(_ endpoint: NWEndpoint) {
        guard isForegroundActive,
              reconnectEnabled,
              connectionState == .idle || isDisconnected else { return }
        connect(to: endpoint)
    }

    /// Confirms the displayed Wi-Fi Host identity after the user compares it
    /// with the identity code shown by the Windows Host.
    public func confirmHostIdentity() {
        networkQueue.async { [weak self] in
            guard let self,
                  self.hostIdentityConfirmationRequired,
                  self.verifiedHostFingerprint != nil,
                  self.verifiedHostIdentityCode != nil,
                  self.connectionState == .awaitingHostIdentity else { return }
            self.hostIdentityConfirmed = true
            self.hostIdentityConfirmationRequired = false
            self.sendTrustedClientHello(generation: self.connectionGeneration)
        }
    }

    /// Sends the 4-digit PIN to the server as an 8-byte AuthPacketHeader.
    /// Should only be called when state == .awaitingPIN.
    public func sendAuthPIN(_ pin: String) {
        guard (connectionState == .awaitingPIN || isAuthFailed),
              activeTransportKind == .usb || hostIdentityConfirmed,
              let pinValue = UInt32(pin), pin.count == 4 else { return }

        var packet = Data(count: AuthProtocol.packetSize)
        packet.withUnsafeMutableBytes { buf in
            buf.storeBytes(of: AuthProtocol.magic.littleEndian, toByteOffset: 0, as: UInt32.self)
            buf.storeBytes(of: pinValue.littleEndian,            toByteOffset: 4, as: UInt32.self)
        }

        let generation = connectionGeneration
        enqueueControlData(packet) { [weak self] error in
            guard let self else { return }
            if let error {
                self.setState(.disconnected(reason: "PIN send failed: \(error)"))
            } else if generation == self.connectionGeneration {
                self.receiveAuthResponse(generation: generation)
            }
        }
    }

    /// Sends raw data back to the host.
    /// ⚠️ Legacy method — prefer `sendTouchEvent(type:x:y:pressure:)` for typed packets.
    public func sendData(_ data: Data) {
        guard connectionState == .streaming else { return }
        enqueueControlData(data) { error in
            if let error {
                print("[NetworkManager] sendData error: \(error)")
            }
        }
    }

    // MARK: - Public API: Touch Input Sender

    /// Sends one 8-byte Touch Input packet to the C# host over the active TLS stream.
    ///
    /// ## Concurrency Safety
    /// `NWConnection.send` is internally serialised onto its private dispatch queue
    /// (`networkQueue`). Calling this from ANY thread — including the 240Hz Pencil
    /// callback or a SwiftUI gesture handler — is safe and does **not** block.
    /// The incremental SCST receive loop runs on the same
    /// `NWConnection` but TCP full-duplex means TX and RX are independent at the OS level.
    ///
    /// ## Wire Format (8 bytes, little-endian)
    /// ```
    /// ┌────────┬──────────┬──────────┬──────┬──────┐
    /// │ Magic  │ EventType│ Pressure │  X   │  Y   │
    /// │ UInt16 │  UInt8   │  UInt8   │UInt16│UInt16│
    /// │ 0x5449 │  0–3     │  0–255   │      │      │
    /// └────────┴──────────┴──────────┴──────┴──────┘
    /// ```
    /// - Parameters:
    ///   - type:     Touch event kind (`.move`, `.down`, `.up`, `.force`).
    ///   - x:        Horizontal position in logical pixels (0–65535 for normalised use).
    ///   - y:        Vertical position in logical pixels (0–65535 for normalised use).
    ///   - pressure: Normalised pressure mapped to 0–255 byte range.
    public func sendTouchEvent(type: TouchEventType, x: UInt16, y: UInt16, pressure: UInt8) {
        guard connectionState == .streaming else { return }

        // Build the 8-byte packet inline — stack allocation, no heap alloc.
        var packet = Data(count: TouchWireProtocol.packetSize)
        packet.withUnsafeMutableBytes { buf in
            // Bytes 0-1: Magic 0x5449 LE
            buf.storeBytes(of: TouchWireProtocol.magic.littleEndian,
                           toByteOffset: 0, as: UInt16.self)
            // Byte 2: EventType
            buf.storeBytes(of: type.rawValue,
                           toByteOffset: 2, as: UInt8.self)
            // Byte 3: Pressure (0–255)
            buf.storeBytes(of: pressure,
                           toByteOffset: 3, as: UInt8.self)
            // Bytes 4-5: X LE
            buf.storeBytes(of: x.littleEndian,
                           toByteOffset: 4, as: UInt16.self)
            // Bytes 6-7: Y LE
            buf.storeBytes(of: y.littleEndian,
                           toByteOffset: 6, as: UInt16.self)
        }

        let generation = connectionGeneration
        networkQueue.async { [weak self] in
            guard let self,
                  generation == self.connectionGeneration,
                  self.committedTransportGeneration == generation,
                  !self.displayRequestGate.isInputSuppressed else {
                return
            }
            let delivery = InputDeliveryPolicy.forEvent(type)
            if self.committedRealtimeMode == RealtimeTransportMode.wifiRTP,
               delivery == .unreliableLatest {
                self.wifiMediaReceiver.enqueueInput(
                    packet,
                    generation: generation)
                return
            }
            let completion: (NWError?) -> Void = { error in
                if let error {
                    print("[NetworkManager] Touch send error: \(error)")
                }
            }
            if delivery == .unreliableLatest {
                self.controlChannelWriter.enqueueMovement(
                    packet,
                    completion: completion)
            } else if !self.controlChannelWriter.enqueue(
                packet,
                completion: completion) {
                self.handleStreamError(
                    "Control queue reached its 64-message bound.")
            }
        }
    }

    /// Convenience overload that maps **normalised float coordinates** (0.0–1.0)
    /// into the full UInt16 space (0–65535), making the packet resolution-independent.
    ///
    /// Use this from SwiftUI `DragGesture` or any view where you only have
    /// view-relative fractional coordinates rather than absolute pixel values.
    ///
    /// - Parameters:
    ///   - type:         Touch event kind.
    ///   - normX:        Horizontal position in [0.0, 1.0]. Clamped automatically.
    ///   - normY:        Vertical position in [0.0, 1.0]. Clamped automatically.
    ///   - pressure01:   Normalised pressure in [0.0, 1.0]. Clamped automatically.
    public func sendTouchEventNormalized(
        type:       TouchEventType,
        normX:      Float,
        normY:      Float,
        pressure01: Float = 1.0
    ) {
        // Map [0.0, 1.0] → [0, 65535] with clamping to prevent UInt16 overflow.
        let x        = UInt16(clamping: Int((normX.clamped(0, 1) * 65535).rounded()))
        let y        = UInt16(clamping: Int((normY.clamped(0, 1) * 65535).rounded()))
        let pressure = UInt8 (clamping: Int((pressure01.clamped(0, 1) * 255).rounded()))
        sendTouchEvent(type: type, x: x, y: y, pressure: pressure)
    }

    // MARK: - Public API: Bitrate Control Sender

    /// Sends a legacy 8-byte frame-stage packet to the host.
    /// - Parameters:
    ///   - frameReceiveDurationMs: Header-and-payload receive duration, not RTT.
    ///   - decodeLatencyMs:  Last-frame VideoToolbox decode latency in milliseconds.
    public func sendLegacyFrameStagePacket(frameReceiveDurationMs: UInt16, decodeLatencyMs: UInt16) {
        guard connectionState == .streaming else { return }

        var pkt = Data(count: TelemetryWireProtocol.packetSize)
        pkt.withUnsafeMutableBytes { buf in
            buf.storeBytes(of: TelemetryWireProtocol.magic.littleEndian, toByteOffset: 0, as: UInt16.self)
            buf.storeBytes(of: UInt16(0),                                toByteOffset: 2, as: UInt16.self) // reserved
            buf.storeBytes(of: frameReceiveDurationMs.littleEndian,      toByteOffset: 4, as: UInt16.self)
            buf.storeBytes(of: decodeLatencyMs.littleEndian,             toByteOffset: 6, as: UInt16.self)
        }
        enqueueControlData(pkt, telemetry: true)
    }

    public func sendSettingsUpdate(bitrateMbps: Double, audioEnabled: Bool) {
        let roundedMbps = round(bitrateMbps)
        guard connectionState == .streaming,
              roundedMbps >= 3, roundedMbps <= 50 else { return }
        let requestID = nextSettingsRequestID
        nextSettingsRequestID &+= 1
        let expectedGeneration = settingsGeneration
        var payload = Data(count: 24)
        payload.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: UInt8(1), toByteOffset: 0, as: UInt8.self)
            bytes.storeBytes(of: audioEnabled ? UInt8(1) : UInt8(0), toByteOffset: 1, as: UInt8.self)
            bytes.storeBytes(of: UInt8(0), toByteOffset: 2, as: UInt8.self)
            bytes.storeBytes(of: requestID.littleEndian, toByteOffset: 4, as: UInt32.self)
            bytes.storeBytes(of: expectedGeneration.littleEndian, toByteOffset: 8, as: UInt64.self)
            bytes.storeBytes(
                of: UInt32(roundedMbps * 1_000_000).littleEndian,
                toByteOffset: 16,
                as: UInt32.self)
        }
        latestSettingsRequestID = requestID
        latestSettingsExpectedGeneration = expectedGeneration
        settingsApplyStatus = "Applying…"
        print("[IPAD][SETTINGS_UPDATE] request=\(requestID) expected_generation=\(expectedGeneration) bitrate_bps=\(UInt32(roundedMbps * 1_000_000)) audio=\(audioEnabled)")
        sendWireMessage(type: .settingsUpdate, payload: payload, sequence: requestID)
    }

    public func forgetTrustedHost() {
        guard connectionState == .streaming,
              let credential = trustedCredential,
              credential.deviceID.count == 16 else { return }
        var payload = Data([1])
        payload.append(credential.deviceID)
        settingsApplyStatus = "Forgetting…"
        sendWireMessage(type: .forgetDevice, payload: payload, sequence: 0)
    }

    /// Gracefully tears down the connection and resets to .idle.
    public func stop() {
        reconnectEnabled = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        let stoppedGeneration = connectionGenerationClock.advance()
        listenerGeneration &+= 1
        decoder.invalidate()
        AudioManager.shared.reset()
        connection?.cancel()
        connection = nil
        usbListener?.cancel()
        usbListener = nil
        usbLaneServer.abort()
        usbLaneConnections.values.forEach { $0.cancel() }
        usbLaneConnections.removeAll()
        networkQueue.async { [weak self] in
            guard let self,
                  stoppedGeneration == self.connectionGeneration else { return }
            self.wireReceiveActiveGeneration = nil
            self.wireAuthenticatedGeneration = nil
            self.committedTransportGeneration = nil
            self.advertisedClientCapabilities = nil
            self.resetDisplaySession()
            self.clearPendingTransportOffer()
            self.wireParser.reset(generation: stoppedGeneration)
            self.controlChannelWriter.cancel()
            self.stopTelemetryTimer()
        }
        setState(.idle)
    }

    func applyDisplayPreference(
        _ preference: DisplayPreference,
        interfaceOrientation: ClientDisplayOrientation
    ) {
        networkQueue.async { [weak self] in
            self?.requestDisplayConfiguration(
                preference: preference,
                interfaceOrientation: interfaceOrientation)
        }
    }

    func applyDisplayPreference(_ preference: DisplayPreference) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.requestDisplayConfiguration(
                preference: preference,
                interfaceOrientation: self.observedInterfaceOrientation)
        }
    }

    func updateInterfaceOrientation(_ orientation: ClientDisplayOrientation) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.observedInterfaceOrientation = orientation
            guard self.activeDisplayCapabilities != nil,
                  self.activeDisplayPreference.orientationMode == .automatic else {
                return
            }
            self.orientationDebounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      self.activeDisplayPreference.orientationMode == .automatic else {
                    return
                }
                self.requestDisplayConfiguration(
                    preference: self.activeDisplayPreference,
                    interfaceOrientation: self.observedInterfaceOrientation)
            }
            self.orientationDebounceWorkItem = workItem
            self.networkQueue.asyncAfter(
                deadline: .now() + .milliseconds(250),
                execute: workItem)
        }
    }

    /// Stops the USB listener/session before deleting the imported Keychain
    /// identity. The bundled identity is imported again on the next explicit
    /// listener start; the Windows host must also explicitly reset its pin.
    public func resetUSBPairing() {
        stop()
        USBServerIdentityStore.delete()
        DispatchQueue.main.async { self.usbServerFingerprint = nil }
    }

    /// Starts the iPad-side TLS endpoint used by iproxy USB mode.
    public func startListening(port: UInt16 = 12345) {
        stop()
        DispatchQueue.main.async {
            self.bytesReceived = 0
            self.lastFrameReceiveDurationMs = 0
            self.lastDecodeLatencyMs = 0
            self.hudTelemetry = TransportHudSnapshot(frameReceiveMs: 0, decodeMs: 0)
        }
        listenerGeneration &+= 1
        let generation = listenerGeneration

        do {
            let parameters = try buildUSBListenerParameters()
            guard let listenerPort = NWEndpoint.Port(rawValue: port) else {
                throw USBListenerError.invalidPort
            }
            let listener = try NWListener(
                using: parameters,
                on: listenerPort)
            usbListener = listener

            listener.stateUpdateHandler = { [weak self] state in
                guard let self,
                      generation == self.listenerGeneration else { return }
                switch state {
                case .ready:
                    print("[NetworkManager] USB TLS listener ready on port \(port).")
                    self.setState(.listening)
                case .failed(let error):
                    self.usbListener = nil
                    self.setState(.disconnected(
                        reason: "USB listener failed: \(error.localizedDescription)"))
                case .cancelled:
                    if self.connection == nil {
                        self.setState(.idle)
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] newConnection in
                guard let self,
                      generation == self.listenerGeneration else {
                    newConnection.cancel()
                    return
                }
                if self.connection != nil {
                    // A Windows host restart can leave the previous forwarded
                    // USB connection looking alive until its next read. The
                    // newly authenticated iproxy connection is authoritative
                    // in USB-listener mode, so replace the stale session.
                    _ = self.connectionGenerationClock.advance()
                    self.wireReceiveActiveGeneration = nil
                    self.wireAuthenticatedGeneration = nil
                    self.committedTransportGeneration = nil
                    self.advertisedClientCapabilities = nil
                    self.clearPendingTransportOffer()
                    self.wireParser.reset(generation: self.connectionGeneration)
                    self.controlChannelWriter.cancel()
                    self.stopTelemetryTimer()
                    self.decoder.invalidate()
                    AudioManager.shared.reset()
                    self.connection?.cancel()
                    self.connection = nil
                }

                _ = self.connectionGenerationClock.advance()
                self.connection = newConnection
                self.setupStateHandler()
                self.setState(.connecting)
                newConnection.start(queue: self.networkQueue)
            }
            listener.start(queue: networkQueue)
        } catch {
            usbListener = nil
            setState(.disconnected(
                reason: "Unable to start USB listener: \(error.localizedDescription)"))
        }
    }

    // MARK: - Private: TLS Configuration

    /// Builds the Wi-Fi client TLS parameters.
    ///
    /// Wi-Fi uses the Windows host's self-signed, session-scoped certificate.
    /// USB identity is authenticated separately by the Windows DPAPI-backed
    /// selected-device pin and must never share this callback.
    private func buildTLSParameters(for endpoint: NWEndpoint) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()

        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions, .TLSv12)

        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { [weak self] _, securityTrust, completionHandler in
                guard let self else {
                    completionHandler(false)
                    return
                }
                let trust = sec_trust_copy_ref(securityTrust).takeRetainedValue()
                guard let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
                    completionHandler(false)
                    return
                }

                let certificateData = SecCertificateCopyData(certificate) as Data
                let fingerprint = SHA256.hash(data: certificateData)
                    .map { String(format: "%02X", $0) }
                    .joined(separator: ":")
                let decision = WifiHostIdentityPolicy.decide(
                    presentedFingerprint: fingerprint,
                    pinnedFingerprint: self.trustedHostFingerprintStore.load())
                guard let identityCode = WifiHostIdentityPolicy.identityCode(
                    for: fingerprint) else {
                    completionHandler(false)
                    return
                }
                self.verifiedHostFingerprint = fingerprint
                self.verifiedHostIdentityCode = identityCode
                DispatchQueue.main.async {
                    self.hostFingerprint = fingerprint
                    self.hostIdentityCode = identityCode
                }
                switch decision {
                case .trusted:
                    self.hostIdentityConfirmationRequired = false
                    self.hostIdentityConfirmed = true
                    print("[IPAD][TLS_VERIFY] identity=known code=\(identityCode) accepted=true")
                    completionHandler(true)
                case .requiresFirstPairingConfirmation:
                    self.hostIdentityConfirmationRequired = true
                    self.hostIdentityConfirmed = false
                    print("[IPAD][TLS_VERIFY] identity=unknown code=\(identityCode) awaiting_confirmation")
                    completionHandler(true)
                case .rejected:
                    self.hostIdentityConfirmationRequired = false
                    self.hostIdentityConfirmed = false
                    print("[IPAD][TLS_VERIFY] identity=mismatch code=\(identityCode) accepted=false")
                    completionHandler(false)
                }
            },
            networkQueue
        )

        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private func buildUSBListenerParameters() throws -> NWParameters {
        guard let identity = USBServerIdentityStore.loadOrCreate(),
              let protocolIdentity = sec_identity_create(identity) else {
            throw USBListenerError.identityUnavailable
        }

        let fingerprint = Self.fingerprint(of: identity)
        DispatchQueue.main.async {
            self.usbServerFingerprint = fingerprint
        }

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv12)
        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions,
            protocolIdentity)

        let parameters = NWParameters(
            tls: tlsOptions,
            tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private static func fingerprint(of identity: SecIdentity) -> String? {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else { return nil }
        return SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    // MARK: - Private: Connection Lifecycle

    private var isDisconnected: Bool {
        if case .disconnected = connectionState { return true }
        return false
    }

    private var isAuthFailed: Bool {
        if case .authFailed = connectionState { return true }
        return false
    }

    private func setupStateHandler() {
        let generation = connectionGeneration
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            guard generation == self.connectionGeneration else { return }
            switch state {
            case .setup:
                print("[IPAD][NW_STATE] setup")
            case .preparing:
                print("[IPAD][NW_STATE] preparing")
            case .waiting(let error):
                print("[IPAD][NW_STATE] waiting error=\(error)")
                // NWConnection remains non-nil while it is waiting. Route the
                // transition through the normal generation-safe teardown so
                // the bounded reconnect attempt can create a fresh socket.
                self.handleStreamError(
                    "Waiting for Windows host: \(error.localizedDescription)")
            case .ready:
                self.connectionTimeoutWorkItem?.cancel()
                print("[IPAD][NW_STATE] ready TLS_VERIFY_COMPLETE accepted")
                self.controlChannelWriter.begin(generation: generation)
                if self.activeTransportKind == .wifi {
                    self.startWireReceiveLoop(generation: generation)
                    if self.hostIdentityConfirmationRequired {
                        print("[IPAD][PAIRING_GATED] reason=host_identity_confirmation")
                        self.setState(.awaitingHostIdentity)
                    } else {
                        self.sendTrustedClientHello(generation: generation)
                    }
                } else {
                    self.setState(.awaitingPIN)
                }

            case .failed(let error):
                self.connectionTimeoutWorkItem?.cancel()
                print("[IPAD][NW_STATE] failed error=\(error)")
                let shouldReconnect = self.connection != nil
                self.controlChannelWriter.cancel()
                self.committedTransportGeneration = nil
                self.advertisedClientCapabilities = nil
                self.clearPendingTransportOffer()
                self.connection = nil
                if self.usbListener != nil {
                    self.setState(.listening)
                } else if shouldReconnect {
                    self.setState(.disconnected(reason: error.localizedDescription))
                    self.scheduleAutoReconnect(reset: false)
                }

            case .cancelled:
                self.connectionTimeoutWorkItem?.cancel()
                print("[IPAD][NW_STATE] cancelled")
                let shouldReconnect = self.connection != nil
                self.controlChannelWriter.cancel()
                self.committedTransportGeneration = nil
                self.advertisedClientCapabilities = nil
                self.clearPendingTransportOffer()
                self.connection = nil
                if self.usbListener != nil {
                    self.setState(.listening)
                } else if shouldReconnect && self.connectionState != .idle {
                    self.setState(.disconnected(reason: "Connection cancelled."))
                    self.scheduleAutoReconnect(reset: false)
                }

            default:
                break
            }
        }
    }

    // MARK: - Private: Auth Handshake

    private func sendTrustedClientHello(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard generation == connectionGeneration,
              let fingerprint = verifiedHostFingerprint else {
            handleStreamError("TLS host identity was unavailable after verification.")
            return
        }
        let stored = trustedCredentialStore.load(fingerprint: fingerprint)
        trustedCredential = stored
        let deviceID = stored?.deviceID ?? trustedDeviceID
        let sessionID = stored?.sessionID ?? Data(repeating: 0, count: 16)
        let name = Data(UIDevice.current.name.utf8.prefix(64))
        guard deviceID.count == 16, sessionID.count == 16, !name.isEmpty else {
            handleStreamError("Trusted device identity is malformed.")
            return
        }
        var payload = Data([1])
        payload.append(deviceID)
        payload.append(sessionID)
        payload.append(UInt8(name.count))
        payload.append(name)
        print(stored == nil
            ? "[IPAD][PAIRING_REQUIRED] credential=absent"
            : "[IPAD][TRUSTED_CREDENTIAL_FOUND] credential=present")
        sendWireMessage(type: .clientHello, payload: payload, sequence: 0)
    }

    private func scheduleAutoReconnect(reset: Bool) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        reconnectGeneration &+= 1
        let generation = reconnectGeneration
        let lastKnownHost = UserDefaults.standard.string(
            forKey: Self.lastKnownHostKey)
        guard TrustedReconnectPolicy.shouldSchedule(
                isForegroundActive: isForegroundActive,
                reconnectEnabled: reconnectEnabled,
                lastKnownHost: lastKnownHost),
              let host = lastKnownHost else { return }
        if reset { reconnectAttempt = 0 }
        reconnectWorkItem?.cancel()
        let delay = TrustedReconnectPolicy.delay(forAttempt: reconnectAttempt)
        reconnectAttempt += 1
        print("[IPAD][AUTO_RECONNECT_ATTEMPT] attempt=\(reconnectAttempt) delay=\(delay)")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isForegroundActive, self.reconnectEnabled,
                  self.reconnectGeneration == generation else { return }
            DispatchQueue.main.async {
                guard self.isForegroundActive,
                      self.reconnectEnabled,
                      self.reconnectGeneration == generation,
                      self.connection == nil else { return }
                print("[IPAD][AUTO_RECONNECT_BEGIN] endpoint=last_known")
                self.connect(to: host)
            }
        }
        reconnectWorkItem = work
        networkQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func answerTrustedChallenge(_ payload: Data, generation: UInt64) {
        guard payload.count == 112,
              let fingerprint = verifiedHostFingerprint,
              let credential = trustedCredential,
              credential.fingerprint == fingerprint,
              credential.deviceID == payload.subdata(in: 16..<32),
              credential.hostID == payload.subdata(in: 32..<48),
              credential.secret.count == 32 else {
            setState(.authFailed(reason: "Trusted Host credential is missing or does not match."))
            return
        }
        var context = Data()
        context.append(payload.subdata(in: 48..<80))
        context.append(payload.subdata(in: 80..<112))
        context.append(payload.subdata(in: 0..<16))
        context.append(payload.subdata(in: 16..<32))
        context.append(payload.subdata(in: 32..<48))
        context.append(WireProtocol.version)
        let key = SymmetricKey(data: credential.secret)
        let proof = Data(HMAC<SHA256>.authenticationCode(for: context, using: key))
        var response = payload.subdata(in: 0..<16)
        response.append(proof)
        print("[IPAD][TRUSTED_AUTH_BEGIN] generation=\(generation)")
        sendWireMessage(type: .trustedDeviceProof, payload: response, sequence: 0)
    }

    private func storePairingCredential(_ payload: Data) {
        guard payload.count == 80,
              let fingerprint = verifiedHostFingerprint else { return }
        let credential = TrustedHostCredential(
            fingerprint: fingerprint,
            hostID: payload.subdata(in: 0..<16),
            deviceID: payload.subdata(in: 16..<32),
            secret: payload.subdata(in: 48..<80),
            sessionID: payload.subdata(in: 32..<48))
        guard trustedCredentialStore.save(credential) else {
            handleStreamError("Unable to save the trusted Host credential in Keychain.")
            return
        }
        trustedCredential = credential
        guard trustedHostFingerprintStore.save(fingerprint) else {
            trustedCredentialStore.delete(fingerprint: fingerprint)
            handleStreamError("Unable to save the trusted Host identity in Keychain.")
            return
        }
        print("[IPAD][PAIRING_SUCCESS] credential=keychain")
    }

    private func updateResumedSession(_ payload: Data) {
        guard payload.count == 17, var credential = trustedCredential else { return }
        credential.sessionID = payload.subdata(in: 1..<17)
        if trustedCredentialStore.save(credential) {
            trustedCredential = credential
            print(payload[0] == 1
                ? "[IPAD][SESSION_RESUMED] result=resumed"
                : "[IPAD][SESSION_NOT_FOUND] result=new_session")
        }
    }

    private func receiveSettingsState(
        _ payload: Data,
        rejected: Bool = false
    ) {
        guard let state = TrustedSettingsState.decode(payload),
              state.generation >= settingsGeneration else { return }
        let isLatest = state.requestID == 0 || state.requestID == latestSettingsRequestID
        if !isLatest && state.generation <= latestSettingsExpectedGeneration {
            print("[IPAD][SETTINGS_STALE] request=\(state.requestID) expected=\(latestSettingsRequestID) generation=\(state.generation)")
            return
        }
        let bitrateMbps = Double(state.bitrateBps) / 1_000_000
        let bitrateChanged = committedBitrateMbps != bitrateMbps
        let audioChanged = committedAudioEnabled != state.audioEnabled
        settingsGeneration = state.generation
        committedBitrateMbps = bitrateMbps
        committedAudioEnabled = state.audioEnabled
        if audioChanged || bitrateChanged {
            decoder.requireKeyFrame()
        }
        if audioChanged && committedTransportGeneration == connectionGeneration {
            if state.audioEnabled {
                if committedRealtimeMode == RealtimeTransportMode.wifiRTP {
                    AudioManager.shared.beginRealtimeSession(
                        generation: connectionGeneration,
                        profile: .wifi)
                } else if committedRealtimeMode == RealtimeTransportMode.usbSplitTLS {
                    AudioManager.shared.beginRealtimeSession(
                        generation: connectionGeneration,
                        profile: .usb)
                }
            } else {
                AudioManager.shared.reset()
            }
        }
        DispatchQueue.main.async {
            self.targetBitrateMbps = bitrateMbps
            self.audioEnabled = state.audioEnabled
            self.isAdaptiveBitrate = false
            if isLatest {
                self.settingsApplyStatus = rejected ? "Failed" : "Applied"
            }
        }
        transportTelemetry.recordBitrateMbps(bitrateMbps)
        print("[IPAD][SETTINGS_RESULT] request=\(state.requestID) expected=\(latestSettingsExpectedGeneration) generation=\(state.generation) bitrate_bps=\(state.bitrateBps) audio=\(state.audioEnabled) rejected=\(rejected)")
    }

    /// Reads exactly the minimum response bytes for AUTH_SUCCESS or AUTH_FAILED.
    private func receiveAuthResponse(generation: UInt64) {
        startWireReceiveLoop(generation: generation)
    }

    // MARK: - Private: Video Stream Receive Loop (2-Phase Framed Protocol)

    // Decoder instance — lazy-created on first streaming connection.
    // Exposed so ContentView can wire onFrameDecoded → MetalVideoView.
    public private(set) lazy var decoder = DecoderManager()

    /// Kicks off the framed 120Hz receive loop immediately after AUTH_SUCCESS.
    private func startVideoReceiveLoop(generation: UInt64) {
        startTelemetryTimer()
    }

    private func startUsbLaneReceiveLoop(
        _ connection: NWConnection,
        lane: UsbLaneKind)
    {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        let generation = connectionGeneration
        let parser = WireStreamParser(generation: generation)

        func receiveNext() {
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: parser.suggestedReceiveLength)
            { [weak self] data, _, isComplete, error in
                guard let self,
                      generation == self.connectionGeneration,
                      self.usbLaneConnections[lane] === connection
                else { return }
                if let error {
                    if lane == .video {
                        self.handleStreamError(
                            "USB video lane failed: \(error.localizedDescription)")
                    }
                    return
                }
                if let data, !data.isEmpty {
                    parser.consume(
                        data,
                        generation: generation,
                        receivedAt: CACurrentMediaTime())
                    { event in
                        guard case .message(let message) = event else { return }
                        let expected: WireMessageType =
                            lane == .video ? .video : .audio
                        guard message.header.type == expected else {
                            connection.cancel()
                            if lane == .video {
                                self.handleStreamError(
                                    "Unexpected message on USB video lane.")
                            }
                            return
                        }
                        self.handleWireMessage(
                            message,
                            generation: generation)
                    }
                }
                if isComplete {
                    if lane == .video {
                        self.handleStreamError("USB video lane closed.")
                    }
                    return
                }
                receiveNext()
            }
        }

        receiveNext()
    }

    // MARK: Telemetry Timer (2 Hz)

    private func startTelemetryTimer() {
        stopTelemetryTimer()
        pendingClientPings.removeAll(keepingCapacity: true)
        lastClientPingSentAt = 0
        _ = transportTelemetry.startLogging()
        if committedRealtimeMode == RealtimeTransportMode.wifiRTP {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)   // 2× per second
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.wireAuthenticatedGeneration == self.connectionGeneration else { return }
            self.sendVideoFeedback()
        }
        timer.resume()
        telemetryTimer = timer

        // Keep the legacy half-second cadence, and add the latency controller's
        // 200 ms feedback cadence without changing the v1 payload schema.
        let adaptiveTimer = DispatchSource.makeTimerSource(queue: networkQueue)
        adaptiveTimer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        adaptiveTimer.setEventHandler { [weak self] in
            guard let self,
                  self.wireAuthenticatedGeneration == self.connectionGeneration else { return }
            self.sendVideoFeedback()
        }
        adaptiveTimer.resume()
        adaptiveTelemetryTimer = adaptiveTimer
    }

    private func stopTelemetryTimer() {
        telemetryTimer?.cancel()
        telemetryTimer = nil
        adaptiveTelemetryTimer?.cancel()
        adaptiveTelemetryTimer = nil
        pendingClientPings.removeAll(keepingCapacity: true)
        transportTelemetry.stopLogging()
    }

    private func sendVideoFeedback() {
        guard wireAuthenticatedGeneration == connectionGeneration else { return }
        sendClientPingIfDue()
        let feedback = transportTelemetry.makeFeedback()
        var payload = Data(count: 16)
        payload.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: feedback.0.littleEndian, toByteOffset: 0, as: UInt32.self)
            bytes.storeBytes(of: feedback.1.littleEndian, toByteOffset: 4, as: UInt32.self)
            bytes.storeBytes(of: feedback.2.littleEndian, toByteOffset: 8, as: UInt16.self)
            bytes.storeBytes(of: feedback.3.littleEndian, toByteOffset: 10, as: UInt16.self)
            bytes.storeBytes(of: feedback.4.littleEndian, toByteOffset: 12, as: UInt16.self)
            bytes.storeBytes(of: feedback.5.littleEndian, toByteOffset: 14, as: UInt16.self)
        }
        let stages = transportTelemetry.frameStageP95Ms()
        let feedbackFlags = transportTelemetry.feedbackValidityFlags()
        sendWireMessage(
            type: .videoFeedback,
            payload: payload,
            sequence: feedback.0,
            flags: feedbackFlags)
        // The legacy 8-byte stage packet remains valid for older hosts and carries
        // receive p95, which intentionally has no slot in v1 VideoFeedback.
        sendLegacyFrameStagePacket(
            frameReceiveDurationMs: stages.receive,
            decodeLatencyMs: stages.decode)
        publishHudSnapshotIfDue()
    }

    /// Measures a true local RTT for the CSV without comparing clocks. The
    /// Windows host echoes this exact 16-byte payload as a Pong.
    private func sendClientPingIfDue() {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastClientPingSentAt >= 1 else { return }
        lastClientPingSentAt = now

        let nonce = nextClientPingNonce
        nextClientPingNonce &+= 1
        if pendingClientPings.count >= 16,
           let oldest = pendingClientPings.min(by: { $0.value < $1.value })?.key {
            pendingClientPings.removeValue(forKey: oldest)
        }
        pendingClientPings[nonce] = now

        let sentNanoseconds = UInt64(max(0, now) * 1_000_000_000.0)
        var payload = Data(count: 16)
        payload.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(
                of: sentNanoseconds.littleEndian,
                toByteOffset: 0,
                as: UInt64.self)
            bytes.storeBytes(
                of: nonce.littleEndian,
                toByteOffset: 8,
                as: UInt64.self)
        }
        sendWireMessage(
            type: .ping,
            payload: payload,
            sequence: UInt32(truncatingIfNeeded: nonce))
    }

    private func publishHudSnapshotIfDue() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastHudSnapshotPublishedAt >= 0.5 else { return }
        lastHudSnapshotPublishedAt = now
        let snapshot = transportTelemetry.hudSnapshot()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hudTelemetry = snapshot
            self.lastFrameReceiveDurationMs = snapshot.frameReceiveMs
            self.lastDecodeLatencyMs = snapshot.decodeMs
        }
    }

    private func sendWireMessage(
        type: WireMessageType,
        payload: Data,
        sequence: UInt32,
        flags: UInt16 = 0
    ) {
        guard payload.count <= WireProtocol.maxPayloadSize else { return }
        var message = Data(count: WireProtocol.headerSize)
        message.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: WireProtocol.magic.littleEndian, toByteOffset: 0, as: UInt32.self)
            bytes.storeBytes(of: WireProtocol.version, toByteOffset: 4, as: UInt8.self)
            bytes.storeBytes(of: type.rawValue, toByteOffset: 5, as: UInt8.self)
            bytes.storeBytes(of: flags.littleEndian, toByteOffset: 6, as: UInt16.self)
            bytes.storeBytes(of: UInt32(payload.count).littleEndian, toByteOffset: 8, as: UInt32.self)
            bytes.storeBytes(of: sequence.littleEndian, toByteOffset: 12, as: UInt32.self)
        }
        message.append(payload)
        enqueueControlData(
            message,
            telemetry: type == .videoFeedback,
            completion: { [weak self] error in
                if let error { self?.handleStreamError("Control send error: \(error)") }
            })
    }

    private func enqueueControlData(
        _ data: Data,
        telemetry: Bool = false,
        movement: Bool = false,
        completion: @escaping (NWError?) -> Void = { _ in }
    ) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            if telemetry {
                self.controlChannelWriter.enqueueTelemetry(data, completion: completion)
            } else if movement {
                self.controlChannelWriter.enqueueMovement(data, completion: completion)
            } else if !self.controlChannelWriter.enqueue(data, completion: completion) {
                self.handleStreamError("Control queue reached its 64-message bound.")
            }
        }
    }

    // MARK: Incremental SCST Receive Loop

    private func startWireReceiveLoop(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard generation == connectionGeneration, connection != nil else { return }
        guard wireReceiveActiveGeneration != generation else { return }
        wireReceiveActiveGeneration = generation
        wireAuthenticatedGeneration = nil
        committedTransportGeneration = nil
        advertisedClientCapabilities = nil
        clearPendingTransportOffer()
        wireParser.reset(generation: generation)
        receiveWireChunk(generation: generation)
    }

    private func receiveWireChunk(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard generation == connectionGeneration,
              wireReceiveActiveGeneration == generation,
              let connection else { return }

        let maximumLength = wireParser.suggestedReceiveLength
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: maximumLength
        ) { [weak self] data, _, isComplete, error in
            guard let self,
                  generation == self.connectionGeneration,
                  self.wireReceiveActiveGeneration == generation else { return }
            if let error {
                self.handleStreamError("SCST receive error: \(error.localizedDescription)")
                return
            }

            if let data, !data.isEmpty {
                self.wireParser.consume(
                    data,
                    generation: generation,
                    receivedAt: CACurrentMediaTime()) { event in
                    self.handleWireParserEvent(event, generation: generation)
                }
            }

            guard generation == self.connectionGeneration,
                  self.wireReceiveActiveGeneration == generation else { return }
            if isComplete {
                self.handleStreamError("Server closed the stream.")
                return
            }
            self.receiveWireChunk(generation: generation)
        }
    }

    private func handleWireParserEvent(_ event: WireParserEvent, generation: UInt64) {
        guard generation == connectionGeneration else { return }
        switch event {
        case .failure(.invalidHeader):
            handleStreamError("Invalid wire-protocol header.")
        case .failure(.oversizedPayload):
            handleStreamError("Wire payload exceeds the 8 MiB limit.")
        case .discardedFixedControl(let header):
            print("[NetworkManager] Discarded malformed \(header.type) payload.")
        case .message(let message):
            handleWireMessage(message, generation: generation)
        }
    }

    private func handleWireMessage(_ message: WireMessage, generation: UInt64) {
        let header = message.header
        let payload = message.payload

        guard wireAuthenticatedGeneration == generation else {
            if header.type == .pairingRequired {
                print("[IPAD][PAIRING_REQUIRED] host=unknown")
                setState(.awaitingPIN)
                return
            }
            if header.type == .trustedDeviceChallenge {
                answerTrustedChallenge(payload, generation: generation)
                return
            }
            guard header.type == .authResult, !payload.isEmpty else {
                handleStreamError("Expected a framed authentication response.")
                return
            }
            let accepted = payload[0] != 0
            let reason = String(data: payload.dropFirst(), encoding: .utf8) ?? ""
            if accepted {
                reconnectAttempt = 0
                reconnectWorkItem?.cancel()
                reconnectWorkItem = nil
                print("[IPAD][AUTO_RECONNECT_SUCCESS] generation=\(generation)")
                wireAuthenticatedGeneration = generation
                committedTransportGeneration = nil
                committedRealtimeSessionID = nil
                wifiLegacyFallbackRequestGeneration = nil
                clearPendingTransportOffer()
                wifiCommitGate.reset()
                let supportsNegotiation =
                    (header.flags &
                     WireProtocol.realtimeNegotiationSupportedFlag) != 0
                if supportsNegotiation {
                    sendClientCapabilities(for: activeTransportKind)
                } else {
                    commitLegacyTransport(generation: generation)
                }
            } else {
                setState(.authFailed(
                    reason: reason.isEmpty ? "Incorrect PIN. Please try again." : reason))
            }
            return
        }

        switch header.type {
        case .pairingSuccess:
            storePairingCredential(payload)

        case .trustedAuthResult:
            guard !payload.isEmpty, payload[0] != 0 else {
                setState(.authFailed(reason: "Trusted device authentication failed."))
                return
            }
            print("[IPAD][TRUSTED_AUTH_SUCCESS] generation=\(generation)")

        case .sessionResumeResult:
            updateResumedSession(payload)

        case .settingsState, .settingsApplied:
            receiveSettingsState(payload)

        case .settingsRejected:
            receiveSettingsState(payload, rejected: true)

        case .forgetDeviceResult:
            guard payload.count == 2, payload[0] == 1 else { return }
            if payload[1] == 1, let fingerprint = verifiedHostFingerprint {
                let endpoint = lastEndpoint
                trustedCredentialStore.delete(fingerprint: fingerprint)
                trustedHostFingerprintStore.delete()
                trustedCredential = nil
                UserDefaults.standard.removeObject(forKey: Self.lastKnownHostKey)
                reconnectEnabled = false
                print("[IPAD][TRUSTED_HOST_FORGOTTEN] credential=deleted")
                stop()
                // Forgetting removes only the credential. Keep discovery and
                // an explicit reconnect available; the next connection still
                // follows the PIN path because the credential was deleted.
                reconnectEnabled = true
                if let endpoint {
                    networkQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self, self.isForegroundActive else { return }
                        self.connect(to: endpoint)
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.settingsApplyStatus = "Forget failed"
                }
            }

        case .displayCapabilities:
            guard let capabilities = DisplayCapabilities.decode(payload) else {
                handleStreamError("Malformed display capabilities.")
                return
            }
            receiveDisplayCapabilities(capabilities)

        case .displayReady:
            guard let ready = DisplayReady.decode(payload) else {
                handleStreamError("Malformed display readiness response.")
                return
            }
            receiveDisplayReady(ready)

        case .displayConfigurationFailed:
            guard let failure = DisplayConfigurationFailed.decode(payload) else {
                handleStreamError("Malformed display configuration failure.")
                return
            }
            receiveDisplayConfigurationFailure(failure)

        case .video:
            guard committedTransportGeneration == generation else { return }
            if committedRealtimeMode == RealtimeTransportMode.wifiRTP {
                // A legacy payload cannot authorize its own transition. The
                // exact host commit must arrive first on authenticated TLS.
                return
            }
            let receivedAt = CACurrentMediaTime()
            let receiveDurationMs = max(0, (receivedAt - message.firstByteAt) * 1_000.0)
            bytesReceived &+= UInt64(payload.count)
            transportTelemetry.recordPayloadReceived(
                sequence: header.sequence,
                receiveDurationMs: receiveDurationMs,
                receivedAt: receivedAt,
                payloadBytes: payload.count,
                isIDR: (header.flags & WireProtocol.videoFlagIDR) != 0,
                generation: generation,
                transportKind: activeTransportKind == .usb
                    ? StreamingTransportKind.usbTypeC.rawValue
                    : StreamingTransportKind.wifi.rawValue)
            decoder.processInputData(
                payload,
                sequence: header.sequence,
                isIDR: (header.flags & WireProtocol.videoFlagIDR) != 0,
                isLengthPrefixed:
                    (header.flags & WireProtocol.videoFlagLengthPrefixed) != 0,
                receivedAt: receivedAt)

        case .videoConfiguration:
            guard committedTransportGeneration == generation,
                  let configuration = VideoConfigurationV1.decode(payload),
                  configuration.generation == generation else {
                handleStreamError("Malformed or stale video configuration.")
                return
            }
            let accepted: Bool
            let errorCode: UInt16
            if configuration.codec == .h264,
               configuration.parameterSets.count == 2,
               configuration.width.isMultiple(of: 2),
               configuration.height.isMultiple(of: 2) {
                accepted = decoder.configureH264(
                    sps: configuration.parameterSets[0],
                    pps: configuration.parameterSets[1])
                errorCode = accepted ? 0 : 2
            } else {
                accepted = false
                errorCode = 1
            }
            if accepted { activeVideoCodec = configuration.codec }
            let ack = VideoConfigurationAckV1(
                generation: configuration.generation,
                accepted: accepted,
                errorCode: errorCode,
                codec: configuration.codec,
                width: accepted ? configuration.width : 0,
                height: accepted ? configuration.height : 0)
            sendWireMessage(
                type: .videoConfigurationAck,
                payload: ack.encode(),
                sequence: header.sequence)

        case .ping:
            sendWireMessage(type: .pong, payload: payload, sequence: header.sequence)

        case .pong:
            guard payload.count == 16 else { return }
            let nonce = payload.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self).littleEndian
            }
            if let sentAt = pendingClientPings.removeValue(forKey: nonce) {
                let rttMs = max(
                    0,
                    (ProcessInfo.processInfo.systemUptime - sentAt) * 1_000.0)
                transportTelemetry.recordRtt(durationMs: rttMs)
            }

        case .videoFeedback:
            return

        case .audio:
            guard committedTransportGeneration == generation else { return }
            switch ScstAudioPolicy.classify(
                mode: committedRealtimeMode,
                flags: header.flags,
                payloadLength: payload.count
            ) {
            case .opus:
                let audioSequence = UInt16(truncatingIfNeeded: header.sequence)
                let audioTimestamp = header.sequence &* 480
                AudioManager.shared.playOpusData(
                    payload,
                    sequence: audioSequence,
                    timestamp: audioTimestamp,
                    generation: generation)
            case .legacyPCM:
                AudioManager.shared.playPCMData(payload)
            case .reject:
                return
            }

        case .bitrate:
            guard committedTransportGeneration == generation else { return }
            guard payload.count == 8 else {
                handleStreamError("Malformed bitrate payload.")
                return
            }
            let adaptive = payload[0] != 0
            let target = payload.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
            }
            transportTelemetry.recordBitrateMbps(Double(target))
            DispatchQueue.main.async {
                self.isAdaptiveBitrate = adaptive
                self.targetBitrateMbps = Double(target)
            }

        case .protocolError:
            let reason = String(data: payload, encoding: .utf8) ?? "Protocol error."
            handleStreamError(reason)

        case .authResult:
            handleStreamError("Unexpected authentication response during streaming.")

        case .transportOffer:
            guard committedTransportGeneration != generation else { return }
            guard var offer = TransportOffer.decode(payload) else {
                handleStreamError("Malformed transport offer.")
                return
            }
            clearPendingTransportOffer(
                invalidateNegotiationTimer: pendingTransportOffer != nil)
            let modeAccepted =
                offer.mode == RealtimeTransportMode.legacyTLS ||
                (offer.mode == RealtimeTransportMode.wifiRTP &&
                 activeTransportKind == .wifi) ||
                (offer.mode == RealtimeTransportMode.usbSplitTLS &&
                 activeTransportKind == .usb)
            var accepted =
                modeAccepted &&
                advertisedClientCapabilities.map {
                    ($0.videoCodecs & offer.videoCodec) != 0 &&
                    RealtimeAudioNegotiationPolicy.isOfferCompatible(
                        mode: offer.mode,
                        audioCodec: offer.audioCodec,
                        advertisedModes: $0.modes,
                        advertisedCodecs: $0.audioCodecs)
                } ?? false
            if accepted && offer.mode == RealtimeTransportMode.wifiRTP {
                accepted = wifiMediaReceiver.configure(
                    offer: offer,
                    generation: generation)
            }
            let status: UInt8 = accepted
                ? TransportReadyStatus.ready
                : TransportReadyStatus.rejected
            if accepted {
                pendingTransportOffer = offer
                if offer.mode == RealtimeTransportMode.wifiRTP {
                    wifiCommitGate.begin(sessionID: offer.sessionID)
                }
                if offer.mode == RealtimeTransportMode.usbSplitTLS {
                    negotiationFallbackToken &+= 1
                    usbSplitCommitGate.begin(sessionID: offer.sessionID)
                    usbLaneServer.start(
                        sessionID: offer.sessionID,
                        secret: offer.usbBindingSecret)
                }
            } else {
                offer.zeroSecrets()
            }
            let ready = TransportReady(
                version: 1,
                mode: offer.mode,
                status: status,
                sessionID: offer.sessionID,
                audioCodec: accepted
                    ? offer.audioCodec
                    : AudioCodecCapabilities.none)
            guard let readyPayload = ready.encode() else {
                handleStreamError("Unable to encode transport readiness.")
                return
            }
            sendWireMessage(
                type: .transportReady,
                payload: readyPayload,
                sequence: header.sequence)
            if !accepted &&
                offer.mode == RealtimeTransportMode.wifiRTP {
                commitLegacyTransport(generation: generation)
            }
            if accepted &&
                offer.mode == RealtimeTransportMode.usbSplitTLS {
                scheduleUsbSplitOfferTimeout(
                    generation: generation,
                    sessionID: offer.sessionID)
            }

        case .transportCommit:
            if committedTransportGeneration == generation {
                guard committedRealtimeMode == RealtimeTransportMode.wifiRTP,
                      wifiLegacyFallbackGeneration != generation,
                      let commit = TransportCommit.decode(payload),
                      commit.mode == RealtimeTransportMode.legacyTLS,
                      commit.audioCodec == AudioCodecCapabilities.pcm,
                      commit.sessionID == committedRealtimeSessionID else {
                    handleStreamError(
                        "Invalid committed Wi-Fi fallback transition.")
                    return
                }
                _ = fallbackCommittedWifiToLegacy(generation: generation)
                return
            }
            guard let offer = pendingTransportOffer,
                  let commit = TransportCommit.decode(payload),
                  commit.sessionID == offer.sessionID else {
                handleStreamError("Invalid transport commit.")
                return
            }
            if offer.mode == RealtimeTransportMode.usbSplitTLS {
                committedRealtimeSessionID = offer.sessionID
                let decision = usbSplitCommitGate.resolve(
                    commit,
                    videoLaneBound: usbLaneConnections[.video] != nil,
                    audioLaneBound: usbLaneConnections[.audio] != nil)
                switch decision {
                case .split:
                    if commit.audioCodec == AudioCodecCapabilities.none {
                        usbLaneConnections[.audio]?.cancel()
                        usbLaneConnections.removeValue(forKey: .audio)
                    }
                    usbLaneServer.finalize()
                    clearPendingTransportOffer(abortUsbSplit: false)
                    commitRealtimeTransport(
                        generation: generation,
                        mode: RealtimeTransportMode.usbSplitTLS,
                        audioEnabled:
                            commit.audioCodec ==
                                AudioCodecCapabilities.opus)
                case .legacyFallback:
                    usbLaneServer.abort()
                    usbLaneConnections.values.forEach { $0.cancel() }
                    usbLaneConnections.removeAll()
                    clearPendingTransportOffer(abortUsbSplit: false)
                    commitLegacyTransport(generation: generation)
                case .reject:
                    handleStreamError("Invalid transport commit.")
                }
            } else {
                committedRealtimeSessionID = offer.sessionID
                guard commit.mode == offer.mode,
                      commit.audioCodec == offer.audioCodec else {
                    if offer.mode == RealtimeTransportMode.wifiRTP,
                       commit.mode == RealtimeTransportMode.legacyTLS,
                       commit.audioCodec == AudioCodecCapabilities.pcm,
                       wifiCommitGate.commitLegacyFallback(
                            sessionID: offer.sessionID) {
                        wifiMediaReceiver.clearOffer()
                        clearPendingTransportOffer(abortWifi: false)
                        commitLegacyTransport(generation: generation)
                        return
                    }
                    handleStreamError("Invalid transport commit.")
                    return
                }
                if offer.mode == RealtimeTransportMode.wifiRTP {
                    guard wifiCommitGate.commit(
                        sessionID: offer.sessionID) else {
                        handleStreamError(
                            "Wi-Fi transport commit arrived before probe " +
                            "authentication or after its deadline.")
                        return
                    }
                    wifiMediaReceiver.activate(generation: generation)
                    clearPendingTransportOffer(abortWifi: false)
                } else {
                    clearPendingTransportOffer()
                    if offer.mode == RealtimeTransportMode.legacyTLS {
                        commitLegacyTransport(generation: generation)
                        return
                    }
                }
                commitRealtimeTransport(
                    generation: generation,
                    mode: offer.mode,
                    audioEnabled:
                        offer.audioCodec != AudioCodecCapabilities.none)
            }

        case .clientCapabilities, .transportReady, .usbLaneBind,
             .usbLaneBindResult, .videoConfigurationAck,
             .displayConfigurationRequest, .clientHello,
             .pairingRequired, .trustedDeviceChallenge,
             .trustedDeviceProof, .settingsGet, .settingsUpdate,
             .forgetDevice:
            handleStreamError("Unexpected client-direction negotiation message.")
        }
    }

    private var activeTransportKind: ActiveTransportKind {
        usbListener == nil ? .wifi : .usb
    }

    private func sendClientCapabilities(for kind: ActiveTransportKind) {
        if case .usb = kind {
            publishClientCapabilities(
                modes: RealtimeTransportMode.legacyTLS |
                    RealtimeTransportMode.usbSplitTLS,
                udpPort: 0)
            return
        }
        let baseModes = RealtimeTransportMode.legacyTLS
        wifiMediaReceiver.start(
            generation: connectionGeneration
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let port):
                self.publishClientCapabilities(
                    modes: baseModes | RealtimeTransportMode.wifiRTP,
                    udpPort: port)
            case .failure:
                self.publishClientCapabilities(modes: baseModes, udpPort: 0)
            }
        }
    }

    private func publishClientCapabilities(modes: UInt8, udpPort: UInt16) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        let capabilities = ClientCapabilities(
            version: 1,
            modes: modes,
            videoCodecs: VideoCodecCapabilities.hevc | VideoCodecCapabilities.h264,
            audioCodecs:
                RealtimeAudioNegotiationPolicy.advertisedCodecs(
                    modes: modes),
            preferredMTU: 1200,
            feedbackIntervalMs: 50,
            clientUDPPort: udpPort)
        advertisedClientCapabilities = capabilities
        sendWireMessage(
            type: .clientCapabilities,
            payload: capabilities.encode(),
            sequence: 0)
        scheduleLegacyFallback(generation: connectionGeneration)
    }

    private func receiveDisplayCapabilities(_ capabilities: DisplayCapabilities) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        activeDisplayCapabilities = capabilities
        let reconciledPreference = activeDisplayPreference.reconciled(
            with: capabilities)
        DispatchQueue.main.async { [weak self] in
            self?.displayCapabilities = capabilities
            self?.displayConfigurationFailureMessage = nil
        }
        requestDisplayConfiguration(
            preference: reconciledPreference,
            interfaceOrientation: observedInterfaceOrientation)
    }

    private func requestDisplayConfiguration(
        preference: DisplayPreference,
        interfaceOrientation: ClientDisplayOrientation
    ) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard wireAuthenticatedGeneration == connectionGeneration,
              let capabilities = activeDisplayCapabilities else {
            return
        }

        let reconciledPreference = preference.reconciled(with: capabilities)
        let proposed = reconciledPreference.makeRequest(
            interfaceOrientation: interfaceOrientation,
            requestId: 0)
        guard let request = displayRequestGate.begin(proposed) else { return }
        pendingDisplayPreference = reconciledPreference
        DispatchQueue.main.async { [weak self] in
            self?.isDisplayConfigurationPending = true
            self?.displayConfigurationFailureMessage = nil
        }
        sendWireMessage(
            type: .displayConfigurationRequest,
            payload: request.encode(),
            sequence: request.requestId)
    }

    private func receiveDisplayReady(_ ready: DisplayReady) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard displayRequestGate.accept(ready),
              let appliedPreference = pendingDisplayPreference else {
            return
        }
        pendingDisplayPreference = nil
        activeDisplayPreference = appliedPreference
        DisplayPreferenceStore.save(appliedPreference)
        DispatchQueue.main.async { [weak self] in
            self?.displayPreference = appliedPreference
            self?.effectiveDisplayState = ready
            self?.isDisplayConfigurationPending = false
            self?.displayConfigurationFailureMessage = nil
        }
    }

    private func receiveDisplayConfigurationFailure(
        _ failure: DisplayConfigurationFailed
    ) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard displayRequestGate.reject(failure) else { return }
        pendingDisplayPreference = nil
        DispatchQueue.main.async { [weak self] in
            self?.isDisplayConfigurationPending = false
            self?.displayConfigurationFailureMessage =
                "Could not apply this display mode."
        }
    }

    private func resetDisplaySession() {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        orientationDebounceWorkItem?.cancel()
        orientationDebounceWorkItem = nil
        activeDisplayCapabilities = nil
        pendingDisplayPreference = nil
        displayRequestGate.reset()
        DispatchQueue.main.async { [weak self] in
            self?.displayCapabilities = nil
            self?.effectiveDisplayState = nil
            self?.isDisplayConfigurationPending = false
            self?.displayConfigurationFailureMessage = nil
        }
    }

    private func commitLegacyTransport(generation: UInt64) {
        wifiCommitGate.abort()
        wifiMediaReceiver.cancel()
        commitRealtimeTransport(
            generation: generation,
            mode: RealtimeTransportMode.legacyTLS)
    }

    private func commitRealtimeTransport(generation: UInt64, mode: UInt8) {
        commitRealtimeTransport(
            generation: generation,
            mode: mode,
            audioEnabled: true)
    }

    private func commitRealtimeTransport(
        generation: UInt64,
        mode: UInt8,
        audioEnabled: Bool
    ) {
        guard generation == connectionGeneration,
              wireAuthenticatedGeneration == generation,
              committedTransportGeneration != generation else { return }
        committedTransportGeneration = generation
        committedRealtimeMode = mode
        wifiLegacyFallbackGeneration = nil
        wifiLegacyFallbackRequestGeneration = nil
        decoder.beginSession(generation: generation)
        if mode == RealtimeTransportMode.wifiRTP && audioEnabled {
            AudioManager.shared.beginRealtimeSession(
                generation: generation,
                profile: .wifi)
        } else if mode == RealtimeTransportMode.usbSplitTLS &&
                    audioEnabled {
            AudioManager.shared.beginRealtimeSession(
                generation: generation,
                profile: .usb)
        }
        setState(.streaming)
        startVideoReceiveLoop(generation: generation)
    }

    private func clearPendingTransportOffer(
        abortUsbSplit: Bool = true,
        abortWifi: Bool = true,
        invalidateNegotiationTimer: Bool = true
    ) {
        if invalidateNegotiationTimer {
            negotiationFallbackToken &+= 1
        }
        if abortUsbSplit,
           let offer = pendingTransportOffer,
           offer.mode == RealtimeTransportMode.usbSplitTLS {
            _ = usbSplitCommitGate.abort(sessionID: offer.sessionID)
            usbLaneServer.abort()
            usbLaneConnections.values.forEach { $0.cancel() }
            usbLaneConnections.removeAll()
        }
        if abortWifi,
           let offer = pendingTransportOffer,
           offer.mode == RealtimeTransportMode.wifiRTP {
            wifiCommitGate.abort()
            wifiMediaReceiver.clearOffer()
        }
        pendingTransportOffer?.zeroSecrets()
        pendingTransportOffer = nil
    }

    private func scheduleUsbSplitOfferTimeout(
        generation: UInt64,
        sessionID: SessionID
    ) {
        negotiationFallbackToken &+= 1
        let token = negotiationFallbackToken
        networkQueue.asyncAfter(
            deadline: .now() + .seconds(5)
        ) { [weak self] in
            guard let self,
                  generation == self.connectionGeneration,
                  self.wireAuthenticatedGeneration == generation,
                  self.committedTransportGeneration != generation,
                  self.negotiationFallbackToken == token,
                  self.usbSplitCommitGate.abort(
                    sessionID: sessionID) else { return }
            self.usbLaneServer.abort()
            self.usbLaneConnections.values.forEach { $0.cancel() }
            self.usbLaneConnections.removeAll()
            self.clearPendingTransportOffer(abortUsbSplit: false)
            self.commitLegacyTransport(generation: generation)
        }
    }

    private func scheduleLegacyFallback(generation: UInt64) {
        negotiationFallbackToken &+= 1
        let token = negotiationFallbackToken
        networkQueue.asyncAfter(
            deadline: .now() + .milliseconds(750)
        ) { [weak self] in
            guard let self,
                  generation == self.connectionGeneration,
                  self.wireAuthenticatedGeneration == generation,
                  self.committedTransportGeneration != generation,
                  self.negotiationFallbackToken == token,
                  self.wifiCommitGate.legacyFallbackAllowed else { return }
            self.clearPendingTransportOffer()
            self.commitLegacyTransport(generation: generation)
        }
    }

    private func handleWifiProbeAuthenticated(
        generation: UInt64,
        sessionID: SessionID
    ) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard generation == connectionGeneration,
              wireAuthenticatedGeneration == generation,
              committedTransportGeneration != generation,
              let offer = pendingTransportOffer,
              offer.mode == RealtimeTransportMode.wifiRTP,
              offer.sessionID == sessionID,
              let deadlineToken =
                wifiCommitGate.acceptProbe(sessionID: sessionID) else { return }

        // The authenticated UDP path is authoritative. The initial legacy
        // fallback must never race a host that is about to commit Wi-Fi.
        negotiationFallbackToken &+= 1
        networkQueue.asyncAfter(
            deadline: .now() + .milliseconds(
                WifiTransportTiming.clientPostProbeCommitTimeoutMs)
        ) { [weak self] in
            guard let self,
                  generation == self.connectionGeneration,
                  self.wireAuthenticatedGeneration == generation,
                  self.committedTransportGeneration != generation,
                  self.wifiCommitGate.timeout(
                    sessionID: sessionID,
                    token: deadlineToken) else { return }
            let fallback = TransportReady(
                version: 1,
                mode: RealtimeTransportMode.legacyTLS,
                status: TransportReadyStatus.ready,
                sessionID: sessionID,
                audioCodec: AudioCodecCapabilities.pcm)
            guard let payload = fallback.encode(),
                  let fallbackToken = self.wifiCommitGate.fallbackToken
            else {
                self.handleStreamError(
                    "Unable to request Wi-Fi legacy fallback.")
                return
            }
            self.sendWireMessage(
                type: .transportReady,
                payload: payload,
                sequence: 0)
            self.networkQueue.asyncAfter(
                deadline: .now() + .milliseconds(
                    WifiTransportTiming.clientFallbackCommitTimeoutMs)
            ) { [weak self] in
                guard let self,
                      generation == self.connectionGeneration,
                      self.wireAuthenticatedGeneration == generation,
                      self.committedTransportGeneration != generation,
                      self.wifiCommitGate.fallbackTimeout(
                        sessionID: sessionID,
                        token: fallbackToken) else { return }
                self.handleStreamError(
                    "Wi-Fi legacy fallback commit timed out.")
            }
        }
    }

    private func handleWifiCommittedFailure(
        generation: UInt64,
        error: Error
    ) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard WifiCommittedFailurePolicy.shouldTearDown(
            failureGeneration: generation,
            connectionGeneration: connectionGeneration,
            committedGeneration: committedTransportGeneration) else { return }
        guard committedRealtimeMode == RealtimeTransportMode.wifiRTP,
              wifiLegacyFallbackRequestGeneration != generation,
              let sessionID = committedRealtimeSessionID,
              connection != nil else {
            if wifiLegacyFallbackRequestGeneration == generation {
                return
            }
            handleStreamError(
                "Wi-Fi media transport failed: \(error.localizedDescription)")
            return
        }
        wifiLegacyFallbackRequestGeneration = generation
        wifiMediaReceiver.clearOffer()
        AudioManager.shared.reset()
        let ready = TransportReady(
            version: 1,
            mode: RealtimeTransportMode.legacyTLS,
            status: TransportReadyStatus.ready,
            sessionID: sessionID,
            audioCodec: AudioCodecCapabilities.pcm)
        guard let payload = ready.encode() else {
            handleStreamError("Unable to encode Wi-Fi fallback request.")
            return
        }
        sendWireMessage(
            type: .transportReady,
            payload: payload,
            sequence: 0)
        networkQueue.asyncAfter(
            deadline: .now() + .milliseconds(
                WifiTransportTiming.clientPostProbeCommitTimeoutMs)
        ) { [weak self] in
            guard let self,
                  generation == self.connectionGeneration,
                  self.wifiLegacyFallbackRequestGeneration == generation,
                  self.committedRealtimeMode ==
                    RealtimeTransportMode.wifiRTP else { return }
            self.handleStreamError(
                "Wi-Fi fallback commit timed out after media failure.")
        }
    }

    @discardableResult
    private func fallbackCommittedWifiToLegacy(
        generation: UInt64
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        guard generation == connectionGeneration,
              committedTransportGeneration == generation,
              committedRealtimeMode == RealtimeTransportMode.wifiRTP,
              wifiLegacyFallbackGeneration != generation,
              connection != nil else {
            return false
        }
        wifiLegacyFallbackGeneration = generation
        wifiLegacyFallbackRequestGeneration = nil
        committedRealtimeMode = RealtimeTransportMode.legacyTLS
        wifiMediaReceiver.clearOffer()
        AudioManager.shared.reset()
        return true
    }

    // Removed: inactive four-byte video framing and recursive Data
    // accumulation. The SCST loop above is the sole receive path.

    // MARK: - Private: Stream Error Helper

    private func handleStreamError(_ reason: String) {
        dispatchPrecondition(condition: .onQueue(networkQueue))
        // A failed NWConnection can deliver both an error and a subsequent
        // cancelled callback. The first teardown owns reconnect scheduling;
        // the second callback must not start another retry chain.
        guard connection != nil else { return }
        let failedGeneration = connectionGenerationClock.advance()
        wireReceiveActiveGeneration = nil
        wireAuthenticatedGeneration = nil
        committedTransportGeneration = nil
        committedRealtimeMode = nil
        committedRealtimeSessionID = nil
        wifiLegacyFallbackGeneration = nil
        wifiLegacyFallbackRequestGeneration = nil
        advertisedClientCapabilities = nil
        resetDisplaySession()
        clearPendingTransportOffer()
        wireParser.reset(generation: failedGeneration)
        controlChannelWriter.cancel()
        decoder.invalidate()
        AudioManager.shared.reset()
        connection?.cancel()
        connection = nil
        usbLaneServer.abort()
        usbLaneConnections.values.forEach { $0.cancel() }
        usbLaneConnections.removeAll()
        wifiMediaReceiver.cancel()
        print("[NetworkManager] ⚠️ \(reason)")
        stopTelemetryTimer()
        if usbListener != nil {
            setState(.listening)
        } else {
            setState(.disconnected(reason: reason))
            scheduleAutoReconnect(reset: false)
        }
    }

    // MARK: - Private: Thread-Safe State Transition

    private func setState(_ newState: ConnectionState) {
        DispatchQueue.main.async {
            self.connectionState = newState
        }
    }

    // MARK: - Published Telemetry

    /// Last-frame header-and-payload receive duration in milliseconds, not RTT.
    /// Updated on main thread — safe for SwiftUI binding via StreamManager.
    @Published public var lastFrameReceiveDurationMs: Double = 0.0

    /// Last-frame VideoToolbox decode latency in milliseconds.
    /// Set by DecoderManager; read by the 2Hz telemetry timer.
    @Published public var lastDecodeLatencyMs: Double = 0.0

    /// The sole SwiftUI-facing transport telemetry publication (2 Hz maximum).
    @Published public private(set) var hudTelemetry = TransportHudSnapshot(
        frameReceiveMs: 0,
        decodeMs: 0)

    /// Records completion of the Metal command buffer as a distinct presentation stage.
    public func recordRenderCompletion(
        sequence: UInt32,
        generation: UInt64
    ) {
        transportTelemetry.recordRenderCompletion(
            sequence: sequence,
            generation: generation)
    }

    public func recordDrawableCommitted(
        sequence: UInt32,
        generation: UInt64
    ) {
        transportTelemetry.recordDrawableCommitted(
            sequence: sequence,
            generation: generation)
    }

    public func recordRenderDrop(sequence: UInt32, generation: UInt64) {
        transportTelemetry.recordRenderDrop(
            sequence: sequence,
            generation: generation)
    }

}

// MARK: - Private Extensions

/// Clamps a `Float` to [lo, hi] inclusive.
/// Used by `sendTouchEventNormalized` to guard against out-of-range gesture values.
private extension Float {
    func clamped(_ lo: Float, _ hi: Float) -> Float {
        Swift.min(Swift.max(self, lo), hi)
    }
}
