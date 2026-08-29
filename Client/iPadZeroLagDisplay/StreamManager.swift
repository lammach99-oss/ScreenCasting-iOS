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

    private let networkManager: NetworkManager
    private var cancellables = Set<AnyCancellable>()
    private var frameCount: Int = 0
    private let frameCountLock = NSLock()
    private var timer: Timer?

    public init(networkManager: NetworkManager) {
        self.networkManager = networkManager

        // Bind to the new ConnectionState machine — only .streaming means "active"
        networkManager.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                let streaming = (state == .streaming)
                self.isConnected = streaming && self.networkManager.currentVideoFrameReady
                if !streaming {
                    self.frameCountLock.lock()
                    self.frameCount = 0
                    self.frameCountLock.unlock()
                    self.currentFPS = 0.0
                    self.frameReceiveMs = 0.0
                }
            }
            .store(in: &cancellables)

        networkManager.$currentVideoFrameReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in
                guard let self else { return }
                self.isConnected = ready && self.networkManager.connectionState == .streaming
                if !ready {
                    self.frameCountLock.lock()
                    self.frameCount = 0
                    self.frameCountLock.unlock()
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
                guard let self = self, snapshot.frameReceiveMs > 0 else { return }
                // Smooth with an EMA (α=0.2) to reduce single-frame jitter in the HUD
                let alpha = 0.2
                self.frameReceiveMs = alpha * snapshot.frameReceiveMs + (1 - alpha) * self.frameReceiveMs
            }
            .store(in: &cancellables)

        // Retrieve local Wi-Fi IP address
        self.localIPAddress = getWiFiIPAddress() ?? "No Wi-Fi detected"

        // Periodic 1-second timer to calculate FPS
        self.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.isConnected {
                self.frameCountLock.lock()
                let completedFrames = self.frameCount
                self.frameCount = 0
                self.frameCountLock.unlock()
                self.currentFPS = Double(completedFrames)
            } else {
                self.currentFPS = 0.0
                self.frameReceiveMs = 0.0
            }
        }
    }

    /// Increments frame counter. Call this each time a frame is decoded/rendered.
    public func registerFrameRendered() {
        guard networkManager.currentVideoFrameReady else { return }
        frameCountLock.lock()
        frameCount += 1
        frameCountLock.unlock()
    }

    /// Enumerates network interfaces to discover local IPv4 address
    private func getWiFiIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0 else { return nil }
        guard let firstAddr = ifaddr else { return nil }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // en0 is the typical Wi-Fi interface name on iOS
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    address = String(cString: hostname)
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }

    deinit {
        timer?.invalidate()
    }
}
