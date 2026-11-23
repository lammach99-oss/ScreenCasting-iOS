import Foundation
import CryptoKit
import Network
import Security

/// Testable decoder for externally supplied identity resource data.
/// No identity material or fallback resource is embedded in the app.
enum USBIdentityResource {
    static func decode(_ encoded: String) -> Data? {
        let normalized = encoded.filter { !$0.isWhitespace }
        return Data(base64Encoded: String(normalized))
    }
}

/// Creates and persists the iPad-side USB TLS identity without shipping a
/// private key. The host pins the certificate fingerprint after first-use
/// pairing, so a device-local self-signed certificate is sufficient.
protocol USBServerIdentityKeychainBackend {
    associatedtype Identity

    mutating func loadIdentity() -> Identity?
    mutating func createIdentity() -> Identity?
    mutating func deleteIdentityRecords()
}

enum USBServerIdentityStore {
    static let keychainLabel = "ScreenCasting USB Server Identity"
    private static let applicationTag = Data("com.screencasting.usb-server-identity".utf8)

    static func loadOrCreate() -> SecIdentity? {
        var backend = SystemKeychainBackend()
        return loadOrCreate(using: &backend)
    }

    /// The recovery algorithm used by the production entry point. XCTest
    /// injects an in-memory backend here, while production supplies the
    /// Security.framework-backed implementation below.
    @discardableResult
    static func loadOrCreate<Backend: USBServerIdentityKeychainBackend>(using backend: inout Backend) -> Backend.Identity? {
        if let existing = backend.loadIdentity() { return existing }

        // A missing identity can mean an orphaned key, a stale certificate,
        // a corrupt certificate, or a duplicate-item race. Purge all records
        // before each bounded regeneration attempt so recovery completes in
        // this public call and never leaves duplicate-key state behind.
        for _ in 0..<2 {
            backend.deleteIdentityRecords()
            if backend.createIdentity() != nil,
               let persisted = backend.loadIdentity() {
                return persisted
            }
            // createIdentity may have persisted a permanent key before a
            // certificate insertion or reload failure. Always roll it back.
            backend.deleteIdentityRecords()
        }
        return nil
    }

    static func copy() -> SecIdentity? {
        var backend = SystemKeychainBackend()
        return backend.loadIdentity()
    }

    static func delete() {
        var backend = SystemKeychainBackend()
        backend.deleteIdentityRecords()
    }

    static func delete<Backend: USBServerIdentityKeychainBackend>(using backend: inout Backend) {
        backend.deleteIdentityRecords()
    }

    private struct SystemKeychainBackend: USBServerIdentityKeychainBackend {
        typealias Identity = SecIdentity
        private let label = USBServerIdentityStore.keychainLabel

        mutating func loadIdentity() -> SecIdentity? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassIdentity,
                kSecAttrLabel as String: label,
                kSecReturnRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var value: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
                  let value,
                  CFGetTypeID(value) == SecIdentityGetTypeID() else { return nil }
            return unsafeBitCast(value, to: SecIdentity.self)
        }

        mutating func createIdentity() -> SecIdentity? {
            guard let key = USBServerIdentityStore.createKey(),
                  let certificate = USBServerIdentityStore.createCertificate(for: key) else {
                deleteIdentityRecords()
                return nil
            }

            let certificateAttributes: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: label,
                kSecValueRef as String: certificate,
            ]
            guard SecItemAdd(certificateAttributes as CFDictionary, nil) == errSecSuccess,
                  let identity = loadIdentity() else {
                deleteIdentityRecords()
                return nil
            }
            return identity
        }

        mutating func deleteIdentityRecords() {
            for type in [kSecClassIdentity, kSecClassCertificate, kSecClassKey] {
                let query: [String: Any] = [
                    kSecClass as String: type,
                    kSecAttrLabel as String: label,
                ]
                SecItemDelete(query as CFDictionary)
            }
        }
    }

    private static func createKey() -> SecKey? {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrLabel as String: keychainLabel,
            kSecAttrApplicationTag as String: applicationTag,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrLabel as String: keychainLabel,
                kSecAttrApplicationTag as String: applicationTag,
            ],
        ]
        var error: Unmanaged<CFError>?
        return SecKeyCreateRandomKey(attributes as CFDictionary, &error)
    }

    private static func createCertificate(for key: SecKey) -> SecCertificate? {
        guard let publicKey = SecKeyCopyPublicKey(key),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { return nil }
        let algorithm = derSequence(derOID("1.2.840.113549.1.1.1"), derNull())
        let subjectPublicKeyInfo = derSequence(algorithm, derBitString(publicKeyData))
        let name = derSequence(derSet(derSequence(derOID("2.5.4.3"), derUTF8("ScreenCasting USB"))))
        let validity = derSequence(derGeneralizedTime(Date().addingTimeInterval(-60)),
                                   derGeneralizedTime(Date().addingTimeInterval(31536000)))
        let tbs = derSequence(
            derExplicit(0, derInteger(Data([2]))),
            derInteger(Data([1])),
            algorithm,
            name,
            validity,
            name,
            subjectPublicKeyInfo)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                                     tbs as CFData, &error) as Data? else { return nil }
        return SecCertificateCreateWithData(nil,
            derSequence(tbs, algorithm, derBitString(signature)) as CFData)
    }

    private static func tlv(_ tag: UInt8, _ value: Data) -> Data {
        var result = Data([tag]); let count = value.count
        if count < 128 { result.append(UInt8(count)) }
        else { let bytes = withUnsafeBytes(of: UInt32(count).bigEndian, Array.init).drop(while: { $0 == 0 }); result.append(0x80 | UInt8(bytes.count)); result.append(contentsOf: bytes) }
        result.append(value); return result
    }
    private static func derSequence(_ values: Data...) -> Data { tlv(0x30, values.reduce(into: Data(), { $0.append($1) })) }
    private static func derSet(_ value: Data) -> Data { tlv(0x31, value) }
    private static func derExplicit(_ tag: UInt8, _ value: Data) -> Data { tlv(0xA0 | tag, value) }
    private static func derInteger(_ value: Data) -> Data { tlv(0x02, value.first.map { $0 & 0x80 != 0 } == true ? Data([0]) + value : value) }
    private static func derNull() -> Data { Data([0x05, 0]) }
    private static func derBitString(_ value: Data) -> Data { tlv(0x03, Data([0]) + value) }
    private static func derUTF8(_ value: String) -> Data { tlv(0x0C, Data(value.utf8)) }
    private static func derGeneralizedTime(_ date: Date) -> Data {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        let value = formatter.string(from: date)
        return tlv(0x18, Data(value.utf8))
    }
    private static func derOID(_ value: String) -> Data {
        let parts = value.split(separator: ".").compactMap { Int($0) }; var bytes = Data([UInt8(parts[0] * 40 + parts[1])])
        for number in parts.dropFirst(2) { var n = number; var encoded = [UInt8(n & 0x7F)]; n >>= 7; while n > 0 { encoded.insert(UInt8(n & 0x7F) | 0x80, at: 0); n >>= 7 }; bytes.append(contentsOf: encoded) }
        return tlv(0x06, bytes)
    }
}

struct USBServerTLSIdentity {
    private let identity: sec_identity_t
    let leafHash: Data

    init?() {
        guard let identity = USBServerIdentityStore.loadOrCreate() else { return nil }
        self.init(identity: identity)
    }

    init?(identity: SecIdentity) {
        guard let protocolIdentity = sec_identity_create(identity) else { return nil }
        var leaf: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &leaf) == errSecSuccess, let leaf else { return nil }
        self.identity = protocolIdentity
        leafHash = Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
    }

    func makeOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
        return options
    }
}

/// NetworkManager registers only the ordinary USB owner immediately before start.
/// The framer consumes that registration on its own Network.framework queue.
final class USBControlTLSUpgrade {
    private struct Key: Hashable {
        let listener: NWEndpoint.Port
        let peer: NWEndpoint.Port
    }

    private static let lock = NSLock()
    private static var registrations: [Key: USBControlTLSUpgrade] = [:]
    static let flag: UInt16 = 0x2000
    static let budget: DispatchTimeInterval = .seconds(5)

    private let key: Key
    private let identity: USBServerTLSIdentity
    private let expectedPin: String
    private let verificationQueue: DispatchQueue
    private let onAdvertise: (DispatchTime) -> Void
    private let advertisementLock = NSLock()
    private var advertisement: DispatchTime?
    private(set) var peerVerified = false // Accessed on verificationQueue.
    let credential: TrustedHostCredential
    var leafHash: Data { identity.leafHash }

    var advertisedAt: DispatchTime? {
        advertisementLock.lock(); defer { advertisementLock.unlock() }
        return advertisement
    }

    init?(listenerPort: NWEndpoint.Port, peer: NWEndpoint, credential: TrustedHostCredential,
          queue: DispatchQueue, loadIdentity: () -> USBServerTLSIdentity?,
          onAdvertise: @escaping (DispatchTime) -> Void) {
        let components = credential.fingerprint.split(separator: ":", omittingEmptySubsequences: false)
        guard case let .hostPort(_, peerPort) = peer,
              components.count == 32, components.allSatisfy({ $0.count == 2 && UInt8($0, radix: 16) != nil }),
              let identity = loadIdentity() else { return nil }
        key = Key(listener: listenerPort, peer: peerPort)
        self.identity = identity
        expectedPin = credential.fingerprint
        verificationQueue = queue
        self.credential = credential
        self.onAdvertise = onAdvertise
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.registrations[key] = self
    }

    func removeRegistration() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if Self.registrations[key] === self { Self.registrations.removeValue(forKey: key) }
    }

    fileprivate static func take(local: NWEndpoint?, remote: NWEndpoint?) -> USBControlTLSUpgrade? {
        guard case let .hostPort(_, localPort)? = local, case let .hostPort(_, remotePort)? = remote else { return nil }
        lock.lock(); defer { lock.unlock() }
        return registrations.removeValue(forKey: Key(listener: localPort, peer: remotePort))
    }

    fileprivate func makeOptions() -> NWProtocolTLS.Options {
        let options = identity.makeOptions()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(security, true)
        sec_protocol_options_set_tls_resumption_enabled(security, false)
        sec_protocol_options_set_tls_tickets_enabled(security, false)
        sec_protocol_options_set_tls_renegotiation_enabled(security, false)
        sec_protocol_options_set_verify_block(security, { [weak self] _, trust, finish in
            let peerTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let self, let leaf = SecTrustGetCertificateAtIndex(peerTrust, 0) else { finish(false); return }
            let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
                .map { String(format: "%02X", $0) }.joined(separator: ":")
            self.peerVerified = fingerprint == self.expectedPin
            finish(self.peerVerified)
        }, verificationQueue)
        return options
    }

    fileprivate func markAdvertised() {
        let now = DispatchTime.now()
        advertisementLock.lock()
        advertisement = now
        advertisementLock.unlock()
        verificationQueue.async { [onAdvertise] in onAdvertise(now) }
    }
}

/// Intercepts just the TLS readiness exchange. The rest of this socket stays a
/// byte stream, with Network.framework TLS added above the framer on opt-in.
final class USBControlTLSFramer: NWProtocolFramerImplementation {
    static let label = "USB control TLS readiness"
    static let definition = NWProtocolFramer.Definition(implementation: USBControlTLSFramer.self)
    private static let offerHeader = Data(ConnectionControlProtocol.frame(
        type: WireMessageType.ping.rawValue, payload: Data(count: 16),
        flags: USBSessionIdentityProof.offerFlag | USBControlTLSUpgrade.flag).prefix(WireProtocol.headerSize))
    private var upgrade: USBControlTLSUpgrade?

    init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        upgrade = USBControlTLSUpgrade.take(local: framer.local, remote: framer.remote)
        guard upgrade != nil else {
            framer.passThroughOutput()
            return .ready
        }
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        guard let upgrade else { return Self.forwardInput(framer: framer) }
        let headerSize = WireProtocol.headerSize
        var matchesOffer = false
        var reachedEnd = false
        let parsedHeader = framer.parseInput(minimumIncompleteLength: headerSize, maximumLength: headerSize) { bytes, complete in
            reachedEnd = complete && (bytes?.count ?? 0) < headerSize
            if let bytes { matchesOffer = Data(bytes) == Self.offerHeader }
            return 0 // Leave legacy readiness bytes for the ordinary SCST parser.
        }
        guard parsedHeader, !reachedEnd else {
            if reachedEnd { framer.markFailed(error: .posix(.EPROTO)); return 0 }
            return headerSize
        }
        if matchesOffer {
            let length = headerSize + 16
            var payload: Data?
            let parsed = framer.parseInput(minimumIncompleteLength: length, maximumLength: length) { bytes, complete in
                guard let bytes, bytes.count == length else { reachedEnd = complete; return 0 }
                payload = Data(bytes.dropFirst(headerSize))
                return length
            }
            if reachedEnd { framer.markFailed(error: .posix(.EPROTO)); return 0 }
            guard parsed, let payload else { return length }
            upgrade.markAdvertised()
            do { try framer.prependApplicationProtocol(options: upgrade.makeOptions()) }
            catch { framer.markFailed(error: .posix(.EPROTO)); return 0 }
            framer.writeOutput(data: ConnectionControlProtocol.frame(type: WireMessageType.pong.rawValue,
                payload: payload, flags: USBSessionIdentityProof.optInFlag | USBControlTLSUpgrade.flag))
        }
        self.upgrade = nil
        framer.passThroughOutput()
        framer.markReady()
        return Self.forwardInput(framer: framer)
    }

    // Network.framework can still invoke input callbacks after passThroughInput().
    // Forward explicitly so the peeked legacy header and later bytes reach the
    // SCST parser (or TLS after an upgrade).
    static func forwardInput(framer: NWProtocolFramer.Instance) -> Int {
        let message = NWProtocolFramer.Message(instance: framer)
        var needsInput = true
        _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { bytes, complete in
            let length = bytes?.count ?? 0
            guard length > 0 || complete else { return 0 }
            let delivered = framer.deliverInputNoCopy(length: length, message: message, isComplete: complete)
            needsInput = delivered && !complete
            return 0 // deliverInputNoCopy already consumes the bytes.
        }
        return needsInput ? 1 : 0
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}
    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message,
                      messageLength: Int, isComplete: Bool) {
        do { try framer.writeOutputNoCopy(length: messageLength) }
        catch { framer.markFailed(error: .posix(.EIO)) }
    }
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}
