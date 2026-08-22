import XCTest
import CoreMedia
import CoreVideo
import Metal
@testable import iPadCasting

final class DecoderParameterSetTests: XCTestCase {
    func testHEVCDecodeOutputAttributesAllocateIOSurfaceBackedMetalCompatibleNV12() throws {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            32,
            18,
            DecoderOutputBufferAttributes.pixelFormat,
            DecoderOutputBufferAttributes.make() as CFDictionary,
            &pixelBuffer)

        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(buffer),
            DecoderOutputBufferAttributes.pixelFormat)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(buffer))
        XCTAssertNil(
            DecoderOutputBufferAttributes.invalidReason(
                for: buffer,
                expectedWidth: 32,
                expectedHeight: 18))

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this test runner")
        }
        var textureCache: CVMetalTextureCache?
        XCTAssertEqual(
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache),
            kCVReturnSuccess)
        let cache = try XCTUnwrap(textureCache)
        var yTexture: CVMetalTexture?
        XCTAssertEqual(
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, buffer, nil, .r8Unorm, 32, 18, 0, &yTexture),
            kCVReturnSuccess)
        XCTAssertNotNil(CVMetalTextureGetTexture(try XCTUnwrap(yTexture)))
        var uvTexture: CVMetalTexture?
        XCTAssertEqual(
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, buffer, nil, .rg8Unorm, 16, 9, 1, &uvTexture),
            kCVReturnSuccess)
        XCTAssertNotNil(CVMetalTextureGetTexture(try XCTUnwrap(uvTexture)))
    }

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
