import SwiftUI
import MetalKit

public struct MetalView: UIViewRepresentable {
    @ObservedObject var networkManager: NetworkManager
    public var onFrameRendered: (() -> Void)?

    public init(networkManager: NetworkManager, onFrameRendered: (() -> Void)? = nil) {
        self.networkManager = networkManager
        self.onFrameRendered = onFrameRendered
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onFrameRendered: onFrameRendered)
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
    }

    public class Coordinator {
        var renderer: Renderer?
        var onFrameRendered: (() -> Void)?

        init(onFrameRendered: (() -> Void)?) {
            self.onFrameRendered = onFrameRendered
        }
    }
}

/// A wrapper matching the name expected by ContentView
public struct MetalVideoView: View {
    @ObservedObject var networkManager: NetworkManager
    public var onFrameRendered: (() -> Void)?

    public init(networkManager: NetworkManager, onFrameRendered: (() -> Void)? = nil) {
        self.networkManager = networkManager
        self.onFrameRendered = onFrameRendered
    }

    public var body: some View {
        MetalView(networkManager: networkManager, onFrameRendered: onFrameRendered)
    }
}
