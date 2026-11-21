import XCTest
import CoreMedia
import CoreVideo
@testable import iPadCasting

final class DecoderParameterSetTests: XCTestCase {
    #if targetEnvironment(simulator)
    func testFailedHEVCReplacementRejectsAccessUnitAndRetriesOnIDR() throws {
        let decoder = DecoderManager()
        defer { decoder.invalidate() }
        let generation = decoder.currentSessionGeneration
        decoder.setMailboxClockForTesting(to: 100)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        var attempts: [UInt8] = []
        var submitted: [UInt32] = []
        let recovery = expectation(description: "rejecting a format requests an IDR")
        decoder.onRecoveryNeeded = { recovery.fulfill() }
        decoder.replaceHEVCFormatForTesting = { _, _, pps in
            let value = pps.last ?? 0
            attempts.append(value)
            return value == 0x10 || attempts.count == 3
        }
        decoder.submitDecodeForTesting = { sequence in
            submitted.append(sequence)
            return pixel
        }
        func receive(_ sequence: UInt32, pps: UInt8?, idr: Bool = true) {
            var bytes: [UInt8] = []
            if let pps {
                bytes = [0, 0, 1, 0x40, 1, 0x11, 0, 0, 1, 0x42, 1, 0x12,
                         0, 0, 1, 0x44, 1, pps]
            }
            bytes += [0, 0, 1, idr ? 0x26 : 0x02, 1, 0x80]
            decoder.processInputData(Data(bytes), sequence: sequence, isIDR: idr, receivedAt: 100)
            decoder.sessionQueueForTesting.sync {}
        }
        receive(1, pps: 0x10)
        receive(2, pps: 0x20)
        receive(3, pps: nil, idr: false)
        receive(4, pps: 0x20)
        receive(5, pps: nil, idr: false)
        wait(for: [recovery], timeout: 1)
        XCTAssertEqual(attempts, [0x10, 0x20, 0x20])
        XCTAssertEqual(submitted, [1, 4, 5])
        XCTAssertEqual(decoder.currentSessionGeneration, generation)
    }
    #endif

    func testIdenticalParameterSetsCreateOneDecoderSession() {
        let vps = Data([0x40, 0x01])
        let sps = Data([0x42, 0x01, 0x0a])
        let pps = Data([0x44, 0x01, 0x80])
        var gate = HevcParameterSetSessionGate()
        let factory = DecoderSessionFactorySpy()

        XCTAssertTrue(gate.replaceIfChanged(vps: vps, sps: sps, pps: pps) {
            factory.create()
        })
        XCTAssertFalse(gate.replaceIfChanged(vps: vps, sps: sps, pps: pps) {
            factory.create()
        })

        XCTAssertEqual(factory.createCount, 1)
        XCTAssertEqual(
            HevcParameterSetSignature(vps: vps, sps: sps, pps: pps),
            HevcParameterSetSignature(vps: vps, sps: sps, pps: pps))
    }

    func testChangedPPSCreatesExactlyOneAdditionalDecoderSession() {
        let vps = Data([0x40, 0x01])
        let sps = Data([0x42, 0x01, 0x0a])
        var gate = HevcParameterSetSessionGate()
        let factory = DecoderSessionFactorySpy()

        XCTAssertTrue(gate.replaceIfChanged(
            vps: vps, sps: sps, pps: Data([0x44, 0x01, 0x80])) {
            factory.create()
        })
        XCTAssertTrue(gate.replaceIfChanged(
            vps: vps, sps: sps, pps: Data([0x44, 0x01, 0x81])) {
            factory.create()
        })
        XCTAssertFalse(gate.replaceIfChanged(
            vps: vps, sps: sps, pps: Data([0x44, 0x01, 0x81])) {
            factory.create()
        })

        XCTAssertEqual(factory.createCount, 2)
    }

    func testFactoryFailureIsRetryableAndOldSetReversionRecreates() {
        let vps = Data([0x40, 0x01])
        let sps = Data([0x42, 0x01, 0x0a])
        let ppsA = Data([0x44, 0x01, 0x80])
        let ppsB = Data([0x44, 0x01, 0x81])
        var gate = HevcParameterSetSessionGate()
        let factory = DecoderSessionFactorySpy()

        XCTAssertTrue(gate.replaceIfChanged(vps: vps, sps: sps, pps: ppsA) {
            factory.create()
        })
        XCTAssertFalse(gate.replaceIfChanged(vps: vps, sps: sps, pps: ppsB) {
            factory.create(succeeds: false)
        })
        XCTAssertEqual(
            gate.activeParameterSetSignature,
            HevcParameterSetSignature(vps: vps, sps: sps, pps: ppsA))
        XCTAssertTrue(gate.replaceIfChanged(vps: vps, sps: sps, pps: ppsB) {
            factory.create()
        })
        XCTAssertTrue(gate.replaceIfChanged(vps: vps, sps: sps, pps: ppsA) {
            factory.create()
        })
        XCTAssertFalse(gate.replaceIfChanged(vps: vps, sps: sps, pps: ppsA) {
            factory.create()
        })

        XCTAssertEqual(factory.createCount, 4)
    }

    func testAccessUnitInitializerDefaultsToAnnexB() {
        let unit = AccessUnit(
            owner: AccessUnitOwner(data: Data([1, 2])),
            sequence: 1,
            sessionGeneration: 1,
            isIDR: true,
            receivedAt: 0)
        XCTAssertFalse(unit.isLengthPrefixed)
    }

    func testRetainedCanonicalBlockOwnsStableBytesUntilCoreMediaFree() {
        let canonical = Data([
            0, 0, 0, 2, 0x40, 1,
            0, 0, 0, 3, 0x26, 2, 3
        ])
        var releases = 0
        var blockBuffer: CMBlockBuffer?
        weak var weakStorage: RetainedDataBlockStorage?

        autoreleasepool {
            let owner = AccessUnitOwner(data: canonical) { releases += 1 }
            let lifetime = DecodeSubmissionLifetime(
                owner: owner,
                sequence: 7,
                decodeStartedAt: 0)
            var storage: RetainedDataBlockStorage? = RetainedDataBlockStorage(
                lifetime: lifetime,
                offset: 6)
            weakStorage = storage
            blockBuffer = storage?.makeBlockBuffer()
            storage = nil

            XCTAssertNotNil(blockBuffer)
            XCTAssertNotNil(weakStorage)
            lifetime.finish()
            XCTAssertEqual(releases, 1)

            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            XCTAssertEqual(
                CMBlockBufferGetDataPointer(
                    blockBuffer!,
                    atOffset: 0,
                    lengthAtOffsetOut: &lengthAtOffset,
                    totalLengthOut: &totalLength,
                    dataPointerOut: &dataPointer),
                noErr)
            XCTAssertEqual(totalLength, canonical.count - 6)
            XCTAssertEqual(
                Array(UnsafeRawBufferPointer(
                    start: dataPointer,
                    count: totalLength)),
                Array(canonical.dropFirst(6)))
        }

        XCTAssertNotNil(weakStorage)
        blockBuffer = nil
        XCTAssertNil(weakStorage)
        XCTAssertEqual(releases, 1)
    }

    func testCanonicalAccessUnitKeepsFrameBytesInRetainedDataRange() throws {
        let canonical = Data([
            0, 0, 0, 2, 0x40, 1,
            0, 0, 0, 3, 0x26, 2, 3
        ])
        let ranges = try XCTUnwrap(LengthPrefixedNALScanner.ranges(in: canonical))
        XCTAssertEqual(ranges, [4..<6, 10..<13])
        XCTAssertEqual(
            HevcCanonicalAccessUnit.frameRange(
                in: canonical,
                nalRanges: ranges),
            6..<13)
    }
}

private final class DecoderSessionFactorySpy {
    private(set) var createCount = 0

    func create(succeeds: Bool = true) -> Bool {
        createCount += 1
        return succeeds
    }
}
