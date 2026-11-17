import Foundation
import Network
import CryptoKit
import QuartzCore
import AVFoundation
import Security
import UIKit

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
    let service: String
    init(service: String = "com.screencasting.trusted-host.v1") { self.service = service }

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

/// Endpoint mappings are indexes into independently pinned host identities.
struct TrustedHostFingerprintStore {
    private let backing: any TrustedHostCredentialBacking
    init(backing: any TrustedHostCredentialBacking = SecurityTrustedHostCredentialBacking(service: "com.screencasting.trusted-host-identity.v1")) {
        self.backing = backing
    }
    private struct Record: Codable { let fingerprint: String; let hostID: Data }
    private func key(_ endpoint: NWEndpoint) -> String? {
        guard let target = WifiReconnectTargetPolicy.target(from: endpoint) else { return nil }
        // Encode deterministically: JSON object key ordering is otherwise unspecified.
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let stable = try? encoder.encode(target) else { return nil }
        return "endpoint." + SHA256.hash(data: stable).map { String(format: "%02x", $0) }.joined()
    }
    func load(endpoint: NWEndpoint) -> String? {
        guard let key = key(endpoint), let bytes = backing.load(fingerprint: key),
              let record = try? JSONDecoder().decode(Record.self, from: bytes),
              record.hostID.count == 16,
              backing.load(fingerprint: "identity." + record.fingerprint) == record.hostID else { return nil }
        return record.fingerprint
    }
    // Selected identity is only for USB's existing proof protocol, never a Wi-Fi endpoint pin.
    func load() -> String? {
        guard let bytes = backing.load(fingerprint: "selected-identity") ?? backing.load(fingerprint: "selected-host") else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
    func save(_ fingerprint: String, endpoint: NWEndpoint, hostID: Data) -> Bool {
        guard !fingerprint.isEmpty, hostID.count == 16, let key = key(endpoint),
              let bytes = try? JSONEncoder().encode(Record(fingerprint: fingerprint, hostID: hostID)) else { return false }
        var keys = endpointKeys(fingerprint)
        if !keys.contains(key) { keys.append(key) }
        guard let index = try? JSONEncoder().encode(keys),
              backing.save(hostID, fingerprint: "identity." + fingerprint),
              backing.save(index, fingerprint: "index." + fingerprint),
              backing.save(bytes, fingerprint: key),
              backing.save(Data(fingerprint.utf8), fingerprint: "selected-identity") else { return false }
        return true
    }
    func migrateLegacy(endpoint: NWEndpoint, presented: String, credential: TrustedHostCredential?) -> String? {
        guard let legacy = backing.load(fingerprint: "selected-host"), String(data: legacy, encoding: .utf8) == presented,
              let credential, credential.fingerprint == presented, credential.hostID.count == 16,
              credential.deviceID.count == 16, credential.secret.count == 32, credential.sessionID.count == 16,
              save(presented, endpoint: endpoint, hostID: credential.hostID) else { return nil }
        backing.delete(fingerprint: "selected-host")
        return presented
    }
    private func endpointKeys(_ fingerprint: String) -> [String] {
        guard let data = backing.load(fingerprint: "index." + fingerprint) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
    func delete(fingerprint: String) {
        for key in endpointKeys(fingerprint) {
            // A reused endpoint might now belong to a different, explicitly confirmed host.
            if let data = backing.load(fingerprint: key),
               let record = try? JSONDecoder().decode(Record.self, from: data), record.fingerprint == fingerprint {
                backing.delete(fingerprint: key)
            }
        }
        backing.delete(fingerprint: "index." + fingerprint)
        backing.delete(fingerprint: "identity." + fingerprint)
        for key in ["selected-identity", "selected-host"] {
            if backing.load(fingerprint: key) == Data(fingerprint.utf8) { backing.delete(fingerprint: key) }
        }
    }
}

/// Serialized on NetworkManager.networkQueue. A server cannot advance a local request stage.
struct WifiAuthenticationState {
    enum Stage { case identity, ready, hello, pin, pinResult, challenge, proofResult, paired, trusted, resume, complete, failed }
    private(set) var stage: Stage = .failed
    mutating func begin(confirmed: Bool) { stage = confirmed ? .ready : .identity }
    mutating func confirm() -> Bool { guard stage == .identity else { return false }; stage = .ready; return true }
    mutating func sentHello() -> Bool { guard stage == .ready else { return false }; stage = .hello; return true }
    mutating func sentPIN() -> Bool { guard stage == .pin else { return false }; stage = .pinResult; return true }
    mutating func sentProof() -> Bool { guard stage == .challenge else { return false }; stage = .proofResult; return true }
    var mayPersistPairing: Bool { stage == .paired }
    mutating func receive(_ type: WireMessageType, accepted: Bool = false) -> Bool {
        switch (stage, type) {
        case (.hello, .pairingRequired): stage = .pin
        case (.hello, .trustedDeviceChallenge): stage = .challenge
        case (.pinResult, .authResult): stage = accepted ? .paired : .pin
        case (.proofResult, .authResult): stage = accepted ? .trusted : .failed
        case (.paired, .pairingSuccess): stage = .resume
        case (.trusted, .trustedAuthResult): stage = accepted ? .resume : .failed
        case (.resume, .sessionResumeResult): stage = accepted ? .complete : .failed
        default: stage = .failed; return false
        }
        return true
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

enum RecentWifiResumePolicy {
    static let relaunchWindow: TimeInterval = 30

    static func isValid(
        resumeUntil: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        guard let resumeUntil else { return false }
        return resumeUntil >= now
    }
}

enum WifiLifecyclePolicy {
    static let backgroundGrace: TimeInterval = 5

    static func shouldTearDownAfterGrace(
        isForegroundActive: Bool,
        isUSB: Bool,
        scheduledGeneration: UInt64,
        currentGeneration: UInt64,
        hasSameConnection: Bool,
        isWaiting: Bool = false
    ) -> Bool {
        (!isForegroundActive || isWaiting) && !isUSB &&
            scheduledGeneration == currentGeneration && hasSameConnection
    }
}

enum RecentWifiResumeStore {
    private static let key = "ScreenCasting.wifi.relaunchResumeUntil"

    static func mark(
        now: TimeInterval = Date().timeIntervalSince1970,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(
            now + RecentWifiResumePolicy.relaunchWindow,
            forKey: key)
    }

    static func consumeIfValid(
        now: TimeInterval = Date().timeIntervalSince1970,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let value = defaults.object(forKey: key) as? NSNumber
        let resumeUntil = value?.doubleValue
        defaults.removeObject(forKey: key)
        return RecentWifiResumePolicy.isValid(
            resumeUntil: resumeUntil,
            now: now)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

struct WifiReconnectTarget: Codable, Equatable {
    enum Kind: String, Codable {
        case hostPort
        case service
    }

    let kind: Kind
    let host: String?
    let port: UInt16?
    let serviceName: String?
    let serviceType: String?
    let serviceDomain: String?

    static func hostPort(host: String, port: UInt16) -> Self {
        Self(
            kind: .hostPort,
            host: host,
            port: port,
            serviceName: nil,
            serviceType: nil,
            serviceDomain: nil)
    }

    static func service(name: String, type: String, domain: String) -> Self {
        Self(
            kind: .service,
            host: nil,
            port: nil,
            serviceName: name,
            serviceType: type,
            serviceDomain: domain)
    }

    var endpoint: NWEndpoint? {
        switch kind {
        case .hostPort:
            guard let host, !host.isEmpty,
                  let port,
                  let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
            return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        case .service:
            guard let serviceName, !serviceName.isEmpty,
                  let serviceType, !serviceType.isEmpty,
                  let serviceDomain, !serviceDomain.isEmpty else { return nil }
            return .service(
                name: serviceName,
                type: serviceType,
                domain: serviceDomain,
                interface: nil)
        }
    }
}

enum WifiReconnectTargetPolicy {
    static func target(from endpoint: NWEndpoint) -> WifiReconnectTarget? {
        switch endpoint {
        case .hostPort(let host, let port):
            return .hostPort(host: String(describing: host), port: port.rawValue)
        case .service(let name, let type, let domain, _):
            return .service(name: name, type: type, domain: domain)
        default:
            return nil
        }
    }
}

enum WifiReconnectTargetSelection {
    static func preferred(
        structured: WifiReconnectTarget?,
        legacyHost: String?
    ) -> WifiReconnectTarget? {
        if let structured { return structured }
        guard let legacyHost, !legacyHost.isEmpty else { return nil }
        return .hostPort(host: legacyHost, port: 27015)
    }
}

enum WifiReconnectTargetStore {
    private static let key = "ScreenCasting.wifi.reconnectTarget.v1"

    static func save(
        _ target: WifiReconnectTarget,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(target) else { return }
        defaults.set(data, forKey: key)
    }

    static func load(
        defaults: UserDefaults = .standard
    ) -> WifiReconnectTarget? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WifiReconnectTarget.self, from: data)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

struct ClientStreamSettingsPreference: Equatable {
    static let minimumBitrateMbps: Double = 3
    static let maximumBitrateMbps: Double = 100
    static let defaultBitrateMbps: Double = 20
    static let defaultAudioEnabled = true

    let bitrateMbps: Double
    let audioEnabled: Bool
    let adaptiveBitrateEnabled: Bool

    static func normalized(
        bitrateMbps: Double,
        audioEnabled: Bool,
        adaptiveBitrateEnabled: Bool = false
    ) -> ClientStreamSettingsPreference {
        let rounded = round(bitrateMbps)
        return ClientStreamSettingsPreference(
            bitrateMbps: min(
                maximumBitrateMbps,
                max(minimumBitrateMbps, rounded)),
            audioEnabled: audioEnabled,
            adaptiveBitrateEnabled: adaptiveBitrateEnabled)
    }
}

enum ClientStreamSettingsStore {
    private static let bitrateKey =
        "ScreenCasting.client.desiredBitrateMbps.v1"
    private static let audioKey =
        "ScreenCasting.client.desiredAudioEnabled.v1"

    private static let adaptiveKey =
        "ScreenCasting.client.desiredAdaptiveBitrateEnabled.v1"

    static func load(
        defaults: UserDefaults = .standard
    ) -> ClientStreamSettingsPreference {
        let bitrate =
            (defaults.object(forKey: bitrateKey) as? NSNumber)?.doubleValue
            ?? ClientStreamSettingsPreference.defaultBitrateMbps
        let audioEnabled =
            (defaults.object(forKey: audioKey) as? NSNumber)?.boolValue
            ?? ClientStreamSettingsPreference.defaultAudioEnabled
        let adaptive = (defaults.object(forKey: adaptiveKey) as? NSNumber)?.boolValue ?? false
        return .normalized(
            bitrateMbps: bitrate,
            audioEnabled: audioEnabled,
            adaptiveBitrateEnabled: adaptive)
    }

    static func save(
        _ preference: ClientStreamSettingsPreference,
        defaults: UserDefaults = .standard
    ) {
        let normalized = ClientStreamSettingsPreference.normalized(
            bitrateMbps: preference.bitrateMbps,
            audioEnabled: preference.audioEnabled,
            adaptiveBitrateEnabled: preference.adaptiveBitrateEnabled)
        defaults.set(normalized.bitrateMbps, forKey: bitrateKey)
        defaults.set(normalized.audioEnabled, forKey: audioKey)
        defaults.set(normalized.adaptiveBitrateEnabled, forKey: adaptiveKey)
    }
}

enum TrustedSettingsRejectReason: UInt8, Equatable {
    case none = 0
    case invalidBitrate = 1
    case staleGeneration = 2
    case runtimeApplyFailed = 3
    case invalidRequest = 4
}

enum ClientSettingsApplyOutcome: Equatable {
    case state
    case applied
    case rejected(TrustedSettingsRejectReason)
}

enum ClientSettingsReconciliationDecision: Equatable {
    case inSync
    case send
    case suppressHardRejection
    case suppressAlreadyAttempted
}

struct ClientSettingsReconciliationGate {
    private(set) var lastAutomaticAttemptGeneration: UInt64?
    private(set) var lastStaleRetryGeneration: UInt64?
    private(set) var hardRejectedGeneration: UInt64?
    private(set) var runtimeApplyFailedGeneration: UInt64?
    private(set) var runtimeReadyRetryGeneration: UInt64?

    mutating func decision(
        hostGeneration: UInt64,
        desired: ClientStreamSettingsPreference,
        effective: ClientStreamSettingsPreference,
        outcome: ClientSettingsApplyOutcome
    ) -> ClientSettingsReconciliationDecision {
        guard desired != effective else {
            runtimeApplyFailedGeneration = nil
            runtimeReadyRetryGeneration = nil
            if hardRejectedGeneration == hostGeneration {
                hardRejectedGeneration = nil
            }
            return .inSync
        }
        if case .rejected(let reason) = outcome {
            if reason == .staleGeneration {
                guard lastAutomaticAttemptGeneration != hostGeneration else {
                    return .suppressAlreadyAttempted
                }
                guard lastStaleRetryGeneration != hostGeneration else {
                    return .suppressAlreadyAttempted
                }
                lastStaleRetryGeneration = hostGeneration
                lastAutomaticAttemptGeneration = hostGeneration
                return .send
            }
            if reason == .runtimeApplyFailed {
                if runtimeReadyRetryGeneration == hostGeneration {
                    runtimeApplyFailedGeneration = hostGeneration
                } else if runtimeApplyFailedGeneration != hostGeneration {
                    runtimeApplyFailedGeneration = hostGeneration
                    runtimeReadyRetryGeneration = nil
                }
                hardRejectedGeneration = hostGeneration
                lastAutomaticAttemptGeneration = hostGeneration
                return .suppressHardRejection
            }
            runtimeApplyFailedGeneration = nil
            runtimeReadyRetryGeneration = nil
            hardRejectedGeneration = hostGeneration
            lastAutomaticAttemptGeneration = hostGeneration
            return .suppressHardRejection
        }
        if case .state = outcome,
           runtimeApplyFailedGeneration != nil {
            if let retryGeneration = runtimeReadyRetryGeneration {
                if retryGeneration == hostGeneration {
                    return .suppressHardRejection
                }
                runtimeApplyFailedGeneration = nil
                runtimeReadyRetryGeneration = nil
                if hardRejectedGeneration == retryGeneration {
                    hardRejectedGeneration = nil
                }
            } else {
                runtimeReadyRetryGeneration = hostGeneration
                hardRejectedGeneration = nil
                lastAutomaticAttemptGeneration = hostGeneration
                return .send
            }
        }
        if hardRejectedGeneration == hostGeneration {
            return .suppressHardRejection
        }
        guard lastAutomaticAttemptGeneration != hostGeneration else {
            return .suppressAlreadyAttempted
        }
        lastAutomaticAttemptGeneration = hostGeneration
        return .send
    }

    mutating func reset() {
        lastAutomaticAttemptGeneration = nil
        lastStaleRetryGeneration = nil
        hardRejectedGeneration = nil
        runtimeApplyFailedGeneration = nil
        runtimeReadyRetryGeneration = nil
    }
}

struct ClientSettingsStateModel {
    private(set) var desired: ClientStreamSettingsPreference
    private(set) var effective: ClientStreamSettingsPreference
    private(set) var generation: UInt64 = 0

    init(desired: ClientStreamSettingsPreference) {
        self.desired = desired
        self.effective = .normalized(
            bitrateMbps: ClientStreamSettingsPreference.defaultBitrateMbps,
            audioEnabled: ClientStreamSettingsPreference.defaultAudioEnabled)
    }

    mutating func receiveHostState(
        _ effective: ClientStreamSettingsPreference,
        generation: UInt64
    ) {
        self.effective = effective
        self.generation = generation
    }

    mutating func setDesired(_ desired: ClientStreamSettingsPreference) {
        self.desired = desired
    }

    mutating func resetHostGeneration() {
        generation = 0
    }
}

struct ClientSettingsSyncPolicy {
    private(set) var lastUsbSettingsGetGeneration: UInt64?

    mutating func shouldRequestUsbSettings(
        committedGeneration: UInt64
    ) -> Bool {
        guard lastUsbSettingsGetGeneration != committedGeneration else {
            return false
        }
        lastUsbSettingsGetGeneration = committedGeneration
        return true
    }

    mutating func reset() {
        lastUsbSettingsGetGeneration = nil
    }
}

enum DesiredSettingsSendResult: Equatable {
    case sent(requestID: UInt32)
    case waitingForHost
}

enum DesiredSettingsSendDecision: Equatable {
    case send
    case waitingForHost
}

enum DesiredSettingsSendPolicy {
    static func decision(canSend: Bool) -> DesiredSettingsSendDecision {
        canSend ? .send : .waitingForHost
    }

    static func status(for result: DesiredSettingsSendResult) -> String {
        switch result {
        case .sent: return "Applying…"
        case .waitingForHost: return "Waiting for Host"
        }
    }
}

struct TrustedSettingsState: Equatable {
    let generation: UInt64
    let bitrateBps: UInt32
    let audioEnabled: Bool
    let adaptiveBitrateEnabled: Bool
    let rejectionReason: TrustedSettingsRejectReason

    static func decode(_ payload: Data) -> TrustedSettingsState? {
        guard payload.count == 24, payload[0] == 1, payload[1] <= 1,
              let rejectionReason = TrustedSettingsRejectReason(rawValue: payload[2]),
              payload[3] <= 1,
              payload[20] == 0, payload[21] == 0,
              payload[22] == 0, payload[23] == 0 else { return nil }
        let generation = payload.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self).littleEndian
        }
        let bitrateBps = payload.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self).littleEndian
        }
        guard bitrateBps >= 3_000_000, bitrateBps <= 100_000_000,
              bitrateBps.isMultiple(of: 1_000_000) else { return nil }
        return TrustedSettingsState(
            generation: generation,
            bitrateBps: bitrateBps,
            audioEnabled: payload[1] == 1,
            adaptiveBitrateEnabled: payload[3] == 1,
            rejectionReason: rejectionReason)
    }
}
