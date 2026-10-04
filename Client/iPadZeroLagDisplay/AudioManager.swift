import Foundation
import AVFoundation

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
    private var receiveDiagnostics = AudioReceiveDiagnostics()
    private var playoutDiagnostics = AudioPlayoutDiagnostics()

    #if targetEnvironment(simulator)
    var interruptionResumeForTesting: (() -> Void)?
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
        guard !engineStarted else { return }
        do {
            try engine.start()
            engineStarted = true
            print("[AudioManager] AVAudioEngine started.")
        } catch {
            print("[AudioManager] ⚠️ AVAudioEngine failed to start: \(error)")
        }
    }

    // MARK: - Public API

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
                self.opusDecoder = try RealtimeOpusDecoder()
                self.realtimeGeneration = generation
                self.activePlaybackGeneration = generation
                self.startPlayoutTimer()
            } catch {
                self.realtimeGeneration = nil
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
            self.playerNode.stop()
            self.playerNode.reset()
            self.queuedFrames = 0
            self.playoutTimer?.cancel()
            self.playoutTimer = nil
            self.jitterBuffer.reset()
            self.opusDecoder = nil
            self.realtimeGeneration = nil
            self.receiveDiagnostics = AudioReceiveDiagnostics()
            self.playoutDiagnostics = AudioPlayoutDiagnostics()
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
            self.queuedFrames += frameCount
            let epoch = self.playbackEpoch
            self.playerNode.scheduleBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                self?.audioQueue.async {
                    guard let self, self.playbackEpoch == epoch else { return }
                    self.queuedFrames = max(0, self.queuedFrames - frameCount)
                }
            }
            self.playoutDiagnostics.record(.pcmScheduled, frames: frameCount)

            // Start playing if not already doing so.
            if !self.playerNode.isPlaying {
                self.playerNode.play()
                self.playoutDiagnostics.record(.playerStart)
            }
        }
    }

    public func reset() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.playbackEpoch &+= 1
            self.activePlaybackGeneration = nil
            self.interruptedPlaybackEpoch = nil
            self.playbackInterrupted = false
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
            self.receiveDiagnostics = AudioReceiveDiagnostics()
            self.playoutDiagnostics = AudioPlayoutDiagnostics()
        }
    }

    private func startPlayoutTimer() {
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
            let packetMetrics = opus
                ? "packets=\(rx.packets) gaps=\(rx.forwardGaps) missing=\(rx.missingPacketUnits) repaired=\(rx.repairedPacketUnits) reorder=\(rx.reorderedPackets) duplicate_stale=\(rx.duplicateOrStalePackets) jitter_ms=\(rx.jitterMs) interarrival_p95_ms=\(rx.interarrivalP95Ms) interarrival_max_ms=\(rx.interarrivalMaxMs) depth=\(self.jitterBuffer.bufferedPacketCount) depth_max=\(jitter.maximumDepth) depth_p50=\(jitter.depthPercentiles.p50) depth_p95=\(jitter.depthPercentiles.p95) inserted=\(jitter.insertedPackets) duplicate_reject=\(jitter.duplicateRejects) stale_reject=\(jitter.staleRejects) startup_wait=\(jitter.startupWaitTicks) target_ms=\(self.jitterBuffer.targetDurationMs) target_drop=\(jitter.targetPolicyDrops) overflow_drop=\(jitter.overflowDrops) plc=\(play.plcActions)"
                : "rtp_jitter_plc=not_applicable"
            sink("[AUDIO_PLAYOUT] generation=\(generation) epoch=\(self.playbackEpoch) profile=\(profile) codec=\(opus ? "opus" : "pcm") \(packetMetrics) \(receiveRejects) ticks=\(play.ticks) nil=\(play.nilTicks) decode=\(play.decodeActions) decode_fail=\(play.decodeFailures) pcm_reject=\(play.pcmQueueRejects) pcm_scheduled=\(play.pcmBuffersScheduled) pcm_frames=\(play.pcmFramesScheduled) queued_frames=\(self.queuedFrames) player_start=\(play.playerStarts) player_restart=\(play.playerRestarts)")
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            audioQueue.async { [weak self] in
                guard let self, self.activePlaybackGeneration != nil,
                      !self.playbackInterrupted else { return }
                // Retire queued output callbacks without retiring the negotiated session.
                self.playbackEpoch &+= 1
                self.interruptedPlaybackEpoch = self.playbackEpoch
                self.playbackInterrupted = true
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
                guard let self, self.activePlaybackGeneration != nil,
                      let epoch = self.interruptedPlaybackEpoch,
                      epoch == self.playbackEpoch, self.playbackInterrupted else { return }
                self.interruptedPlaybackEpoch = nil
                guard options.contains(.shouldResume) else { return }
                self.playbackInterrupted = false
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
                guard self.engineStarted else { return }
                self.playerNode.play()
                self.playoutDiagnostics.record(.playerStart)
            }

        @unknown default:
            break
        }
    }
}
