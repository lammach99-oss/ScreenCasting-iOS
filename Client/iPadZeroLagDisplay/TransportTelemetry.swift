import Foundation
import QuartzCore

/// SCST VideoFeedback header flags.  The 16-byte v1 payload is unchanged so
/// old hosts continue to parse it; new hosts use these flags to distinguish an
/// unavailable stage from a valid zero-millisecond observation.
enum VideoFeedbackValidityFlags {
    static let frameReceive: UInt16 = 1 << 8
    static let decode: UInt16 = 1 << 9
    static let queue: UInt16 = 1 << 10
    static let presentation: UInt16 = 1 << 11
}

public struct TransportHudSnapshot: Equatable {
    public let frameReceiveMs: Double
    public let decodeMs: Double
}

enum StreamingTransportKind: String, Equatable {
    case wifi
    case usbTypeC = "usb_type_c"
}

enum UsbQualificationRttState: Equatable {
    case notAuthenticatedUsbGeneration
    case pending
    case qualified
    case rejectedMissingNonceMatchedRtt
}

struct TransportTelemetryContext: Equatable {
    var transportKind: StreamingTransportKind = .wifi
    var transportBackend: String = "network_framework"
    var connectionGeneration: UInt64 = 0
    var udidSha256_12: String = ""
    var tunnelStartMs: Double = 0
    var tlsMs: Double = 0
    var authMs: Double = 0
    var reconnectMs: Double = 0
    var helperExitCode: Int32?
    var helperRestartCount: UInt32 = 0
}

struct LatencyPercentiles: Equatable {
    let p50: Double
    let p95: Double
    let p99: Double

    static func calculate<S: Sequence>(_ samples: S) -> LatencyPercentiles
    where S.Element == Double {
        let ordered = samples
            .filter { $0.isFinite && $0 >= 0 }
            .sorted()
        guard !ordered.isEmpty else {
            return LatencyPercentiles(p50: 0, p95: 0, p99: 0)
        }
        func nearestRank(_ percentile: Double) -> Double {
            let rank = Int(ceil(percentile * Double(ordered.count)))
            return ordered[min(ordered.count - 1, max(0, rank - 1))]
        }
        return LatencyPercentiles(
            p50: nearestRank(0.50),
            p95: nearestRank(0.95),
            p99: nearestRank(0.99))
    }
}

enum LocalTelemetryStage: String, CaseIterable, Hashable {
    case captureAcquired
    case conversionSubmitted
    case conversionCompleted
    case encodeCompleted
    case transportEnqueued
    case firstPacketSent
    case lastPacketSent
    case firstPacketReceived
    case lastPacketReceived
    case reassemblyCompleted
    case reassemblyExpired
    case dropped
    case decodeSubmitted
    case decodeCallback
    case drawableCommitted
    case commandBufferCompleted
}

struct FrameTelemetryDimensions: Equatable {
    let sessionGeneration: UInt64
    let transportKind: String
    let frameSequence: UInt32
    let isIDR: Bool
    let queueDepth: Int
    let packetCount: Int
    let bytes: Int
    let lossCount: Int
    let rttMilliseconds: Double
    let routeKind: String
}

struct LocalStageRecord {
    /// Names the local monotonic epoch. Production uses "ipad"; imported host
    /// records use "host" and are correlated by sequence without clock math.
    let clockDomain: String
    let stage: LocalTelemetryStage
    let monotonicTime: TimeInterval
    let dimensions: FrameTelemetryDimensions
}

struct SequenceLatencyReport {
    let dimensions: FrameTelemetryDimensions
    let localDurationsMilliseconds: [String: Double]
}

final class SequenceLatencyReporter {
    private struct FrameKey: Hashable {
        let generation: UInt64
        let sequence: UInt32
    }

    private struct StageKey: Hashable {
        let clock: String
        let stage: LocalTelemetryStage
    }

    private struct PendingFrame {
        var dimensions: FrameTelemetryDimensions
        var times: [StageKey: TimeInterval] = [:]
        var csvWritten = false
    }

    private static let durationPairs: [
        (String, String, LocalTelemetryStage, LocalTelemetryStage)
    ] = [
        ("host.capture_to_conversion_submit", "host.native",
         .captureAcquired, .conversionSubmitted),
        ("host.conversion", "host.native",
         .conversionSubmitted, .conversionCompleted),
        ("host.conversion_to_encode", "host.native",
         .conversionCompleted, .encodeCompleted),
        ("host.enqueue_to_first_packet", "host.managed",
         .transportEnqueued, .firstPacketSent),
        ("host.packet_send", "host.managed",
         .firstPacketSent, .lastPacketSent),
        ("ipad.packet_receive", "ipad",
         .firstPacketReceived, .lastPacketReceived),
        ("ipad.reassembly", "ipad",
         .lastPacketReceived, .reassemblyCompleted),
        ("ipad.reassembly_expiry", "ipad",
         .lastPacketReceived, .reassemblyExpired),
        ("ipad.reassembly_to_decode_submit", "ipad",
         .reassemblyCompleted, .decodeSubmitted),
        ("ipad.decode", "ipad",
         .decodeSubmitted, .decodeCallback),
        ("ipad.decode_to_drawable_commit", "ipad",
         .decodeCallback, .drawableCommitted),
        ("ipad.command_buffer", "ipad",
         .drawableCommitted, .commandBufferCompleted),
    ]

    private let lock = NSLock()
    private let capacity: Int
    private var frames: [FrameKey: PendingFrame] = [:]
    private var insertionOrder: [FrameKey] = []
    private var pendingCsvRows: [String] = []

    static let csvHeader = [
        "session_generation", "transport_kind", "frame_sequence", "is_idr",
        "queue_depth", "packet_count", "bytes", "loss", "rtt_ms",
        "route_kind"
    ] + LocalTelemetryStage.allCases.map { "\($0.rawValue)_local_ms" } +
        durationPairs.map { "\($0.0)_ms" }

    init(capacity: Int = 4_096) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    func record(_ record: LocalStageRecord) {
        precondition(!record.clockDomain.isEmpty)
        precondition(record.monotonicTime.isFinite &&
                     record.monotonicTime >= 0)
        let key = FrameKey(
            generation: record.dimensions.sessionGeneration,
            sequence: record.dimensions.frameSequence)
        lock.lock()
        defer { lock.unlock() }
        if frames[key] == nil {
            while frames.count >= capacity, !insertionOrder.isEmpty {
                frames.removeValue(forKey: insertionOrder.removeFirst())
            }
            frames[key] = PendingFrame(dimensions: record.dimensions)
            insertionOrder.append(key)
        }
        guard var frame = frames[key] else {
            preconditionFailure("Frame telemetry allocation failed")
        }
        frame.times[
            StageKey(clock: record.clockDomain, stage: record.stage)
        ] = record.monotonicTime
        if !frame.csvWritten &&
            (record.stage == .reassemblyExpired ||
             record.stage == .commandBufferCompleted ||
             record.stage == .dropped) {
            if pendingCsvRows.count >= capacity {
                pendingCsvRows.removeFirst()
            }
            pendingCsvRows.append(Self.csvRow(frame))
            frame.csvWritten = true
        }
        frames[key] = frame
    }

    func updateDimensions(_ dimensions: FrameTelemetryDimensions) {
        let key = FrameKey(
            generation: dimensions.sessionGeneration,
            sequence: dimensions.frameSequence)
        lock.lock()
        defer { lock.unlock() }
        guard var frame = frames[key] else { return }
        frame.dimensions = dimensions
        frames[key] = frame
    }

    func drainCsvRows() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let rows = pendingCsvRows
        pendingCsvRows.removeAll(keepingCapacity: true)
        return rows
    }

    func reset() {
        lock.lock()
        frames.removeAll(keepingCapacity: true)
        insertionOrder.removeAll(keepingCapacity: true)
        pendingCsvRows.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func snapshot() -> [SequenceLatencyReport] {
        lock.lock()
        defer { lock.unlock() }
        return insertionOrder.compactMap { key in
            guard let frame = frames[key] else { return nil }
            return SequenceLatencyReport(
                dimensions: frame.dimensions,
                localDurationsMilliseconds: Self.durations(frame))
        }
    }

    func percentileReport() -> [String: LatencyPercentiles] {
        lock.lock()
        defer { lock.unlock() }
        var samples: [String: [Double]] = [:]
        for frame in frames.values {
            for (name, duration) in Self.durations(frame) {
                samples[name, default: []].append(duration)
            }
        }
        return samples.mapValues { values in
            LatencyPercentiles.calculate(values)
        }
    }

    private static func durations(
        _ frame: PendingFrame
    ) -> [String: Double] {
        var result: [String: Double] = [:]
        for (name, clock, startStage, endStage) in durationPairs {
            guard let start = frame.times[
                    StageKey(clock: clock, stage: startStage)],
                  let end = frame.times[
                    StageKey(clock: clock, stage: endStage)],
                  end >= start else { continue }
            result[name] = (end - start) * 1_000.0
        }
        return result
    }

    private static func csvRow(_ frame: PendingFrame) -> String {
        let dimensions = frame.dimensions
        var fields = [
            String(dimensions.sessionGeneration),
            csv(dimensions.transportKind),
            String(dimensions.frameSequence),
            dimensions.isIDR ? "true" : "false",
            String(dimensions.queueDepth),
            String(dimensions.packetCount),
            String(dimensions.bytes),
            String(dimensions.lossCount),
            decimal(dimensions.rttMilliseconds),
            csv(dimensions.routeKind),
        ]
        for stage in LocalTelemetryStage.allCases {
            let value = frame.times[
                StageKey(clock: "ipad", stage: stage)
            ].map { decimal($0 * 1_000.0) } ?? ""
            fields.append(value)
        }
        let localDurations = durations(frame)
        for (name, _, _, _) in durationPairs {
            fields.append(localDurations[name].map(decimal) ?? "")
        }
        return fields.joined(separator: ",")
    }

    private static func csv(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func decimal(_ value: Double) -> String {
        String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            value)
    }
}

final class TransportTelemetry {
    struct SecurityDropSnapshot: Equatable {
        let authentication: UInt64
        let replay: UInt64
        let wrongEndpoint: UInt64
    }
    private struct TelemetryFrameKey: Hashable {
        let generation: UInt64
        let sequence: UInt32
    }

    private struct PacketStageState {
        var firstArrival: TimeInterval
        var lastArrival: TimeInterval
        var packetCount: Int
        var bytes: Int
        var isIDR: Bool
    }

    private struct RollingHistogram {
        var values: [Double] = []
        let capacity: Int
        private var nextReplacementIndex = 0

        init(capacity: Int = 256) {
            self.capacity = capacity
        }

        mutating func add(_ value: Double) {
            guard value.isFinite, value >= 0 else { return }
            if values.count < capacity {
                values.append(value)
            } else {
                values[nextReplacementIndex] = value
                nextReplacementIndex = (nextReplacementIndex + 1) % capacity
            }
        }

        func p95() -> UInt16 {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let index = min(
                sorted.count - 1,
                Int(ceil(Double(sorted.count) * 0.95)) - 1)
            return UInt16(clamping: Int(sorted[index].rounded()))
        }

        func p50() -> UInt16 {
            percentile(0.50)
        }

        func p99() -> UInt16 {
            percentile(0.99)
        }

        var count: Int { values.count }

        mutating func removeAll() {
            values.removeAll(keepingCapacity: true)
            nextReplacementIndex = 0
        }

        func summary() -> (count: Int, p50: Double?, p95: Double?, p99: Double?) {
            guard !values.isEmpty else { return (0, nil, nil, nil) }
            let sorted = values.sorted()
            func value(at fraction: Double) -> Double {
                let index = min(
                    sorted.count - 1,
                    Int(ceil(Double(sorted.count) * fraction)) - 1)
                return sorted[index]
            }
            return (sorted.count, value(at: 0.50), value(at: 0.95), value(at: 0.99))
        }

        private func percentile(_ fraction: Double) -> UInt16 {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let index = min(
                sorted.count - 1,
                Int(ceil(Double(sorted.count) * fraction)) - 1)
            return UInt16(clamping: Int(sorted[index].rounded()))
        }
    }

    private let lock = NSLock()
    private var receive = RollingHistogram()
    private var decode = RollingHistogram()
    private var mailboxAge = RollingHistogram()
    private var presentation = RollingHistogram()
    private var rtt = RollingHistogram()
    private var exportRtt = RollingHistogram(capacity: 4_096)
    private var exportReceive = RollingHistogram(capacity: 4_096)
    private var exportDecode = RollingHistogram(capacity: 4_096)
    private var exportPresentation = RollingHistogram(capacity: 4_096)
    // 262,144 samples retain more than 36 minutes at 120 FPS while keeping
    // cumulative percentile calculation bounded and exact for Task 8.
    private var sessionRtt = RollingHistogram(capacity: 262_144)
    private var sessionReceive = RollingHistogram(capacity: 262_144)
    private var sessionDecode = RollingHistogram(capacity: 262_144)
    private var sessionPresentation = RollingHistogram(capacity: 262_144)
    private var receiveTicks: [TelemetryFrameKey: TimeInterval] = [:]
    private var decodeCompleteTicks: [TelemetryFrameKey: TimeInterval] = [:]
    private var lastDecoded: UInt32 = 0
    private var lastPresented: UInt32 = 0
    private var droppedSinceFeedback: UInt16 = 0
    private var droppedSinceExport: UInt64 = 0
    private var totalDropped: UInt64 = 0
    private var wifiSecurityDrops = SecurityDropSnapshot(
        authentication: 0,
        replay: 0,
        wrongEndpoint: 0)
    private var latestBitrateMbps: Double = 20
    private let pendingLimit = 8
    private let fileQueue = DispatchQueue(label: "com.iPadCasting.telemetry-file", qos: .utility)
    private var exportTimer: DispatchSourceTimer?
    private var exportFileURL: URL?
    private var exportStartedAt: TimeInterval = 0
    private var sessionContext = TransportTelemetryContext()
    private var qualificationTransportKind: StreamingTransportKind?
    private var qualificationGeneration: UInt64 = 0
    private var qualificationAuthenticatedAt: TimeInterval = 0
    private var qualificationRttCount = 0
    private let sequenceReporter = SequenceLatencyReporter()
    private var packetStages: [TelemetryFrameKey: PacketStageState] = [:]
    private var frameDimensions:
        [TelemetryFrameKey: FrameTelemetryDimensions] = [:]
    private var frameOrder: [TelemetryFrameKey] = []
    private let frameCapacity = 4_096
    private var frameExportFileURL: URL?
    private var diagnosticExportFileURL: URL?

    func setSessionContext(_ context: TransportTelemetryContext) {
        precondition(
            context.udidSha256_12.isEmpty ||
            (context.udidSha256_12.count == 12 &&
             context.udidSha256_12.allSatisfy { $0.isHexDigit && !$0.isLowercase }),
            "USB telemetry identity must be a 12-character uppercase SHA-256 prefix")
        lock.lock()
        if sessionContext.connectionGeneration != context.connectionGeneration {
            packetStages.removeAll(keepingCapacity: true)
            frameDimensions.removeAll(keepingCapacity: true)
            frameOrder.removeAll(keepingCapacity: true)
        }
        sessionContext = context
        lock.unlock()
    }

    func recordWifiSecurityDrops(_ counters: WifiSecurityDropCounters) {
        lock.lock()
        wifiSecurityDrops = SecurityDropSnapshot(
            authentication: counters.authentication,
            replay: counters.replay,
            wrongEndpoint: counters.wrongEndpoint)
        lock.unlock()
    }

    func wifiSecurityDropSnapshot() -> SecurityDropSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return wifiSecurityDrops
    }

    func beginAuthenticatedGeneration(
        transportKind: StreamingTransportKind,
        connectionGeneration: UInt64,
        authenticatedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        lock.lock()
        if qualificationGeneration != connectionGeneration {
            packetStages.removeAll(keepingCapacity: true)
            frameDimensions.removeAll(keepingCapacity: true)
            frameOrder.removeAll(keepingCapacity: true)
        }
        qualificationTransportKind = transportKind
        qualificationGeneration = connectionGeneration
        qualificationAuthenticatedAt = authenticatedAt
        qualificationRttCount = 0
        lock.unlock()
    }

    func usbQualificationRttState(
        connectionGeneration: UInt64,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> UsbQualificationRttState {
        lock.lock()
        defer { lock.unlock() }
        guard qualificationTransportKind == .usbTypeC,
              qualificationGeneration == connectionGeneration else {
            return .notAuthenticatedUsbGeneration
        }
        if qualificationRttCount > 0 { return .qualified }
        return max(0, now - qualificationAuthenticatedAt) < 10
            ? .pending
            : .rejectedMissingNonceMatchedRtt
    }

    func recordPayloadReceived(
        sequence: UInt32,
        receiveDurationMs: Double,
        receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
        payloadBytes: Int = 0,
        isIDR: Bool = false,
        generation: UInt64? = nil,
        transportKind: String? = nil
    ) {
        lock.lock()
        receive.add(receiveDurationMs)
        exportReceive.add(receiveDurationMs)
        sessionReceive.add(receiveDurationMs)
        if receiveTicks.count >= pendingLimit,
           let oldest = receiveTicks.min(by: { $0.value < $1.value })?.key {
            receiveTicks.removeValue(forKey: oldest)
        }
        let resolvedGeneration =
            generation ?? sessionContext.connectionGeneration
        let key = TelemetryFrameKey(
            generation: resolvedGeneration,
            sequence: sequence)
        receiveTicks[key] = receivedAt
        let dimensions = makeDimensionsLocked(
            sequence: sequence,
            isIDR: isIDR,
            packetCount: 1,
            bytes: payloadBytes,
            generation: generation,
            transportKind: transportKind,
            routeKind: "legacy_tls")
        storeDimensionsLocked(dimensions)
        lock.unlock()
        sequenceReporter.record(LocalStageRecord(
            clockDomain: "ipad",
            stage: .firstPacketReceived,
            monotonicTime: receivedAt - receiveDurationMs / 1_000.0,
            dimensions: dimensions))
        sequenceReporter.record(LocalStageRecord(
            clockDomain: "ipad",
            stage: .lastPacketReceived,
            monotonicTime: receivedAt,
            dimensions: dimensions))
        sequenceReporter.record(LocalStageRecord(
            clockDomain: "ipad",
            stage: .reassemblyCompleted,
            monotonicTime: receivedAt,
            dimensions: dimensions))
    }

    func recordWifiPacket(
        sequence: UInt32,
        marker: Bool,
        isIDR: Bool,
        bytes: Int,
        arrivalTime: TimeInterval,
        generation: UInt64
    ) {
        let key = TelemetryFrameKey(
            generation: generation,
            sequence: sequence)
        lock.lock()
        var state = packetStages[key] ?? PacketStageState(
            firstArrival: arrivalTime,
            lastArrival: arrivalTime,
            packetCount: 0,
            bytes: 0,
            isIDR: false)
        state.firstArrival = min(state.firstArrival, arrivalTime)
        state.lastArrival = max(state.lastArrival, arrivalTime)
        state.packetCount += 1
        state.bytes += max(0, bytes)
        state.isIDR = state.isIDR || isIDR
        packetStages[key] = state
        let dimensions = makeDimensionsLocked(
            sequence: sequence,
            isIDR: state.isIDR,
            packetCount: state.packetCount,
            bytes: state.bytes,
            generation: generation,
            transportKind: StreamingTransportKind.wifi.rawValue,
            routeKind: "wifi_rtp")
        storeDimensionsLocked(dimensions)
        lock.unlock()
        sequenceReporter.updateDimensions(dimensions)
        _ = marker
    }

    func recordWifiReassembly(
        outcome: HevcReassemblyOutcome,
        observedAt: TimeInterval,
        generation: UInt64
    ) {
        let sequence: UInt32
        let stage: LocalTelemetryStage
        switch outcome {
        case .completed(_, let frameSequence, _):
            sequence = frameSequence
            stage = .reassemblyCompleted
        case .expired(let frameSequence):
            sequence = frameSequence
            stage = .reassemblyExpired
        default:
            return
        }
        let key = TelemetryFrameKey(
            generation: generation,
            sequence: sequence)
        lock.lock()
        let state = packetStages.removeValue(forKey: key)
        let dimensions = frameDimensions[key] ?? makeDimensionsLocked(
            sequence: sequence,
            isIDR: state?.isIDR ?? false,
            packetCount: state?.packetCount ?? 0,
            bytes: state?.bytes ?? 0,
            generation: generation,
            transportKind: StreamingTransportKind.wifi.rawValue,
            routeKind: "wifi_rtp")
        storeDimensionsLocked(dimensions)
        lock.unlock()
        sequenceReporter.updateDimensions(dimensions)
        if let state {
            sequenceReporter.record(LocalStageRecord(
                clockDomain: "ipad",
                stage: .firstPacketReceived,
                monotonicTime: state.firstArrival,
                dimensions: dimensions))
            sequenceReporter.record(LocalStageRecord(
                clockDomain: "ipad",
                stage: .lastPacketReceived,
                monotonicTime: state.lastArrival,
                dimensions: dimensions))
        }
        sequenceReporter.record(LocalStageRecord(
            clockDomain: "ipad",
            stage: stage,
            monotonicTime: observedAt,
            dimensions: dimensions))
        if stage == .reassemblyExpired {
            lock.lock()
            frameDimensions.removeValue(forKey: key)
            frameOrder.removeAll { $0 == key }
            lock.unlock()
        }
    }

    func recordDecodeSubmitted(
        sequence: UInt32,
        generation: UInt64,
        observedAt: TimeInterval
    ) {
        guard let dimensions = dimensions(
            for: sequence,
            generation: generation) else { return }
        sequenceReporter.record(LocalStageRecord(
            clockDomain: "ipad",
            stage: .decodeSubmitted,
            monotonicTime: observedAt,
            dimensions: dimensions))
    }

    func recordMailboxAge(sequence: UInt32, ageMs: Double) {
        lock.lock()
        mailboxAge.add(ageMs)
        lock.unlock()
    }

    func recordDropped(
        sequence: UInt32,
        generation: UInt64? = nil,
        observedAt: TimeInterval = CACurrentMediaTime()
    ) {
        let dimensions: FrameTelemetryDimensions?
        lock.lock()
        droppedSinceFeedback = droppedSinceFeedback == .max
            ? .max
            : droppedSinceFeedback + 1
        droppedSinceExport &+= 1
        totalDropped &+= 1
        if let generation {
            dimensions = frameDimensions[TelemetryFrameKey(
                generation: generation,
                sequence: sequence)]
        } else {
            dimensions = frameOrder.reversed().compactMap { key in
                key.sequence == sequence ? frameDimensions[key] : nil
            }.first
        }
        lock.unlock()
        if let dimensions {
            sequenceReporter.record(LocalStageRecord(
                clockDomain: "ipad",
                stage: .dropped,
                monotonicTime: observedAt,
                dimensions: dimensions))
        }
    }

    func recordDecodeCallback(
        sequence: UInt32,
        generation: UInt64,
        decodeStartedAt: TimeInterval,
        durationMs: Double
    ) {
        let callbackAt = CACurrentMediaTime()
        let key = TelemetryFrameKey(
            generation: generation,
            sequence: sequence)
        lock.lock()
        decode.add(durationMs)
        exportDecode.add(durationMs)
        sessionDecode.add(durationMs)
        receiveTicks.removeValue(forKey: key)
        if decodeCompleteTicks.count >= pendingLimit,
           let oldest = decodeCompleteTicks.min(by: { $0.value < $1.value })?.key {
            decodeCompleteTicks.removeValue(forKey: oldest)
        }
        decodeCompleteTicks[key] = callbackAt
        lastDecoded = sequence
        lock.unlock()
        if let dimensions = dimensions(
            for: sequence,
            generation: generation) {
            sequenceReporter.record(LocalStageRecord(
                clockDomain: "ipad",
                stage: .decodeSubmitted,
                monotonicTime: decodeStartedAt,
                dimensions: dimensions))
            sequenceReporter.record(LocalStageRecord(
                clockDomain: "ipad",
                stage: .decodeCallback,
                monotonicTime: callbackAt,
                dimensions: dimensions))
        }
    }

    func recordRenderDrop(sequence: UInt32, generation: UInt64) {
        recordDropped(sequence: sequence, generation: generation)
    }

    func recordRenderCompletion(sequence: UInt32, generation: UInt64) {
        let completedAt = CACurrentMediaTime()
        let key = TelemetryFrameKey(
            generation: generation,
            sequence: sequence)
        lock.lock()
        if let decodedAt = decodeCompleteTicks.removeValue(forKey: key) {
            let durationMs = max(0, (completedAt - decodedAt) * 1_000.0)
            presentation.add(durationMs)
            exportPresentation.add(durationMs)
            sessionPresentation.add(durationMs)
        }
        lastPresented = sequence
        lock.unlock()
        if let dimensions = dimensions(
            for: sequence,
            generation: generation) {
            sequenceReporter.record(LocalStageRecord(
                clockDomain: "ipad",
                stage: .commandBufferCompleted,
                monotonicTime: completedAt,
                dimensions: dimensions))
        }
        lock.lock()
        frameDimensions.removeValue(forKey: key)
        frameOrder.removeAll { $0 == key }
        lock.unlock()
    }

    func recordDrawableCommitted(sequence: UInt32, generation: UInt64) {
        guard let dimensions = dimensions(
            for: sequence,
            generation: generation) else { return }
        sequenceReporter.record(LocalStageRecord(
            clockDomain: "ipad",
            stage: .drawableCommitted,
            monotonicTime: CACurrentMediaTime(),
            dimensions: dimensions))
    }

    func recordRtt(durationMs: Double) {
        lock.lock()
        recordRttLocked(durationMs: durationMs)
        lock.unlock()
    }

    func recordAuthenticatedRtt(
        durationMs: Double,
        transportKind: StreamingTransportKind,
        connectionGeneration: UInt64,
        observedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        lock.lock()
        recordRttLocked(durationMs: durationMs)
        if transportKind == .usbTypeC,
           qualificationTransportKind == .usbTypeC,
           qualificationGeneration == connectionGeneration,
           observedAt >= qualificationAuthenticatedAt,
           observedAt - qualificationAuthenticatedAt <= 10,
           durationMs.isFinite,
           durationMs >= 0 {
            qualificationRttCount += 1
        }
        lock.unlock()
    }

    private func recordRttLocked(durationMs: Double) {
        rtt.add(durationMs)
        exportRtt.add(durationMs)
        sessionRtt.add(durationMs)
    }

    func recordBitrateMbps(_ bitrateMbps: Double) {
        guard bitrateMbps.isFinite, bitrateMbps >= 0 else { return }
        lock.lock()
        latestBitrateMbps = bitrateMbps
        lock.unlock()
    }

    /// Enqueues a logging restart and returns its planned URL immediately.
    /// `completion` runs on the utility queue after both headers are created,
    /// or with `nil` after setup fails.
    /// FileHandle writes are synchronous on that queue and are not cancellable;
    /// `stopLogging` is the ordered completion boundary for all queued writes.
    @discardableResult
    func startLogging(
        directoryURL: URL? = nil,
        summaryInterval: TimeInterval = 10,
        completion: ((URL?) -> Void)? = nil
    ) -> URL? {
        let directory = directoryURL ?? FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask).first
        guard let directory else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent(
            "ScreenCasting-Telemetry-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).csv")
        let frameURL = directory.appendingPathComponent(
            "ScreenCasting-Frame-Telemetry-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).csv")
        let diagnosticURL = directory.appendingPathComponent(
            "ScreenCasting-Diagnostics-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).log")
        fileQueue.async { [weak self] in
            guard let self else {
                completion?(nil)
                return
            }
            self.finishLogging(reason: "restart")
            self.resetSessionMetrics()
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true)
                try Self.csvHeader.write(to: url, atomically: true, encoding: .utf8)
                try (SequenceLatencyReporter.csvHeader.joined(separator: ",") + "\n")
                    .write(to: frameURL, atomically: true, encoding: .utf8)
                try "".write(to: diagnosticURL, atomically: true, encoding: .utf8)
                self.exportFileURL = url
                self.frameExportFileURL = frameURL
                self.diagnosticExportFileURL = diagnosticURL
                self.exportStartedAt = ProcessInfo.processInfo.systemUptime
                print("[TransportTelemetry] CSV log: \(url.lastPathComponent)")

                let timer = DispatchSource.makeTimerSource(queue: self.fileQueue)
                timer.schedule(
                    deadline: .now() + summaryInterval,
                    repeating: summaryInterval,
                    leeway: .milliseconds(250))
                timer.setEventHandler { [weak self] in
                    self?.appendSummary(reason: "periodic", cumulative: false)
                }
                timer.resume()
                self.exportTimer = timer
                completion?(url)
            } catch {
                print("[TransportTelemetry] Unable to create CSV log: \(error)")
                self.exportFileURL = nil
                self.frameExportFileURL = nil
                self.diagnosticExportFileURL = nil
                completion?(nil)
            }
        }
        return url
    }

    func recordDiagnosticLine(_ line: String) {
        fileQueue.async { [weak self] in
            self?.appendDiagnosticLine(line)
        }
    }

    /// Enqueues the final cumulative row after all earlier logging operations.
    /// Completion is invoked on the utility queue. The underlying synchronous
    /// file-system calls cannot be cancelled, so lifecycle callers must impose
    /// their own timeout if they need a bounded external wait.
    func stopLogging(completion: (() -> Void)? = nil) {
        let snapshot = takeExportSnapshot(cumulative: true)
        fileQueue.async { [weak self] in
            guard let self else {
                completion?()
                return
            }
            finishLogging(reason: "final", snapshot: snapshot)
            completion?()
        }
    }

    /// Flushes the current interval without ending the session. The timer uses
    /// the same path; this explicit hook is also suitable for app-background
    /// lifecycle events where preserving the latest interval is desirable.
    func flushIntervalSummary() {
        let snapshot = takeExportSnapshot(cumulative: false)
        fileQueue.async { [weak self] in
            guard let self else { return }
            appendSummary(
                reason: "periodic",
                cumulative: false,
                snapshot: snapshot)
        }
    }

    func makeFeedback(
        rttP95Ms: UInt16? = nil
    ) -> (UInt32, UInt32, UInt16, UInt16, UInt16, UInt16) {
        lock.lock()
        defer { lock.unlock() }
        let dropped = droppedSinceFeedback
        droppedSinceFeedback = 0
        return (
            lastPresented,
            lastDecoded,
            rttP95Ms ?? rtt.p95(),
            decode.p95(),
            mailboxAge.p95(),
            dropped)
    }

    /// v1 feedback has no receive-duration slot; preserve this local p95 for diagnostics.
    func receiveP95Ms() -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return receive.p95()
    }

    func frameStageP95Ms() -> (receive: UInt16, decode: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        return (receive.p95(), decode.p95())
    }

    func feedbackValidityFlags() -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        var flags: UInt16 = 0
        if receive.count > 0 { flags |= VideoFeedbackValidityFlags.frameReceive }
        if decode.count > 0 { flags |= VideoFeedbackValidityFlags.decode }
        if mailboxAge.count > 0 { flags |= VideoFeedbackValidityFlags.queue }
        if lastPresented != 0 { flags |= VideoFeedbackValidityFlags.presentation }
        return flags
    }

    func hudSnapshot() -> TransportHudSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return TransportHudSnapshot(
            frameReceiveMs: Double(receive.p95()),
            decodeMs: Double(decode.p95()))
    }

    /// Local frame stages are deliberately exposed separately from protocol RTT.
    func frameReceivePercentilesMs() -> (p50: UInt16, p95: UInt16, p99: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        return (receive.p50(), receive.p95(), receive.p99())
    }

    private struct ExportSnapshot {
        let context: TransportTelemetryContext
        let rtt: (count: Int, p50: Double?, p95: Double?, p99: Double?)
        let receive: (count: Int, p50: Double?, p95: Double?, p99: Double?)
        let decode: (count: Int, p50: Double?, p95: Double?, p99: Double?)
        let presentation: (count: Int, p50: Double?, p95: Double?, p99: Double?)
        let droppedInterval: UInt64
        let droppedTotal: UInt64
        let bitrateMbps: Double
        let securityDrops: SecurityDropSnapshot
    }

    private static let csvHeader = "timestamp_utc,elapsed_s,reason,transport_kind,transport_backend,connection_generation,udid_sha256_12,tunnel_start_ms,tls_ms,auth_ms,reconnect_ms,helper_exit_code,helper_restart_count,rtt_count,rtt_p50_ms,rtt_p95_ms,rtt_p99_ms,receive_count,receive_p50_ms,receive_p95_ms,receive_p99_ms,decode_count,decode_p50_ms,decode_p95_ms,decode_p99_ms,presentation_count,presentation_p50_ms,presentation_p95_ms,presentation_p99_ms,dropped_interval,dropped_total,bitrate_mbps,wifi_srtp_auth_drops,wifi_srtp_replay_drops,wifi_wrong_endpoint_drops\n"

    private func resetSessionMetrics() {
        sequenceReporter.reset()
        lock.lock()
        receive.removeAll()
        decode.removeAll()
        mailboxAge.removeAll()
        presentation.removeAll()
        rtt.removeAll()
        exportRtt.removeAll()
        exportReceive.removeAll()
        exportDecode.removeAll()
        exportPresentation.removeAll()
        sessionRtt.removeAll()
        sessionReceive.removeAll()
        sessionDecode.removeAll()
        sessionPresentation.removeAll()
        receiveTicks.removeAll(keepingCapacity: true)
        decodeCompleteTicks.removeAll(keepingCapacity: true)
        packetStages.removeAll(keepingCapacity: true)
        frameDimensions.removeAll(keepingCapacity: true)
        frameOrder.removeAll(keepingCapacity: true)
        lastDecoded = 0
        lastPresented = 0
        droppedSinceFeedback = 0
        droppedSinceExport = 0
        totalDropped = 0
        wifiSecurityDrops = SecurityDropSnapshot(
            authentication: 0,
            replay: 0,
            wrongEndpoint: 0)
        lock.unlock()
    }

    private func takeExportSnapshot(cumulative: Bool) -> ExportSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = ExportSnapshot(
            context: sessionContext,
            rtt: cumulative ? sessionRtt.summary() : exportRtt.summary(),
            receive: cumulative ? sessionReceive.summary() : exportReceive.summary(),
            decode: cumulative ? sessionDecode.summary() : exportDecode.summary(),
            presentation: cumulative ? sessionPresentation.summary() : exportPresentation.summary(),
            droppedInterval: cumulative ? totalDropped : droppedSinceExport,
            droppedTotal: totalDropped,
            bitrateMbps: latestBitrateMbps,
            securityDrops: wifiSecurityDrops)
        if !cumulative {
            exportRtt.removeAll()
            exportReceive.removeAll()
            exportDecode.removeAll()
            exportPresentation.removeAll()
            droppedSinceExport = 0
        }
        return snapshot
    }

    private func finishLogging(
        reason: String,
        snapshot: ExportSnapshot? = nil
    ) {
        guard exportFileURL != nil else { return }
        exportTimer?.cancel()
        exportTimer = nil
        appendSummary(
            reason: "\(reason)_cumulative",
            cumulative: true,
            snapshot: snapshot)
        appendFrameRows()
        exportFileURL = nil
        frameExportFileURL = nil
        diagnosticExportFileURL = nil
        exportStartedAt = 0
    }

    private func appendDiagnosticLine(_ line: String) {
        guard let url = diagnosticExportFileURL else { return }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            print("[TransportTelemetry] Unable to append diagnostic log: \(error)")
        }
    }

    private func appendSummary(
        reason: String,
        cumulative: Bool,
        snapshot suppliedSnapshot: ExportSnapshot? = nil
    ) {
        guard let url = exportFileURL else { return }
        let snapshot = suppliedSnapshot ??
            takeExportSnapshot(cumulative: cumulative)
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - exportStartedAt)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fields: [String] = [
            timestamp,
            Self.decimal(elapsed),
            reason,
            Self.csvString(snapshot.context.transportKind.rawValue),
            Self.csvString(snapshot.context.transportBackend),
            String(snapshot.context.connectionGeneration),
            Self.csvString(snapshot.context.udidSha256_12),
            Self.decimal(snapshot.context.tunnelStartMs),
            Self.decimal(snapshot.context.tlsMs),
            Self.decimal(snapshot.context.authMs),
            Self.decimal(snapshot.context.reconnectMs),
            snapshot.context.helperExitCode.map { String($0) } ?? "",
            String(snapshot.context.helperRestartCount),
            String(snapshot.rtt.count), Self.csv(snapshot.rtt.p50), Self.csv(snapshot.rtt.p95), Self.csv(snapshot.rtt.p99),
            String(snapshot.receive.count), Self.csv(snapshot.receive.p50), Self.csv(snapshot.receive.p95), Self.csv(snapshot.receive.p99),
            String(snapshot.decode.count), Self.csv(snapshot.decode.p50), Self.csv(snapshot.decode.p95), Self.csv(snapshot.decode.p99),
            String(snapshot.presentation.count), Self.csv(snapshot.presentation.p50), Self.csv(snapshot.presentation.p95), Self.csv(snapshot.presentation.p99),
            String(snapshot.droppedInterval),
            String(snapshot.droppedTotal),
            Self.decimal(snapshot.bitrateMbps),
            String(snapshot.securityDrops.authentication),
            String(snapshot.securityDrops.replay),
            String(snapshot.securityDrops.wrongEndpoint),
        ]
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((fields.joined(separator: ",") + "\n").utf8))
            appendFrameRows()
        } catch {
            print("[TransportTelemetry] Unable to append CSV summary: \(error)")
        }
    }

    private func appendFrameRows() {
        guard let url = frameExportFileURL else { return }
        let rows = sequenceReporter.drainCsvRows()
        guard !rows.isEmpty else { return }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(
                contentsOf: Data((rows.joined(separator: "\n") + "\n").utf8))
        } catch {
            print("[TransportTelemetry] Unable to append frame CSV: \(error)")
        }
    }

    private func dimensions(
        for sequence: UInt32,
        generation: UInt64
    ) -> FrameTelemetryDimensions? {
        lock.lock()
        defer { lock.unlock() }
        return frameDimensions[TelemetryFrameKey(
            generation: generation,
            sequence: sequence)]
    }

    private func storeDimensionsLocked(
        _ dimensions: FrameTelemetryDimensions
    ) {
        let key = TelemetryFrameKey(
            generation: dimensions.sessionGeneration,
            sequence: dimensions.frameSequence)
        if frameDimensions[key] == nil {
            while frameDimensions.count >= frameCapacity,
                  !frameOrder.isEmpty {
                let stale = frameOrder.removeFirst()
                frameDimensions.removeValue(forKey: stale)
                packetStages.removeValue(forKey: stale)
            }
            frameOrder.append(key)
        }
        frameDimensions[key] = dimensions
    }

    private func makeDimensionsLocked(
        sequence: UInt32,
        isIDR: Bool,
        packetCount: Int,
        bytes: Int,
        generation: UInt64?,
        transportKind: String?,
        routeKind: String
    ) -> FrameTelemetryDimensions {
        FrameTelemetryDimensions(
            sessionGeneration:
                generation ?? sessionContext.connectionGeneration,
            transportKind:
                transportKind ?? sessionContext.transportKind.rawValue,
            frameSequence: sequence,
            isIDR: isIDR,
            queueDepth: receiveTicks.count + decodeCompleteTicks.count,
            packetCount: packetCount,
            bytes: bytes,
            lossCount: Int(clamping: totalDropped),
            rttMilliseconds: Double(rtt.p95()),
            routeKind: routeKind)
    }

    private static func csv(_ value: Double?) -> String {
        value.map { decimal($0) } ?? ""
    }

    private static func csvString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func decimal(_ value: Double) -> String {
        String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            value)
    }
}
