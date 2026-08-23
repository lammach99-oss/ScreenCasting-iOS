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

/// One UIKit container for the two surfaces that make up a connected stream.
/// SwiftUI previously hosted each representable independently. They shared a
/// proposed frame, but not an actual UIKit layout contract. Pinning both views
/// to this container removes that ambiguity while retaining the existing Metal
/// renderer, decoder callbacks, and Pencil touch implementation.
public final class ConnectedPresentationContainer: UIView {
    let metalView = MTKView()
    let touchView = PencilUIKitView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        clipsToBounds = true

        // The container owns the one runtime rectangle used by both surfaces.
        // Autoresizing plus layoutSubviews avoids a representable/constraint
        // timing gap during fullscreen and rotation layout.
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        touchView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(metalView)
        addSubview(touchView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    override public func layoutSubviews() {
        super.layoutSubviews()

        let sharedBounds = bounds
        metalView.frame = sharedBounds
        touchView.frame = sharedBounds

        let scale = window?.screen.scale ?? traitCollection.displayScale
        guard scale > 0 else { return }

        metalView.contentScaleFactor = scale
        metalView.drawableSize = CGSize(
            width: sharedBounds.width * scale,
            height: sharedBounds.height * scale)
    }
}

public struct ConnectedPresentationSurface: UIViewRepresentable {
    @ObservedObject var networkManager: NetworkManager
    public var onFrameRendered: (() -> Void)?
    public var onContentViewportChanged: ((VideoContentViewport?) -> Void)?
    var onGeometrySnapshotChanged: ((RendererGeometrySnapshot) -> Void)?
    var onTouchBoundsChanged: ((CGRect) -> Void)?
    var onPencilInput: ((PencilPacket) -> Void)?
    var onSendTouchEvent: ((TouchEventType, UInt16, UInt16, UInt8) -> Void)?

    public init(
        networkManager: NetworkManager,
        onFrameRendered: (() -> Void)? = nil,
        onContentViewportChanged: ((VideoContentViewport?) -> Void)? = nil,
        onGeometrySnapshotChanged: ((RendererGeometrySnapshot) -> Void)? = nil,
        onTouchBoundsChanged: ((CGRect) -> Void)? = nil,
        onPencilInput: ((PencilPacket) -> Void)? = nil,
        onSendTouchEvent: ((TouchEventType, UInt16, UInt16, UInt8) -> Void)? = nil
    ) {
        self.networkManager = networkManager
        self.onFrameRendered = onFrameRendered
        self.onContentViewportChanged = onContentViewportChanged
        self.onGeometrySnapshotChanged = onGeometrySnapshotChanged
        self.onTouchBoundsChanged = onTouchBoundsChanged
        self.onPencilInput = onPencilInput
        self.onSendTouchEvent = onSendTouchEvent
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeUIView(context: Context) -> ConnectedPresentationContainer {
        let container = ConnectedPresentationContainer(frame: .zero)
        configure(
            container,
            coordinator: context.coordinator,
            createRenderer: true)
        return container
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: ConnectedPresentationContainer,
        context: Context
    ) -> CGSize? {
        FullscreenSurfaceLayout.exactSize(
            width: proposal.width,
            height: proposal.height)
    }

    public func updateUIView(
        _ uiView: ConnectedPresentationContainer,
        context: Context
    ) {
        configure(
            uiView,
            coordinator: context.coordinator,
            createRenderer: false)
    }

    private func configure(
        _ container: ConnectedPresentationContainer,
        coordinator: Coordinator,
        createRenderer: Bool
    ) {
        coordinator.onFrameRendered = onFrameRendered
        coordinator.onContentViewportChanged = onContentViewportChanged
        coordinator.onGeometrySnapshotChanged = onGeometrySnapshotChanged
        coordinator.onTouchBoundsChanged = onTouchBoundsChanged

        let touchView = container.touchView
        touchView.onPencilInput = onPencilInput
        touchView.onSendTouchEvent = onSendTouchEvent
        touchView.onBoundsChanged = { [weak coordinator] bounds in
            coordinator?.onTouchBoundsChanged?(bounds)
        }

        let metalView = container.metalView
        // ConnectedPresentationContainer owns drawable sizing from its shared
        // bounds so the Metal surface and the touch surface cannot diverge.
        metalView.autoResizeDrawable = false
        if let screen = metalView.window?.screen {
            metalView.contentScaleFactor = screen.scale
        }

        guard createRenderer, let renderer = Renderer(metalView: metalView) else {
            return
        }

        coordinator.renderer = renderer
        coordinator.touchView = touchView
        renderer.beginSession(generation: networkManager.decoder.currentSessionGeneration)
        renderer.onFrameRendered = { [weak coordinator, weak networkManager] sequence, generation in
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
        renderer.onFrameDropped = { [weak networkManager] sequence, generation in
            networkManager?.recordRenderDrop(
                sequence: sequence,
                generation: generation)
        }
        renderer.onContentViewportChanged = { [weak coordinator] viewport in
            coordinator?.touchView?.contentViewport = viewport
            coordinator?.onContentViewportChanged?(viewport)
        }
        renderer.onGeometrySnapshotChanged = { [weak coordinator] snapshot in
            coordinator?.onGeometrySnapshotChanged?(snapshot)
        }

        networkManager.decoder.onSessionBegan = { [weak renderer] generation in
            renderer?.beginSession(generation: generation)
        }
        networkManager.decoder.onFrameDecoded = { [weak renderer] pixelBuffer, sequence, generation in
            renderer?.updateFrame(
                pixelBuffer,
                sequence: sequence,
                generation: generation)
        }
    }

    public final class Coordinator {
        var renderer: Renderer?
        weak var touchView: PencilUIKitView?
        var onFrameRendered: (() -> Void)?
        var onContentViewportChanged: ((VideoContentViewport?) -> Void)?
        var onGeometrySnapshotChanged: ((RendererGeometrySnapshot) -> Void)?
        var onTouchBoundsChanged: ((CGRect) -> Void)?
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
