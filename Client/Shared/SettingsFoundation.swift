import Foundation

public enum StreamQuality: String, CaseIterable, Codable { case performance, balanced, quality }
public enum StreamResolution: String, CaseIterable, Codable {
    case native

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard value == Self.native.rawValue || ["hd", "fullHD", "ultraHD"].contains(value) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unsupported stream resolution")
        }
        self = .native
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
public enum StreamRotation: String, CaseIterable, Codable { case automatic, landscape, portrait }
public enum ConnectionPreference: String, CaseIterable, Codable { case automatic, wifi, usb }
public enum InputDevice: String, CaseIterable, Codable { case touch, pencil, trackpad }
public enum SettingsOption: Hashable { case quality, resolution, rotation, connection, inputDevice }

public struct IpadSettings: Equatable, Codable {
    public var quality: StreamQuality = .balanced
    public var resolution: StreamResolution = .native
    public var rotation: StreamRotation = .automatic
    public var frameRate: Int = 60
    public var connection: ConnectionPreference = .automatic
    public var inputDevice: InputDevice = .touch
    public var showPerformanceOverlay = false
    public var pointerSensitivity = 50

    mutating func normalize() {
        frameRate = min(max(frameRate, 24), 120)
        pointerSensitivity = min(max(pointerSensitivity, 0), 100)
    }
}

public struct IpadSettingsCapabilities: Equatable {
    public let supportedQualities: Set<StreamQuality>
    public let supportedResolutions: Set<StreamResolution>
    public let supportedRotations: Set<StreamRotation>
    public let maximumFrameRate: Int
    public let supportsUSB: Bool
    public let availableInputDevices: Set<InputDevice>

    public init?(
        supportedQualities: Set<StreamQuality>,
        supportedResolutions: Set<StreamResolution>,
        supportedRotations: Set<StreamRotation>,
        maximumFrameRate: Int,
        supportsUSB: Bool,
        availableInputDevices: Set<InputDevice>
    ) {
        guard !supportedQualities.isEmpty,
              !supportedResolutions.isEmpty,
              !supportedRotations.isEmpty,
              !availableInputDevices.isEmpty,
              maximumFrameRate >= 24 else { return nil }
        self.supportedQualities = supportedQualities
        self.supportedResolutions = supportedResolutions
        self.supportedRotations = supportedRotations
        self.maximumFrameRate = maximumFrameRate
        self.supportsUSB = supportsUSB
        self.availableInputDevices = availableInputDevices
    }

    public static let mockDefault = IpadSettingsCapabilities(
        supportedQualities: [.performance, .balanced, .quality],
        supportedResolutions: [.native],
        supportedRotations: [.automatic, .landscape, .portrait],
        maximumFrameRate: 120,
        supportsUSB: true,
        availableInputDevices: [.touch, .pencil]
    )!
}

public protocol SettingsKeyValueStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
}

public final class InMemorySettingsStore: SettingsKeyValueStore {
    private var values: [String: String]
    public init(values: [String: String] = [:]) { self.values = values }
    public func string(forKey key: String) -> String? { values[key] }
    public func set(_ value: String, forKey key: String) { values[key] = value }
}

public final class IpadSettingsModel {
    public static let storageKey = "ipad.settings"
    private static let schemaVersion = 1
    private let store: SettingsKeyValueStore
    public let capabilities: IpadSettingsCapabilities
    public private(set) var requested: IpadSettings
    public var effective: IpadSettings { Self.effectiveSettings(for: requested, capabilities: capabilities) }

    public init(store: SettingsKeyValueStore, capabilities: IpadSettingsCapabilities) {
        self.store = store
        self.capabilities = capabilities
        requested = Self.load(from: store)
    }

    public func update(_ change: (inout IpadSettings) -> Void) {
        change(&requested)
        requested.normalize()
        save()
    }

    public func options(for option: SettingsOption) -> [String] {
        switch option {
        case .quality: return StreamQuality.allCases.filter(capabilities.supportedQualities.contains).map(\.rawValue)
        case .resolution: return StreamResolution.allCases.filter(capabilities.supportedResolutions.contains).map(\.rawValue)
        case .rotation: return StreamRotation.allCases.filter(capabilities.supportedRotations.contains).map(\.rawValue)
        case .connection: return ConnectionPreference.allCases.filter { $0 != .usb || capabilities.supportsUSB }.map(\.rawValue)
        case .inputDevice: return InputDevice.allCases.filter(capabilities.availableInputDevices.contains).map(\.rawValue)
        }
    }

    public var rows: [IpadSettingsAccessibilityRow] {
        let values = effective
        return [
            .init(id: "quality", accessibilityLabel: "Quality and performance", accessibilityValue: display(values.quality)),
            .init(id: "resolution", accessibilityLabel: "Resolution", accessibilityValue: display(values.resolution)),
            .init(id: "rotation", accessibilityLabel: "Rotation", accessibilityValue: display(values.rotation)),
            .init(id: "general", accessibilityLabel: "General", accessibilityValue: values.showPerformanceOverlay ? "Performance overlay on" : "Performance overlay off"),
            .init(id: "connection", accessibilityLabel: "Connection", accessibilityValue: display(values.connection)),
            .init(id: "input", accessibilityLabel: "Input devices", accessibilityValue: display(values.inputDevice))
        ]
    }

    private func save() {
        let payload = PersistedSettings(schemaVersion: Self.schemaVersion, settings: requested)
        guard let data = try? JSONEncoder().encode(payload), let json = String(data: data, encoding: .utf8) else { return }
        store.set(json, forKey: Self.storageKey)
    }

    private static func load(from store: SettingsKeyValueStore) -> IpadSettings {
        guard let json = store.string(forKey: storageKey), let data = json.data(using: .utf8) else { return IpadSettings() }
        if let current = try? JSONDecoder().decode(PersistedSettings.self, from: data), current.schemaVersion == schemaVersion {
            var settings = current.settings; settings.normalize(); return settings
        }
        if let legacy = try? JSONDecoder().decode(LegacySettings.self, from: data) {
            var migrated = IpadSettings()
            migrated.quality = legacy.quality ?? migrated.quality
            migrated.resolution = legacy.resolution ?? migrated.resolution
            migrated.rotation = legacy.rotation ?? migrated.rotation
            migrated.frameRate = legacy.frameRate ?? migrated.frameRate
            migrated.connection = legacy.connection ?? migrated.connection
            migrated.inputDevice = legacy.inputDevice ?? migrated.inputDevice
            migrated.showPerformanceOverlay = legacy.showPerformanceOverlay ?? migrated.showPerformanceOverlay
            migrated.pointerSensitivity = legacy.pointerSensitivity ?? migrated.pointerSensitivity
            migrated.normalize()
            let model = IpadSettingsModel(store: store, capabilities: .mockDefault, initial: migrated)
            model.save()
            return migrated
        }
        return IpadSettings()
    }

    private init(store: SettingsKeyValueStore, capabilities: IpadSettingsCapabilities, initial: IpadSettings) {
        self.store = store; self.capabilities = capabilities; self.requested = initial
    }

    private static func effectiveSettings(for requested: IpadSettings, capabilities: IpadSettingsCapabilities) -> IpadSettings {
        var result = requested
        result.quality = supported(requested.quality, in: capabilities.supportedQualities, fallback: .balanced)
        result.resolution = supported(requested.resolution, in: capabilities.supportedResolutions, fallback: .native)
        result.rotation = supported(requested.rotation, in: capabilities.supportedRotations, fallback: .automatic)
        result.frameRate = min(requested.frameRate, max(24, capabilities.maximumFrameRate))
        if requested.connection == .usb && !capabilities.supportsUSB { result.connection = .wifi }
        result.inputDevice = supported(requested.inputDevice, in: capabilities.availableInputDevices, fallback: .touch)
        return result
    }

    private static func supported<T: Hashable>(_ value: T, in options: Set<T>, fallback: T) -> T {
        options.contains(value) ? value : (options.contains(fallback) ? fallback : options.sorted { String(describing: $0) < String(describing: $1) }.first ?? fallback)
    }

    private func display(_ value: StreamQuality) -> String { value.rawValue.capitalized }
    private func display(_: StreamResolution) -> String { "Native 2388 x 1668" }
    private func display(_ value: StreamRotation) -> String { value.rawValue.capitalized }
    private func display(_ value: ConnectionPreference) -> String { value.rawValue.uppercased() }
    private func display(_ value: InputDevice) -> String { value.rawValue.capitalized }
}

private struct PersistedSettings: Codable { let schemaVersion: Int; let settings: IpadSettings }
private struct LegacySettings: Decodable {
    let quality: StreamQuality?
    let resolution: StreamResolution?
    let rotation: StreamRotation?
    let frameRate: Int?
    let connection: ConnectionPreference?
    let inputDevice: InputDevice?
    let showPerformanceOverlay: Bool?
    let pointerSensitivity: Int?
}

public struct IpadSettingsAccessibilityRow: Equatable {
    public let id: String
    public let accessibilityLabel: String
    public let accessibilityValue: String
}
