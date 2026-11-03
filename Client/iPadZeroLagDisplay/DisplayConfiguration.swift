import Foundation
import Network
import CryptoKit
import QuartzCore
import AVFoundation
import Security
import UIKit

enum ClientDisplayOrientation: UInt8, Equatable {
    case landscape = 0
    case portrait = 1
}

enum DisplayOrientationMode: String, CaseIterable, Hashable {
    case automatic
    case landscape
    case portrait

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .landscape: return "Landscape"
        case .portrait: return "Portrait"
        }
    }

    func resolved(using interfaceOrientation: ClientDisplayOrientation) -> ClientDisplayOrientation {
        switch self {
        case .automatic: return interfaceOrientation
        case .landscape: return .landscape
        case .portrait: return .portrait
        }
    }
}

struct DisplayResolution: Hashable, Identifiable {
    let width: UInt32
    let height: UInt32

    var id: String { "\(width)x\(height)" }
    var title: String { "\(width) × \(height)" }
}

struct DisplayMode: Hashable {
    let width: UInt32
    let height: UInt32
    let refreshHz: UInt32
    let isExperimental: Bool

    var resolution: DisplayResolution {
        DisplayResolution(width: width, height: height)
    }
}

struct DisplayCapabilities: Equatable {
    static let encodedSize = 52

    let modes: [DisplayMode]
    let preferred: DisplayMode

    var resolutions: [DisplayResolution] {
        var seen = Set<DisplayResolution>()
        return modes.compactMap { mode in
            let resolution = mode.resolution
            return seen.insert(resolution).inserted ? resolution : nil
        }
    }

    func refreshRates(for resolution: DisplayResolution) -> [UInt32] {
        modes.compactMap { mode in
            mode.resolution == resolution ? mode.refreshHz : nil
        }
    }

    func supports(_ preference: DisplayPreference) -> Bool {
        modes.contains {
            $0.width == preference.width &&
            $0.height == preference.height &&
            $0.refreshHz == preference.refreshHz
        }
    }

    static func decode(_ data: Data) -> DisplayCapabilities? {
        guard data.count == encodedSize,
              data[0] == 1,
              (1...4).contains(Int(data[1])) else {
            return nil
        }

        let modeCount = Int(data[1])
        var decodedModes: [DisplayMode] = []
        decodedModes.reserveCapacity(modeCount)
        for index in 0..<modeCount {
            let offset = 4 + (index * 12)
            let width = data.loadLittleEndian(UInt32.self, at: offset)
            let height = data.loadLittleEndian(UInt32.self, at: offset + 4)
            let refreshHz = UInt32(data.loadLittleEndian(UInt16.self, at: offset + 8))
            let flags = data.loadLittleEndian(UInt16.self, at: offset + 10)
            guard width > 0,
                  height > 0,
                  refreshHz > 0,
                  (flags & ~UInt16(1)) == 0 else {
                return nil
            }
            decodedModes.append(DisplayMode(
                width: width,
                height: height,
                refreshHz: refreshHz,
                isExperimental: (flags & 1) != 0))
        }
        let nativeModes = decodedModes.filter {
            $0.width == 2388 &&
            $0.height == 1668 &&
            ($0.refreshHz == 120 || $0.refreshHz == 60) &&
            !$0.isExperimental
        }
        guard !nativeModes.isEmpty,
              nativeModes.count == decodedModes.count,
              let preferred = nativeModes.first(where: { $0.refreshHz == 120 })
                ?? nativeModes.first else { return nil }
        return DisplayCapabilities(modes: nativeModes, preferred: preferred)
    }
}

struct DisplayConfigurationRequest: Equatable {
    let width: UInt32
    let height: UInt32
    let refreshHz: UInt32
    let orientation: ClientDisplayOrientation
    let requestId: UInt32

    func encode() -> Data {
        var data = Data(count: 20)
        data[0] = 1
        data[1] = orientation.rawValue
        data.storeLittleEndian(width, at: 4)
        data.storeLittleEndian(height, at: 8)
        data.storeLittleEndian(refreshHz, at: 12)
        data.storeLittleEndian(requestId, at: 16)
        return data
    }
}

struct DisplayReady: Equatable {
    let width: UInt32
    let height: UInt32
    let refreshHz: UInt32
    let orientation: ClientDisplayOrientation
    let requestId: UInt32
    let generation: UInt32

    static func decode(_ data: Data) -> DisplayReady? {
        guard data.count == 24,
              data[0] == 1,
              let orientation = ClientDisplayOrientation(rawValue: data[1]) else {
            return nil
        }
        let width = data.loadLittleEndian(UInt32.self, at: 4)
        let height = data.loadLittleEndian(UInt32.self, at: 8)
        let refreshHz = data.loadLittleEndian(UInt32.self, at: 12)
        guard width > 0, height > 0, refreshHz > 0 else { return nil }
        return DisplayReady(
            width: width,
            height: height,
            refreshHz: refreshHz,
            orientation: orientation,
            requestId: data.loadLittleEndian(UInt32.self, at: 16),
            generation: data.loadLittleEndian(UInt32.self, at: 20))
    }
}

enum DisplayConfigurationFailureReason: UInt8, Equatable {
    case unsupportedMode = 1
    case applyFailed = 2
}

struct DisplayConfigurationFailed: Equatable {
    let requestId: UInt32
    let reason: DisplayConfigurationFailureReason

    static func decode(_ data: Data) -> DisplayConfigurationFailed? {
        guard data.count == 8,
              data[0] == 1,
              let reason = DisplayConfigurationFailureReason(rawValue: data[1]) else {
            return nil
        }
        return DisplayConfigurationFailed(
            requestId: data.loadLittleEndian(UInt32.self, at: 4),
            reason: reason)
    }
}

struct DisplayPreference: Equatable {
    static let nativeLandscapeWidth: UInt32 = 2388
    static let nativeLandscapeHeight: UInt32 = 1668
    static let nativeRefreshHz: UInt32 = 120
    static let defaultValue = DisplayPreference(
        width: nativeLandscapeWidth,
        height: nativeLandscapeHeight,
        refreshHz: nativeRefreshHz,
        orientationMode: .automatic)

    let width: UInt32
    let height: UInt32
    let refreshHz: UInt32
    let orientationMode: DisplayOrientationMode

    var resolution: DisplayResolution {
        DisplayResolution(width: width, height: height)
    }

    func makeRequest(
        interfaceOrientation: ClientDisplayOrientation,
        requestId: UInt32
    ) -> DisplayConfigurationRequest {
        let orientation = orientationMode.resolved(using: interfaceOrientation)
        return DisplayConfigurationRequest(
            width: orientation == .portrait
                ? Self.nativeLandscapeHeight
                : Self.nativeLandscapeWidth,
            height: orientation == .portrait
                ? Self.nativeLandscapeWidth
                : Self.nativeLandscapeHeight,
            refreshHz: Self.nativeRefreshHz,
            orientation: orientation,
            requestId: requestId)
    }

    func reconciled(with capabilities: DisplayCapabilities) -> DisplayPreference {
        let canonical = DisplayPreference(
            width: Self.nativeLandscapeWidth,
            height: Self.nativeLandscapeHeight,
            refreshHz: Self.nativeRefreshHz,
            orientationMode: orientationMode)
        guard capabilities.supports(canonical) else {
            return DisplayPreference(
                width: capabilities.preferred.width,
                height: capabilities.preferred.height,
                refreshHz: capabilities.preferred.refreshHz,
                orientationMode: orientationMode)
        }
        return canonical
    }
}

enum DisplayOrientationResolver {
    static func resolve(width: CGFloat, height: CGFloat) -> ClientDisplayOrientation? {
        guard width > 0, height > 0, width != height else { return nil }
        return height > width ? .portrait : .landscape
    }
}

struct DisplayRequestGate {
    private var nextRequestId: UInt32 = 0
    private(set) var pending: DisplayConfigurationRequest?
    private(set) var effective: DisplayReady?
    private(set) var latestDesired: DisplayConfigurationRequest?

    var isInputSuppressed: Bool { pending != nil }

    mutating func begin(_ requested: DisplayConfigurationRequest) -> DisplayConfigurationRequest? {
        let candidate = DisplayConfigurationRequest(
            width: requested.width,
            height: requested.height,
            refreshHz: requested.refreshHz,
            orientation: requested.orientation,
            requestId: 0)
        latestDesired = candidate
        guard pending == nil else { return nil }
        guard effective == nil || !sameConfiguration(candidate, effective!) else {
            latestDesired = nil
            return nil
        }
        return issue(candidate)
    }

    mutating func accept(_ ready: DisplayReady) -> DisplayConfigurationRequest? {
        guard let pending,
              pending.requestId == ready.requestId,
              sameConfiguration(pending, ready) else {
            return nil
        }
        effective = ready
        self.pending = nil
        guard let latestDesired,
              !sameConfiguration(latestDesired, ready) else {
            self.latestDesired = nil
            return nil
        }
        return issue(latestDesired)
    }

    mutating func reject(_ failed: DisplayConfigurationFailed) -> DisplayConfigurationRequest? {
        guard let pending, pending.requestId == failed.requestId else { return nil }
        self.pending = nil
        // Retry only a newer desired mode, never the rejected request itself.
        guard let latestDesired, !sameConfiguration(latestDesired, pending) else {
            self.latestDesired = nil
            return nil
        }
        return issue(latestDesired)
    }

    mutating func reset() {
        pending = nil
        effective = nil
        latestDesired = nil
    }

    private func sameConfiguration(
        _ request: DisplayConfigurationRequest,
        _ candidate: DisplayConfigurationRequest
    ) -> Bool {
        request.width == candidate.width &&
        request.height == candidate.height &&
        request.refreshHz == candidate.refreshHz &&
        request.orientation == candidate.orientation
    }

    private func sameConfiguration(
        _ request: DisplayConfigurationRequest,
        _ ready: DisplayReady
    ) -> Bool {
        request.width == ready.width &&
        request.height == ready.height &&
        request.refreshHz == ready.refreshHz &&
        request.orientation == ready.orientation
    }

    private mutating func issue(
        _ candidate: DisplayConfigurationRequest
    ) -> DisplayConfigurationRequest {
        nextRequestId &+= 1
        if nextRequestId == 0 { nextRequestId = 1 }
        let issued = DisplayConfigurationRequest(
            width: candidate.width,
            height: candidate.height,
            refreshHz: candidate.refreshHz,
            orientation: candidate.orientation,
            requestId: nextRequestId)
        pending = issued
        return issued
    }
}
