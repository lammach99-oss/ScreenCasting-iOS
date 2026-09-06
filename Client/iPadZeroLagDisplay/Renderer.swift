import Foundation
import Metal
import MetalKit
import CoreVideo
import UIKit

enum VideoQualityDiagnostics {
    static let sampleInterval: UInt32 = 120

    static func shouldLog(sequence: UInt32) -> Bool {
        sequence <= 5 || sequence.isMultiple(of: sampleInterval)
    }

    static func log(
        stage: String,
        sequence: UInt32,
        generation: UInt64,
        collectibleSink: ((String) -> Void)? = nil,
        details: @autoclosure () -> String
    ) {
        guard shouldLog(sequence: sequence) else { return }
        let line =
            "[VIDEO_QUALITY] stage=\(stage) generation=\(generation) sequence=\(sequence) \(details())"
        print(line)
        collectibleSink?(line)
    }

    static func fourCC(_ value: OSType) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ??
            String(format: "0x%08X", value)
    }

    static func pixels(_ size: CGSize) -> String {
        String(
            format: "%.0fx%.0f",
            Double(size.width),
            Double(size.height))
    }

    static func rect(_ rect: CGRect) -> String {
        String(
            format: "%.4f,%.4f,%.4f,%.4f",
            Double(rect.minX),
            Double(rect.minY),
            Double(rect.width),
            Double(rect.height))
    }
}

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
public struct VideoContentViewport: Equatable {
    let rect: CGRect

    func contentRect(in container: CGRect) -> CGRect {
        CGRect(
            x: container.minX + rect.minX * container.width,
            y: container.minY + rect.minY * container.height,
            width: rect.width * container.width,
            height: rect.height * container.height)
    }

    static func aspectFit(
        containerSize: CGSize,
        videoSize: CGSize
    ) -> VideoContentViewport? {
        guard containerSize.width > 0,
              containerSize.height > 0,
              videoSize.width > 0,
              videoSize.height > 0 else {
            return nil
        }

        let scale = min(
            containerSize.width / videoSize.width,
            containerSize.height / videoSize.height)
        let renderedSize = CGSize(
            width: videoSize.width * scale,
            height: videoSize.height * scale)
        return VideoContentViewport(
            rect: CGRect(
                x: (containerSize.width - renderedSize.width) /
                    (2 * containerSize.width),
                y: (containerSize.height - renderedSize.height) /
                    (2 * containerSize.height),
                width: renderedSize.width / containerSize.width,
                height: renderedSize.height / containerSize.height))
    }

    func normalizedPoint(
        for location: CGPoint,
        in container: CGRect
    ) -> CGPoint? {
        guard let point = normalizedContainerPoint(for: location, in: container),
              point.x >= rect.minX,
              point.x <= rect.maxX,
              point.y >= rect.minY,
              point.y <= rect.maxY else {
            return nil
        }
        return CGPoint(
            x: (point.x - rect.minX) / rect.width,
            y: (point.y - rect.minY) / rect.height)
    }

    func clampedNormalizedPoint(
        for location: CGPoint,
        in container: CGRect
    ) -> CGPoint? {
        guard let point = normalizedContainerPoint(for: location, in: container) else {
            return nil
        }
        return CGPoint(
            x: min(max((point.x - rect.minX) / rect.width, 0), 1),
            y: min(max((point.y - rect.minY) / rect.height, 0), 1))
    }

    private func normalizedContainerPoint(
        for location: CGPoint,
        in container: CGRect
    ) -> CGPoint? {
        guard container.width > 0,
              container.height > 0,
              rect.width > 0,
              rect.height > 0 else {
            return nil
        }
        return CGPoint(
            x: (location.x - container.minX) / container.width,
            y: (location.y - container.minY) / container.height)
    }
}

public struct RendererGeometrySnapshot: Equatable {
    let decodedFrameSize: CGSize
    let windowBounds: CGRect
    let safeAreaInsets: UIEdgeInsets
    let metalBounds: CGRect
    let drawableSize: CGSize
    let contentScaleFactor: CGFloat
    let contentViewport: VideoContentViewport

    public static func == (
        lhs: RendererGeometrySnapshot,
        rhs: RendererGeometrySnapshot
    ) -> Bool {
        lhs.decodedFrameSize == rhs.decodedFrameSize &&
            lhs.windowBounds == rhs.windowBounds &&
            lhs.safeAreaInsets.top == rhs.safeAreaInsets.top &&
            lhs.safeAreaInsets.left == rhs.safeAreaInsets.left &&
            lhs.safeAreaInsets.bottom == rhs.safeAreaInsets.bottom &&
            lhs.safeAreaInsets.right == rhs.safeAreaInsets.right &&
            lhs.metalBounds == rhs.metalBounds &&
            lhs.drawableSize == rhs.drawableSize &&
            lhs.contentScaleFactor == rhs.contentScaleFactor &&
            lhs.contentViewport == rhs.contentViewport
    }
}

public class Renderer: NSObject, MTKViewDelegate {
    public var onFrameRendered: ((UInt32, UInt64) -> Void)?
    public var onDrawableCommitted: ((UInt32, UInt64) -> Void)?
    public var onFrameDropped: ((UInt32, UInt64) -> Void)?
    var onContentViewportChanged: ((VideoContentViewport?) -> Void)?
    var onGeometrySnapshotChanged: ((RendererGeometrySnapshot) -> Void)?
    var diagnosticSink: ((String) -> Void)?
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private var aspectRatioBuffer: MTLBuffer?
    private var currentPixelBuffer: CVPixelBuffer?
    private var freshness = RenderFreshnessTracker()
    private var publishedContentViewport: VideoContentViewport?
    private var publishedGeometrySnapshot: RendererGeometrySnapshot?

    static func contentViewport(
        forDrawableSize drawableSize: CGSize,
        videoSize: CGSize
    ) -> VideoContentViewport? {
        VideoContentViewport.aspectFit(
            containerSize: drawableSize,
            videoSize: videoSize)
    }

    private var lastDecodedFrameSize: CGSize?
    private let lock = NSLock()
    private let diagnosticLock = NSLock()
    private var staleGenerationDiagnostics: Set<UInt64> = []
    private var submitGenerationDiagnostics: Set<UInt64> = []

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
            aspectRatioBuffer = device.makeBuffer(
                length: MemoryLayout<SIMD2<Float>>.size,
                options: .storageModeShared)
        } catch {
            print("[Renderer] Failed to create render pipeline: \(error)")
        }
    }

    public func beginSession(generation: UInt64) {
        lock.lock()
        currentPixelBuffer = nil
        freshness.beginSession(generation: generation)
        let shouldResetContentViewport = publishedContentViewport != nil
        publishedContentViewport = nil
        publishedGeometrySnapshot = nil
        lastDecodedFrameSize = nil
        lock.unlock()
        if let textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        if shouldResetContentViewport {
            DispatchQueue.main.async { [weak self] in
                self?.onContentViewportChanged?(nil)
            }
        }
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
            if noteStaleGeneration(generation) {
                print("[IPAD][RENDER_FRAME_DROPPED_STALE] frameGeneration=\(generation) currentGeneration=\(freshness.sessionGeneration ?? 0)")
            }
            break
        }
        lock.unlock()
        if let dropped { onFrameDropped?(dropped, generation) }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        lock.lock()
        let decodedFrameSize = lastDecodedFrameSize
        lock.unlock()
        guard let decodedFrameSize,
              let contentViewport = Self.contentViewport(
                forDrawableSize: size,
                videoSize: decodedFrameSize) else { return }
        publishContentViewport(contentViewport)
        publishGeometrySnapshot(
            for: view,
            decodedFrameSize: decodedFrameSize,
            drawableSize: size,
            contentViewport: contentViewport)
    }

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
        let decodedFrameSize = CGSize(width: width, height: height)
        lock.lock()
        lastDecodedFrameSize = decodedFrameSize
        lock.unlock()
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == DecoderOutputBufferAttributes.pixelFormat else {
            print("[Renderer] Metal presentation rejected: pixelFormat=\(CVPixelBufferGetPixelFormatType(pixelBuffer)) expected=\(DecoderOutputBufferAttributes.pixelFormat)")
            abandon(identity)
            return
        }
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
              let uvTexture = CVMetalTextureGetTexture(uvTextureRef) else {
            print("[Renderer] CVMetalTextureCacheCreateTextureFromImage failed: yStatus=\(yStatus) uvStatus=\(uvStatus) size=\(width)x\(height) pixelFormat=\(CVPixelBufferGetPixelFormatType(pixelBuffer))")
            abandon(identity)
            return
        }
        VideoQualityDiagnostics.log(
            stage: "metal_texture",
            sequence: identity.sequence,
            generation: identity.generation,
            collectibleSink: diagnosticSink,
            details:
                "y_px=\(yTexture.width)x\(yTexture.height) uv_px=\(uvTexture.width)x\(uvTexture.height) y_format=\(yTexture.pixelFormat.rawValue) uv_format=\(uvTexture.pixelFormat.rawValue)")
        VideoQualityDiagnostics.log(
            stage: "drawable",
            sequence: identity.sequence,
            generation: identity.generation,
            collectibleSink: diagnosticSink,
            details:
                "texture_px=\(drawable.texture.width)x\(drawable.texture.height) drawable_px=\(VideoQualityDiagnostics.pixels(view.drawableSize)) format=\(drawable.texture.pixelFormat.rawValue)")
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: renderPassDescriptor) else {
            abandon(identity)
            return
        }

        guard let contentViewport = Self.contentViewport(
            forDrawableSize: view.drawableSize,
            videoSize: decodedFrameSize) else {
            abandon(identity)
            return
        }
        VideoQualityDiagnostics.log(
            stage: "viewport",
            sequence: identity.sequence,
            generation: identity.generation,
            collectibleSink: diagnosticSink,
            details:
                "normalized=\(VideoQualityDiagnostics.rect(contentViewport.rect)) pixels=\(VideoQualityDiagnostics.rect(contentViewport.contentRect(in: CGRect(origin: .zero, size: view.drawableSize))))")
        publishContentViewport(contentViewport)
        publishGeometrySnapshot(
            for: view,
            decodedFrameSize: decodedFrameSize,
            drawableSize: view.drawableSize,
            contentViewport: contentViewport)
        let scale = SIMD2<Float>(
            Float(contentViewport.rect.width),
            Float(contentViewport.rect.height))
        aspectRatioBuffer?.contents().storeBytes(of: scale, as: SIMD2<Float>.self)
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(aspectRatioBuffer, offset: 0, index: 0)
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
            let currentGeneration = self.freshness.sessionGeneration ?? 0
            self.lock.unlock()
            guard isCurrent else {
                if self.noteStaleGeneration(identity.generation) {
                    print("[IPAD][RENDER_FRAME_DROPPED_STALE] frameGeneration=\(identity.generation) currentGeneration=\(currentGeneration)")
                }
                return
            }
            DispatchQueue.main.async {
                self.onFrameRendered?(
                    identity.sequence,
                    identity.generation)
            }
        }
        commandBuffer.commit()
        diagnosticLock.lock()
        let shouldLogSubmit = submitGenerationDiagnostics.insert(identity.generation).inserted
        diagnosticLock.unlock()
        if shouldLogSubmit {
            print("[IPAD][RENDER_FRAME_SUBMIT] generation=\(identity.generation)")
        }
        onDrawableCommitted?(identity.sequence, identity.generation)
    }

    private func publishContentViewport(_ contentViewport: VideoContentViewport) {
        lock.lock()
        let changed = publishedContentViewport != contentViewport
        publishedContentViewport = contentViewport
        lock.unlock()
        guard changed else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onContentViewportChanged?(contentViewport)
        }
    }

    private func publishGeometrySnapshot(
        for view: MTKView,
        decodedFrameSize: CGSize,
        drawableSize: CGSize,
        contentViewport: VideoContentViewport
    ) {
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self,
                  let view else {
                return
            }

            let snapshot = RendererGeometrySnapshot(
                decodedFrameSize: decodedFrameSize,
                windowBounds: view.window?.bounds ?? .zero,
                safeAreaInsets: view.window?.safeAreaInsets ?? view.safeAreaInsets,
                metalBounds: view.bounds,
                drawableSize: drawableSize,
                contentScaleFactor: view.contentScaleFactor,
                contentViewport: contentViewport)
            self.lock.lock()
            let changed = self.publishedGeometrySnapshot != snapshot
            self.publishedGeometrySnapshot = snapshot
            self.lock.unlock()
            guard changed else { return }
            self.onGeometrySnapshotChanged?(snapshot)
        }
    }

    private func abandon(_ identity: RenderFrameIdentity) {
        lock.lock()
        let isCurrent = freshness.isCurrent(identity)
        lock.unlock()
        if isCurrent {
            onFrameDropped?(identity.sequence, identity.generation)
        }
    }

    private func noteStaleGeneration(_ generation: UInt64) -> Bool {
        diagnosticLock.lock()
        defer { diagnosticLock.unlock() }
        return staleGenerationDiagnostics.insert(generation).inserted
    }
}
