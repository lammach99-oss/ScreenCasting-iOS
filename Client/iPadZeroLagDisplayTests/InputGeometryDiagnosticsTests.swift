import CoreGraphics
import XCTest
@testable import iPadCasting

final class InputGeometryDiagnosticsTests: XCTestCase {
    @MainActor func testHostCompositedCursorPixelMovesWithZoomedPannedVideo() throws {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let surface = ConnectedPresentationContainer(frame: bounds, pencilInteractionsEnabled: false)
        let controls = LocalViewportControls()
        surface.configureLocalViewport(controls)
        surface.layoutIfNeeded()
        surface.setBaseViewport(VideoContentViewport.aspectFit(containerSize: bounds.size,
                                                               videoSize: CGSize(width: 400, height: 200)))
        // The host cursor at video pixel (240, 80) has a 50-point top margin at Fit.
        surface.adjustViewport(by: 2, translation: CGPoint(x: -30, y: 12))
        let cursor = surface.metalView.convert(CGPoint(x: 240, y: 130), to: surface.touchView)
        XCTAssertEqual(cursor.x, 250, accuracy: 0.001)
        XCTAssertEqual(cursor.y, 122, accuracy: 0.001)
        let mapped = try XCTUnwrap(surface.touchView.contentViewport?.normalizedPoint(for: cursor, in: bounds))
        XCTAssertEqual(mapped.x, 0.6, accuracy: 0.001)
        XCTAssertEqual(mapped.y, 0.4, accuracy: 0.001)
    }

    @MainActor func testPhoneVideoAndInputUseSameTransformAfterResize() throws {
        let surface = ConnectedPresentationContainer(frame: .zero, pencilInteractionsEnabled: false)
        let controls = LocalViewportControls()
        surface.configureLocalViewport(controls)
        for size in [CGSize(width: 320, height: 700), CGSize(width: 700, height: 320)] {
            surface.bounds = CGRect(origin: .zero, size: size)
            surface.layoutIfNeeded()
            XCTAssertNil(surface.touchView.contentViewport)
            let fit = try XCTUnwrap(VideoContentViewport.aspectFit(containerSize: size,
                videoSize: CGSize(width: 1920, height: 1080)))
            surface.setBaseViewport(fit)
            controls.fit()
            let rect = fit.contentRect(in: surface.bounds)
            for factor in [CGFloat(1), 1.5, 2] {
                surface.adjustViewport(by: factor, translation: CGPoint(x: 12, y: -10))
                let source = CGPoint(x: rect.midX + rect.width * 0.05, y: rect.midY)
                let shown = surface.metalView.convert(source, to: surface.touchView)
                let mapped = try XCTUnwrap(surface.touchView.contentViewport?.normalizedPoint(
                    for: shown, in: surface.touchView.bounds))
                XCTAssertEqual(mapped.x, 0.55, accuracy: 0.00001)
                XCTAssertEqual(mapped.y, 0.5, accuracy: 0.00001)
            }
            controls.fit()
            XCTAssertFalse(surface.touchView.point(inside: .zero, with: nil))
        }
    }

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
