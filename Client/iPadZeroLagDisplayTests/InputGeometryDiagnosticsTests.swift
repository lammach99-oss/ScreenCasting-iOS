import CoreGraphics
import XCTest
@testable import iPadCasting

final class InputGeometryDiagnosticsTests: XCTestCase {
    func testLandscapeCenterReportsNativeVideoCenterAndPreservesWire() throws {
        let snapshot = makeSnapshot(
            frameSize: CGSize(width: 2388, height: 1668),
            normalizedPoint: CGPoint(x: 0.5, y: 0.5),
            wireX: 32768,
            wireY: 32768)

        XCTAssertEqual(snapshot.context.orientation, "landscape")
        XCTAssertEqual(try XCTUnwrap(snapshot.normalizedPoint).x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.normalizedPoint).y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.videoPixelX), 1194, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.videoPixelY), 834, accuracy: 0.0001)
        XCTAssertEqual(snapshot.wireX, 32768)
        XCTAssertEqual(snapshot.wireY, 32768)
    }

    func testPortraitCenterReportsNativeVideoCenterAndPreservesWire() throws {
        let snapshot = makeSnapshot(
            frameSize: CGSize(width: 1668, height: 2388),
            normalizedPoint: CGPoint(x: 0.5, y: 0.5),
            wireX: 32768,
            wireY: 32768)

        XCTAssertEqual(snapshot.context.orientation, "portrait")
        XCTAssertEqual(try XCTUnwrap(snapshot.normalizedPoint).x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.normalizedPoint).y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.videoPixelX), 834, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(snapshot.videoPixelY), 1194, accuracy: 0.0001)
        XCTAssertEqual(snapshot.wireX, 32768)
        XCTAssertEqual(snapshot.wireY, 32768)
    }

    func testPortraitPointUsesContentRectRelativeNormalization() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let viewport = try XCTUnwrap(VideoContentViewport.aspectFit(
            containerSize: bounds.size,
            videoSize: CGSize(width: 1668, height: 2388)))
        let contentRect = viewport.contentRect(in: bounds)
        let point = CGPoint(x: contentRect.midX, y: contentRect.minY + contentRect.height * 0.25)
        let normalized = try XCTUnwrap(viewport.normalizedPoint(for: point, in: bounds))

        XCTAssertEqual(normalized.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(normalized.y, 0.25, accuracy: 0.0001)
    }

    func testOutsideContentIsObservedWithoutInventingMappedValues() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let viewport = try XCTUnwrap(VideoContentViewport.aspectFit(
            containerSize: bounds.size,
            videoSize: CGSize(width: 1668, height: 2388)))
        let point = CGPoint(x: 0, y: bounds.midY)
        XCTAssertNil(viewport.normalizedPoint(for: point, in: bounds))

        let snapshot = InputGeometrySnapshot.make(
            event: .down,
            context: InputGeometryDiagnosticContext(
                sessionGeneration: 4,
                frameSize: CGSize(width: 1668, height: 2388)),
            touchPoint: point,
            touchBounds: bounds,
            contentRect: viewport.contentRect(in: bounds),
            insideContent: false,
            normalizedPoint: nil,
            wireX: nil,
            wireY: nil)

        XCTAssertFalse(snapshot.insideContent)
        XCTAssertNil(snapshot.normalizedPoint)
        XCTAssertNil(snapshot.videoPixelX)
        XCTAssertNil(snapshot.videoPixelY)
        XCTAssertNil(snapshot.wireX)
        XCTAssertNil(snapshot.wireY)
    }

    func testMoveDiagnosticsAreSampledWithoutChangingEventRate() {
        let context = InputGeometryDiagnosticContext(
            sessionGeneration: 8,
            frameSize: CGSize(width: 2388, height: 1668))
        var sampler = InputGeometryDiagnosticSampler()
        var sentEvents = 0
        var diagnosticEvents = 0

        for sample in 0..<20 {
            sentEvents += 1
            if sampler.shouldLog(
                event: .move,
                timestamp: Double(sample) * 0.01,
                context: context) {
                diagnosticEvents += 1
            }
        }

        XCTAssertEqual(sentEvents, 20)
        XCTAssertEqual(diagnosticEvents, 2)
        XCTAssertTrue(sampler.shouldLog(event: .down, timestamp: 0.20, context: context))
        XCTAssertTrue(sampler.shouldLog(event: .up, timestamp: 0.21, context: context))

        let reconnected = InputGeometryDiagnosticContext(
            sessionGeneration: 9,
            frameSize: context.frameSize)
        XCTAssertTrue(sampler.shouldLog(
            event: .move, timestamp: 0.22, context: reconnected))
        let portrait = InputGeometryDiagnosticContext(
            sessionGeneration: 9,
            frameSize: CGSize(width: 1668, height: 2388))
        XCTAssertTrue(sampler.shouldLog(
            event: .move, timestamp: 0.23, context: portrait))
    }

    func testSnapshotPreservesAuthoritativeWireCoordinates() {
        let snapshot = makeSnapshot(
            frameSize: CGSize(width: 2388, height: 1668),
            normalizedPoint: CGPoint(x: 0.125, y: 0.875),
            wireX: 8192,
            wireY: 57343)

        XCTAssertEqual(snapshot.wireX, 8192)
        XCTAssertEqual(snapshot.wireY, 57343)
    }

    private func makeSnapshot(
        frameSize: CGSize,
        normalizedPoint: CGPoint,
        wireX: UInt16,
        wireY: UInt16
    ) -> InputGeometrySnapshot {
        let bounds = CGRect(origin: .zero, size: frameSize)
        return InputGeometrySnapshot.make(
            event: .move,
            context: InputGeometryDiagnosticContext(
                sessionGeneration: 3,
                frameSize: frameSize),
            touchPoint: CGPoint(
                x: normalizedPoint.x * bounds.width,
                y: normalizedPoint.y * bounds.height),
            touchBounds: bounds,
            contentRect: bounds,
            insideContent: true,
            normalizedPoint: normalizedPoint,
            wireX: wireX,
            wireY: wireY)
    }
}
