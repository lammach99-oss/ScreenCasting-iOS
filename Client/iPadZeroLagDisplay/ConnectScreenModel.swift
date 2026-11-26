import Foundation

struct PhoneConnectScreenModel {
    enum Section: String, CaseIterable {
        case recent = "Recent remote hosts"
        case manual = "Manual address"
        case discovered = "Discovered remote hosts"
    }

    struct Preview {
        let destination: String
        let purpose = "Remote control"
    }

    let sections = Section.allCases
    let recentHosts: [RecentRemoteHost]
    private let capabilities: ClientDeviceCapabilities

    init?(capabilities: ClientDeviceCapabilities, history: [RecentRemoteHost]) {
        guard capabilities.family == .phone else { return nil }
        self.capabilities = capabilities
        recentHosts = history.filter {
            if case .success = RemoteSessionPolicy.admit(.recent($0), for: capabilities) { return true }
            return false
        }
    }

    func preview(_ intent: RemoteIntent, current: RemoteIntent.ResumeContext? = nil) -> Preview? {
        guard case .success(let address) = RemoteSessionPolicy.admit(intent, for: capabilities, current: current)
        else { return nil }
        return Preview(destination: address.host)
    }
}

/// The connect screen's single status line: plain words, one tone, at most one action.
public struct ConnectScreenStatus: Equatable {
    public static func connectionRecommendation(_ state: ConnectionSwitchState) -> String { state.recommendationText }
    public enum Tone: Equatable { case neutral, busy, warning, danger, ready }
    public enum Action: Equatable { case none, cancel, stop, retry, restartUSB }
    public let text: String
    /// The underlying reason, shown smaller under a failure or a reconnect.
    public let detail: String?
    public let tone: Tone
    public let action: Action

    public static func connectionChange(_ state: ConnectionSwitchState) -> Self? {
        guard state.pending != nil || state.offersReconnect else { return nil }
        return Self(text: state.message, detail: nil, tone: state.offersReconnect ? .danger : .busy,
                    action: state.offersReconnect ? .none : .cancel)
    }

    /// `usb` is a USB-C attempt (the last Wi-Fi PC is not involved); `canRetry` means a Wi-Fi reconnect target exists.
    public static func make(state: ConnectionState, pcName: String?, discoveredCount: Int, reconnectAttempt: Int,
                            usb: Bool = false, canRetry: Bool = true, tailnetTarget: Bool = false) -> Self {
        let trimmed = pcName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pc = usb ? "the PC over USB-C" : trimmed.isEmpty ? "your PC" : trimmed
        let reconnecting = !usb && reconnectAttempt > 0
        let reconnectText = "Reconnecting to \(pc)… try \(reconnectAttempt)"
        switch state {
        case .idle:
            return searching(found: discoveredCount)
        case .listening:
            return Self(text: "Waiting for the PC over USB-C…", detail: nil, tone: .busy, action: .stop)
        case .connecting:
            return reconnecting ? Self(text: reconnectText, detail: nil, tone: .warning, action: .stop)
                : Self(text: "Connecting to \(pc)…", detail: nil, tone: .busy, action: .cancel)
        case .awaitingHostIdentity:
            return Self(text: "Check the code on the PC", detail: nil, tone: .busy, action: .cancel)
        case .awaitingPIN:
            return Self(text: "Enter the PIN shown on the PC", detail: nil, tone: .busy, action: .cancel)
        case .submittingPIN:
            return Self(text: "Checking the PIN…", detail: nil, tone: .busy, action: .cancel)
        case .authFailed:
            return Self(text: "Wrong PIN. Try again.", detail: nil, tone: .warning, action: .cancel)
        case .streaming:
            return Self(text: "Connected to \(pc)", detail: nil, tone: .ready, action: .none)
        case .disconnected(let reason):
            let detail = reason.isEmpty ? nil : reason
            if reconnecting { return Self(text: reconnectText, detail: detail, tone: .warning, action: .stop) }
            if reason.isEmpty { return searching(found: discoveredCount) }
            if usb { return Self(text: "The USB-C connection ended.", detail: detail, tone: .danger, action: .restartUSB) }
            let failureDetail = tailnetTarget ? reason + " Check that Tailscale is connected on this iPad and on the PC." : reason
            return Self(text: "Couldn't connect to \(pc).", detail: failureDetail, tone: .danger, action: canRetry ? .retry : .none)
        }
    }

    private static func searching(found: Int) -> Self {
        Self(text: found == 0 ? "Looking for PCs on this Wi-Fi…" : found == 1 ? "1 PC on this Wi-Fi" : "\(found) PCs on this Wi-Fi",
             detail: nil, tone: found == 0 ? .busy : .neutral, action: .none)
    }
}

public enum CastingPermissionCopy {
    public static let requestSent = "Request sent. Approve it in the pop-up on the PC."
}
