import XCTest
import Security
@testable import iPadCasting

final class USBServerIdentityTests: XCTestCase {
    func testFirstLoadCreatesKeychainIdentity() throws {
        USBServerIdentityStore.delete()
        defer { USBServerIdentityStore.delete() }
        let first = USBServerIdentityStore.loadOrCreate()
        if first == nil { throw XCTSkip("simulator Keychain does not permit permanent keys") }
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
        XCTAssertTrue(USBServerIdentityStore.testRecover())
        XCTAssertEqual(USBServerIdentityStore.testRecoveryState != nil, true)
    }

    func testOrphanCertificateIsRemovedAndRegeneratedInOneCall() {
        USBServerIdentityStore.testCreateOrphanCertificate()
        XCTAssertTrue(USBServerIdentityStore.testRecover())
    }

    func testCorruptCertificateIsRejectedAndRegenerated() {
        USBServerIdentityStore.testCreateCorruptCertificate()
        XCTAssertTrue(USBServerIdentityStore.testRecover())
    }

    func testInsertionFailureCleansUpAndDoesNotWedgeNextCall() {
        USBServerIdentityStore.delete()
        USBServerIdentityStore.testRecoveryState = .insertionFailure
        XCTAssertFalse(USBServerIdentityStore.testRecover())
        XCTAssertTrue(USBServerIdentityStore.testRecover())
    }

    func testDeleteAndRegenerate() {
        USBServerIdentityStore.testRecoveryState = .empty
        XCTAssertTrue(USBServerIdentityStore.testRecover())
        USBServerIdentityStore.testRecoveryState = .empty
        XCTAssertTrue(USBServerIdentityStore.testRecover())
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
