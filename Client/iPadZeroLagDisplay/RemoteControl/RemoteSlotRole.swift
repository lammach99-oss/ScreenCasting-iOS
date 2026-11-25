import Network

public enum RemoteSlotRole {
    case primary
    case secondaryRemote

    func permits(_ endpoint: NWEndpoint) -> Bool {
        self == .primary || RemoteSessionPolicy.isRemoteControl(endpoint: endpoint)
    }
}
