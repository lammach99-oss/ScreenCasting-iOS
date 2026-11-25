import Foundation
import Combine
import Network
import QuartzCore    // CACurrentMediaTime() for latency stamping

/// Central State Manager for ScreenCasting iPad client.
/// Manages connection state, FPS counters, streaming latency, and local IP.
public class StreamManager: ObservableObject {
    @Published public var isConnected: Bool = false
    @Published public var currentFPS: Double = 0.0
    /// Local receiver-stage timing, not protocol RTT or a ping measurement.
    @Published public var frameReceiveMs: Double = 0.0
    @Published public var localIPAddress: String = "127.0.0.1"

    private var networkManager: NetworkManager
    private var slot: SlotOrdinal = .one
    private var generation: UInt64?
    private var binding = UUID()
    private var cancellables = Set<AnyCancellable>()
    private var frameCount: Int = 0
    private let frameCountLock = NSLock()
    private var timer: Timer?

    public init(networkManager: NetworkManager) {
        self.networkManager = networkManager

        subscribe(to: networkManager)

        // Retrieve local Wi-Fi IP address
        self.localIPAddress = getWiFiIPAddress() ?? "No Wi-Fi detected"

        // Periodic 1-second timer to calculate FPS
        self.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.isConnected && self.generationIsCurrent {
                self.frameCountLock.lock()
                let completedFrames = self.frameCount
                self.frameCount = 0
                self.frameCountLock.unlock()
                self.currentFPS = Double(completedFrames)
            } else {
                if self.isConnected { self.isConnected = false }
                self.currentFPS = 0.0
                self.frameReceiveMs = 0.0
            }
        }
    }

    private var generationIsCurrent: Bool {
        generation == nil || generation == networkManager.remoteKeyboardGeneration
    }

    // The original single-manager initializer follows its manager across reconnects.
    // An explicit binding only observes the named connection lifetime.
    @MainActor func observe(_ manager: NetworkManager, slot: SlotOrdinal, generation: UInt64) {
        guard networkManager !== manager || self.slot != slot || self.generation != generation else { return }
        cancellables.removeAll()
        binding = UUID()
        frameCountLock.lock()
        networkManager = manager
        self.slot = slot
        self.generation = generation
        frameCount = 0
        frameCountLock.unlock()
        isConnected = false
        currentFPS = 0
        frameReceiveMs = 0
        subscribe(to: manager)
    }

    private func subscribe(to networkManager: NetworkManager) {
        let ticket = binding
        // Bind to the new ConnectionState machine — only .streaming means "active"
        networkManager.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, self.binding == ticket, self.generationIsCurrent else { return }
                let streaming = (state == .streaming)
                self.isConnected = streaming
                if !streaming {
                    self.currentFPS = 0.0
                    self.frameReceiveMs = 0.0
                }
            }
            .store(in: &cancellables)

        // Bind the local receive-stage duration; protocol RTT is reported separately.
        networkManager.$hudTelemetry
            .receive(on: DispatchQueue.main)
            .filter { [weak self] _ in self?.isConnected == true }
            .sink { [weak self] snapshot in
                guard let self, self.binding == ticket, self.generationIsCurrent, snapshot.frameReceiveMs > 0 else { return }
                // Smooth with an EMA (α=0.2) to reduce single-frame jitter in the HUD
                let alpha = 0.2
                self.frameReceiveMs = alpha * snapshot.frameReceiveMs + (1 - alpha) * self.frameReceiveMs
            }
            .store(in: &cancellables)
    }

    /// Increments frame counter. Call this each time a frame is decoded/rendered.
    public func registerFrameRendered() {
        frameCountLock.lock()
        if generation == nil { frameCount += 1 }
        frameCountLock.unlock()
    }

    func registerFrameRendered(slot: SlotOrdinal, generation: UInt64) {
        frameCountLock.lock()
        defer { frameCountLock.unlock() }
        guard self.slot == slot, self.generation == generation, generationIsCurrent else { return }
        frameCount += 1
    }

    /// Enumerates network interfaces to discover local IPv4 address
    private func getWiFiIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(firstAddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard let interfaceAddress = interface.ifa_addr else { continue }
            let addrFamily = interfaceAddress.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // en0 is the typical Wi-Fi interface name on iOS
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let result = getnameinfo(
                        interfaceAddress,
                        socklen_t(interfaceAddress.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    if result == 0 { address = String(cString: hostname) }
                }
            }
        }
        return address
    }

    deinit {
        timer?.invalidate()
    }
}
