import Foundation
import AVFoundation

struct AudioInterruptionDiagnosticMetadata {
    let fields: String

    init(userInfo: [AnyHashable: Any]?) {
        let info = userInfo ?? [:]
        let type = info[AVAudioSessionInterruptionTypeKey] as? UInt
        let reason = info[AVAudioSessionInterruptionReasonKey] as? UInt
        let suspended = info[AVAudioSessionInterruptionWasSuspendedKey] as? Bool
        let option = info[AVAudioSessionInterruptionOptionKey] as? UInt
        let event = type == AVAudioSession.InterruptionType.began.rawValue ? "began"
            : type == AVAudioSession.InterruptionType.ended.rawValue ? "ended" : "unknown"
        let resume = option.map {
            AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) ? "1" : "0"
        } ?? "unknown"
        fields = "event=\(event) interruption_type_present=\(info[AVAudioSessionInterruptionTypeKey] != nil ? 1 : 0) interruption_type_raw=\(type.map { String($0) } ?? "none") reason_key_present=\(info[AVAudioSessionInterruptionReasonKey] != nil ? 1 : 0) reason_raw=\(reason.map { String($0) } ?? "none") was_suspended_key_present=\(info[AVAudioSessionInterruptionWasSuspendedKey] != nil ? 1 : 0) was_suspended_value=\(suspended.map { $0 ? "1" : "0" } ?? "none") option_key_present=\(info[AVAudioSessionInterruptionOptionKey] != nil ? 1 : 0) option_raw=\(option.map { String($0) } ?? "none") should_resume=\(resume)"
    }
}

enum RealtimeAudioTimerPolicy {
    static func shouldRun(mode: UInt8, audioEnabled: Bool) -> Bool {
        audioEnabled &&
            (mode == RealtimeTransportMode.wifiRTP ||
             mode == RealtimeTransportMode.usbSplitTLS)
    }
}

// MARK: - AudioManager

enum AudioPlayoutDiagnosticEvent {
    case tick, nilTick, decode, plc, decodeFailure, pcmRejected, pcmScheduled, playerStart
}

struct AudioPlayoutDiagnostics {
    var ticks = 0
    var nilTicks = 0
    var decodeActions = 0
    var plcActions = 0
    var decodeFailures = 0
    var pcmQueueRejects = 0
    var pcmBuffersScheduled = 0
    var pcmFramesScheduled = 0
    var playerStarts = 0
    var lastPcmRejection: (generation: UInt64, epoch: UInt64, incoming: Int, queued: Int, cap: Int, playing: Bool, engine: Bool)?
    var pcmRejectionContext: String {
        guard let sample = lastPcmRejection else { return "pcm_reject_context=none" }
        return "pcm_reject_generation=\(sample.generation) pcm_reject_epoch=\(sample.epoch) pcm_reject_incoming_frames=\(sample.incoming) pcm_reject_queued_before=\(sample.queued) pcm_reject_cap=\(sample.cap) pcm_reject_player_playing=\(sample.playing ? 1 : 0) pcm_reject_engine_running=\(sample.engine ? 1 : 0)"
    }
    var playerRestarts: Int { max(0, playerStarts - 1) }
    mutating func record(_ event: AudioPlayoutDiagnosticEvent, frames: Int = 0) {
        switch event {
        case .tick: ticks += 1
        case .nilTick: nilTicks += 1
        case .decode: decodeActions += 1
        case .plc: plcActions += 1
        case .decodeFailure: decodeFailures += 1
        case .pcmRejected: pcmQueueRejects += 1
        case .pcmScheduled: pcmBuffersScheduled += 1; pcmFramesScheduled += frames
        case .playerStart: playerStarts += 1
        }
    }
}

/// Singleton that receives raw 16-bit / 48 kHz / Stereo PCM from the
/// ScreenCasting Windows host and plays it through the device's speaker
/// using AVAudioEngine + AVAudioPlayerNode.
///
/// Format contract (must match C# AudioManager.cs):
///   - commonFormat : .pcmFormatInt16
///   - sampleRate   : 48 000 Hz
///   - channels     : 2 (stereo, interleaved)
///
/// Thread-safety:
///   `playPCMData(_:)` is safe to call from any thread.
///   All AVAudioEngine operations are dispatched to `audioQueue`.

public final class AudioManager {

    // MARK: Singleton
    public static let shared = AudioManager()

    // MARK: Constants
    /// Sample rate advertised by the C# host.
    private let sampleRate: Double  = 48_000
    /// Number of audio channels.
    private let channelCount: AVAudioChannelCount = 2
    /// Bytes per sample for Int16 PCM.
    private let bytesPerSample = 2

    // MARK: AVAudioEngine pipeline
    private let engine      = AVAudioEngine()
    private let playerNode  = AVAudioPlayerNode()

    /// The exact format that matches the wire protocol.
    private let pcmFormat: AVAudioFormat

    // MARK: Private state
    private let audioQueue = DispatchQueue(
        label: "com.iPadCasting.audio",
        qos: .userInteractive)
    private var engineStarted = false
    private var queuedFrames = 0
    private let maxQueuedFrames = 9_600
    private var opusDecoder: RealtimeOpusDecoder?
    private var jitterBuffer = AudioJitterBuffer(profile: .wifi)
    private var realtimeGeneration: UInt64?
    private var playoutTimer: DispatchSourceTimer?
    private var playbackEpoch: UInt64 = 0
    private var activePlaybackGeneration: UInt64?
    private var interruptedPlaybackEpoch: UInt64?
    private var playbackInterrupted = false
    private var legacyLifecycleSuspendedGeneration: UInt64?
    private var legacyLifecycleFreshFenceSatisfiedGeneration: UInt64?
    private var pendingLegacyLifecycleDiagnostics: [String] = []
    private var audioDiagnosticEventSequence: UInt64 = 0
    private var legacyLifecycleDropCount: UInt64 = 0
    private var legacyResumeFenceDropCount: UInt64 = 0
    private var receiveDiagnostics = AudioReceiveDiagnostics()
    private var playoutDiagnostics = AudioPlayoutDiagnostics()
    private var pcmCompletionCount: UInt64 = 0
    private var playoutRecoveryCount: UInt64 = 0
    private var realtimeProfile: RealtimeAudioTransportProfile?
    private var lastPcmProgressAt: TimeInterval?
    private var lastAnyRecoveryAt: TimeInterval?
    private var pendingRecoveryDiagnostic: String?
    private var engineObservers: [NSObjectProtocol] = []
    private let recoveryOwnerLock = NSLock()
    private var recoveryOwner: (generation: UInt64, epoch: UInt64, profile: RealtimeAudioTransportProfile)?

    #if targetEnvironment(simulator)
    var interruptionResumeForTesting: (() -> Void)?
    var engineStartForTesting: (() -> Void)?
    var engineRunningForTesting: (() -> Bool)?
    var clockForTesting: (() -> TimeInterval)?
    var pcmScheduleForTesting: ((Int, @escaping () -> Void) -> Void)?
    var manualPlayoutForTesting = false
    var engineForTesting: AVAudioEngine { engine }
    var cachedEngineStartedForTesting: Bool {
        get { audioQueue.sync { engineStarted } }
        set { audioQueue.sync { engineStarted = newValue } }
    }
    var playbackStateForTesting: (epoch: UInt64, generation: UInt64?, queued: Int, completions: UInt64, recoveries: UInt64) {
        audioQueue.sync { (playbackEpoch, activePlaybackGeneration, queuedFrames, pcmCompletionCount, playoutRecoveryCount) }
    }
    func startEngineForTesting() { audioQueue.sync { startEngineIfNeeded() } }
    func playoutTickForTesting() { audioQueue.sync { playoutTick() } }
    var audioQueueForTesting: DispatchQueue { audioQueue }

    static func makeForTesting() -> AudioManager { AudioManager() }

    var interruptionStateForTesting: (queuedFrames: Int, packets: Int, timerActive: Bool) {
        audioQueue.sync { (queuedFrames, jitterBuffer.bufferedPacketCount, playoutTimer != nil) }
    }

    func interruptForTesting(began: Bool, shouldResume: Bool = true) {
        handleInterruption(Notification(
            name: AVAudioSession.interruptionNotification,
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    (began ? AVAudioSession.InterruptionType.began : .ended).rawValue,
                AVAudioSessionInterruptionOptionKey:
                    shouldResume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : UInt(0)
            ]))
        audioQueue.sync { }
    }

    func interruptionNotificationForTesting(userInfo: [AnyHashable: Any]?) {
        handleInterruption(Notification(name: AVAudioSession.interruptionNotification, userInfo: userInfo))
        audioQueue.sync { }
    }
    #endif

    // MARK: Init
    private init() {
        guard let fmt = AVAudioFormat(
            commonFormat : .pcmFormatInt16,
            sampleRate   : sampleRate,
            channels     : channelCount,
            interleaved  : true)
        else {
            fatalError("[AudioManager] Failed to create AVAudioFormat — impossible on iOS.")
        }
        pcmFormat = fmt
        setupEngine()
    }

    // MARK: - Engine Setup

    private func setupEngine() {
        for (name, object, reason): (Notification.Name, AnyObject?, String) in [
            (.AVAudioEngineConfigurationChange, engine, "engine_configuration"),
            (AVAudioSession.routeChangeNotification, nil, "route_change")
        ] {
            engineObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
                guard let self, let owner = self.captureRecoveryOwner() else { return }
                self.audioQueue.async { [weak self] in
                    self?.reprimeRealtimeOnQueue(generation: owner.generation, epoch: owner.epoch, profile: owner.profile, reason: reason, automatic: true)
                }
            })
        }
        #if !targetEnvironment(simulator)
        engine.attach(playerNode)

        // Connect playerNode to mainMixerNode using our target format.
        // The mixer converts to the hardware format automatically.
        engine.connect(
            playerNode,
            to   : engine.mainMixerNode,
            format: pcmFormat)

        // Prepare but don't start yet - startEngineIfNeeded() handles that.
        engine.prepare()

        // Listen for audio session interruptions (phone calls, Siri, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector : #selector(handleInterruption(_:)),
            name     : AVAudioSession.interruptionNotification,
            object   : nil)

        // Configure audio session for playback
        configureAudioSession()
        #endif
    }

    private func configureAudioSession() {
        #if !targetEnvironment(simulator)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("[AudioManager] Warning: AVAudioSession setup failed: \(error)")
        }
        #endif
    }

    private func startEngineIfNeeded() {
        guard !engineIsRunning else { engineStarted = true; return }
        #if targetEnvironment(simulator)
        if let start = engineStartForTesting { start(); engineStarted = engineIsRunning; return }
        #endif
        do {
            engine.prepare()
            try engine.start()
            engineStarted = engine.isRunning
            print("[AudioManager] AVAudioEngine started.")
        } catch {
            engineStarted = engine.isRunning
            print("[AudioManager] ⚠️ AVAudioEngine failed to start: \(error)")
        }
    }

    // MARK: - Public API

    func resumeCurrentRealtimeSession(generation: UInt64, profile: RealtimeAudioTransportProfile) {
        guard case .wifi = profile, let owner = captureRecoveryOwner(), owner.generation == generation,
              owner.profile == profile else { return }
        audioQueue.async { [weak self] in
            self?.reprimeRealtimeOnQueue(generation: generation, epoch: owner.epoch, profile: owner.profile, reason: "preserved_wifi_resume", automatic: false)
        }
    }

    private var engineIsRunning: Bool {
        #if targetEnvironment(simulator)
        if let read = engineRunningForTesting { return read() }
        #endif
        return engine.isRunning
    }

    private var playoutNow: TimeInterval {
        #if targetEnvironment(simulator)
        if let clock = clockForTesting { return clock() }
        #endif
        return ProcessInfo.processInfo.systemUptime
    }

    private func captureRecoveryOwner() -> (generation: UInt64, epoch: UInt64, profile: RealtimeAudioTransportProfile)? {
        recoveryOwnerLock.lock()
        defer { recoveryOwnerLock.unlock() }
        return recoveryOwner
    }

    private func publishRecoveryOwner() {
        recoveryOwnerLock.lock()
        defer { recoveryOwnerLock.unlock() }
        if let profile = realtimeProfile, let generation = realtimeGeneration,
           activePlaybackGeneration == generation, opusDecoder != nil, !playbackInterrupted {
            recoveryOwner = (generation, playbackEpoch, profile)
        } else {
            recoveryOwner = nil
        }
    }

    private func reprimeRealtimeOnQueue(generation: UInt64, epoch: UInt64, profile: RealtimeAudioTransportProfile, reason: String, automatic: Bool) {
        guard playbackEpoch == epoch, activePlaybackGeneration == generation,
              realtimeGeneration == generation, realtimeProfile == profile,
              opusDecoder != nil, !playbackInterrupted else { return }
        let now = playoutNow
        if automatic, let last = lastAnyRecoveryAt, now - last < 1 { return }
        lastAnyRecoveryAt = now
        let queued = queuedFrames
        let age = lastPcmProgressAt.map { max(0, now - $0) * 1000 } ?? 0
        playbackEpoch &+= 1
        publishRecoveryOwner()
        playerNode.stop()
        playerNode.reset()
        queuedFrames = 0
        lastPcmProgressAt = nil
        jitterBuffer.reset(profile: profile)
        configureAudioSession()
        startEngineIfNeeded()
        if playoutTimer == nil { startPlayoutTimer() }
        playoutRecoveryCount &+= 1
        let line = "[AUDIO_PLAYOUT_RECOVERY] reason=\(reason) generation=\(generation) old_epoch=\(epoch) new_epoch=\(playbackEpoch) queued_frames=\(queued) completion_age_ms=\(age) engine_running=\(engineIsRunning ? 1 : 0) player_playing=\(playerNode.isPlaying ? 1 : 0)"
        pendingRecoveryDiagnostic = line
        print(line)
    }

    deinit {
        engineObservers.forEach(NotificationCenter.default.removeObserver)
        NotificationCenter.default.removeObserver(self)
        playoutTimer?.cancel()
    }

    func beginRealtimeSession(
        generation: UInt64,
        profile: RealtimeAudioTransportProfile
    ) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.playbackEpoch &+= 1
            self.activePlaybackGeneration = nil
            self.interruptedPlaybackEpoch = nil
            self.playbackInterrupted = false
            self.playerNode.stop()
            self.playerNode.reset()
            self.queuedFrames = 0
            self.playoutTimer?.cancel()
            self.playoutTimer = nil
            self.jitterBuffer.reset(profile: profile)
            self.receiveDiagnostics = AudioReceiveDiagnostics()
            self.playoutDiagnostics = AudioPlayoutDiagnostics()
            self.opusDecoder = nil
            do {
                self.realtimeProfile = profile
                self.lastPcmProgressAt = nil
                self.lastAnyRecoveryAt = nil
                self.pendingRecoveryDiagnostic = nil
                self.pcmCompletionCount = 0
                self.playoutRecoveryCount = 0
                self.opusDecoder = try RealtimeOpusDecoder()
                self.realtimeGeneration = generation
                self.activePlaybackGeneration = generation
                self.publishRecoveryOwner()
                self.startPlayoutTimer()
            } catch {
                self.realtimeGeneration = nil
                self.publishRecoveryOwner()
                print("[AudioManager] Opus decoder setup failed: \(error)")
            }
        }
    }

    func beginLegacySession(generation: UInt64) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            if self.activePlaybackGeneration == generation,
               self.realtimeGeneration == nil, !self.playbackInterrupted { return }
            self.playbackEpoch &+= 1
            self.activePlaybackGeneration = generation
            self.interruptedPlaybackEpoch = nil
            self.playbackInterrupted = false
            self.legacyLifecycleSuspendedGeneration = nil
            self.legacyLifecycleFreshFenceSatisfiedGeneration = nil
            self.legacyLifecycleDropCount = 0
            self.legacyResumeFenceDropCount = 0
            self.playerNode.stop()
            self.playerNode.reset()
            self.queuedFrames = 0
            self.playoutTimer?.cancel()
            self.playoutTimer = nil
            self.jitterBuffer.reset()
            self.opusDecoder = nil
            self.realtimeGeneration = nil
            self.realtimeProfile = nil
            self.lastPcmProgressAt = nil
            self.lastAnyRecoveryAt = nil
            self.pendingRecoveryDiagnostic = nil
            self.pcmCompletionCount = 0
            self.playoutRecoveryCount = 0
            self.publishRecoveryOwner()
            self.receiveDiagnostics = AudioReceiveDiagnostics()
            self.playoutDiagnostics = AudioPlayoutDiagnostics()
        }
    }

    func suspendLegacySessionForLifecycle(generation: UInt64) {
        audioQueue.async { [weak self] in
            guard let self, self.activePlaybackGeneration == generation,
                  self.realtimeGeneration == nil,
                  self.legacyLifecycleSuspendedGeneration != generation else { return }
            self.legacyLifecycleSuspendedGeneration = generation
            self.legacyLifecycleFreshFenceSatisfiedGeneration = nil
            self.playbackEpoch &+= 1
            if self.playbackInterrupted { self.interruptedPlaybackEpoch = self.playbackEpoch }
            self.playerNode.stop()
            self.playerNode.reset()
            self.queuedFrames = 0
            self.lastPcmProgressAt = nil
            self.engine.pause()
            self.engineStarted = false
            self.recordLegacyLifecycleTransition(generation: generation, action: "suspend")
        }
    }

    func resumeLegacySessionAfterFreshFence(generation: UInt64) {
        audioQueue.async { [weak self] in
            guard let self, self.activePlaybackGeneration == generation,
                  self.realtimeGeneration == nil,
                  self.legacyLifecycleSuspendedGeneration == generation else { return }
            guard self.legacyLifecycleFreshFenceSatisfiedGeneration != generation else { return }
            self.legacyLifecycleFreshFenceSatisfiedGeneration = generation
            self.recordLegacyLifecycleTransition(generation: generation, action: "fresh_fence_satisfied")
            if self.playbackInterrupted {
                self.recordLegacyLifecycleTransition(generation: generation, action: "resume_deferred", detail: "reason=interruption_active")
            }
            self.completeLegacyLifecycleResumeIfReady(generation: generation, reason: "fresh_fence")
        }
    }

    @discardableResult
    private func completeLegacyLifecycleResumeIfReady(generation: UInt64, reason: String) -> Bool {
        guard activePlaybackGeneration == generation, realtimeGeneration == nil,
              legacyLifecycleSuspendedGeneration == generation,
              legacyLifecycleFreshFenceSatisfiedGeneration == generation,
              !playbackInterrupted else { return false }
        playbackEpoch &+= 1
        playerNode.stop()
        playerNode.reset()
        queuedFrames = 0
        lastPcmProgressAt = nil
        legacyLifecycleSuspendedGeneration = nil
        legacyLifecycleFreshFenceSatisfiedGeneration = nil
        configureAudioSession()
        startEngineIfNeeded()
        recordLegacyLifecycleTransition(generation: generation, action: "resume_complete", detail: "reason=\(reason)")
        return true
    }

    private func recordLegacyLifecycleTransition(generation: UInt64, action: String, detail: String = "") {
        let suspended = legacyLifecycleSuspendedGeneration.map { String($0) } ?? "none"
        let fence = legacyLifecycleFreshFenceSatisfiedGeneration.map { String($0) } ?? "none"
        let line = "[USB_PCM_LIFECYCLE] generation=\(generation) epoch=\(playbackEpoch) action=\(action) \(detail) playback_interrupted=\(playbackInterrupted ? 1 : 0) suspended_generation=\(suspended) fresh_fence_generation=\(fence) engine_running=\(engineIsRunning ? 1 : 0)"
        retainAudioLifecycleDiagnostic(line)
    }

    static var audioSessionDiagnosticFields: String {
        #if targetEnvironment(simulator)
        return "session_snapshot=simulator"
        #else
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        let types = outputs.map { $0.portType.rawValue }.joined(separator: ",")
        return "session_category=\(session.category.rawValue) session_mode=\(session.mode.rawValue) session_sample_rate=\(session.sampleRate) session_output_channels=\(session.outputNumberOfChannels) session_output_count=\(outputs.count) session_output_types=\(types.isEmpty ? "none" : types) secondary_audio_should_be_silenced=\(session.secondaryAudioShouldBeSilencedHint ? 1 : 0)"
        #endif
    }

    private func retainAudioLifecycleDiagnostic(_ line: String) {
        audioDiagnosticEventSequence &+= 1
        let timed = "\(line) audio_event_seq=\(audioDiagnosticEventSequence) uptime_ms=\(Int64(ProcessInfo.processInfo.systemUptime * 1000)) \(Self.audioSessionDiagnosticFields)"
        print(timed)
        pendingLegacyLifecycleDiagnostics.append(timed)
        if pendingLegacyLifecycleDiagnostics.count > 16 { pendingLegacyLifecycleDiagnostics.removeFirst() }
    }

    private func recordInterruptionDiagnostic(_ metadata: AudioInterruptionDiagnosticMetadata,
                                             receivedAt: Int64, phase: String) {
        // Audio ownership is observed only on audioQueue, never on the notification thread.
        retainAudioLifecycleDiagnostic("[USB_PCM_AUDIO_SESSION] phase=\(phase) notification_received_uptime_ms=\(receivedAt) \(metadata.fields) activePlaybackGeneration=\(activePlaybackGeneration.map { String($0) } ?? "none") realtimeGeneration=\(realtimeGeneration.map { String($0) } ?? "none") playbackEpoch=\(playbackEpoch) interruptedPlaybackEpoch=\(interruptedPlaybackEpoch.map { String($0) } ?? "none") playbackInterrupted=\(playbackInterrupted ? 1 : 0) legacyLifecycleSuspendedGeneration=\(legacyLifecycleSuspendedGeneration.map { String($0) } ?? "none") legacyLifecycleFreshFenceSatisfiedGeneration=\(legacyLifecycleFreshFenceSatisfiedGeneration.map { String($0) } ?? "none") engine_running=\(engineIsRunning ? 1 : 0) queued_frames=\(queuedFrames) pcm_scheduled=\(playoutDiagnostics.pcmBuffersScheduled) pcm_completed=\(pcmCompletionCount) pcm_reject=\(playoutDiagnostics.pcmQueueRejects)")
    }

    func recordLegacyResumeFenceDrop(generation: UInt64) {
        audioQueue.async { [weak self] in
            guard let self, self.activePlaybackGeneration == generation,
                  self.realtimeGeneration == nil else { return }
            self.legacyResumeFenceDropCount &+= 1
        }
    }

    func playOpusData(
        _ data: Data,
        sequence: UInt16,
        timestamp: UInt32,
        generation: UInt64
    ) {
        guard !data.isEmpty else { return }
        let arrivedAt = ProcessInfo.processInfo.systemUptime
        audioQueue.async { [weak self] in
            guard let self,
                  self.realtimeGeneration == generation,
                  self.activePlaybackGeneration == generation,
                  !self.playbackInterrupted else { return }
            self.receiveDiagnostics.record(sequence: sequence, timestamp: timestamp, arrivedAt: arrivedAt)
            self.jitterBuffer.insert(AudioJitterPacket(
                sequence: sequence,
                timestamp: timestamp,
                payload: data))
        }
    }

    /// Accepts a raw PCM `Data` blob from the network layer and schedules
    /// it for immediate playback on the AVAudioPlayerNode.
    ///
    /// - Parameter data: 16-bit / 48 kHz / Stereo / interleaved PCM bytes.
    ///   Must be non-empty and byte-aligned to 4 bytes (2 ch × 2 bytes/sample).
    public func playPCMData(_ data: Data, generation: UInt64? = nil) {
        enqueuePCMData(data, generation: generation, expectedEpoch: nil)
    }

    private func enqueuePCMData(_ data: Data, generation: UInt64?, expectedEpoch: UInt64?) {
        guard !data.isEmpty else { return }

        audioQueue.async { [weak self] in
            guard let self, self.activePlaybackGeneration != nil,
                  !self.playbackInterrupted,
                  generation == nil || self.activePlaybackGeneration == generation,
                  expectedEpoch == nil || self.playbackEpoch == expectedEpoch else { return }

            if self.realtimeGeneration == nil,
               let suspendedGeneration = self.legacyLifecycleSuspendedGeneration,
               suspendedGeneration == self.activePlaybackGeneration {
                self.legacyLifecycleDropCount &+= 1
                return
            }

            self.startEngineIfNeeded()

            // Calculate frame count: each frame = 2 channels × 2 bytes = 4 bytes
            let bytesPerFrame = Int(self.channelCount) * self.bytesPerSample
            guard data.count.isMultiple(of: bytesPerFrame) else {
                print("[AudioManager] Received misaligned PCM; skipping.")
                return
            }
            let frameCount    = data.count / bytesPerFrame

            guard frameCount > 0 else {
                print("[AudioManager] ⚠️ Received odd-sized PCM chunk (\(data.count) bytes) — skipping.")
                return
            }

            guard self.queuedFrames + frameCount <= self.maxQueuedFrames else {
                self.playoutDiagnostics.record(.pcmRejected)
                self.playoutDiagnostics.lastPcmRejection = (
                    self.activePlaybackGeneration ?? 0, self.playbackEpoch,
                    frameCount, self.queuedFrames, self.maxQueuedFrames,
                    self.playerNode.isPlaying, self.engineIsRunning)
                return
            }

            // Allocate an AVAudioPCMBuffer for exactly `frameCount` frames.
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat  : self.pcmFormat,
                frameCapacity: AVAudioFrameCount(frameCount))
            else {
                print("[AudioManager] ⚠️ Failed to allocate AVAudioPCMBuffer.")
                return
            }
            buffer.frameLength = AVAudioFrameCount(frameCount)

            // ── Zero-copy path for Int16 interleaved data ──────────────────
            // `mData` of an interleaved Int16 buffer points to the raw sample
            // memory. We copy directly into it to avoid an extra heap allocation.
            guard let intData = buffer.int16ChannelData else {
                print("[AudioManager] ⚠️ int16ChannelData is nil — format mismatch?")
                return
            }

            data.withUnsafeBytes { rawPtr in
                guard let src = rawPtr.baseAddress else { return }
                memcpy(intData[0], src, data.count)
            }

            // Schedule with `.interruptsAtLoop = false` so chunks queue smoothly.
            if self.queuedFrames == 0 { self.lastPcmProgressAt = self.playoutNow }
            self.queuedFrames += frameCount
            let epoch = self.playbackEpoch
            let completion: () -> Void = { [weak self] in
                self?.audioQueue.async {
                    guard let self, self.playbackEpoch == epoch else { return }
                    self.queuedFrames = max(0, self.queuedFrames - frameCount)
                    self.pcmCompletionCount &+= 1
                    self.lastPcmProgressAt = self.playoutNow
                }
            }
            #if targetEnvironment(simulator)
            if let schedule = self.pcmScheduleForTesting {
                schedule(frameCount, completion)
                self.playoutDiagnostics.record(.pcmScheduled, frames: frameCount)
                return
            }
            #endif
            if self.realtimeGeneration == nil {
                self.playerNode.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { _ in completion() }
            } else {
                self.playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in completion() }
            }
            self.playoutDiagnostics.record(.pcmScheduled, frames: frameCount)

            // Start playing if not already doing so.
            if self.engineIsRunning && !self.playerNode.isPlaying {
                self.playerNode.play()
                self.playoutDiagnostics.record(.playerStart)
            }
        }
    }

    public func reset() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let revokedGeneration = self.legacyLifecycleSuspendedGeneration
            self.playbackEpoch &+= 1
            self.activePlaybackGeneration = nil
            self.interruptedPlaybackEpoch = nil
            self.playbackInterrupted = false
            self.legacyLifecycleSuspendedGeneration = nil
            self.legacyLifecycleFreshFenceSatisfiedGeneration = nil
            self.legacyLifecycleDropCount = 0
            self.legacyResumeFenceDropCount = 0
            self.playerNode.stop()
            self.playerNode.reset()
            self.engine.pause()
            self.engineStarted = false
            self.queuedFrames = 0
            self.playoutTimer?.cancel()
            self.playoutTimer = nil
            self.jitterBuffer.reset()
            self.opusDecoder = nil
            self.realtimeGeneration = nil
            self.realtimeProfile = nil
            self.lastPcmProgressAt = nil
            self.lastAnyRecoveryAt = nil
            self.pendingRecoveryDiagnostic = nil
            self.pcmCompletionCount = 0
            self.playoutRecoveryCount = 0
            self.publishRecoveryOwner()
            self.receiveDiagnostics = AudioReceiveDiagnostics()
            self.playoutDiagnostics = AudioPlayoutDiagnostics()
            if let revokedGeneration {
                self.recordLegacyLifecycleTransition(generation: revokedGeneration, action: "reset_revoke")
            }
        }
    }

    private func startPlayoutTimer() {
        #if targetEnvironment(simulator)
        if manualPlayoutForTesting { return }
        #endif
        playoutTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(10),
            repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            self?.playoutTick()
        }
        timer.resume()
        playoutTimer = timer
    }

    private func playoutTick() {
        guard !playbackInterrupted else { return }
        if let generation = realtimeGeneration, activePlaybackGeneration == generation,
           let profile = realtimeProfile, queuedFrames >= maxQueuedFrames - 480,
           let progress = lastPcmProgressAt, playoutNow - progress >= 0.250 {
            reprimeRealtimeOnQueue(generation: generation, epoch: playbackEpoch, profile: profile, reason: "stalled_playout", automatic: true)
        }
        playoutDiagnostics.record(.tick)
        guard let opusDecoder,
              let action = jitterBuffer.dequeue() else {
            playoutDiagnostics.record(.nilTick)
            return
        }
        do {
            let samples: [Int16]
            switch action {
            case .decode(let packet):
                playoutDiagnostics.record(.decode)
                samples = try opusDecoder.decode(packet.payload)
            case .plc:
                playoutDiagnostics.record(.plc)
                samples = try opusDecoder.decode(nil)
            }
            let data = samples.withUnsafeBytes { Data($0) }
            enqueuePCMData(data, generation: realtimeGeneration, expectedEpoch: playbackEpoch)
        } catch {
            playoutDiagnostics.record(.decodeFailure)
            print("[AudioManager] Opus decode failed: \(error)")
        }
    }

    // MARK: - Audio Session Interruption Handling

    func publishDiagnostics(generation: UInt64, profile: String, opus: Bool,
                            receiveRejects: String, sink: @escaping (String) -> Void) {
        audioQueue.async { [weak self] in
            guard let self, !opus || self.realtimeGeneration == generation else { return }
            let rx = self.receiveDiagnostics
            let jitter = self.jitterBuffer.diagnostics
            let play = self.playoutDiagnostics
            if let line = self.pendingRecoveryDiagnostic {
                sink(line)
                self.pendingRecoveryDiagnostic = nil
            }
            self.pendingLegacyLifecycleDiagnostics.forEach(sink)
            self.pendingLegacyLifecycleDiagnostics.removeAll(keepingCapacity: true)
            let packetMetrics = opus
                ? "packets=\(rx.packets) gaps=\(rx.forwardGaps) missing=\(rx.missingPacketUnits) repaired=\(rx.repairedPacketUnits) reorder=\(rx.reorderedPackets) duplicate_stale=\(rx.duplicateOrStalePackets) jitter_ms=\(rx.jitterMs) interarrival_p95_ms=\(rx.interarrivalP95Ms) interarrival_max_ms=\(rx.interarrivalMaxMs) depth=\(self.jitterBuffer.bufferedPacketCount) depth_max=\(jitter.maximumDepth) depth_p50=\(jitter.depthPercentiles.p50) depth_p95=\(jitter.depthPercentiles.p95) inserted=\(jitter.insertedPackets) duplicate_reject=\(jitter.duplicateRejects) stale_reject=\(jitter.staleRejects) startup_wait=\(jitter.startupWaitTicks) target_ms=\(self.jitterBuffer.targetDurationMs) target_drop=\(jitter.targetPolicyDrops) overflow_drop=\(jitter.overflowDrops) plc=\(play.plcActions) short_starvation_entries=\(jitter.shortStarvationEntries) bounded_plc_actions=\(jitter.boundedPlcActions) rebuffer_entries=\(jitter.rebufferEntries) rebuffer_wait_ticks=\(jitter.rebufferWaitTicks) rebuffer_resumes=\(jitter.rebufferResumes) fresh_reanchor_skip_units=\(jitter.freshReanchorSkipUnits)"
                : "rtp_jitter_plc=not_applicable pcm_lifecycle_drop=\(self.legacyLifecycleDropCount) pcm_resume_fence_drop=\(self.legacyResumeFenceDropCount) legacy_lifecycle_suspended=\(self.legacyLifecycleSuspendedGeneration == self.activePlaybackGeneration && self.activePlaybackGeneration != nil ? 1 : 0) playback_interrupted=\(self.playbackInterrupted ? 1 : 0) interruption_epoch=\(self.interruptedPlaybackEpoch.map { String($0) } ?? "none") fresh_fence_satisfied=\(self.legacyLifecycleFreshFenceSatisfiedGeneration == self.activePlaybackGeneration && self.activePlaybackGeneration != nil ? 1 : 0) legacy_resume_pending=\(self.legacyLifecycleSuspendedGeneration == self.activePlaybackGeneration && self.legacyLifecycleFreshFenceSatisfiedGeneration == self.activePlaybackGeneration && self.activePlaybackGeneration != nil ? 1 : 0)"
            sink("[AUDIO_PLAYOUT] generation=\(generation) epoch=\(self.playbackEpoch) profile=\(profile) codec=\(opus ? "opus" : "pcm") \(packetMetrics) \(receiveRejects) ticks=\(play.ticks) nil=\(play.nilTicks) decode=\(play.decodeActions) decode_fail=\(play.decodeFailures) pcm_reject=\(play.pcmQueueRejects) \(play.pcmRejectionContext) pcm_scheduled=\(play.pcmBuffersScheduled) pcm_frames=\(play.pcmFramesScheduled) queued_frames=\(self.queuedFrames) pcm_completed=\(self.pcmCompletionCount) playout_recoveries=\(self.playoutRecoveryCount) engine_running=\(self.engineIsRunning ? 1 : 0) player_start=\(play.playerStarts) player_restart=\(play.playerRestarts)")
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        let metadata = AudioInterruptionDiagnosticMetadata(userInfo: notification.userInfo)
        let receivedAt = Int64(ProcessInfo.processInfo.systemUptime * 1000)
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            audioQueue.async { [weak self] in
                self?.recordInterruptionDiagnostic(metadata, receivedAt: receivedAt, phase: "received")
                self?.recordInterruptionDiagnostic(metadata, receivedAt: receivedAt, phase: "applied")
            }
            return
        }

        switch type {
        case .began:
            audioQueue.async { [weak self] in
                self?.recordInterruptionDiagnostic(metadata, receivedAt: receivedAt, phase: "received")
                defer { self?.recordInterruptionDiagnostic(metadata, receivedAt: receivedAt, phase: "applied") }
                guard let self, self.activePlaybackGeneration != nil,
                      !self.playbackInterrupted else { return }
                // Retire queued output callbacks without retiring the negotiated session.
                self.playbackEpoch &+= 1
                self.interruptedPlaybackEpoch = self.playbackEpoch
                self.playbackInterrupted = true
                self.lastPcmProgressAt = nil
                self.publishRecoveryOwner()
                self.playerNode.stop()
                self.playerNode.reset()
                self.engine.pause()
                self.engineStarted = false
                self.queuedFrames = 0
                self.playoutTimer?.cancel()
                self.playoutTimer = nil
                self.jitterBuffer.reset()
            }

        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            audioQueue.async { [weak self] in
                self?.recordInterruptionDiagnostic(metadata, receivedAt: receivedAt, phase: "received")
                defer { self?.recordInterruptionDiagnostic(metadata, receivedAt: receivedAt, phase: "applied") }
                guard let self, self.activePlaybackGeneration != nil,
                      let epoch = self.interruptedPlaybackEpoch,
                      epoch == self.playbackEpoch, self.playbackInterrupted else { return }
                self.interruptedPlaybackEpoch = nil
                if self.realtimeGeneration == nil,
                   let generation = self.activePlaybackGeneration,
                   self.legacyLifecycleSuspendedGeneration == generation {
                    self.playbackInterrupted = false
                    if !self.completeLegacyLifecycleResumeIfReady(generation: generation, reason: "interruption_end") {
                        self.recordLegacyLifecycleTransition(generation: generation, action: "interruption_ended_waiting_fence", detail: "should_resume=\(options.contains(.shouldResume) ? 1 : 0)")
                    }
                    return
                }
                guard options.contains(.shouldResume) else { return }
                self.playbackInterrupted = false
                self.publishRecoveryOwner()
                if self.realtimeGeneration == nil,
                   let suspendedGeneration = self.legacyLifecycleSuspendedGeneration,
                   suspendedGeneration == self.activePlaybackGeneration { return }
                self.configureAudioSession()
                if self.realtimeGeneration != nil, self.opusDecoder != nil {
                    self.startPlayoutTimer()
                }
                #if targetEnvironment(simulator)
                if let resume = self.interruptionResumeForTesting {
                    resume()
                    return
                }
                #endif
                self.startEngineIfNeeded()
                if self.realtimeGeneration == nil { return }
                guard self.engineIsRunning else { return }
                self.playerNode.play()
                self.playoutDiagnostics.record(.playerStart)
            }

        @unknown default:
            audioQueue.async { [weak self] in
                self?.recordInterruptionDiagnostic(metadata, receivedAt: receivedAt, phase: "received")
                self?.recordInterruptionDiagnostic(metadata, receivedAt: receivedAt, phase: "applied")
            }
        }
    }
}
