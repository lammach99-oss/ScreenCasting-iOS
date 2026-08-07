import SwiftUI
import UIKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Pattern A: PencilTouchView (UIViewRepresentable — Recommended)
// ─────────────────────────────────────────────────────────────────────────────
//
// Use this pattern when you need:
//   • Apple Pencil Pro (240Hz coalesced samples)
//   • Pressure sensitivity (UITouch.force)
//   • Tilt / altitude angles
//   • Precise finger vs. Pencil disambiguation
//
// The `onSendTouchEvent` closure receives pre-mapped UInt16 coordinates directly
// from the UIKit layer — zero extra math needed at the SwiftUI call site.

struct StreamingOverlay_PencilVariant: View {
    @ObservedObject var networkManager: NetworkManager

    var body: some View {
        PencilTouchView(
            // ── Optional: local tilt / barrel-roll rendering ──────────────
            onPencilInput: { packet in
                // Use PencilPacket.tiltX / tiltY / pressure for a local cursor overlay.
                // This fires on main thread alongside onSendTouchEvent.
            },
            // ── Preferred: typed callback ─────────────────────────────────
            onSendTouchEvent: { [weak networkManager] type, x, y, pressure in
                // Called at up to 240Hz on the UIKit main-thread coalesced loop.
                // sendTouchEvent is non-blocking and thread-safe — call directly.
                networkManager?.sendTouchEvent(type: type, x: x, y: y, pressure: pressure)
            }
        )
        .ignoresSafeArea()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Pattern B: SwiftUI DragGesture (finger / mouse pointer)
// ─────────────────────────────────────────────────────────────────────────────
//
// Use this pattern when:
//   • Apple Pencil is NOT required (finger gestures only)
//   • You only have SwiftUI-level view coordinates
//   • You need quick prototyping without a UIViewRepresentable wrapper
//
// SwiftUI gives you CGPoint in view-local points. We normalise to [0.0, 1.0]
// via GeometryReader, then map to the 0–65535 UInt16 space in sendTouchEventNormalized.

struct StreamingOverlay_DragGestureVariant: View {
    @ObservedObject var networkManager: NetworkManager

    var body: some View {
        GeometryReader { geometry in
            Color.clear   // invisible hit-test surface; sits above MetalVideoView
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            let size = geometry.size
                            guard size.width > 0, size.height > 0 else { return }

                            // ── Normalise to [0.0, 1.0] ───────────────────
                            let normX = Float(value.location.x / size.width)
                            let normY = Float(value.location.y / size.height)

                            // DragGesture fires .changed for the first point too,
                            // so check startLocation to distinguish Down vs Move.
                            let isFirstSample = (value.location == value.startLocation)
                            let eventType: TouchEventType = isFirstSample ? .down : .move

                            // ── Send ──────────────────────────────────────
                            // sendTouchEventNormalized clamps and maps internally.
                            networkManager.sendTouchEventNormalized(
                                type:       eventType,
                                normX:      normX,
                                normY:      normY,
                                pressure01: 1.0      // DragGesture has no pressure API
                            )
                        }
                        .onEnded { value in
                            let size = geometry.size
                            guard size.width > 0, size.height > 0 else { return }

                            let normX = Float(value.location.x / size.width)
                            let normY = Float(value.location.y / size.height)

                            networkManager.sendTouchEventNormalized(
                                type:       .up,
                                normX:      normX,
                                normY:      normY,
                                pressure01: 0.0
                            )
                        }
                )
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Coordinate Space Diagram
// ─────────────────────────────────────────────────────────────────────────────
//
// iPad Screen (2732 × 2048 pt @2×)                  Wire Packet (UInt16)
// ┌───────────────────────────────┐                  ┌───────────┬───────────┐
// │(0,0)          (2732,0)        │                  │ X = 0     │ X = 65535 │
// │                               │    normalise      │           │           │
// │     touch @ (x, y) pt         │ ─────────────►   │     X = (x/width)×65535    │
// │                               │                  │     Y = (y/height)×65535   │
// │(0,2048)       (2732,2048)     │                  │ Y = 0     │ Y = 65535 │
// └───────────────────────────────┘                  └───────────┴───────────┘
//
// On the C# host side, NetworkManager fires OnTouchInputReceived(TouchInputPacket).
// The subscriber maps back:
//   actualX = packet.X * virtualScreenWidth  / 65535
//   actualY = packet.Y * virtualScreenHeight / 65535

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Recommended Composition in ContentView
// ─────────────────────────────────────────────────────────────────────────────

struct RecommendedContentViewComposition: View {
    @StateObject var networkManager = NetworkManager()

    var body: some View {
        ZStack {
            // Layer 1 — video
            MetalVideoView(networkManager: networkManager)
                .ignoresSafeArea()

            // Layer 2 — touch overlay (Pattern A for Pencil, Pattern B for finger)
            // Choose ONE of the following:
            StreamingOverlay_PencilVariant(networkManager: networkManager)
            // – OR –
            // StreamingOverlay_DragGestureVariant(networkManager: networkManager)
        }
    }
}
