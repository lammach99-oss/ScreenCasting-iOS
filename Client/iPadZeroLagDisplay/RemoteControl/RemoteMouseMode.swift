import Foundation

enum RemoteMouseDevice: CaseIterable {
    case finger, pencil, indirectPointer
}

enum RemoteMouseMode: String, CaseIterable {
    case auto, trackpad, direct

    func resolved(for device: RemoteMouseDevice) -> RemoteMouseMode {
        self == .auto ? (device == .finger ? .trackpad : .direct) : self
    }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .trackpad: return "Trackpad"
        case .direct: return "Direct"
        }
    }
}

// Matches ClientStreamSettingsStore: versioned client key, injectable defaults.
enum RemoteMouseModeStore {
    static let key = "ScreenCasting.client.remoteMouseMode.v1"

    static func load(defaults: UserDefaults = .standard) -> RemoteMouseMode {
        defaults.string(forKey: key).flatMap(RemoteMouseMode.init(rawValue:)) ?? .auto
    }

    static func save(_ mode: RemoteMouseMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: key)
    }
}
