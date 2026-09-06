import XCTest
@testable import iPadCasting

final class USBServerIdentityTests: XCTestCase {
    func testEmptyStoreCreatesAndPersistsIdentityThroughProductionRecoveryAlgorithm() {
        var backend = FakeKeychainBackend()

        let identity = USBServerIdentityStore.loadOrCreate(using: &backend)

        XCTAssertEqual(identity, FakeIdentity(id: 1))
        XCTAssertEqual(backend.state, .valid(FakeIdentity(id: 1)))
        XCTAssertEqual(backend.createCount, 1)
    }

    func testValidStoreReloadsWithoutRegeneration() {
        var backend = FakeKeychainBackend(state: .valid(FakeIdentity(id: 9)))

        let identity = USBServerIdentityStore.loadOrCreate(using: &backend)

        XCTAssertEqual(identity, FakeIdentity(id: 9))
        XCTAssertEqual(backend.createCount, 0)
        XCTAssertEqual(backend.deleteCount, 0)
    }

    func testOrphanKeyIsDeletedAndRegeneratedInOneCall() {
        assertRegenerates(from: .orphanKey)
    }

    func testOrphanCertificateIsDeletedAndRegeneratedInOneCall() {
        assertRegenerates(from: .orphanCertificate)
    }

    func testCorruptCertificateIsDeletedAndRegeneratedInOneCall() {
        assertRegenerates(from: .corruptCertificate)
    }

    func testInsertionFailureCleansUpPermanentKeyAndRetries() {
        var backend = FakeKeychainBackend(plannedResults: [.insertionFailure])

        let identity = USBServerIdentityStore.loadOrCreate(using: &backend)

        XCTAssertEqual(identity, FakeIdentity(id: 1))
        XCTAssertEqual(backend.state, .valid(FakeIdentity(id: 1)))
        XCTAssertEqual(backend.createCount, 2)
        XCTAssertEqual(backend.state.orphanRecordCount, 0)
    }

    func testPersistentInsertionFailureLeavesNoOrphanRecords() {
        var backend = FakeKeychainBackend(plannedResults: [.insertionFailure, .insertionFailure])

        let identity = USBServerIdentityStore.loadOrCreate(using: &backend)

        XCTAssertNil(identity)
        XCTAssertEqual(backend.state, .empty)
        XCTAssertEqual(backend.state.orphanRecordCount, 0)
    }

    func testDuplicateItemIsCleanedUpAndRegenerated() {
        var backend = FakeKeychainBackend(plannedResults: [.duplicateItem])

        let identity = USBServerIdentityStore.loadOrCreate(using: &backend)

        XCTAssertEqual(identity, FakeIdentity(id: 1))
        XCTAssertEqual(backend.state, .valid(FakeIdentity(id: 1)))
        XCTAssertEqual(backend.state.orphanRecordCount, 0)
    }

    func testDeleteThenRegenerateCreatesNewIdentity() {
        var backend = FakeKeychainBackend(state: .valid(FakeIdentity(id: 4)))
        USBServerIdentityStore.delete(using: &backend)

        let regenerated = USBServerIdentityStore.loadOrCreate(using: &backend)

        XCTAssertEqual(regenerated, FakeIdentity(id: 1))
        XCTAssertEqual(backend.state, .valid(FakeIdentity(id: 1)))
    }

    func testRecoveryUsesOnlyTheKeychainBackendContract() {
        var backend = FakeKeychainBackend()

        _ = USBServerIdentityStore.loadOrCreate(using: &backend)

        XCTAssertEqual(backend.insecurePersistenceWrites, 0)
    }

    private func assertRegenerates(from state: FakeKeychainBackend.RecordState) {
        var backend = FakeKeychainBackend(state: state)

        let identity = USBServerIdentityStore.loadOrCreate(using: &backend)

        XCTAssertEqual(identity, FakeIdentity(id: 1))
        XCTAssertEqual(backend.state, .valid(FakeIdentity(id: 1)))
        XCTAssertEqual(backend.state.orphanRecordCount, 0)
    }
}

private struct FakeIdentity: Equatable {
    let id: Int
}

private struct FakeKeychainBackend: USBServerIdentityKeychainBackend {
    enum RecordState: Equatable {
        case empty
        case valid(FakeIdentity)
        case orphanKey
        case orphanCertificate
        case corruptCertificate

        var orphanRecordCount: Int {
            switch self {
            case .orphanKey, .orphanCertificate, .corruptCertificate:
                return 1
            case .empty, .valid:
                return 0
            }
        }
    }

    enum CreateResult {
        case success
        case insertionFailure
        case duplicateItem
    }

    var state: RecordState = .empty
    var plannedResults: [CreateResult] = []
    var nextIdentityID = 1
    var createCount = 0
    var deleteCount = 0
    var insecurePersistenceWrites = 0

    init(state: RecordState = .empty, plannedResults: [CreateResult] = []) {
        self.state = state
        self.plannedResults = plannedResults
    }

    mutating func loadIdentity() -> FakeIdentity? {
        guard case let .valid(identity) = state else { return nil }
        return identity
    }

    mutating func createIdentity() -> FakeIdentity? {
        createCount += 1
        let result = plannedResults.isEmpty ? .success : plannedResults.removeFirst()
        switch result {
        case .success:
            let identity = FakeIdentity(id: nextIdentityID)
            nextIdentityID += 1
            state = .valid(identity)
            return identity
        case .insertionFailure:
            state = .orphanKey
            return nil
        case .duplicateItem:
            state = .orphanCertificate
            return nil
        }
    }

    mutating func deleteIdentityRecords() {
        deleteCount += 1
        state = .empty
    }
}
