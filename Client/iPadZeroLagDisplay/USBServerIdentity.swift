import Foundation
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

        mutating func loadIdentity() -> SecIdentity? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassIdentity,
                kSecAttrLabel as String: USBServerIdentityStore.keychainLabel,
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
                kSecAttrLabel as String: USBServerIdentityStore.keychainLabel,
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
                    kSecAttrLabel as String: USBServerIdentityStore.keychainLabel,
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
