import Foundation

/// Session identity is independent of whether input permission is available.
public enum SessionPanelKind: Equatable {
    case wholePCRemote, castingMirror, castingExtend, castingUnknown

    public static func make(remote: Bool, targets: CaptureTargetState, legacy: MirrorControlState?,
                            catalogue: MirrorMonitorCatalogue?) -> Self {
        if remote { return .wholePCRemote }
        if targets.enabled {
            guard !targets.unknownOutcome, let entry = targets.catalogue?.entries.first(where: {
                $0.id == targets.confirmedCurrentId
            }) else { return .castingUnknown }
            return entry.kind == .extend ? .castingExtend : .castingMirror
        }
        if legacy?.mode == .virtualDisplay { return .castingExtend }
        if let catalogue, catalogue.monitors.contains(where: { $0.id == catalogue.selected }) { return .castingMirror }
        return .castingUnknown
    }
}

/// Display-only cycle. The network owner still admits every request against its catalogue.
public struct ScreenCyclePresentation: Equatable {
    public let currentLabel: String
    public let position: Int?
    public let count: Int
    public let nextTargetId: UInt64?
    public let nextLabel: String?
    public let pending: Bool
    public let reason: String?
    let usesCaptureTargets: Bool
    public var enabled: Bool { nextTargetId != nil && reason == nil }
    public var accessibilityValue: String {
        position.map { "\(currentLabel), \($0) of \(count)" } ?? currentLabel
    }
    public var detail: String {
        position.map { "\(currentLabel) \u{00B7} \($0) of \(count)" } ?? currentLabel
    }
    public var hint: String { reason ?? nextLabel.map { "Show \($0)" } ?? "Choose a screen" }

    public static func make(candidates: [ScreenPickerTile], currentId: UInt64?, pending: Bool,
                            disabledReason: String? = nil, extendActive: Bool = false,
                            usesCaptureTargets: Bool = false) -> Self {
        let screens = usesCaptureTargets ? candidates : candidates.filter { !$0.isExtend }
        let index = screens.firstIndex { $0.id == currentId }
        let next = index.map { screens[($0 + 1) % screens.count] } ??
            screens.first { !$0.isExtend } ?? screens.first
        let legacyExtend = extendActive && !usesCaptureTargets
        let reason: String?
        if pending { reason = "Switching screens\u{2026}" }
        else if legacyExtend { reason = "Choose Mirror to switch PC screens." }
        else if let disabledReason { reason = disabledReason }
        else if screens.isEmpty { reason = "No screens are available." }
        else if screens.count == 1 && index != nil { reason = "Only one screen is available." }
        else if next?.canSelect != true { reason = "Screen selection is not ready. Refresh screens to try again." }
        else { reason = nil }
        return Self(currentLabel: legacyExtend ? "Extend iPad" : index.map { screens[$0].label } ?? "Choose a screen",
                    position: legacyExtend ? nil : index.map { $0 + 1 }, count: screens.count,
                    nextTargetId: next?.id, nextLabel: next?.label, pending: pending, reason: reason,
                    usesCaptureTargets: usesCaptureTargets)
    }
}

public struct CaptureModeChoice: Equatable {
    public let targetId: UInt64?
    public let selected: Bool
    public let enabled: Bool
}

/// A selected Extend segment can be activated again only for an admitted unknown-outcome recovery.
public struct CaptureModePresentation: Equatable {
    public let extend: CaptureModeChoice
    public let mirror: CaptureModeChoice
    public let explanation: String?

    public static func make(targets: CaptureTargetState, kind: SessionPanelKind,
                            lastPhysicalId: UInt64?, switchBlockedReason: String? = nil) -> Self {
        guard targets.enabled else {
            return Self(extend: CaptureModeChoice(targetId: nil, selected: kind == .castingExtend, enabled: false),
                        mirror: CaptureModeChoice(targetId: nil, selected: kind == .castingMirror, enabled: false),
                        explanation: "Update ScreenCasting on the PC to change Extend or Mirror.")
        }
        let catalogue = targets.catalogue
        let entries = catalogue?.entries ?? []
        let physical = entries.filter { $0.kind == .physical }
        let extended = entries.first { $0.kind == .extend }
        let current = entries.first { $0.id == targets.confirmedCurrentId }
        let ready = switchBlockedReason == nil && targets.canSelect && !targets.needsCatalogueRefresh && !targets.isSwitching &&
            catalogue?.state == 1 && catalogue?.allowed == true
        let mirror = physical.first { $0.id == lastPhysicalId } ?? physical.first
        let recoveringExtend = targets.unknownOutcome && current?.kind == .extend
        return Self(extend: CaptureModeChoice(targetId: extended?.id, selected: current?.kind == .extend,
                        enabled: ready && extended != nil && (current?.kind != .extend || recoveringExtend)),
                    mirror: CaptureModeChoice(targetId: mirror?.id, selected: current?.kind == .physical,
                        enabled: ready && mirror != nil && current?.kind != .physical),
                     explanation: switchBlockedReason ?? (recoveringExtend ? "Choose Extend again to restore the picture." : nil))
    }
}

/// Remembers confirmed physical identity only within the current source/session owner.
public struct ConfirmedPhysicalScreen: Equatable {
    private var session: UUID?
    private var owner: UInt64?
    public private(set) var id: UInt64?
    public init() {}
    public mutating func observe(_ targets: CaptureTargetState) {
        if session != targets.session || owner != targets.catalogue?.owner || !targets.enabled {
            id = nil
        }
        session = targets.session; owner = targets.catalogue?.owner
        if let id, targets.catalogue?.entries.contains(where: { $0.id == id && $0.kind == .physical }) != true {
            self.id = nil
        }
        guard !targets.isSwitching, !targets.unknownOutcome, !targets.inputBlocked,
              let entry = targets.catalogue?.entries.first(where: { $0.id == targets.confirmedCurrentId }),
              entry.kind == .physical else { return }
        id = entry.id
    }
}

/// One PC screen as the iPad picker shows it.
public struct ScreenPickerTile: Equatable, Identifiable {
    public enum Status: Equatable { case showing, available, switching, locked }
    public let id: UInt64
    public let label: String
    public let isBuiltIn: Bool
    public let status: Status
    public let isExtend: Bool
    public let canSelect: Bool
    public init(id: UInt64, label: String, isBuiltIn: Bool, status: Status,
                isExtend: Bool = false, canSelect: Bool? = nil) {
        self.id=id;self.label=label;self.isBuiltIn=isBuiltIn;self.status=status;self.isExtend=isExtend
        self.canSelect=canSelect ?? (status == .available)
    }
}

/// Pure view state for the screen picker. Everything it shows comes from the Host's catalogue and mirror
/// state. Only an explicit cycle or mode activation asks the Host for a change.
public struct ScreenPickerSnapshot: Equatable {
    public enum Phase: Equatable { case loading, ready, locked }
    public enum Control: Equatable { case on, viewOnly, unavailable }

    public let phase: Phase
    public let tiles: [ScreenPickerTile]
    public let control: Control
    public var canType: Bool { control == .on }
    /// The Host can be asked to allow switching, and has not been asked yet.
    public let canAskPermission: Bool
    public let isSwitching: Bool
    /// Name of the screen the iPad is showing now, or nil before the list arrives.
    public let currentLabel: String?
    public var selectionDisabledReason: String? = nil
    var usesCaptureTargets = false

    public func cycle(kind: SessionPanelKind, disabledReason: String? = nil) -> ScreenCyclePresentation {
        let fallback: String? = phase == .loading ? "Loading screens..."
            : phase == .locked ? "Screen switching is off on the PC." : nil
        return .make(candidates: tiles, currentId: tiles.first { $0.status == .showing }?.id,
                     pending: isSwitching, disabledReason: disabledReason ?? selectionDisabledReason ?? fallback,
                     extendActive: kind == .castingExtend, usesCaptureTargets: usesCaptureTargets)
    }

    private static func castingControl(state: MirrorControlState?, inputBlocked: Bool,
                                       legacyInputAvailable: Bool, legacyInputSuspended: Bool) -> Control {
        if state?.mode == .virtualDisplay || state == nil && (legacyInputAvailable || legacyInputSuspended) {
            return inputBlocked || legacyInputSuspended ? .viewOnly : .on
        }
        guard state?.geometry != nil else { return .unavailable }
        return state?.mode == .active && !inputBlocked ? .on : .viewOnly
    }

    public static func make(catalogue: MirrorMonitorCatalogue?, state: MirrorControlState?, switchingTo: UInt64?,
                            switchPending: Bool, pickerSupported: Bool, permissionAsked: Bool,
                            legacyInputAvailable: Bool = false, legacyInputSuspended: Bool = false) -> Self {
        let control = castingControl(state: state, inputBlocked: switchPending,
            legacyInputAvailable: legacyInputAvailable, legacyInputSuspended: legacyInputSuspended)
        guard let catalogue else {
            return Self(phase: .loading, tiles: [], control: control, canAskPermission: false,
                        isSwitching: switchPending, currentLabel: nil)
        }
        let target = switchPending ? switchingTo : nil
        let tiles = catalogue.monitors.map { monitor -> ScreenPickerTile in
            let status: ScreenPickerTile.Status
            if monitor.id == catalogue.selected { status = .showing }
            else if monitor.id == target { status = .switching }
            else if !catalogue.allowed || switchPending { status = .locked }
            else { status = .available }
            return ScreenPickerTile(id: monitor.id, label: monitor.label, isBuiltIn: isBuiltIn(monitor.label), status: status)
        }
        return Self(phase: catalogue.allowed ? .ready : .locked, tiles: tiles, control: control,
                    canAskPermission: !catalogue.allowed && pickerSupported && !permissionAsked,
                    isSwitching: switchPending,
                    currentLabel: catalogue.monitors.first { $0.id == catalogue.selected }?.label)
    }

    public static func shouldShowPicker(remote: Bool, mirror: Bool, acceptedFeatures: UInt64,
                                        typedSources: Bool = false) -> Bool {
        remote ? acceptedFeatures & 7 == 7 : mirror || typedSources
    }

    public static func make(captureTargets: CaptureTargetState, state: MirrorControlState?,
                            permissionAsked: Bool = false, legacyInputAvailable: Bool = false,
                            legacyInputSuspended: Bool = false) -> Self {
        let current=captureTargets.unknownOutcome ? 0 : captureTargets.confirmedCurrentId
        let control = castingControl(state: state, inputBlocked: captureTargets.inputBlocked,
            legacyInputAvailable: legacyInputAvailable, legacyInputSuspended: legacyInputSuspended)
        let listUnavailableReason = captureTargets.listUnavailable
            ? "The screen list is unavailable. Refresh screens to try again." : nil
        guard let pickerCatalogue = captureTargets.pickerCatalogue else {
            return Self(phase: captureTargets.listUnavailable ? .locked : .loading, tiles: [], control: control,
                        canAskPermission: false, isSwitching: captureTargets.isSwitching, currentLabel: nil,
                        selectionDisabledReason: listUnavailableReason)
        }
        let catalogue = captureTargets.catalogue
        let ready = catalogue?.state == 1 && catalogue?.allowed == true
        let selectable=ready && captureTargets.canSelect && !captureTargets.needsCatalogueRefresh
        let tiles=pickerCatalogue.entries.map { entry -> ScreenPickerTile in
            let status: ScreenPickerTile.Status
            if entry.id == captureTargets.pending?.request.targetId &&
                pickerCatalogue.revision == captureTargets.pending?.request.revision { status = .switching }
            else if entry.id == current { status = .showing }
            else if !selectable { status = .locked }
            else { status = .available }
            return ScreenPickerTile(id: entry.id, label: entry.kind == .extend ? "Extend iPad" : entry.name,
                isBuiltIn: entry.kind == .physical && isBuiltIn(entry.name), status: status,
                isExtend: entry.kind == .extend, canSelect: selectable)
        }
        let phase: Phase = ready ? .ready : catalogue == nil && !captureTargets.listUnavailable ? .loading : .locked
        return Self(phase: phase, tiles: tiles,
                    control: control, canAskPermission: catalogue?.state == 1 && catalogue?.allowed == false &&
                        !permissionAsked && !captureTargets.isSwitching,
                    isSwitching: captureTargets.isSwitching,
                    currentLabel: tiles.first(where: { $0.id == current })?.label,
                    selectionDisabledReason: catalogue == nil ? listUnavailableReason ?? "Loading screens..."
                        : catalogue?.state != 1 ? "Screens are unavailable. Stop and restart the session."
                        : !ready ? "Screen switching is off on the PC."
                        : captureTargets.needsCatalogueRefresh ? "Refresh screens before choosing a screen."
                        : !captureTargets.canSelect ? "Wait for the new screen picture." : nil,
                    usesCaptureTargets: true)
    }

    /// Remote catalogue adapter; admission remains owned by RemoteMonitorState.
    public static func make(remote: RemoteMonitorState, inputReady: Bool, controlEnabled: Bool = false) -> Self {
        let control: Control = remote.isSourceRecovery ? (controlEnabled ? .on : .viewOnly)
            : remote.context?.state == 1 ? (inputReady && controlEnabled ? .on : .viewOnly) : .unavailable
        guard remote.enabled, let catalogue = remote.catalogue else {
            return Self(phase: .loading, tiles: [], control: control, canAskPermission: false,
                        isSwitching: remote.pending != nil, currentLabel: nil)
        }
        let unavailable = catalogue.state == 0 || remote.issue == .unavailable
        let busy = remote.pending != nil || catalogue.state == 2 || remote.needsCatalogueRefresh
        let current = unavailable ? 0 : remote.displayCurrentId
        let selectable = control == .on && remote.selectionReady(inputReady: inputReady, controlEnabled: controlEnabled)
        let tiles = catalogue.entries.map { entry -> ScreenPickerTile in
            let status: ScreenPickerTile.Status
            if entry.id == current { status = .showing }
            else if !unavailable && entry.id == remote.pending?.request.targetId { status = .switching }
            else if unavailable || busy || control != .on || !selectable { status = .locked }
            else { status = .available }
            return ScreenPickerTile(id: entry.id, label: entry.name, isBuiltIn: isBuiltIn(entry.name), status: status)
        }
        return Self(phase: unavailable ? .locked : .ready, tiles: tiles, control: unavailable ? .unavailable : control,
                    canAskPermission: false, isSwitching: remote.pending != nil || catalogue.state == 2,
                    currentLabel: catalogue.entries.first { $0.id == current }?.name,
                    selectionDisabledReason: control != .on ? "Turn Control on to choose a screen."
                        : !selectable ? remote.selectionStatus(inputReady: inputReady, controlEnabled: controlEnabled) : nil)
    }

    /// The Host names a laptop panel with no reported name "Built-in display".
    static func isBuiltIn(_ label: String) -> Bool {
        label.caseInsensitiveCompare("Built-in display") == .orderedSame
    }
}

/// What the session pill says in every session: which PC, over what, which screen, and whether it is reconnecting.
public struct SessionPanelSnapshot: Equatable {
    public enum Icon: Equatable { case extended, monitor, laptop }
    public let title: String
    public let hostLabel: String
    public let transport: String?
    public let isMirror: Bool
    public let control: ScreenPickerSnapshot.Control
    public let reconnecting: Bool
    public let icon: Icon
    public let kind: SessionPanelKind
    public var reconnectingText: String { "Reconnecting to \(hostLabel)\u{2026}" }

    /// Casting uses the actual transfer route; remote uses the target category, never measured routing.
    public static func make(hostLabel: String?, transport: String, connection: ConnectionState,
                            control: ScreenPickerSnapshot.Control, mirrorLabel: String?,
                            kind: SessionPanelKind, tailnet: Bool = false) -> Self {
        let trimmed = hostLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = trimmed.isEmpty ? "Your PC" : trimmed
        let isMirror = kind == .castingMirror
        let icon: Icon = kind == .castingExtend ? .extended
            : mirrorLabel.map(ScreenPickerSnapshot.isBuiltIn) == true ? .laptop : .monitor
        let route: String? = kind == .wholePCRemote ? (tailnet ? "Tailnet" : "Network")
            : transport == "USB-C" ? "USB" : transport == "Wi-Fi" ? "Wi-Fi" : nil
        return Self(title: kind == .castingExtend ? "Extend iPad" : mirrorLabel ?? "Choose a screen", hostLabel: host,
                    transport: route, isMirror: isMirror, control: control, reconnecting: connection != .streaming,
                    icon: icon, kind: kind)
    }
}

public extension SessionPanelSnapshot {
    /// The PC to name in the pill. A Wi-Fi session started by auto-reconnect has no fresh label, so it falls back to
    /// the last Wi-Fi PC; a USB-C session never does, since that PC may be a different one.
    static func sessionHost(current: String, lastWifi: String, usb: Bool) -> String {
        current.isEmpty && !usb ? lastWifi : current
    }
}

/// Full pill, or a slim handle that keeps the top of the PC picture clear once the iPad is left alone.
public enum SessionPillPresentation: Equatable {
    case full, handle
    public static let idleDelay: TimeInterval = 3
    public static func make(isOpen: Bool, idleFor: TimeInterval, reconnecting: Bool) -> Self {
        isOpen || reconnecting || idleFor < idleDelay ? .full : .handle
    }
}

/// Disconnect asks once inline: the first tap arms it, a second tap within the window confirms.
public struct DisconnectArming: Equatable {
    public static let window: TimeInterval = 4
    private var armedAt: Date?
    public init() {}
    public func isArmed(at now: Date) -> Bool {
        armedAt.map { now.timeIntervalSince($0) <= Self.window } ?? false
    }
    public mutating func tap(at now: Date) -> Bool {
        if isArmed(at: now) { armedAt = nil; return true }
        armedAt = now
        return false
    }
    public mutating func reset() { armedAt = nil }
}

/// Geometry changes columns, never the section order or control set.
public enum SessionPanelLayout {
    public static func actionColumns(width: Double, idealWidths: [Double], accessibility: Bool) -> Int {
        guard !accessibility, let widest = idealWidths.max() else { return 1 }
        if widest * 3 + 16 <= width { return 3 }
        if widest * 2 + 8 <= width { return 2 }
        return 1
    }
}
