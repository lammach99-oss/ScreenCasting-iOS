import XCTest
@testable import iPadCasting

final class TransferCenterPresentationTests: XCTestCase {
    func testUnknownFailureNeverInventsStorageCauseOrRetry() {
        var state=DataTransferManager.Snapshot();state.phase = .failed
        XCTAssertFalse(TransferPresentation.failure(state).contains("storage"))
        XCTAssertEqual(TransferPresentation.nextAction(state), "Ask the PC to send again.")
        state.outgoing=true
        XCTAssertEqual(TransferPresentation.nextAction(state), "Choose files to start a new transfer.")
    }
    func testProgressBoundedIncludingEmptyAndHugeFiles() {
        var state=DataTransferManager.Snapshot()
        XCTAssertEqual(TransferPresentation.progress(state),0)
        state.phase = .completed;XCTAssertEqual(TransferPresentation.progress(state),1)
        state.total=1;state.bytes=UInt64.max;XCTAssertEqual(TransferPresentation.progress(state),1)
        XCTAssertFalse(TransferPresentation.size(UInt64.max).isEmpty)
    }
    func testTerminalStatesAreNotCancellable() {
        for phase: DataTransferManager.Phase in [.completed,.failed,.cancelled,.rejected,.retired,.idle] {
            XCTAssertFalse(TransferPresentation.active(phase))
        }
        XCTAssertTrue(TransferPresentation.active(.awaitingDecision))
    }
    func testFailureClassificationNeverExportsPrivateNSErrorText() {
        let error=NSError(domain:NSCocoaErrorDomain,code:CocoaError.fileWriteOutOfSpace.rawValue,userInfo:[NSFilePathErrorKey:"/private/user/secret.pdf"])
        let failure=DataTransferManager.FailureDetail.classify(error,stage:"admission")
        XCTAssertEqual(failure.reason,"STORAGE_FULL")
        XCTAssertFalse(String(describing:failure).contains("secret"))
        XCTAssertEqual(DataTransferManager.FailureDetail.classify(NSError(domain:"/private/secret",code:9),stage:"write").domain,"Transfer")
    }
}
