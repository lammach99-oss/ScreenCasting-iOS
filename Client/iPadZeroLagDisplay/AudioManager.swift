import Foundation
import AVFoundation

// MARK: - AudioManager

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
    private let maxQueuedFrames = 1_440 // 30ms max audio queue threshold to prevent audio lag
    private var opusDecoder: RealtimeOpusDecoder?
    private var jitterBuffer = AudioJitterBuffer(profile: .wifi)
    private var realtimeGeneration: UInt64?
    private var playoutTimer: DispatchSourceTimer?
    private var playbackEpoch: UInt64 = 0

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
        engine.attach(playerNode)

        // Connect playerNode → mainMixerNode using our target format.
        // The mixer converts to the hardware format automatically.
        engine.connect(
            playerNode,
            to   : engine.mainMixerNode,
            format: pcmFormat)

        // Prepare but don't start yet — startEngineIfNeeded() handles that.
        engine.prepare()

        // Listen for audio session interruptions (phone calls, Siri, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector : #selector(handleInterruption(_:)),
            name     : AVAudioSession.interruptionNotification,
            object   : nil)

        // Configure audio session for playback
        configureAudioSession()
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .measurement, options: [.mixWithOthers])
            try session.setPreferredIOBufferDuration(0.005) // 5ms low-latency hardware buffer
            try session.setPreferredSampleRate(sampleRate)
            try session.setActive(true)
        } catch {
            print("[AudioManager] ⚠️ AVAudioSession setup failed: \(error)")
        }
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
            self.playerNode.stop()
            self.playerNode.reset()
            self.queuedFrames = 0
            self.playoutTimer?.cancel()
            self.playoutTimer = nil
            self.jitterBuffer.reset(profile: profile)
            self.opusDecoder = nil
            do {
                self.opusDecoder = try RealtimeOpusDecoder()
                self.realtimeGeneration = generation
                self.startPlayoutTimer()
            } catch {
                self.realtimeGeneration = nil
                print("[AudioManager] Opus decoder setup failed: \(error)")
            }
        }
    }

    func playOpusData(
        _ data: Data,
        sequence: UInt16,
        timestamp: UInt32,
        generation: UInt64
    ) {
        guard !data.isEmpty else { return }
        audioQueue.async { [weak self] in
            guard let self,
                  self.realtimeGeneration == generation else { return }
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
    public func playPCMData(_ data: Data) {
        guard !data.isEmpty else { return }

        audioQueue.async { [weak self] in
            guard let self else { return }

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

            // Start playing if not already doing so.
            if !self.playerNode.isPlaying {
                self.playerNode.play()
            }
        }
    }

    public func reset() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.playbackEpoch &+= 1
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
        guard let opusDecoder,
              let action = jitterBuffer.dequeue() else { return }
        do {
            let samples: [Int16]
            switch action {
            case .decode(let packet):
                samples = try opusDecoder.decode(packet.payload)
            case .plc:
                samples = try opusDecoder.decode(nil)
            }
            let data = samples.withUnsafeBytes { Data($0) }
            playPCMData(data)
        } catch {
            print("[AudioManager] Opus decode failed: \(error)")
        }
    }

    // MARK: - Audio Session Interruption Handling

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            // System interrupted us (e.g. phone call): pause the engine.
            audioQueue.async { [weak self] in
                self?.playerNode.pause()
                self?.engine.pause()
                self?.engineStarted = false
            }

        case .ended:
            // Resume after interruption ends (e.g. call finished).
            guard let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                configureAudioSession()
                audioQueue.async { [weak self] in
                    self?.startEngineIfNeeded()
                    self?.playerNode.play()
                }
            }

        @unknown default:
            break
        }
    }
}
