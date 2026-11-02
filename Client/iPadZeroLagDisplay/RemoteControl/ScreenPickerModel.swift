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
