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
