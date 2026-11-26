import Network
import SwiftUI

enum PairPanelModel {
    static func recent(_ entries: [RecentRemoteHost]) -> [RecentRemoteHost] {
        entries.filter(\.remoteControl)
    }

    static func address(_ text: String) -> RemoteHostAddress? {
        RemoteHostAddress.parseManual(text, port: NetworkManager.remoteControlPort)
    }

    static func accepts(first: TrustedPeerReference, candidate: TrustedPeerReference?) -> Bool {
        first != candidate
    }

    static func label(_ phase: SlotPhase) -> String {
        switch phase {
        case .active, .authenticated: return "Connected"
        case .parked: return "Paused"
        case .resuming, .connecting: return "Reconnecting"
        case .offline, .idle: return "Offline"
        case .refused: return "Refused"
        }
    }

    static func switchLabel(_ name: String) -> String { "Switch to \(name)" }

    @MainActor static func tapTarget(_ model: SessionSwitcher, scene: String) -> SlotOrdinal? {
        let other = model.selected.alternate
        guard model.surfaceOwner == scene, model.inFlight == nil, model[other].phase == .parked else { return nil }
        return other
    }

    static func reason(_ error: SlotFailure?) -> String {
        switch error {
        case .duplicatePeer: return "This PC is already PC 1."
        case .identityMismatch: return "This PC's identity has changed."
        case .busy: return "This PC is busy."
        case .forgotten: return "This PC is no longer trusted."
        case .refused: return "This PC refused the connection."
        case .transport, nil: return "Reconnecting..."
        }
    }
}
