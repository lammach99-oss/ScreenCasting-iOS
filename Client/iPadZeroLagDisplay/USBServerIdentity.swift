import Foundation
import Security

/// Creates and persists the iPad-side USB TLS identity without shipping a
/// private key. The host pins the certificate fingerprint after first-use
/// pairing, so a device-local self-signed certificate is sufficient.
enum USBServerIdentityStore {
    static let keychainLabel = "ScreenCasting USB Server Identity"
    private static let applicationTag = Data("com.screencasting.usb-server-identity".utf8)

    #if DEBUG
    static var testCertificateInsertStatus: OSStatus?
    #endif

    static func loadOrCreate() -> SecIdentity? {
        if let existing = copy() { return existing }

        // A missing identity can mean an orphaned key, a stale certificate,
        // or a corrupt keychain record. Purge all identity records before
        // regenerating so recovery completes in this public call and never
        // leaves duplicate-key state for the next launch.
        for _ in 0..<2 {
            delete()
            guard let key = createKey(),
                  let certificate = createCertificate(for: key) else {
                delete()
                continue
            }
            var identity: SecIdentity?
            guard SecIdentityCreateWithCertificate(nil, certificate, &identity) == errSecSuccess,
                  let identity else {
                delete()
                continue
            }

            let certificateAttributes: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: keychainLabel,
                kSecValueRef as String: certificate,
            ]
            #if DEBUG
            let status = testCertificateInsertStatus ?? SecItemAdd(certificateAttributes as CFDictionary, nil)
            #else
            let status = SecItemAdd(certificateAttributes as CFDictionary, nil)
            #endif
            if status == errSecSuccess { return identity }
            // The RSA key is permanent. Remove it when certificate persistence
            // fails, including duplicate-item races, then perform one bounded
            // regeneration attempt in this call.
            delete()
        }
        return nil
    }

    /// Kept internal so XCTest can lock down the Keychain recovery contract
    /// without manufacturing Security.framework objects or writing secrets.
    static func certificateInsertSucceeded(_ status: OSStatus) -> Bool {
        status == errSecSuccess
    }

    static func copy() -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: keychainLabel,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let value,
              CFGetTypeID(value) == SecIdentityGetTypeID() else { return nil }
        return value as! SecIdentity
    }

    static func delete() {
        for type in [kSecClassIdentity, kSecClassCertificate, kSecClassKey] {
            let query: [String: Any] = [
                kSecClass as String: type,
                kSecAttrLabel as String: keychainLabel,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    #if DEBUG
    static func testCreateOrphanKey() { delete(); _ = createKey() }

    static func testCreateOrphanCertificate() {
        delete()
        guard let key = createKey(), let certificate = createCertificate(for: key) else { return }
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrLabel as String: keychainLabel] as CFDictionary)
        _ = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: keychainLabel,
            kSecValueRef as String: certificate,
        ] as CFDictionary, nil)
    }

    static func testCreateCorruptCertificate() {
        delete()
        _ = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: keychainLabel,
            kSecValueData as String: Data([0x01, 0x02, 0x03]),
        ] as CFDictionary, nil)
    }
    #endif

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
