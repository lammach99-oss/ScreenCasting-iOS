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
    // Older Keychain records omit this field.
    var usbControlTLSSeen: Bool? = nil
}

enum TrustedHostBackingRead {
    case found(Data)
    case missing
    case failed
}

protocol TrustedHostCredentialBacking {
    func load(fingerprint: String) -> Data?
    func read(fingerprint: String) -> TrustedHostBackingRead
    func save(_ data: Data, fingerprint: String) -> Bool
    @discardableResult func delete(fingerprint: String) -> Bool
}

extension TrustedHostCredentialBacking {
    func read(fingerprint: String) -> TrustedHostBackingRead {
        load(fingerprint: fingerprint).map { .found($0) } ?? .missing
    }
}

struct SecurityTrustedHostCredentialBacking: TrustedHostCredentialBacking {
    let service: String
    init(service: String = "com.screencasting.trusted-host.v1") { self.service = service }

    func load(fingerprint: String) -> Data? {
        if case .found(let data) = read(fingerprint: fingerprint) { return data }
        return nil
    }

    func read(fingerprint: String) -> TrustedHostBackingRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: fingerprint,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = result as? Data else { return .failed }
        return .found(data)
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

    func delete(fingerprint: String) -> Bool {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: fingerprint,
        ] as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
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

    @discardableResult
    func delete(fingerprint: String) -> Bool {
        backing.delete(fingerprint: fingerprint)
    }
}

/// Endpoint mappings are indexes into independently pinned host identities.
struct TrustedHostFingerprintStore {
    private let backing: any TrustedHostCredentialBacking
    init(backing: any TrustedHostCredentialBacking = SecurityTrustedHostCredentialBacking(service: "com.screencasting.trusted-host-identity.v1")) {
        self.backing = backing
    }
    private struct Record: Codable {
        let fingerprint: String
        let hostID: Data
        let target: WifiReconnectTarget?
    }
    private func key(_ endpoint: NWEndpoint) -> String? {
        guard let target = WifiReconnectTargetPolicy.target(from: endpoint) else { return nil }
        // Encode deterministically: JSON object key ordering is otherwise unspecified.
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let stable = try? encoder.encode(target) else { return nil }
        return "endpoint." + SHA256.hash(data: stable).map { String(format: "%02x", $0) }.joined()
    }
    func load(endpoint: NWEndpoint) -> String? {
        key(endpoint).flatMap { record(for: $0)?.fingerprint }
    }

    private func record(for key: String) -> Record? {
        guard let record = storedRecord(for: key),
              backing.load(fingerprint: "identity." + record.fingerprint) == record.hostID else { return nil }
        return record
    }

    private func storedRecord(for key: String) -> Record? {
        guard let bytes = backing.load(fingerprint: key),
              let record = try? JSONDecoder().decode(Record.self, from: bytes),
              record.hostID.count == 16 else { return nil }
        return record
    }

    // Includes invalidated endpoint records so callers can suppress retries during cleanup.
    func fingerprintForCleanup(endpoint: NWEndpoint) -> String? {
        key(endpoint).flatMap { storedRecord(for: $0)?.fingerprint }
    }

    func targets(for fingerprint: String) -> [WifiReconnectTarget] {
        (endpointKeys(fingerprint) ?? []).reversed().compactMap { key in
            guard let record = record(for: key), record.fingerprint == fingerprint else { return nil }
            return record.target
        }
    }
    // Selected identity is only for USB's existing proof protocol, never a Wi-Fi endpoint pin.
    func load() -> String? {
        guard let bytes = backing.load(fingerprint: "selected-identity") ?? backing.load(fingerprint: "selected-host") else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
    func save(_ fingerprint: String, endpoint: NWEndpoint, hostID: Data, select: Bool = true,
              saveCredential: () -> Bool = { true }) -> Bool {
        guard !fingerprint.isEmpty, hostID.count == 16, let key = key(endpoint),
              var keys = endpointKeys(fingerprint),
              let target = WifiReconnectTargetPolicy.target(from: endpoint),
              let bytes = try? JSONEncoder().encode(Record(fingerprint: fingerprint, hostID: hostID, target: target)) else { return false }
        if !keys.contains(key) { keys.append(key) }
        guard let index = try? JSONEncoder().encode(keys), saveCredential(),
              backing.save(hostID, fingerprint: "identity." + fingerprint),
              backing.save(index, fingerprint: "index." + fingerprint),
              backing.save(bytes, fingerprint: key) else { return false }
        return !select || backing.save(Data(fingerprint.utf8), fingerprint: "selected-identity")
    }
    func migrateLegacy(endpoint: NWEndpoint, presented: String, credential: TrustedHostCredential?) -> String? {
        guard let legacy = backing.load(fingerprint: "selected-host"), String(data: legacy, encoding: .utf8) == presented,
              let credential, credential.fingerprint == presented, credential.hostID.count == 16,
              credential.deviceID.count == 16, credential.secret.count == 32, credential.sessionID.count == 16,
              save(presented, endpoint: endpoint, hostID: credential.hostID) else { return nil }
        backing.delete(fingerprint: "selected-host")
        return presented
    }
    private func endpointKeys(_ fingerprint: String) -> [String]? {
        switch backing.read(fingerprint: "index." + fingerprint) {
        case .found(let data): return try? JSONDecoder().decode([String].self, from: data)
        case .missing: return []
        case .failed: return nil
        }
    }
    @discardableResult
    func delete(fingerprint: String) -> Bool {
        // Removing the identity invalidates every endpoint pin before cleaning up its index.
        guard let keys = endpointKeys(fingerprint),
              backing.delete(fingerprint: "identity." + fingerprint) else { return false }
        for key in keys {
            // A reused endpoint might now belong to a different, explicitly confirmed host.
            switch backing.read(fingerprint: key) {
            case .missing: continue
            case .failed: return false
            case .found(let data):
                guard let record = try? JSONDecoder().decode(Record.self, from: data) else { return false }
                if record.fingerprint == fingerprint, !backing.delete(fingerprint: key) { return false }
            }
        }
        for key in ["selected-identity", "selected-host"] {
            switch backing.read(fingerprint: key) {
            case .missing: continue
            case .failed: return false
            case .found(let data):
                if data == Data(fingerprint.utf8), !backing.delete(fingerprint: key) { return false }
            }
        }
        // Keep the inventory until every dependent deletion has succeeded or the item is absent.
        return backing.delete(fingerprint: "index." + fingerprint)
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
        // Both validated result values establish a session.
        case (.resume, .sessionResumeResult): stage = .complete
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

enum TrustedHostForgetOutcome: Equatable {
    case both
    case localOnly
    case savedTargetRemoved
    case noSavedPairing
    case localFailed(pcConfirmed: Bool)
    case cleanupIncomplete(pcConfirmed: Bool)

    var message: String {
        switch self {
        case .both: return "Pairing was removed from this iPad and the PC."
        case .localOnly:
            return "Pairing was removed from this iPad only. The PC may still list this iPad as paired. Remove it from the PC’s paired devices."
        case .savedTargetRemoved: return "The saved reconnect target was removed from this iPad."
        case .noSavedPairing: return "This iPad has no saved pairing for this PC."
        case .localFailed(let pcConfirmed):
            return pcConfirmed
                ? "The PC removed this iPad from its paired devices. This iPad couldn’t remove its saved pairing."
                : "This iPad couldn’t remove its saved pairing. The PC may still list this iPad as paired."
        case .cleanupIncomplete(let pcConfirmed):
            return pcConfirmed
                ? "The PC removed this iPad from its paired devices. This iPad blocked the saved pairing and still has records to remove. Retry cleanup."
                : "This iPad blocked the saved pairing and still has records to remove. The PC may still list this iPad as paired. Retry cleanup."
        }
    }
}

struct WifiReconnectTarget: Codable, Hashable {
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
            return .hostPort(host: RemoteHostAddress.networkHost(host), port: nwPort)
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

    static let remoteUnsupportedReason = "PC audio is not available in remote sessions."
    static func supportsAudioAndAuto(remote: Bool) -> Bool { !remote }

    func forSession(remote: Bool, manualFallback: Bool = false) -> ClientStreamSettingsPreference {
        ClientStreamSettingsPreference(bitrateMbps: bitrateMbps,
            audioEnabled: remote ? false : audioEnabled,
            adaptiveBitrateEnabled: !remote && !manualFallback && adaptiveBitrateEnabled)
    }

    /// A whole-Mbps control must not rewrite a host's fractional readback just
    /// because its display rounded. Explicit user changes still send exactly.
    func matchesReportedSettings(_ host: ClientStreamSettingsPreference) -> Bool {
        bitrateMbps == host.bitrateMbps.rounded() && audioEnabled == host.audioEnabled &&
            adaptiveBitrateEnabled == host.adaptiveBitrateEnabled
    }

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
    private static let migratedCastingBitrateKey =
        "ScreenCasting.client.migratedCastingBitrateMbps.v1"
    private static let migratedRemoteBitrateKey =
        "ScreenCasting.client.migratedRemoteBitrateMbps.v1"
    private static let audioKey =
        "ScreenCasting.client.desiredAudioEnabled.v1"

    private static let adaptiveKey =
        "ScreenCasting.client.desiredAdaptiveBitrateEnabled.v1"

    // Keep structural Auto consent scoped to the paired PC across routes.
    // The former app-wide flag cannot identify which PC the user chose.
    private static func hostSettingKey(_ setting: String, hostID: Data, remote: Bool = false) -> String {
        let prefix = remote ? "ScreenCasting.client.remoteHostSettings.v1." : "ScreenCasting.client.hostSettings.v1."
        return prefix + hostID.base64EncodedString() + "." + setting
    }

    static func loadAutoQuality(hostID: Data, remote: Bool = false, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: hostSettingKey("autoQuality", hostID: hostID, remote: remote))
    }

    static func saveAutoQuality(_ enabled: Bool, hostID: Data, remote: Bool = false, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: hostSettingKey("autoQuality", hostID: hostID, remote: remote))
    }

    static func loadRemoteAudio(hostID: Data, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: hostSettingKey("remoteAudio", hostID: hostID, remote: true))
    }

    static func saveRemoteAudio(_ enabled: Bool, hostID: Data, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: hostSettingKey("remoteAudio", hostID: hostID, remote: true))
    }

    static func migrateCastingBitrate(defaults: UserDefaults) {
        // Existing credentials are looked up individually. Snapshot the old
        // shared value for each existing host that has no override yet.
        guard defaults.object(forKey: migratedCastingBitrateKey) == nil else { return }
        defaults.set(load(defaults: defaults).bitrateMbps, forKey: migratedCastingBitrateKey)
    }
    static func migrateRemoteBitrate(defaults: UserDefaults) {
        guard defaults.object(forKey: migratedRemoteBitrateKey) == nil else { return }
        defaults.set(load(defaults: defaults).bitrateMbps, forKey: migratedRemoteBitrateKey)
    }

    static func initializeCastingBitrateForNewPairing(hostID: Data, remote: Bool = false, defaults: UserDefaults) {
        let key = hostSettingKey("manualBitrateMbps", hostID: hostID, remote: remote)
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(load(defaults: defaults).bitrateMbps, forKey: key)
    }

    static func load(
        hostID: Data? = nil,
        remote: Bool = false,
        defaults: UserDefaults = .standard
    ) -> ClientStreamSettingsPreference {
        let defaultBitrate = (defaults.object(forKey: bitrateKey) as? NSNumber)?.doubleValue
            ?? ClientStreamSettingsPreference.defaultBitrateMbps
        let bitrate: Double
        if let hostID {
            let key = hostSettingKey("manualBitrateMbps", hostID: hostID, remote: remote)
            bitrate = (defaults.object(forKey: key) as? NSNumber)?.doubleValue
                ?? (defaults.object(forKey: remote ? migratedRemoteBitrateKey : migratedCastingBitrateKey) as? NSNumber)?.doubleValue
                ?? defaultBitrate
        } else {
            bitrate = defaultBitrate
        }
        let audioEnabled =
            (defaults.object(forKey: audioKey) as? NSNumber)?.boolValue
            ?? ClientStreamSettingsPreference.defaultAudioEnabled
        let adaptive = (defaults.object(forKey: adaptiveKey) as? NSNumber)?.boolValue ?? false
        return .normalized(
            bitrateMbps: bitrate,
            audioEnabled: audioEnabled,
            adaptiveBitrateEnabled: adaptive).forSession(remote: remote)
    }

    static func save(
        _ preference: ClientStreamSettingsPreference,
        hostID: Data? = nil,
        remote: Bool = false,
        defaults: UserDefaults = .standard
    ) {
        let normalized = ClientStreamSettingsPreference.normalized(
            bitrateMbps: preference.bitrateMbps,
            audioEnabled: preference.audioEnabled,
            adaptiveBitrateEnabled: preference.adaptiveBitrateEnabled)
        if remote {
            guard let hostID else { return }
            defaults.set(normalized.bitrateMbps, forKey: hostSettingKey("manualBitrateMbps", hostID: hostID, remote: true))
            return
        }
        let key = hostID.map { hostSettingKey("manualBitrateMbps", hostID: $0) } ?? bitrateKey
        defaults.set(normalized.bitrateMbps, forKey: key)
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

enum ClientSettingsWireCodec {
    static func get(requestID: UInt32) -> Data {
        var payload = Data(count: 24)
        payload[0] = 1
        payload.storeLittleEndian(requestID, at: 4)
        return payload
    }

    static func update(requestID: UInt32, generation: UInt64,
                       desired: ClientStreamSettingsPreference, remote: Bool) -> Data {
        let supported = desired.forSession(remote: remote)
        var payload = get(requestID: requestID)
        payload[1] = supported.audioEnabled ? 1 : 0
        payload[3] = supported.adaptiveBitrateEnabled ? 1 : 0
        payload.storeLittleEndian(generation, at: 8)
        payload.storeLittleEndian(UInt32(supported.bitrateMbps * 1_000_000), at: 16)
        return payload
    }
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
        outcome: ClientSettingsApplyOutcome,
        remote: Bool = false
    ) -> ClientSettingsReconciliationDecision {
        // Remote has no persisted casting preference authority. Only explicit
        // user changes send Update; readback/rejections never manufacture one.
        if remote {
            if desired.forSession(remote: true).matchesReportedSettings(effective) { return .inSync }
            if case .rejected = outcome { return .suppressHardRejection }
            return .suppressAlreadyAttempted
        }
        guard !desired.matchesReportedSettings(effective) else {
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
    private(set) var lastSettingsGetGeneration: UInt64?

    mutating func shouldRequestSettings(
        committedGeneration: UInt64
    ) -> Bool {
        guard lastSettingsGetGeneration != committedGeneration else {
            return false
        }
        lastSettingsGetGeneration = committedGeneration
        return true
    }

    mutating func reset() {
        lastSettingsGetGeneration = nil
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

    var preference: ClientStreamSettingsPreference {
        ClientStreamSettingsPreference(bitrateMbps: Double(bitrateBps) / 1_000_000,
            audioEnabled: audioEnabled, adaptiveBitrateEnabled: adaptiveBitrateEnabled)
    }

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
        guard bitrateBps >= 3_000_000, bitrateBps <= 100_000_000 else { return nil }
        return TrustedSettingsState(
            generation: generation,
            bitrateBps: bitrateBps,
            audioEnabled: payload[1] == 1,
            adaptiveBitrateEnabled: payload[3] == 1,
            rejectionReason: rejectionReason)
    }
}
