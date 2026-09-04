import CoreGraphics
import Foundation

struct InputGeometryDiagnosticContext: Equatable {
    let sessionGeneration: UInt64
    let frameSize: CGSize

    var orientation: String {
        if frameSize.width > frameSize.height { return "landscape" }
        if frameSize.height > frameSize.width { return "portrait" }
        return "unknown"
    }
}

struct InputGeometrySnapshot: Equatable {
    let event: TouchEventType
    let context: InputGeometryDiagnosticContext
    let touchPoint: CGPoint
    let touchBounds: CGRect
    let contentRect: CGRect
    let insideContent: Bool
    let normalizedPoint: CGPoint?
    let videoPixelX: CGFloat?
    let videoPixelY: CGFloat?
    let wireX: UInt16?
    let wireY: UInt16?

    static func make(
        event: TouchEventType,
        context: InputGeometryDiagnosticContext,
        touchPoint: CGPoint,
        touchBounds: CGRect,
        contentRect: CGRect,
        insideContent: Bool,
        normalizedPoint: CGPoint?,
        wireX: UInt16?,
        wireY: UInt16?
    ) -> InputGeometrySnapshot {
        InputGeometrySnapshot(
            event: event,
            context: context,
            touchPoint: touchPoint,
            touchBounds: touchBounds,
            contentRect: contentRect,
            insideContent: insideContent,
            normalizedPoint: normalizedPoint,
            videoPixelX: normalizedPoint.map { $0.x * context.frameSize.width },
            videoPixelY: normalizedPoint.map { $0.y * context.frameSize.height },
            wireX: wireX,
            wireY: wireY)
    }

    var logLine: String {
        [
            "[INPUT_GEOMETRY]",
            "event=\(event.diagnosticName)",
            "sessionGeneration=\(context.sessionGeneration)",
            "orientation=\(context.orientation)",
            "touchPointPointsX=\(Self.decimal(touchPoint.x))",
            "touchPointPointsY=\(Self.decimal(touchPoint.y))",
            "touchBoundsX=\(Self.decimal(touchBounds.minX))",
            "touchBoundsY=\(Self.decimal(touchBounds.minY))",
            "touchBoundsWidth=\(Self.decimal(touchBounds.width))",
            "touchBoundsHeight=\(Self.decimal(touchBounds.height))",
            "contentRectX=\(Self.decimal(contentRect.minX))",
            "contentRectY=\(Self.decimal(contentRect.minY))",
            "contentRectWidth=\(Self.decimal(contentRect.width))",
            "contentRectHeight=\(Self.decimal(contentRect.height))",
            "insideContent=\(insideContent ? "true" : "false")",
            "normalizedX=\(Self.decimal(normalizedPoint?.x))",
            "normalizedY=\(Self.decimal(normalizedPoint?.y))",
            "frameWidthPx=\(Self.decimal(context.frameSize.width))",
            "frameHeightPx=\(Self.decimal(context.frameSize.height))",
            "videoPixelX=\(Self.decimal(videoPixelX))",
            "videoPixelY=\(Self.decimal(videoPixelY))",
            "wireX=\(wireX.map { String($0) } ?? "unavailable")",
            "wireY=\(wireY.map { String($0) } ?? "unavailable")"
        ].joined(separator: " ")
    }

    private static func decimal(_ value: CGFloat?) -> String {
        guard let value else { return "unavailable" }
        return String(format: "%.4f", Double(value))
    }
}

struct InputGeometryDiagnosticSampler {
    static let moveInterval: TimeInterval = 0.125

    private var lastContext: InputGeometryDiagnosticContext?
    private var lastMoveTimestamp: TimeInterval?

    mutating func shouldLog(
        event: TouchEventType,
        timestamp: TimeInterval,
        context: InputGeometryDiagnosticContext
    ) -> Bool {
        let contextChanged = lastContext != context
        if contextChanged {
            lastContext = context
            lastMoveTimestamp = nil
        }
        if event != .move { return true }
        if contextChanged || lastMoveTimestamp == nil {
            lastMoveTimestamp = timestamp
            return true
        }
        guard let lastMoveTimestamp,
              timestamp - lastMoveTimestamp >= Self.moveInterval else {
            return false
        }
        self.lastMoveTimestamp = timestamp
        return true
    }
}

enum InputGeometryDiagnostics {
    static func log(_ snapshot: InputGeometrySnapshot) {
        print(snapshot.logLine)
    }
}

private extension TouchEventType {
    var diagnosticName: String {
        switch self {
        case .down: return "Down"
        case .move: return "Move"
        case .up: return "Up"
        case .force: return "Force"
        }
    }
}
