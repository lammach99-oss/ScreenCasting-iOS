import Foundation
import Metal
import MetalKit
import CoreVideo

enum RenderOfferDecision: Equatable {
    case accepted(replaced: UInt32?)
    case rejected
    case staleSession
}

struct RenderFrameIdentity: Equatable {
    let generation: UInt64
    let sequence: UInt32
}

/// Persistent, wrap-safe sequence watermarks scoped to one wire session.
struct RenderFreshnessTracker {
    private(set) var sessionGeneration: UInt64?
    private(set) var acceptedSequence: UInt32?
    private(set) var presentedSequence: UInt32?
    private(set) var pendingIdentity: RenderFrameIdentity?

    mutating func beginSession(generation: UInt64) {
        sessionGeneration = generation
        acceptedSequence = nil
        presentedSequence = nil
        pendingIdentity = nil
    }

    mutating func offer(
        _ sequence: UInt32,
        generation: UInt64
    ) -> RenderOfferDecision {
        guard generation == sessionGeneration else { return .staleSession }
        if let acceptedSequence,
           !Self.isNewer(sequence, than: acceptedSequence) {
            return .rejected
        }
        let replaced = pendingIdentity?.sequence
        acceptedSequence = sequence
        pendingIdentity = RenderFrameIdentity(
            generation: generation,
            sequence: sequence)
        return .accepted(replaced: replaced)
    }

    mutating func takePending() -> RenderFrameIdentity? {
        let result = pendingIdentity
        pendingIdentity = nil
        return result
    }

    func shouldCommit(_ identity: RenderFrameIdentity) -> Bool {
        guard identity.generation == sessionGeneration else { return false }
        let sequence = identity.sequence
        if let acceptedSequence,
           acceptedSequence != sequence,
           Self.isNewer(acceptedSequence, than: sequence) {
            return false
        }
        if let presentedSequence,
           !Self.isNewer(sequence, than: presentedSequence) {
            return false
        }
        return true
    }

    mutating func markPresented(_ identity: RenderFrameIdentity) -> Bool {
        guard identity.generation == sessionGeneration else { return false }
        let sequence = identity.sequence
        if let presentedSequence,
           !Self.isNewer(sequence, than: presentedSequence) {
            return false
        }
        presentedSequence = sequence
        return true
    }

    func isCurrent(_ identity: RenderFrameIdentity) -> Bool {
        identity.generation == sessionGeneration
    }

    static func isNewer(_ candidate: UInt32, than reference: UInt32) -> Bool {
        Int32(bitPattern: candidate &- reference) > 0
    }
}

/// High-performance zero-copy Metal renderer for a 120 Hz iPad display.
public class Renderer: NSObject, MTKViewDelegate {
    public var onFrameRendered: ((UInt32, UInt64) -> Void)?
    public var onDrawableCommitted: ((UInt32, UInt64) -> Void)?
    public var onFrameDropped: ((UInt32, UInt64) -> Void)?
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private var currentPixelBuffer: CVPixelBuffer?
    private var freshness = RenderFreshnessTracker()
    private let lock = NSLock()

    public init?(metalView: MTKView) {
        guard let defaultDevice = MTLCreateSystemDefaultDevice(),
              let queue = defaultDevice.makeCommandQueue() else {
            return nil
        }
        device = defaultDevice
        commandQueue = queue
        metalView.device = defaultDevice
        super.init()
        metalView.delegate = self
        metalView.preferredFramesPerSecond = 120
        metalView.framebufferOnly = true
        metalView.clearColor = MTLClearColor(red: 0.05, green: 0.09, blue: 0.16, alpha: 1)
        setupTextureCache()
        setupPipeline()
    }

    private func setupTextureCache() {
        var cache: CVMetalTextureCache?
        if CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess {
            textureCache = cache
        }
    }

    private func setupPipeline() {
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "yuvVertexShader"),
              let fragment = library.makeFunction(name: "yuvFragmentShader") else { return }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("[Renderer] Failed to create render pipeline: \(error)")
        }
    }

    public func beginSession(generation: UInt64) {
        lock.lock()
        currentPixelBuffer = nil
        freshness.beginSession(generation: generation)
        lock.unlock()
    }

    public func updateFrame(
        _ pixelBuffer: CVPixelBuffer,
        sequence: UInt32,
        generation: UInt64
    ) {
        var dropped: UInt32?
        lock.lock()
        switch freshness.offer(sequence, generation: generation) {
        case .rejected:
            dropped = sequence
        case .accepted(let replaced):
            currentPixelBuffer = pixelBuffer
            dropped = replaced
        case .staleSession:
            break
        }
        lock.unlock()
        if let dropped { onFrameDropped?(dropped, generation) }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        lock.lock()
        guard let pixelBuffer = currentPixelBuffer,
              let identity = freshness.takePending() else {
            lock.unlock()
            return
        }
        currentPixelBuffer = nil
        lock.unlock()

        guard let textureCache,
              let pipelineState,
              let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else {
            abandon(identity)
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var yTextureRef: CVMetalTexture?
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .r8Unorm, width, height, 0, &yTextureRef)
        var uvTextureRef: CVMetalTexture?
        let uvStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .rg8Unorm, width / 2, height / 2, 1, &uvTextureRef)

        guard yStatus == kCVReturnSuccess,
              uvStatus == kCVReturnSuccess,
              let yTextureRef,
              let uvTextureRef,
              let yTexture = CVMetalTextureGetTexture(yTextureRef),
              let uvTexture = CVMetalTextureGetTexture(uvTextureRef),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: renderPassDescriptor) else {
            abandon(identity)
            return
        }

        let viewAspect = Float(view.drawableSize.width / view.drawableSize.height)
        let videoAspect = Float(width) / Float(height)
        var scale = SIMD2<Float>(1, 1)
        if videoAspect > viewAspect {
            scale.y = viewAspect / videoAspect
        } else {
            scale.x = videoAspect / viewAspect
        }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uvTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        lock.lock()
        let shouldCommit = freshness.shouldCommit(identity)
        lock.unlock()
        guard shouldCommit else {
            abandon(identity)
            return
        }

        commandBuffer.present(drawable)
        let retainedPixelBuffer = pixelBuffer
        commandBuffer.addCompletedHandler { [weak self] _ in
            _ = yTextureRef
            _ = uvTextureRef
            _ = retainedPixelBuffer
            guard let self else { return }
            self.lock.lock()
            let isCurrent = self.freshness.markPresented(identity)
            self.lock.unlock()
            guard isCurrent else { return }
            DispatchQueue.main.async {
                self.onFrameRendered?(
                    identity.sequence,
                    identity.generation)
            }
        }
        commandBuffer.commit()
        onDrawableCommitted?(identity.sequence, identity.generation)
    }

    private func abandon(_ identity: RenderFrameIdentity) {
        lock.lock()
        let isCurrent = freshness.isCurrent(identity)
        lock.unlock()
        if isCurrent {
            onFrameDropped?(identity.sequence, identity.generation)
        }
    }
}
