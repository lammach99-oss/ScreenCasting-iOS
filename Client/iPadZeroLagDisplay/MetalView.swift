import SwiftUI
import MetalKit
import UIKit

/// Resolves the size that both UIKit presentation surfaces receive from their
/// shared SwiftUI container. An incomplete proposal must stay incomplete: the
/// old 10-point fallback from `replacingUnspecifiedDimensions()` could shrink a
/// representable before the fullscreen container finished its layout.
enum FullscreenSurfaceLayout {
    static func exactSize(width: CGFloat?, height: CGFloat?) -> CGSize? {
        guard let width, let height, width >= 0, height >= 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}

public struct MetalView: UIViewRepresentable {
    @ObservedObject var networkManager: NetworkManager
    public var onFrameRendered: (() -> Void)?
    public var onContentViewportChanged: ((VideoContentViewport?) -> Void)?
    var onGeometrySnapshotChanged: ((RendererGeometrySnapshot) -> Void)?

    public init(
        networkManager: NetworkManager,
        onFrameRendered: (() -> Void)? = nil,
        onContentViewportChanged: ((VideoContentViewport?) -> Void)? = nil,
        onGeometrySnapshotChanged: ((RendererGeometrySnapshot) -> Void)? = nil
    ) {
        self.networkManager = networkManager
        self.onFrameRendered = onFrameRendered
        self.onContentViewportChanged = onContentViewportChanged
        self.onGeometrySnapshotChanged = onGeometrySnapshotChanged
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            onFrameRendered: onFrameRendered,
            onContentViewportChanged: onContentViewportChanged,
            onGeometrySnapshotChanged: onGeometrySnapshotChanged)
    }

    public func makeUIView(context: Context) -> MTKView {
        let metalView = MTKView()
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        if let renderer = Renderer(metalView: metalView) {
            context.coordinator.renderer = renderer
            renderer.beginSession(
                generation: networkManager.decoder.currentSessionGeneration)
            renderer.onFrameRendered = { [weak coordinator = context.coordinator, weak networkManager] sequence, generation in
                networkManager?.recordRenderCompletion(
                    sequence: sequence,
                    generation: generation)
                coordinator?.onFrameRendered?()
            }
            renderer.onDrawableCommitted = { [weak networkManager] sequence, generation in
                networkManager?.recordDrawableCommitted(
                    sequence: sequence,
                    generation: generation)
            }
            renderer.onFrameDropped = {
                [weak networkManager] sequence, generation in
                networkManager?.recordRenderDrop(
                    sequence: sequence,
                    generation: generation)
            }
            renderer.onContentViewportChanged = { [weak coordinator = context.coordinator] viewport in
                coordinator?.onContentViewportChanged?(viewport)
            }
            renderer.onGeometrySnapshotChanged = { [weak coordinator = context.coordinator] snapshot in
                coordinator?.onGeometrySnapshotChanged?(snapshot)
            }

            // Connect VideoToolbox Decoded PixelBuffers directly into Metal Renderer
            networkManager.decoder.onSessionBegan = { [weak renderer] generation in
                renderer?.beginSession(generation: generation)
            }
            networkManager.decoder.onFrameDecoded = {
                [weak renderer] pixelBuffer, sequence, generation in
                renderer?.updateFrame(
                    pixelBuffer,
                    sequence: sequence,
                    generation: generation)
            }
        }

        return metalView
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MTKView,
        context: Context
    ) -> CGSize? {
        FullscreenSurfaceLayout.exactSize(
            width: proposal.width,
            height: proposal.height)
    }

    public func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.onFrameRendered = onFrameRendered
        context.coordinator.onContentViewportChanged = onContentViewportChanged
        context.coordinator.onGeometrySnapshotChanged = onGeometrySnapshotChanged

        // MTKView owns its drawable lifetime. Keep automatic resizing enabled
        // and give it the screen scale once it has a window; this keeps its
        // bounds and drawable size aligned with the shared fullscreen rect.
        uiView.autoResizeDrawable = true
        if let screen = uiView.window?.screen {
            uiView.contentScaleFactor = screen.scale
        }
    }

    public class Coordinator {
        var renderer: Renderer?
        var onFrameRendered: (() -> Void)?
        var onContentViewportChanged: ((VideoContentViewport?) -> Void)?
        var onGeometrySnapshotChanged: ((RendererGeometrySnapshot) -> Void)?

        init(
            onFrameRendered: (() -> Void)?,
            onContentViewportChanged: ((VideoContentViewport?) -> Void)?,
            onGeometrySnapshotChanged: ((RendererGeometrySnapshot) -> Void)?
        ) {
            self.onFrameRendered = onFrameRendered
            self.onContentViewportChanged = onContentViewportChanged
            self.onGeometrySnapshotChanged = onGeometrySnapshotChanged
        }
    }
}

/// A wrapper matching the name expected by ContentView
public struct MetalVideoView: View {
    @ObservedObject var networkManager: NetworkManager
    public var onFrameRendered: (() -> Void)?
    public var onContentViewportChanged: ((VideoContentViewport?) -> Void)?
    var onGeometrySnapshotChanged: ((RendererGeometrySnapshot) -> Void)?

    public init(
        networkManager: NetworkManager,
        onFrameRendered: (() -> Void)? = nil,
        onContentViewportChanged: ((VideoContentViewport?) -> Void)? = nil,
        onGeometrySnapshotChanged: ((RendererGeometrySnapshot) -> Void)? = nil
    ) {
        self.networkManager = networkManager
        self.onFrameRendered = onFrameRendered
        self.onContentViewportChanged = onContentViewportChanged
        self.onGeometrySnapshotChanged = onGeometrySnapshotChanged
    }

    public var body: some View {
        MetalView(
            networkManager: networkManager,
            onFrameRendered: onFrameRendered,
            onContentViewportChanged: onContentViewportChanged,
            onGeometrySnapshotChanged: onGeometrySnapshotChanged)
    }
}
