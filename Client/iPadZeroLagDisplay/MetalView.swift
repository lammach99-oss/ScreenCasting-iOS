import SwiftUI
import MetalKit

public struct MetalView: UIViewRepresentable {
    @ObservedObject var networkManager: NetworkManager
    public var onFrameRendered: (() -> Void)?
    public var onContentViewportChanged: ((VideoContentViewport?) -> Void)?

    public init(
        networkManager: NetworkManager,
        onFrameRendered: (() -> Void)? = nil,
        onContentViewportChanged: ((VideoContentViewport?) -> Void)? = nil
    ) {
        self.networkManager = networkManager
        self.onFrameRendered = onFrameRendered
        self.onContentViewportChanged = onContentViewportChanged
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            onFrameRendered: onFrameRendered,
            onContentViewportChanged: onContentViewportChanged)
    }

    public func makeUIView(context: Context) -> MTKView {
        let metalView = MTKView()

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

    public func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.onFrameRendered = onFrameRendered
        context.coordinator.onContentViewportChanged = onContentViewportChanged
    }

    public class Coordinator {
        var renderer: Renderer?
        var onFrameRendered: (() -> Void)?
        var onContentViewportChanged: ((VideoContentViewport?) -> Void)?

        init(
            onFrameRendered: (() -> Void)?,
            onContentViewportChanged: ((VideoContentViewport?) -> Void)?
        ) {
            self.onFrameRendered = onFrameRendered
            self.onContentViewportChanged = onContentViewportChanged
        }
    }
}

/// A wrapper matching the name expected by ContentView
public struct MetalVideoView: View {
    @ObservedObject var networkManager: NetworkManager
    public var onFrameRendered: (() -> Void)?
    public var onContentViewportChanged: ((VideoContentViewport?) -> Void)?

    public init(
        networkManager: NetworkManager,
        onFrameRendered: (() -> Void)? = nil,
        onContentViewportChanged: ((VideoContentViewport?) -> Void)? = nil
    ) {
        self.networkManager = networkManager
        self.onFrameRendered = onFrameRendered
        self.onContentViewportChanged = onContentViewportChanged
    }

    public var body: some View {
        MetalView(
            networkManager: networkManager,
            onFrameRendered: onFrameRendered,
            onContentViewportChanged: onContentViewportChanged)
    }
}
