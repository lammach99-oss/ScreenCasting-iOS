import XCTest
@testable import iPadCasting

final class RealtimeNativeWrapperTests: XCTestCase {
    func testSrtpReceiverCreationFailureDestroysStagedHandles() {
        let spy = SrtpNativeSpy()
        spy.receiverResult = -1

        XCTAssertThrowsError(
            try SrtpSession(
                key: Data(repeating: 1, count: 16),
                salt: Data(repeating: 2, count: 12),
                ssrc: 0xcafebabe,
                native: spy.api))
        XCTAssertEqual(spy.destroyed, [2, 1])
    }

    func testSrtpRejectsEmptyAndUndersizedRtpAndRtcpBeforeNativeCall() throws {
        let spy = SrtpNativeSpy()
        do {
            let session = try SrtpSession(
                key: Data(repeating: 1, count: 16),
                salt: Data(repeating: 2, count: 12),
                ssrc: 0xcafebabe,
                native: spy.api)

            var empty = Data()
            XCTAssertThrowsError(try session.protectRtp(&empty, plaintextLength: 0))
            XCTAssertThrowsError(try session.unprotectRtp(&empty, protectedLength: 0))
            XCTAssertThrowsError(try session.protectRtcp(&empty, plaintextLength: 0))
            XCTAssertThrowsError(try session.unprotectRtcp(&empty, protectedLength: 0))

            var shortRtp = Data(count: 27)
            XCTAssertThrowsError(
                try session.protectRtp(&shortRtp, plaintextLength: 11))
            XCTAssertThrowsError(
                try session.unprotectRtp(&shortRtp, protectedLength: 27))

            var shortRtcp = Data(count: 27)
            XCTAssertThrowsError(
                try session.protectRtcp(&shortRtcp, plaintextLength: 7))
            XCTAssertThrowsError(
                try session.unprotectRtcp(&shortRtcp, protectedLength: 27))
        }

        XCTAssertEqual(spy.packetOperationCount, 0)
    }

    func testOpusCreationFailureDestroysReturnedHandle() {
        var destroyed: [Int] = []
        let api = OpusDecoderNativeAPI(
            create: { output in
                output.pointee = OpaquePointer(bitPattern: 3)
                return -1
            },
            decode: { _, _, _, _, _, _ in
                XCTFail("decode should not be called")
                return -1
            },
            destroy: { destroyed.append(Int(bitPattern: $0)) })

        XCTAssertThrowsError(try RealtimeOpusDecoder(native: api))
        XCTAssertEqual(destroyed, [3])
    }
}

private final class SrtpNativeSpy {
    var receiverResult: Int32 = 0
    var destroyed: [Int] = []
    var packetOperationCount = 0

    lazy var api = SrtpNativeAPI(
        createSender: { _, _, _, _, _, output in
            output.pointee = OpaquePointer(bitPattern: 1)
            return 0
        },
        createReceiver: { [unowned self] _, _, _, _, _, output in
            output.pointee = OpaquePointer(bitPattern: 2)
            return self.receiverResult
        },
        protectRtp: { [unowned self] _, _, _, _ in
            self.packetOperationCount += 1
            return 0
        },
        unprotectRtp: { [unowned self] _, _, _ in
            self.packetOperationCount += 1
            return 0
        },
        protectRtcp: { [unowned self] _, _, _, _ in
            self.packetOperationCount += 1
            return 0
        },
        unprotectRtcp: { [unowned self] _, _, _ in
            self.packetOperationCount += 1
            return 0
        },
        destroy: { [unowned self] handle in
            self.destroyed.append(Int(bitPattern: handle))
        })
}
