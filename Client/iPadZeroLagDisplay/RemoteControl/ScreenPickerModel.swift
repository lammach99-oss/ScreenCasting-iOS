import Foundation

/// One PC screen as the iPad picker shows it.
public struct ScreenPickerTile: Equatable, Identifiable {
    public enum Status: Equatable { case showing, available, switching, locked }
    public let id: UInt64
    public let label: String
    public let isBuiltIn: Bool
    public let status: Status
}

/// Pure view state for the screen picker. Everything it shows comes from the Host's catalogue and mirror
/// state; tapping a tile or a button is the only thing that asks the Host for a change.
public struct ScreenPickerSnapshot: Equatable {
    public enum Phase: Equatable { case loading, ready, locked }
    public enum Control: Equatable { case on, viewOnly, unavailable }

    public let phase: Phase
    public let tiles: [ScreenPickerTile]
    public let control: Control
    /// The Host can be asked to allow switching, and has not been asked yet.
    public let canAskPermission: Bool
    public let isSwitching: Bool
    /// Name of the screen the iPad is showing now, or nil before the list arrives.
    public let currentLabel: String?

    public static func make(catalogue: MirrorMonitorCatalogue?, state: MirrorControlState?, switchingTo: UInt64?,
                            switchPending: Bool, pickerSupported: Bool, permissionAsked: Bool) -> Self {
        let control: Control = state?.geometry == nil ? .unavailable : state?.mode == .active ? .on : .viewOnly
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
    public var reconnectingText: String { "Reconnecting to \(hostLabel)…" }

    /// `transport` is the transfer snapshot's label; anything but "Wi-Fi" or "USB-C" means not known yet.
    public static func make(hostLabel: String?, transport: String, connection: ConnectionState,
                            control: ScreenPickerSnapshot.Control, mirrorLabel: String?) -> Self {
        let trimmed = hostLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = trimmed.isEmpty ? "Your PC" : trimmed
        let isMirror = control != .unavailable
        let icon: Icon = !isMirror ? .extended
            : mirrorLabel.map(ScreenPickerSnapshot.isBuiltIn) == true ? .laptop : .monitor
        return Self(title: isMirror ? mirrorLabel ?? host : host, hostLabel: host,
                    transport: ["Wi-Fi", "USB-C"].contains(transport) ? transport : nil,
                    isMirror: isMirror, control: control, reconnecting: connection != .streaming, icon: icon)
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
