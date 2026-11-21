import SwiftUI

/// Presentation only. The session owns mode changes and all input retirement.
struct RemoteTouchPresentation {
    let mode: IPadTouchMode
    let canPoint: Bool
    let canDirect: Bool

    var directSelected: Bool { mode == .direct && canPoint && canDirect }
    func enabled(_ choice: IPadTouchMode) -> Bool {
        canPoint && (choice != .direct || canDirect)
    }
    var helper: String { "Direct sends Windows touch. Trackpad moves the PC mouse pointer." }
    static let directUnavailable = "Direct touch is unavailable on this desktop. Select Trackpad to control it."
}

@MainActor struct RemoteMouseControls: View {
    @EnvironmentObject private var inputSession: IPadInputSession
    private var presentation: RemoteTouchPresentation {
        RemoteTouchPresentation(mode: inputSession.touchMode, canPoint: inputSession.canPoint,
                                canDirect: inputSession.canDirect)
    }

    var body: some View {
        SessionSegmentLayout {
            if presentation.enabled(.direct) {
                modeButton(.direct, title: "Direct")
            }
            modeButton(.trackpad, title: "Trackpad")
        }
        .foregroundStyle(Color(uiColor: SessionInk.text))
    }

    private func modeButton(_ choice: IPadTouchMode, title: String) -> some View {
        let enabled = presentation.enabled(choice)
        let selected = enabled && inputSession.touchMode == choice
        return Button {
            guard enabled else { return }
            inputSession.selectTouchMode(choice)
        } label: {
            SessionSegmentLabel(title: title, selected: selected, enabled: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
        .accessibilityValue(!enabled ? "Unavailable" : (selected ? "Selected" : "Not selected"))
        .accessibilityHint(choice == .direct && !inputSession.canDirect
                           ? (inputSession.unavailableReason ?? RemoteTouchPresentation.directUnavailable) : presentation.helper)
        .accessibilityIdentifier("session.touch.\(choice.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The existing extras slot now shares the same pointer actions in every session.
@MainActor struct RemoteMouseExtras: View {
    @EnvironmentObject private var inputSession: IPadInputSession
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        SessionActionLayout(accessibility: typeSize.isAccessibilitySize) {
            clickButton("Click", button: .left)
            clickButton("Right click", button: .right)
            clickButton("Middle click", button: .middle)
            Button {
                if inputSession.dragState != .idle { inputSession.releaseDrag() }
                else if inputSession.canPoint { inputSession.beginDrag() }
            } label: {
                SessionInputControlLabel(title: inputSession.dragState == .idle ? "Drag" : "Release drag")
            }
            .buttonStyle(.plain)
            .disabled(!inputSession.canPoint && inputSession.dragState == .idle)
            .accessibilityLabel(inputSession.dragState == .idle ? "Drag" : "Release drag")
            .accessibilityValue(dragValue)
            .accessibilityHint("Direct holds a Windows touch contact. Trackpad holds the left mouse button.")
            .accessibilityIdentifier("session.input.drag")
            Button { inputSession.releaseAll() } label: {
                SessionInputControlLabel(title: "Release all")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Release all")
            .accessibilityHint("Releases held touch, mouse buttons, keys and modifiers")
            .accessibilityIdentifier("session.input.release-all")
        }
    }

    private var dragValue: String {
        switch inputSession.dragState {
        case .idle: return "Off"
        case .armed: return "Armed; touch a position to start"
        case .latched: return "Dragging"
        }
    }

    private func clickButton(_ title: String, button: IPadPointerButton) -> some View {
        Button {
            guard inputSession.canPoint else { return }
            inputSession.click(button)
        } label: { SessionInputControlLabel(title: title) }
        .buttonStyle(.plain)
        .disabled(!inputSession.canPoint).opacity(inputSession.canPoint ? 1 : 0.45)
        .accessibilityLabel(title)
        .accessibilityHint("At the accessible pointer position")
    }
}
