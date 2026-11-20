import AVFoundation
import QuartzCore

final class RemoteAudioPlayback {
    struct Timing {
        fileprivate var firstQueuedAt: TimeInterval?
        fileprivate(set) var startupMs: Int?
        fileprivate(set) var maximumVideoHoldMs = 0
    }

    private final class Output {
        let decoder: RealtimeOpusDecoder
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format: AVAudioFormat
        var queued = 0
        var lastProgressAt: TimeInterval = 0

        init() throws {
            decoder = try RealtimeOpusDecoder()
            guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                             channels: 2, interleaved: true) else { throw Failure.format }
            self.format = format
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
        }

        deinit {
            player.stop()
            engine.stop()
        }
    }

    private enum Failure: Error { case format }
    private let queue = DispatchQueue(label: "ScreenCasting.remoteAudio", qos: .userInitiated)
    private let lock = NSLock()
    // Lock-owned data can be fenced from the network queue without waiting for AVAudioEngine.
    private var revision: UInt64 = 0
    private var epoch: UInt64 = 0
    private var jitter = RemoteAudioJitter()
    private var clock: RemoteAudioClock?
    private var timing = Timing()
    // Audio-queue data.
    private var output: Output?
    private var timer: DispatchSourceTimer?

    deinit { timer?.cancel() }

    @discardableResult
    func setEpoch(_ epoch: UInt64, failed: @escaping () -> Void) -> Timing? {
        lock.lock()
        guard self.epoch != epoch else { lock.unlock(); return nil }
        let previous = self.epoch == 0 ? nil : timing
        self.epoch = epoch
        revision &+= 1
        let revision = self.revision
        jitter = RemoteAudioJitter()
        clock = nil
        timing = Timing()
        lock.unlock()

        queue.async { [weak self] in
            guard let self, self.isCurrent(revision) else { return }
            self.stopOutput()
            guard epoch != 0 else { return }
            do {
                self.output = try Output()
            } catch {
                self.fail(revision, notify: failed)
                return
            }
            guard self.isCurrent(revision) else { self.stopOutput(); return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.play(revision, failed: failed) }
            self.timer = timer
            timer.resume()
        }
        return previous
    }

    func enqueue(epoch: UInt64, packet: RemoteAudioJitter.Packet) {
        lock.lock()
        defer { lock.unlock() }
        guard epoch != 0, self.epoch == epoch else { return }
        if timing.firstQueuedAt == nil { timing.firstQueuedAt = CACurrentMediaTime() }
        jitter.insert(packet)
    }

    func videoDeadline(captureUs: UInt64, receivedAt: TimeInterval, now: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard let clock, now - clock.playoutAt < 0.120 else { return now }
        let deadline = clock.videoDeadline(captureUs: captureUs, receivedAt: receivedAt, now: now)
        timing.maximumVideoHoldMs = max(timing.maximumVideoHoldMs, Int(((deadline - now) * 1000).rounded(.up)))
        return deadline
    }

    private func isCurrent(_ revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.revision == revision
    }

    private func stopOutput() {
        timer?.cancel()
        timer = nil
        output = nil
    }

    private func fail(_ revision: UInt64, notify: () -> Void) {
        stopOutput()
        lock.lock()
        let current = self.revision == revision
        if current {
            epoch = 0
            jitter = RemoteAudioJitter()
            clock = nil
        }
        lock.unlock()
        if current { notify() }
    }

    private func play(_ revision: UInt64, failed: () -> Void) {
        guard let output, isCurrent(revision) else { return }
        let now = CACurrentMediaTime()
        guard output.engine.isRunning, output.queued == 0 || now - output.lastProgressAt < 0.250 else {
            fail(revision, notify: failed)
            return
        }
        guard output.queued < 3 else { return }
        lock.lock()
        let frame = self.revision == revision ? jitter.dequeue() : nil
        lock.unlock()
        guard let frame else { return }

        let samples: [Int16]
        do {
            samples = try output.decoder.decode(frame.opus)
        } catch {
            // A bad Opus packet is audio-scoped. Keep the video and input session alive.
            return
        }
        let frames = AVAudioFrameCount(samples.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output.format, frameCapacity: frames),
              let channels = buffer.int16ChannelData else { fail(revision, notify: failed); return }
        buffer.frameLength = frames
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channels[0].update(from: base, count: source.count) }
        }
        lock.lock()
        defer { lock.unlock() }
        guard self.revision == revision else { return }
        if output.queued == 0 { output.lastProgressAt = now }
        output.queued += 1
        let captureUs = frame.captureUs
        output.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self, weak output] _ in
            let playedAt = CACurrentMediaTime() - 0.010
            self?.queue.async { [weak self, weak output] in
                guard let self, let output else { return }
                output.queued -= 1
                output.lastProgressAt = playedAt + 0.010
                self.lock.lock()
                if self.revision == revision, self.epoch != 0 {
                    self.clock = RemoteAudioClock(captureUs: captureUs, playoutAt: playedAt)
                    if self.timing.startupMs == nil, let first = self.timing.firstQueuedAt {
                        self.timing.startupMs = Int(max(0, playedAt - first) * 1000)
                    }
                }
                self.lock.unlock()
            }
        }
        if !output.player.isPlaying { output.player.play() }
    }
}

/// Bounded metadata for decoded pictures that can still reach the renderer.
final class RemoteVideoPresentationTiming {
    private struct Frame {
        let sequence: UInt32
        let generation: UInt64
        let captureUs: UInt64
        let receivedAt: TimeInterval
    }

    private let lock = NSLock()
    private var frames: [Frame] = []

    func record(sequence: UInt32, generation: UInt64, captureUs: UInt64, receivedAt: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        if frames.count == 16 { frames.removeFirst() }
        frames.append(.init(sequence: sequence, generation: generation, captureUs: captureUs, receivedAt: receivedAt))
    }

    func reset() {
        lock.lock()
        frames.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func deadline(sequence: UInt32, generation: UInt64, now: TimeInterval, playback: RemoteAudioPlayback) -> TimeInterval {
        lock.lock()
        let frame = frames.last { $0.sequence == sequence && $0.generation == generation }
        lock.unlock()
        guard let frame else { return now }
        return playback.videoDeadline(captureUs: frame.captureUs, receivedAt: frame.receivedAt, now: now)
    }
}
