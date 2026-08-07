import XCTest
@testable import iPadCasting

final class SettingsFoundationContractTests: XCTestCase {

    func testDefaultsAndAccessiblePresentation() {
        let store = InMemorySettingsStore()
        let model = IpadSettingsModel(store: store, capabilities: .mockDefault)

        expect(model.requested.quality == .balanced, "default quality")
        expect(model.effective.quality == .balanced, "default effective quality")
        expect(model.requested.resolution == .fullHD, "default resolution")
        expect(model.rows.first(where: { $0.id == "quality" })?.accessibilityLabel == "Quality and performance", "quality accessibility label")
        expect(model.rows.first(where: { $0.id == "quality" })?.accessibilityValue == "Balanced", "quality accessibility value")
    }

    func testRequestedAndEffectiveValuesDifferWhenUnsupported() {
        let capabilities = IpadSettingsCapabilities(
            supportedQualities: [.quality],
            supportedResolutions: [.hd],
            supportedRotations: [.landscape],
            maximumFrameRate: 30,
            supportsUSB: false,
            availableInputDevices: [.touch]
        )!
        let model = IpadSettingsModel(store: InMemorySettingsStore(), capabilities: capabilities)
        model.update { $0.quality = .performance; $0.resolution = .ultraHD; $0.frameRate = 120; $0.connection = .usb; $0.inputDevice = .pencil }

        expect(model.requested.quality == .performance, "requested quality remains user choice")
        expect(model.effective.quality == .quality, "effective quality is capability constrained")
        expect(model.effective.resolution == .hd, "effective resolution is capability constrained")
        expect(model.effective.frameRate == 30, "effective framerate is capability constrained")
        expect(model.effective.connection == .wifi, "effective connection falls back")
        expect(model.effective.inputDevice == .touch, "effective input falls back")
    }

    func testCapabilityFilteringAndInvalidBounds() {
        let model = IpadSettingsModel(store: InMemorySettingsStore(), capabilities: .mockDefault)
        expect(model.options(for: .resolution) == ["hd", "fullHD"], "resolution options are capability filtered")
        model.update { $0.frameRate = 999; $0.pointerSensitivity = -4 }
        expect(model.requested.frameRate == 120, "requested framerate clamps to valid bounds")
        expect(model.requested.pointerSensitivity == 0, "requested sensitivity clamps to valid bounds")
    }

    func testCapabilityInvariantRejectsEmptySnapshot() {
        let invalid = IpadSettingsCapabilities(
            supportedQualities: [], supportedResolutions: [.hd],
            supportedRotations: [.landscape], maximumFrameRate: 60,
            supportsUSB: false, availableInputDevices: [.touch])
        expect(invalid == nil, "empty quality capability snapshot is rejected")
    }

    func testCapabilityInvariantRejectsTooLowFrameRate() {
        let invalid = IpadSettingsCapabilities(
            supportedQualities: [.balanced], supportedResolutions: [.hd],
            supportedRotations: [.landscape], maximumFrameRate: 23,
            supportsUSB: false, availableInputDevices: [.touch])
        expect(invalid == nil, "maximum frame rate below 24 is rejected")
    }

    func testPersistenceAndLegacyMigration() {
        let store = InMemorySettingsStore()
        let model = IpadSettingsModel(store: store, capabilities: .mockDefault)
        model.update { $0.quality = .quality; $0.rotation = .portrait; $0.frameRate = 90 }
        let restored = IpadSettingsModel(store: store, capabilities: .mockDefault)
        expect(restored.requested.quality == .quality && restored.requested.rotation == .portrait && restored.requested.frameRate == 90, "settings persist")

        let legacy = InMemorySettingsStore(values: ["ipad.settings": "{\"quality\":\"performance\",\"frameRate\":60}"])
        let migrated = IpadSettingsModel(store: legacy, capabilities: .mockDefault)
        expect(migrated.requested.quality == .performance && migrated.requested.frameRate == 60, "legacy settings migrate")
        expect(legacy.string(forKey: "ipad.settings")?.contains("schemaVersion") == true, "migration persists current schema")
    }

    private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        XCTAssertTrue(condition(), message)
    }
}
