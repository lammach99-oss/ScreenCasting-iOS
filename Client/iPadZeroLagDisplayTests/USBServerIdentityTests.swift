import XCTest
import Security
@testable import iPadCasting

final class USBServerIdentityTests: XCTestCase {
    func testFirstLoadCreatesKeychainIdentity() {
        USBServerIdentityStore.delete()
        defer { USBServerIdentityStore.delete() }
        let first = USBServerIdentityStore.loadOrCreate()
        let second = USBServerIdentityStore.copy()
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(fingerprint(first), fingerprint(second))
    }

    func testCertificateInsertionFailureIsNotAccepted() {
        XCTAssertFalse(USBServerIdentityStore.certificateInsertSucceeded(errSecAuthFailed))
        XCTAssertFalse(USBServerIdentityStore.certificateInsertSucceeded(errSecDecode))
    }

    func testDuplicateCertificateIsAcceptedForRecovery() {
        XCTAssertTrue(USBServerIdentityStore.certificateInsertSucceeded(errSecDuplicateItem))
    }

    private func fingerprint(_ identity: SecIdentity?) -> Data? {
        guard let identity else { return nil }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else { return nil }
        return SecCertificateCopyData(certificate) as Data
    }
}
