import Foundation

/// The connect screen's single status line.
public struct ConnectScreenStatus: Equatable {
    public enum Tone: Equatable { case neutral, busy, warning, danger, ready }
    public enum Action: Equatable { case none, cancel, stop, retry }
    public let text: String
    public let detail: String?
    public let tone: Tone
    public let action: Action

    public static func make(state: ConnectionState, pcName: String?, discoveredCount: Int, reconnectAttempt: Int) -> Self {
        Self(text: "", detail: nil, tone: .neutral, action: .none)
    }
}
