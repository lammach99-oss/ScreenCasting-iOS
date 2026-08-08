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

    func testDuplicateCertificateIsRejectedAndTriggersRegeneration() {
        XCTAssertFalse(USBServerIdentityStore.certificateInsertSucceeded(errSecDuplicateItem))
    }

    func testOrphanKeyIsReconciledAndRegeneratedInOneCall() {
        USBServerIdentityStore.testCreateOrphanKey()
        defer { USBServerIdentityStore.delete() }
        XCTAssertNotNil(USBServerIdentityStore.loadOrCreate())
        XCTAssertNotNil(USBServerIdentityStore.copy())
    }

    func testOrphanCertificateIsRemovedAndRegeneratedInOneCall() {
        USBServerIdentityStore.testCreateOrphanCertificate()
        defer { USBServerIdentityStore.delete() }
        XCTAssertNotNil(USBServerIdentityStore.loadOrCreate())
        XCTAssertNotNil(USBServerIdentityStore.copy())
    }

    func testCorruptCertificateIsRejectedAndRegenerated() {
        USBServerIdentityStore.testCreateCorruptCertificate()
        defer { USBServerIdentityStore.delete() }
        XCTAssertNotNil(USBServerIdentityStore.loadOrCreate())
    }

    func testInsertionFailureCleansUpAndDoesNotWedgeNextCall() {
        USBServerIdentityStore.delete()
        USBServerIdentityStore.testCertificateInsertStatus = errSecAuthFailed
        XCTAssertNil(USBServerIdentityStore.loadOrCreate())
        USBServerIdentityStore.testCertificateInsertStatus = nil
        defer { USBServerIdentityStore.delete() }
        XCTAssertNotNil(USBServerIdentityStore.loadOrCreate())
    }

    func testDeleteAndRegenerate() {
        XCTAssertNotNil(USBServerIdentityStore.loadOrCreate())
        USBServerIdentityStore.delete()
        XCTAssertNotNil(USBServerIdentityStore.loadOrCreate())
    }

    func testAllCertificateInsertionFailuresAreRejected() {
        for status in [errSecAuthFailed, errSecDecode, errSecDuplicateItem, errSecMissingEntitlement] {
            XCTAssertFalse(USBServerIdentityStore.certificateInsertSucceeded(status))
        }
    }

    private func fingerprint(_ identity: SecIdentity?) -> Data? {
        guard let identity else { return nil }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else { return nil }
        return SecCertificateCopyData(certificate) as Data
    }
}
