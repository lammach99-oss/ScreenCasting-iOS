import SwiftUI
import UIKit

// MARK: - PencilTouchView

/// SwiftUI wrapper for high-frequency (240Hz) Apple Pencil & pressure touch ingestion.
///
/// ## Two output paths (both fire simultaneously):
/// - `onPencilInput`:      Delivers the rich `PencilPacket` (legacy — backward-compat)
/// - `onSendTouchEvent`:   Delivers the typed arguments for `NetworkManager.sendTouchEvent`
///                         matching the 8-byte wire format the C# host expects.
/// - `onNetworkSend`:      Legacy raw-bytes callback (now emits the 8-byte packet, NOT
///                         the old PencilPacket struct) to avoid breaking existing callers.
public struct PencilTouchView: UIViewRepresentable {

    // MARK: Callbacks

    /// Called with the full `PencilPacket` for local rendering / tilt visualisation.
    public var onPencilInput: ((PencilPacket) -> Void)?

    /// Preferred callback — delivers typed arguments directly to `NetworkManager`.
    /// ```swift
    /// PencilTouchView { type, x, y, pressure in
    ///     networkManager.sendTouchEvent(type: type, x: x, y: y, pressure: pressure)
    /// }
    /// ```
    public var onSendTouchEvent: ((TouchEventType, UInt16, UInt16, UInt8) -> Void)?

    /// Legacy raw-bytes callback. Now emits the 8-byte TouchInputPacket wire format.
    /// Kept for backward compatibility with code that passes bytes directly to `sendData`.
    public var onNetworkSend: ((Data) -> Void)?

    /// Normalized aspect-fit rectangle occupied by the remote video in this view.
    /// The Metal renderer is the source of truth for this displayed geometry.
    public var contentViewport: VideoContentViewport?
    var onBoundsChanged: ((CGRect) -> Void)?

    // MARK: Init

    public init(
        onPencilInput:    ((PencilPacket) -> Void)?                        = nil,
        onSendTouchEvent: ((TouchEventType, UInt16, UInt16, UInt8) -> Void)? = nil,
        onNetworkSend:    ((Data) -> Void)?                                = nil,
        contentViewport:  VideoContentViewport?                             = nil,
        onBoundsChanged:  ((CGRect) -> Void)?                               = nil
    ) {
        self.onPencilInput    = onPencilInput
        self.onSendTouchEvent = onSendTouchEvent
        self.onNetworkSend    = onNetworkSend
        self.contentViewport  = contentViewport
        self.onBoundsChanged  = onBoundsChanged
    }

    public func makeUIView(context: Context) -> PencilUIKitView {
        let view = PencilUIKitView()
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        updateUIView(view, context: context)
        return view
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: PencilUIKitView,
        context: Context
    ) -> CGSize? {
        FullscreenSurfaceLayout.exactSize(
            width: proposal.width,
            height: proposal.height)
    }

    public func updateUIView(_ uiView: PencilUIKitView, context: Context) {
        uiView.onPencilInput    = onPencilInput
        uiView.onSendTouchEvent = onSendTouchEvent
        uiView.onNetworkSend    = onNetworkSend
        uiView.contentViewport  = contentViewport
        uiView.onBoundsChanged  = onBoundsChanged
    }
}

// MARK: - PencilPacket (legacy, for onPencilInput)

public struct PencilPacket {
    public var magic: UInt32 = 0x50454E43 // "PENC"
    public var xRatio: Float
    public var yRatio: Float
    public var pressure: Float
    public var tiltX: UInt16
    public var tiltY: UInt16
    public var pointerFlags: UInt8 // 1=TouchDown, 2=Move, 4=TouchUp, 8=IsEraser
}

// MARK: - Touch Event Type flag mapping

/// Maps PencilUIKitView's UIKit touch flags to the wire-protocol `TouchEventType`.
private func touchEventType(for flags: UInt8) -> TouchEventType {
    switch flags {
    case 1: return .down
    case 4: return .up
    default: return .move   // flags == 2 (move) and anything else
    }
}

// MARK: - Touch Wire Format constants (mirrors NetworkManager.swift)

private let kTouchMagic: UInt16 = 0x5449
private let kTouchPacketSize    = 8

// MARK: - PencilUIKitView

public class PencilUIKitView: UIView {

    // MARK: Callbacks (set by PencilTouchView.updateUIView)
    public var onPencilInput:    ((PencilPacket) -> Void)?
    public var onSendTouchEvent: ((TouchEventType, UInt16, UInt16, UInt8) -> Void)?
    public var onNetworkSend:    ((Data) -> Void)?
    public var contentViewport: VideoContentViewport?
    var inputGeometryContext: InputGeometryDiagnosticContext?
    var diagnosticSink: ((String) -> Void)?
    public var onBoundsChanged: ((CGRect) -> Void)?

    private var activeTouchIdentifier: ObjectIdentifier?
    private var lastNormalizedPoint: CGPoint?
    private var lastReportedBounds: CGRect?
    private var lastCorrelationLogUptime: TimeInterval = 0
    private var moveCorrelationLogged = false
    private var inputGeometrySampler = InputGeometryDiagnosticSampler()

    override public init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        guard bounds != lastReportedBounds else { return }
        lastReportedBounds = bounds
        onBoundsChanged?(bounds)
    }

    // MARK: - UIKit touch overrides (pass event for coalesced touch access)

    override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        handleTouches(touches, flags: 1, event: event)
    }

    override public func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        handleTouches(touches, flags: 2, event: event)
    }

    override public func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        handleTouches(touches, flags: 4, event: event)
    }

    override public func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        handleTouches(touches, flags: 4, event: event)
    }

    // MARK: - Core packet builder

    private func handleTouches(_ touches: Set<UITouch>, flags: UInt8, event: UIEvent?) {
        guard let primaryTouch = touches.first else { return }

        // Consume all 240Hz coalesced samples — every intermediate Pencil position.
        let allTouches = flags == 4
            ? [primaryTouch]
            : event?.coalescedTouches(for: primaryTouch) ?? [primaryTouch]

        let bounds = self.bounds
        guard
            bounds.width > 0,
            bounds.height > 0,
            let contentViewport
        else {
            if flags == 4 {
                activeTouchIdentifier = nil
                lastNormalizedPoint = nil
            }
            return
        }

        let touchIdentifier = ObjectIdentifier(primaryTouch)
        let primaryLocation = primaryTouch.location(in: self)
        let primaryMappedPoint = contentViewport.normalizedPoint(
            for: primaryLocation,
            in: bounds)
        if flags == 1 {
            guard activeTouchIdentifier == nil, primaryMappedPoint != nil else {
                logRejectedTouchIfNeeded(
                    event: touchEventType(for: flags),
                    location: primaryLocation,
                    bounds: bounds,
                    contentViewport: contentViewport,
                    insideContent: primaryMappedPoint != nil,
                    timestamp: primaryTouch.timestamp)
                return
            }
            activeTouchIdentifier = touchIdentifier
        } else {
            guard activeTouchIdentifier == touchIdentifier else { return }
        }

        for touch in allTouches {
            let location = touch.location(in: self)
            let mappedNormalizedPoint = contentViewport.normalizedPoint(
                for: location,
                in: bounds)
            let normalizedPoint = mappedNormalizedPoint ??
                (flags == 4 ? lastNormalizedPoint : nil)
            guard let normalizedPoint else {
                logRejectedTouchIfNeeded(
                    event: touchEventType(for: flags),
                    location: location,
                    bounds: bounds,
                    contentViewport: contentViewport,
                    insideContent: false,
                    timestamp: touch.timestamp)
                continue
            }
            lastNormalizedPoint = normalizedPoint

            // ── Normalised ratios (0.0 – 1.0) ───────────────────────────────
            let xRatio = Float(normalizedPoint.x).clamped(0, 1)
            let yRatio = Float(normalizedPoint.y).clamped(0, 1)

            // ── Pressure ─────────────────────────────────────────────────────
            let pressureFloat: Float = touch.maximumPossibleForce > 0
                ? Float(touch.force / touch.maximumPossibleForce).clamped(0, 1)
                : 1.0

            // ── Tilt (for the legacy PencilPacket) ───────────────────────────
            let altitude = touch.altitudeAngle
            let azimuth  = touch.azimuthAngle(in: self)
            let tiltX = UInt16(clamping: Int(abs(cos(azimuth) * cos(altitude) * (180.0 / .pi))))
            let tiltY = UInt16(clamping: Int(abs(sin(azimuth) * cos(altitude) * (180.0 / .pi))))

            // ── Map to wire-format integers ───────────────────────────────────
            // UInt16 space (0 – 65535) is resolution-independent; the C# host
            // divides by 65535 and multiplies by its virtual screen resolution.
            let wireX        = UInt16(clamping: Int((xRatio       * 65535).rounded()))
            let wireY        = UInt16(clamping: Int((yRatio        * 65535).rounded()))
            let wirePressure = UInt8 (clamping: Int((pressureFloat * 255  ).rounded()))
            let wireType     = touchEventType(for: flags)

            if let inputGeometryContext {
                let snapshot = InputGeometrySnapshot.make(
                    event: wireType,
                    context: inputGeometryContext,
                    touchPoint: location,
                    touchBounds: bounds,
                    contentRect: contentViewport.contentRect(in: bounds),
                    insideContent: mappedNormalizedPoint != nil,
                    normalizedPoint: normalizedPoint,
                    wireX: wireX,
                    wireY: wireY)
                if inputGeometrySampler.shouldLog(
                    event: wireType,
                    timestamp: touch.timestamp,
                    context: inputGeometryContext) {
                    InputGeometryDiagnostics.log(
                        snapshot,
                        collectibleSink: diagnosticSink)
                }
            }

            let now = ProcessInfo.processInfo.systemUptime
            let sampleCorrelation = flags != 2 ||
                !moveCorrelationLogged ||
                now - lastCorrelationLogUptime >= 0.35
            if sampleCorrelation {
                print("[IPAD][TOUCH_CORRELATION] event=\(wireType) " +
                    "touchLocal=(\(String(format: "%.2f", location.x)),\(String(format: "%.2f", location.y))) " +
                    "touchBounds=(\(String(format: "%.2f", bounds.width)),\(String(format: "%.2f", bounds.height))) " +
                    "viewport=(\(String(format: "%.4f", contentViewport.rect.minX)),\(String(format: "%.4f", contentViewport.rect.minY)),\(String(format: "%.4f", contentViewport.rect.width)),\(String(format: "%.4f", contentViewport.rect.height))) " +
                    "normalized=(\(String(format: "%.5f", xRatio)),\(String(format: "%.5f", yRatio))) wire=(\(wireX),\(wireY))")
                lastCorrelationLogUptime = now
                moveCorrelationLogged = flags == 2
            }

            // ── Emit: typed callback (primary path) ───────────────────────────
            onSendTouchEvent?(wireType, wireX, wireY, wirePressure)

            // ── Emit: legacy raw-bytes callback ───────────────────────────────
            // Now serialises the 8-byte TouchInputPacket instead of PencilPacket.
            if onNetworkSend != nil {
                var packet = Data(count: kTouchPacketSize)
                packet.withUnsafeMutableBytes { buf in
                    buf.storeBytes(of: kTouchMagic.littleEndian,   toByteOffset: 0, as: UInt16.self)
                    buf.storeBytes(of: wireType.rawValue,           toByteOffset: 2, as: UInt8.self)
                    buf.storeBytes(of: wirePressure,                toByteOffset: 3, as: UInt8.self)
                    buf.storeBytes(of: wireX.littleEndian,          toByteOffset: 4, as: UInt16.self)
                    buf.storeBytes(of: wireY.littleEndian,          toByteOffset: 6, as: UInt16.self)
                }
                onNetworkSend?(packet)
            }

            // ── Emit: legacy PencilPacket (for local tilt / rendering) ────────
            var pencilPacket = PencilPacket(
                xRatio:       xRatio,
                yRatio:       yRatio,
                pressure:     pressureFloat,
                tiltX:        tiltX,
                tiltY:        tiltY,
                pointerFlags: flags
            )
            onPencilInput?(pencilPacket)
        }

        if flags == 4 {
            moveCorrelationLogged = false
            activeTouchIdentifier = nil
            lastNormalizedPoint = nil
        }
    }

    private func logRejectedTouchIfNeeded(
        event: TouchEventType,
        location: CGPoint,
        bounds: CGRect,
        contentViewport: VideoContentViewport,
        insideContent: Bool,
        timestamp: TimeInterval
    ) {
        guard let inputGeometryContext,
              inputGeometrySampler.shouldLog(
                event: event,
                timestamp: timestamp,
                context: inputGeometryContext) else {
            return
        }
        InputGeometryDiagnostics.log(
            InputGeometrySnapshot.make(
                event: event,
                context: inputGeometryContext,
                touchPoint: location,
                touchBounds: bounds,
                contentRect: contentViewport.contentRect(in: bounds),
                insideContent: insideContent,
                normalizedPoint: nil,
                wireX: nil,
                wireY: nil),
            collectibleSink: diagnosticSink)
    }
}

// MARK: - Private Float helper

private extension Float {
    func clamped(_ lo: Float, _ hi: Float) -> Float {
        Swift.min(Swift.max(self, lo), hi)
    }
}
