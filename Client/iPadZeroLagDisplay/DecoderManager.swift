import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import CryptoKit
import QuartzCore

enum DecoderOutputBufferAttributes {
    static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

    static func make() -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
    }

    static func invalidReason(
        for pixelBuffer: CVPixelBuffer,
        expectedWidth: Int,
        expectedHeight: Int
    ) -> String? {
        guard CVPixelBufferGetIOSurface(pixelBuffer) != nil else {
            return "IOSurface unavailable"
        }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == pixelFormat else {
            return "pixelFormat=\(CVPixelBufferGetPixelFormatType(pixelBuffer)) expected=\(pixelFormat)"
        }
        guard CVPixelBufferGetWidth(pixelBuffer) == expectedWidth,
              CVPixelBufferGetHeight(pixelBuffer) == expectedHeight else {
            return "dimensions=\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)) expected=\(expectedWidth)x\(expectedHeight)"
        }
        return nil
    }
}

enum AnnexBNALScanner {
    static func ranges(in data: Data) -> [Range<Data.Index>] {
        var starts: [(offset: Int, length: Int)] = []
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index + 2 < bytes.count {
                if bytes[index] == 0, bytes[index + 1] == 0 {
                    if bytes[index + 2] == 1 {
                        starts.append((index, 3))
                        index += 3
                        continue
                    }
                    if index + 3 < bytes.count,
                       bytes[index + 2] == 0, bytes[index + 3] == 1 {
                        starts.append((index, 4))
                        index += 4
                        continue
                    }
                }
                index += 1
            }
        }

        guard !starts.isEmpty else {
            return data.isEmpty ? [] : [data.startIndex..<data.endIndex]
        }
        return starts.enumerated().compactMap { index, start in
            let lower = data.startIndex + start.offset + start.length
            var upper = index + 1 < starts.count
                ? data.startIndex + starts[index + 1].offset
                : data.endIndex
            while upper > lower, data[data.index(before: upper)] == 0 {
                upper = data.index(before: upper)
            }
            return lower < upper ? lower..<upper : nil
        }
    }
}

enum LengthPrefixedNALScanner {
    static func ranges(in data: Data) -> [Range<Data.Index>]? {
        var result: [Range<Data.Index>] = []
        let valid = data.withUnsafeBytes { raw -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            var offset = 0
            while offset < bytes.count {
                guard bytes.count - offset >= 4 else { return false }
                let nalLength =
                    (Int(bytes[offset]) << 24) |
                    (Int(bytes[offset + 1]) << 16) |
                    (Int(bytes[offset + 2]) << 8) |
                    Int(bytes[offset + 3])
                offset += 4
                guard nalLength >= 2, nalLength <= bytes.count - offset else {
                    return false
                }
                let lower = data.startIndex + offset
                offset += nalLength
                result.append(lower..<(data.startIndex + offset))
            }
            return !result.isEmpty
        }
        return valid ? result : nil
    }
}

struct HevcCanonicalAccessUnit {
    static func frameRange(
        in data: Data,
        nalRanges: [Range<Data.Index>]
    ) -> Range<Data.Index>? {
        for range in nalRanges where !range.isEmpty {
            let nalType = (data[range.lowerBound] >> 1) & 0x3f
            guard nalType != 32, nalType != 33, nalType != 34 else {
                continue
            }
            guard let lower = data.index(
                range.lowerBound,
                offsetBy: -4,
                limitedBy: data.startIndex) else {
                return nil
            }
            return lower..<data.endIndex
        }
        return nil
    }
}

struct HevcParameterSetSignature: Equatable {
    let digest: SHA256.Digest

    init(vps: Data, sps: Data, pps: Data) {
        var bytes = Data()
        Self.append(vps, to: &bytes)
        Self.append(sps, to: &bytes)
        Self.append(pps, to: &bytes)
        digest = SHA256.hash(data: bytes)
    }

    private static func append(_ value: Data, to bytes: inout Data) {
        precondition(value.count <= Int(UInt32.max))
        var length = UInt32(value.count).bigEndian
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
        bytes.append(value)
    }
}

struct HevcParameterSetSessionGate {
    private(set) var activeParameterSetSignature: HevcParameterSetSignature?

    mutating func replaceIfChanged(
        vps: Data,
        sps: Data,
        pps: Data,
        factory: () -> Bool
    ) -> Bool {
        let candidate = HevcParameterSetSignature(vps: vps, sps: sps, pps: pps)
        guard candidate != activeParameterSetSignature, factory() else {
            return false
        }
        activeParameterSetSignature = candidate
        return true
    }

    mutating func reset() {
        activeParameterSetSignature = nil
    }
}

struct H264ParameterSetSignature: Equatable {
    let digest: SHA256.Digest

    init(sps: Data, pps: Data) {
        var bytes = Data()
        Self.append(sps, to: &bytes)
        Self.append(pps, to: &bytes)
        digest = SHA256.hash(data: bytes)
    }

    private static func append(_ value: Data, to bytes: inout Data) {
        precondition(value.count <= Int(UInt32.max))
        var length = UInt32(value.count).bigEndian
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
        bytes.append(value)
    }
}

struct H264ParameterSetSessionGate {
    private(set) var activeParameterSetSignature: H264ParameterSetSignature?

    mutating func replaceIfChanged(
        sps: Data,
        pps: Data,
        factory: () -> Bool
    ) -> Bool {
        let candidate = H264ParameterSetSignature(sps: sps, pps: pps)
        guard candidate != activeParameterSetSignature, factory() else {
            return false
        }
        activeParameterSetSignature = candidate
        return true
    }

    mutating func reset() {
        activeParameterSetSignature = nil
    }
}

/// Keeps a canonical payload's backing Data and decode lifetime alive until
/// CoreMedia releases the block. No Annex-B reconstruction is needed.
final class RetainedDataBlockStorage {
    let lifetime: DecodeSubmissionLifetime
    let bytes: NSData
    let offset: Int

    init?(lifetime: DecodeSubmissionLifetime, offset: Int) {
        guard let data = lifetime.owner.retainedDataBacking(),
              offset >= 0,
              offset < data.length else { return nil }
        self.lifetime = lifetime
        bytes = data
        self.offset = offset
    }

    var dataLength: Int { bytes.length - offset }

    func makeBlockBuffer() -> CMBlockBuffer? {
        let retained = Unmanaged.passRetained(self)
        var blockSource = CMBlockBufferCustomBlockSource(
            version: UInt32(kCMBlockBufferCustomBlockSourceVersion),
            AllocateBlock: nil,
            FreeBlock: { refCon, _, _ in
                guard let refCon else { return }
                Unmanaged<RetainedDataBlockStorage>
                    .fromOpaque(refCon)
                    .release()
            },
            refCon: retained.toOpaque())
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: UnsafeMutableRawPointer(mutating: bytes.bytes),
            blockLength: bytes.length,
            blockAllocator: nil,
            customBlockSource: &blockSource,
            offsetToData: offset,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer)
        if status != noErr {
            retained.release()
            return nil
        }
        return blockBuffer
    }
}

/// Owns the single AVCC conversion allocation used by CMBlockBuffer. The
/// custom block source keeps this object (and the received owner) alive until
/// CoreMedia releases the buffer.
private final class LengthPrefixedBlockStorage {
    let lifetime: DecodeSubmissionLifetime
    let bytes: NSMutableData

    init?(lifetime: DecodeSubmissionLifetime, ranges: [Range<Data.Index>]) {
        let source = lifetime.owner.data
        let total = ranges.reduce(0) { $0 + 4 + $1.count }
        guard total > 0, let storage = NSMutableData(length: total) else { return nil }
        self.lifetime = lifetime
        self.bytes = storage

        var destinationOffset = 0
        source.withUnsafeBytes { sourceBytes in
            guard let sourceBase = sourceBytes.baseAddress else { return }
            for range in ranges {
                var length = UInt32(range.count).bigEndian
                Swift.withUnsafeBytes(of: &length) {
                    storage.mutableBytes.advanced(by: destinationOffset)
                        .copyMemory(from: $0.baseAddress!, byteCount: 4)
                }
                destinationOffset += 4
                let sourceOffset = source.distance(
                    from: source.startIndex,
                    to: range.lowerBound)
                storage.mutableBytes.advanced(by: destinationOffset).copyMemory(
                    from: sourceBase.advanced(by: sourceOffset),
                    byteCount: range.count)
                destinationOffset += range.count
            }
        }
    }

    func makeBlockBuffer() -> CMBlockBuffer? {
        let retained = Unmanaged.passRetained(self)
        var blockSource = CMBlockBufferCustomBlockSource(
            version: UInt32(kCMBlockBufferCustomBlockSourceVersion),
            AllocateBlock: nil,
            FreeBlock: { refCon, _, _ in
                guard let refCon else { return }
                Unmanaged<LengthPrefixedBlockStorage>.fromOpaque(refCon).release()
            },
            refCon: retained.toOpaque())
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: bytes.mutableBytes,
            blockLength: bytes.length,
            blockAllocator: nil,
            customBlockSource: &blockSource,
            offsetToData: 0,
            dataLength: bytes.length,
            flags: 0,
            blockBufferOut: &blockBuffer)
        if status != noErr {
            retained.release()
            return nil
        }
        return blockBuffer
    }
}

private final class DecodeCompletionIdentity {
    let sequence: UInt32
    let sessionGeneration: UInt64
    private let lock = NSLock()
    private var emitted = false

    init(sequence: UInt32, sessionGeneration: UInt64) {
        self.sequence = sequence
        self.sessionGeneration = sessionGeneration
    }

    func claimEmission() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !emitted else { return false }
        emitted = true
        return true
    }
}

private final class VideoDecodeSubmission {
    let ticket: DecodeTicket
    let lifetime: DecodeSubmissionLifetime
    let decodeStartedAt: TimeInterval
    let expectedWidth: Int
    let expectedHeight: Int

    init(
        ticket: DecodeTicket,
        lifetime: DecodeSubmissionLifetime,
        decodeStartedAt: TimeInterval,
        expectedWidth: Int,
        expectedHeight: Int
    ) {
        self.ticket = ticket
        self.lifetime = lifetime
        self.decodeStartedAt = decodeStartedAt
        self.expectedWidth = expectedWidth
        self.expectedHeight = expectedHeight
    }
}

public enum VideoDecoderCodec: UInt8 {
    case hevc = 1
    case h264 = 2
}

/// Hardware-accelerated, freshness-first VideoToolbox decoder.
public final class DecoderManager {
    public var onFrameDecoded: ((CVPixelBuffer, UInt32, UInt64) -> Void)?
    public var onDecodeCompleted: ((UInt32, UInt64, Bool) -> Void)?
    public var onSessionBegan: ((UInt64) -> Void)?
    public var onDecodeLatency:
        ((UInt32, UInt64, TimeInterval, Double) -> Void)?
    public var onMailboxAge: ((UInt32, Double) -> Void)?
    public var onFrameDropped: ((UInt32, UInt64) -> Void)?
    public var onRecoveryNeeded: (() -> Void)?

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var vpsData: Data?
    private var spsData: Data?
    private var ppsData: Data?
    private var activeCodec: VideoDecoderCodec = .hevc
    // A format-set change (for example landscape -> portrait) invalidates
    // reference pictures. Wait for the next IRAP/IDR before decoding frames.
    private var hevcKeyframeRequired = false
    private var hasDecodedH264Idr = false
    private var parameterSetSessionGate = HevcParameterSetSessionGate()
    private var activeParameterSetSignature: HevcParameterSetSignature? {
        parameterSetSessionGate.activeParameterSetSignature
    }
    private var h264ParameterSetSessionGate = H264ParameterSetSessionGate()
    private var activeH264ParameterSetSignature: H264ParameterSetSignature? {
        h264ParameterSetSessionGate.activeParameterSetSignature
    }
    private let queue = DispatchQueue(
        label: "com.iPadZeroLagDisplay.decoder",
        qos: .userInteractive)
    private lazy var mailbox = makeMailbox()
    private let mailboxStateLock = NSLock()
    private var localSessionGeneration: UInt64 = 0
    private let completionIdentityLock = NSLock()
    private var completionIdentities:
        [ObjectIdentifier: DecodeCompletionIdentity] = [:]

    public init() {
        localSessionGeneration = 1
        mailbox.beginSession(generation: localSessionGeneration)
    }

    public func beginSession(generation: UInt64) {
        mailboxStateLock.lock()
        mailbox.beginSession(generation: generation)
        localSessionGeneration = generation
        mailboxStateLock.unlock()

        // A reconnect must not reuse the previous VideoToolbox session or
        // deliver IOSurface-backed buffers whose owner belongs to the old
        // connection. Flush and invalidate synchronously before the new
        // generation can submit compressed frames; the next IDR recreates the
        // format/session state and repopulates the mailbox with fresh surfaces.
        queue.sync {
            if let session = decompressionSession {
                VTDecompressionSessionWaitForAsynchronousFrames(session)
                VTDecompressionSessionInvalidate(session)
                decompressionSession = nil
            }
            formatDescription = nil
            vpsData = nil
            spsData = nil
            ppsData = nil
            activeCodec = .hevc
            hevcKeyframeRequired = false
            hasDecodedH264Idr = false
            parameterSetSessionGate.reset()
            h264ParameterSetSessionGate.reset()
        }
        onSessionBegan?(generation)
    }

    public var currentSessionGeneration: UInt64 {
        mailboxStateLock.lock()
        defer { mailboxStateLock.unlock() }
        return localSessionGeneration
    }

    /// Installs the H.264 decoder before the control channel acknowledges the
    /// configuration.  Canonical four-byte NAL-length samples can then arrive.
    public func configureH264(sps: Data, pps: Data) -> Bool {
        guard !sps.isEmpty, !pps.isEmpty else { return false }
        return queue.sync {
            guard replaceH264DecompressionSession(sps: sps, pps: pps) else {
                return false
            }
            activeCodec = .h264
            hasDecodedH264Idr = false
            vpsData = nil
            spsData = sps
            ppsData = pps
            _ = h264ParameterSetSessionGate.replaceIfChanged(sps: sps, pps: pps) { true }
            return true
        }
    }

    /// Drop inter-frames after a live stream setting changes. The host keeps
    /// the same codec configuration, but the decoder may still hold reference
    /// pictures from before the encoder refresh. The next IDR restores a clean
    /// reference chain without recreating the VideoToolbox session.
    public func requireKeyFrame() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.activeCodec == .hevc {
                self.hevcKeyframeRequired = true
            } else {
                self.hasDecodedH264Idr = false
            }
        }
    }

    /// Transfers the SCST payload into the capacity-one mailbox and returns
    /// without waiting for the decoder queue.
    public func processInputData(
        _ data: Data,
        sequence: UInt32,
        isIDR: Bool,
        isLengthPrefixed: Bool = false,
        receivedAt: TimeInterval = CACurrentMediaTime()
    ) {
        mailboxStateLock.lock()
        let identity = DecodeCompletionIdentity(
            sequence: sequence,
            sessionGeneration: localSessionGeneration)
        var ownerIdentifier: ObjectIdentifier?
        let owner = AccessUnitOwner(
            data: data,
            onRelease: { [weak self, identity] in
                guard let ownerIdentifier else { return }
                self?.emitCompletion(
                    identity,
                    ownerIdentifier: ownerIdentifier,
                    succeeded: false)
            })
        ownerIdentifier = ObjectIdentifier(owner)
        completionIdentityLock.lock()
        completionIdentities[ObjectIdentifier(owner)] = identity
        completionIdentityLock.unlock()
        let accessUnit = AccessUnit(
            owner: owner,
            sequence: sequence,
            sessionGeneration: identity.sessionGeneration,
            isIDR: isIDR,
            receivedAt: receivedAt,
            isLengthPrefixed: isLengthPrefixed)
        let ticket = mailbox.publish(accessUnit)
        mailboxStateLock.unlock()
        guard let ticket else { return }
        schedule(ticket)
    }

    private func schedule(_ ticket: DecodeTicket) {
        queue.async { [weak self] in
            self?.decode(ticket)
        }
    }

    private func decode(_ ticket: DecodeTicket) {
        if let expired = mailbox.expireIfNeeded(ticket) {
            if let next = expired.next { schedule(next) }
            return
        }
        guard mailbox.isCurrent(ticket) else {
            ticket.unit.owner.release()
            return
        }
        let accessUnit = ticket.unit
        onMailboxAge?(
            accessUnit.sequence,
            max(0, (CACurrentMediaTime() - accessUnit.receivedAt) * 1_000.0))
        let lifetime = DecodeSubmissionLifetime(
            owner: accessUnit.owner,
            sequence: accessUnit.sequence)
        let data = lifetime.owner.data
        guard !data.isEmpty else {
            finish(ticket, lifetime: lifetime, succeeded: false)
            return
        }
        guard activeCodec != .h264 || accessUnit.isIDR || hasDecodedH264Idr else {
            finish(ticket, lifetime: lifetime, succeeded: false)
            return
        }
        guard activeCodec != .hevc || !hevcKeyframeRequired || accessUnit.isIDR else {
            finish(ticket, lifetime: lifetime, succeeded: false)
            return
        }

        let ranges: [Range<Data.Index>]
        if accessUnit.isLengthPrefixed {
            guard let canonicalRanges = LengthPrefixedNALScanner.ranges(in: data) else {
                finish(ticket, lifetime: lifetime, succeeded: false)
                return
            }
            ranges = canonicalRanges
        } else {
            ranges = AnnexBNALScanner.ranges(in: data)
        }
        var frameRanges: [Range<Data.Index>] = []
        for range in ranges where !range.isEmpty {
            if activeCodec == .h264 {
                let nalType = data[range.lowerBound] & 0x1f
                switch nalType {
                case 7: spsData = Data(data[range])
                case 8: ppsData = Data(data[range])
                default: frameRanges.append(range)
                }
            } else {
                let nalType = (data[range.lowerBound] >> 1) & 0x3f
                switch nalType {
                case 32: vpsData = Data(data[range])
                case 33: spsData = Data(data[range])
                case 34: ppsData = Data(data[range])
                default: frameRanges.append(range)
                }
            }
        }
        if activeCodec == .hevc,
           let vps = vpsData, let sps = spsData, let pps = ppsData {
            let candidate = HevcParameterSetSignature(vps: vps, sps: sps, pps: pps)
            if candidate != activeParameterSetSignature {
                let decoder = self
                _ = parameterSetSessionGate.replaceIfChanged(
                    vps: vps,
                    sps: sps,
                    pps: pps) {
                    decoder.replaceDecompressionSession(vps: vps, sps: sps, pps: pps)
                }
            }
        } else if activeCodec == .h264,
                  let sps = spsData, let pps = ppsData {
            let candidate = H264ParameterSetSignature(sps: sps, pps: pps)
            if candidate != activeH264ParameterSetSignature {
                let decoder = self
                _ = h264ParameterSetSessionGate.replaceIfChanged(
                    sps: sps,
                    pps: pps) {
                    decoder.replaceH264DecompressionSession(sps: sps, pps: pps)
                }
            }
        }

        guard !frameRanges.isEmpty,
              let session = decompressionSession,
              let description = formatDescription else {
            finish(ticket, lifetime: lifetime, succeeded: false)
            return
        }

        let blockBuffer: CMBlockBuffer
        let sampleSize: Int
        if accessUnit.isLengthPrefixed {
            guard let frameRange = HevcCanonicalAccessUnit.frameRange(
                in: data,
                nalRanges: frameRanges),
                  let storage = RetainedDataBlockStorage(
                    lifetime: lifetime,
                    offset: data.distance(
                        from: data.startIndex,
                        to: frameRange.lowerBound)),
                  let retainedBlockBuffer = storage.makeBlockBuffer() else {
                finish(ticket, lifetime: lifetime, succeeded: false)
                return
            }
            blockBuffer = retainedBlockBuffer
            sampleSize = storage.dataLength
        } else {
            guard let storage = LengthPrefixedBlockStorage(
                lifetime: lifetime,
                ranges: frameRanges),
                  let convertedBlockBuffer = storage.makeBlockBuffer() else {
                finish(ticket, lifetime: lifetime, succeeded: false)
                return
            }
            blockBuffer = convertedBlockBuffer
            sampleSize = storage.bytes.length
        }

        var sampleBuffer: CMSampleBuffer?
        var mutableSampleSize = sampleSize
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: description,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &mutableSampleSize,
            sampleBufferOut: &sampleBuffer)
        guard sampleStatus == noErr, let sampleBuffer else {
            finish(ticket, lifetime: lifetime, succeeded: false)
            return
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = kCFBooleanTrue
        }

        var infoFlags = VTDecodeInfoFlags()
        let decodeStartedAt = CACurrentMediaTime()
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let expectedWidth = Int(dimensions.width)
        let expectedHeight = Int(dimensions.height)
        guard expectedWidth > 0, expectedHeight > 0 else {
            finish(ticket, lifetime: lifetime, succeeded: false, decodeStartedAt: decodeStartedAt)
            return
        }
        let submission = VideoDecodeSubmission(
            ticket: ticket,
            lifetime: lifetime,
            decodeStartedAt: decodeStartedAt,
            expectedWidth: expectedWidth,
            expectedHeight: expectedHeight)
        let frameRefCon = Unmanaged.passRetained(submission).toOpaque()
        // Async is enabled, while temporal processing is deliberately omitted:
        // VideoToolbox therefore has no permission to delay output for reorder.
        let decodeFlags = VTDecodeFrameFlags(rawValue: 1 << 0)
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: decodeFlags,
            frameRefcon: frameRefCon,
            infoFlagsOut: &infoFlags)
        if status != noErr {
            let failed = Unmanaged<VideoDecodeSubmission>
                .fromOpaque(frameRefCon).takeRetainedValue()
            finish(
                failed.ticket,
                lifetime: failed.lifetime,
                succeeded: false,
                decodeStartedAt: failed.decodeStartedAt)
        }
    }

    private func replaceDecompressionSession(
        vps: Data,
        sps: Data,
        pps: Data
    ) -> Bool {
        var candidateDescription: CMVideoFormatDescription?
        var candidateSession: VTDecompressionSession?

        vps.withUnsafeBytes { vpsBuffer in
            sps.withUnsafeBytes { spsBuffer in
                pps.withUnsafeBytes { ppsBuffer in
                    guard let vpsBase = vpsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let spsBase = spsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let ppsBase = ppsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    else { return }
                    var pointers: [UnsafePointer<UInt8>] = [vpsBase, spsBase, ppsBase]
                    var sizes = [vps.count, sps.count, pps.count]
                    let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: &pointers,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &candidateDescription)
                    guard status == noErr, let description = candidateDescription else {
                        print("[DecoderManager] HEVC format rejected: \(status)")
                        return
                    }

                    var callback = VTDecompressionOutputCallbackRecord(
                        decompressionOutputCallback: {
                            outputRefCon, sourceFrameRefCon, status, _, imageBuffer, _, _ in
                            guard let sourceFrameRefCon else { return }
                            let submission = Unmanaged<VideoDecodeSubmission>
                                .fromOpaque(sourceFrameRefCon).takeRetainedValue()
                            let lifetime = submission.lifetime
                            guard let outputRefCon else {
                                lifetime.finish()
                                return
                            }
                            let decoder = Unmanaged<DecoderManager>
                                .fromOpaque(outputRefCon).takeUnretainedValue()
                            guard status == noErr, let imageBuffer else {
                                decoder.finish(
                                    submission.ticket,
                                    lifetime: lifetime,
                                    succeeded: false,
                                    decodeStartedAt: submission.decodeStartedAt)
                                return
                            }
                            let pixelBuffer = imageBuffer as CVPixelBuffer
                            if let reason = DecoderOutputBufferAttributes.invalidReason(
                                for: pixelBuffer,
                                expectedWidth: submission.expectedWidth,
                                expectedHeight: submission.expectedHeight) {
                                print("[DecoderManager] HEVC decoded buffer rejected: \(reason)")
                                decoder.finish(
                                    submission.ticket,
                                    lifetime: lifetime,
                                    succeeded: false,
                                    decodeStartedAt: submission.decodeStartedAt)
                                return
                            }
                            decoder.finish(
                                submission.ticket,
                                lifetime: lifetime,
                                succeeded: true,
                                decodeStartedAt: submission.decodeStartedAt,
                                imageBuffer: pixelBuffer)
                        },
                        decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
                    let sessionStatus = VTDecompressionSessionCreate(
                        allocator: kCFAllocatorDefault,
                        formatDescription: description,
                        decoderSpecification: nil,
                        imageBufferAttributes: DecoderOutputBufferAttributes.make() as CFDictionary,
                        outputCallback: &callback,
                        decompressionSessionOut: &candidateSession)
                    guard sessionStatus == noErr, candidateSession != nil else {
                        print("[DecoderManager] session creation rejected: \(sessionStatus)")
                        if let failedSession = candidateSession {
                            VTDecompressionSessionInvalidate(failedSession)
                        }
                        candidateSession = nil
                        return
                    }
                }
            }
        }
        guard let description = candidateDescription,
              let session = candidateSession else {
            return false
        }

        let previousSession = decompressionSession
        formatDescription = description
        decompressionSession = session
        hevcKeyframeRequired = true
        setPropertyIfSupported(
            session,
            key: kVTDecompressionPropertyKey_RealTime,
            value: kCFBooleanTrue,
            name: "real-time")
        if let previousSession {
            VTDecompressionSessionWaitForAsynchronousFrames(previousSession)
            VTDecompressionSessionInvalidate(previousSession)
        }
        return true
    }

    private func replaceH264DecompressionSession(sps: Data, pps: Data) -> Bool {
        var description: CMVideoFormatDescription?
        let formatStatus = sps.withUnsafeBytes { spsBuffer in
            pps.withUnsafeBytes { ppsBuffer -> OSStatus in
                guard let spsBase = spsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return -1 }
                var pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description)
            }
        }
        guard formatStatus == noErr, let description else {
            print("[DecoderManager] H264 format rejected: \(formatStatus)")
            return false
        }
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { outputRefCon, sourceFrameRefCon, status, _, imageBuffer, _, _ in
                guard let sourceFrameRefCon else { return }
                let submission = Unmanaged<VideoDecodeSubmission>
                    .fromOpaque(sourceFrameRefCon).takeRetainedValue()
                guard let outputRefCon else { submission.lifetime.finish(); return }
                let decoder = Unmanaged<DecoderManager>.fromOpaque(outputRefCon).takeUnretainedValue()
                guard status == noErr, let imageBuffer else {
                    decoder.finish(submission.ticket, lifetime: submission.lifetime, succeeded: false, decodeStartedAt: submission.decodeStartedAt)
                    return
                }
                let pixelBuffer = imageBuffer as CVPixelBuffer
                if let reason = DecoderOutputBufferAttributes.invalidReason(
                    for: pixelBuffer,
                    expectedWidth: submission.expectedWidth,
                    expectedHeight: submission.expectedHeight) {
                    print("[DecoderManager] H264 decoded buffer rejected: \(reason)")
                    decoder.finish(submission.ticket, lifetime: submission.lifetime, succeeded: false, decodeStartedAt: submission.decodeStartedAt)
                    return
                }
                decoder.finish(submission.ticket, lifetime: submission.lifetime, succeeded: true, decodeStartedAt: submission.decodeStartedAt, imageBuffer: pixelBuffer)
            }, decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        var session: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: nil, imageBufferAttributes: DecoderOutputBufferAttributes.make() as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &session)
        guard sessionStatus == noErr, let session else {
            print("[DecoderManager] H264 session rejected: \(sessionStatus)")
            return false
        }
        let previous = decompressionSession
        formatDescription = description
        decompressionSession = session
        setPropertyIfSupported(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue, name: "real-time")
        if let previous {
            VTDecompressionSessionWaitForAsynchronousFrames(previous)
            VTDecompressionSessionInvalidate(previous)
        }
        return true
    }

    private func setPropertyIfSupported(
        _ session: VTDecompressionSession,
        key: CFString,
        value: CFTypeRef,
        name: String
    ) {
        var supported: CFDictionary?
        let queryStatus = VTSessionCopySupportedPropertyDictionary(
            session,
            supportedPropertyDictionaryOut: &supported)
        guard queryStatus == noErr,
              let dictionary = supported as NSDictionary?,
              dictionary.object(forKey: key) != nil else {
            print("[DecoderManager] \(name) property unsupported; using fallback.")
            return
        }
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            print("[DecoderManager] \(name) property rejected (\(status)); using fallback.")
        }
    }

    private func finish(
        _ ticket: DecodeTicket,
        lifetime: DecodeSubmissionLifetime,
        succeeded: Bool,
        decodeStartedAt: TimeInterval? = nil,
        imageBuffer: CVPixelBuffer? = nil
    ) {
        let completion = mailbox.complete(ticket, succeeded: succeeded)
        if succeeded, activeCodec == .h264, ticket.unit.isIDR {
            hasDecodedH264Idr = true
        }
        let delivered =
            completion.disposition == .deliver && imageBuffer != nil
        emitCompletion(for: ticket.unit.owner, succeeded: delivered)
        if delivered, let imageBuffer, let decodeStartedAt {
            onDecodeLatency?(
                lifetime.sequence,
                ticket.sessionGeneration,
                decodeStartedAt,
                (CACurrentMediaTime() - decodeStartedAt) * 1_000.0)
            onFrameDecoded?(
                imageBuffer,
                lifetime.sequence,
                ticket.sessionGeneration)
            if activeCodec == .hevc, ticket.unit.isIDR {
                hevcKeyframeRequired = false
            }
        }
        lifetime.finish()
        if let next = completion.next {
            schedule(next)
        }
    }

    public func invalidate() {
        mailboxStateLock.lock()
        mailbox.invalidate()
        mailboxStateLock.unlock()
        queue.sync {
            if let session = decompressionSession {
                VTDecompressionSessionWaitForAsynchronousFrames(session)
                VTDecompressionSessionInvalidate(session)
                decompressionSession = nil
            }
            formatDescription = nil
            vpsData = nil
            spsData = nil
            ppsData = nil
            activeCodec = .hevc
            hevcKeyframeRequired = false
            hasDecodedH264Idr = false
            parameterSetSessionGate.reset()
            h264ParameterSetSessionGate.reset()
        }
    }

    private func makeMailbox() -> AccessUnitMailbox {
        AccessUnitMailbox(
            onRecoveryNeeded: { [weak self] in self?.onRecoveryNeeded?() },
            onDrop: { [weak self] sequence, generation, _ in
                self?.onFrameDropped?(sequence, generation)
            })
    }

    private func completionIdentity(
        for owner: AccessUnitOwner
    ) -> DecodeCompletionIdentity? {
        completionIdentityLock.lock()
        defer { completionIdentityLock.unlock() }
        return completionIdentities[ObjectIdentifier(owner)]
    }

    private func emitCompletion(
        for owner: AccessUnitOwner,
        succeeded: Bool
    ) {
        guard let identity = completionIdentity(for: owner) else { return }
        emitCompletion(
            identity,
            ownerIdentifier: ObjectIdentifier(owner),
            succeeded: succeeded)
    }

    private func emitCompletion(
        _ identity: DecodeCompletionIdentity,
        ownerIdentifier: ObjectIdentifier,
        succeeded: Bool
    ) {
        guard identity.claimEmission() else { return }
        completionIdentityLock.lock()
        if completionIdentities[ownerIdentifier] === identity {
            completionIdentities.removeValue(forKey: ownerIdentifier)
        }
        completionIdentityLock.unlock()
        onDecodeCompleted?(
            identity.sequence,
            identity.sessionGeneration,
            succeeded)
    }
}
