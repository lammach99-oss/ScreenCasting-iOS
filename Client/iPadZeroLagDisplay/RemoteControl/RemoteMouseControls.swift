import SwiftUI

/// Two primary choices preserve all three underlying input behaviors.
struct RemoteTouchPresentation: Equatable {
    let mode: RemoteMouseMode
    init(mode: RemoteMouseMode) { self.mode = mode }
    var trackpadSelected: Bool { mode != .direct }
    static let trackpadChoice: RemoteMouseMode = .auto
    static func advancedChoice(enabled: Bool) -> RemoteMouseMode { enabled ? .trackpad : .auto }
    var helper: String {
        trackpadSelected ? "Move your finger to move the pointer. Tap to click." : "Tap where you want to click."
    }
}

struct RemoteMouseControls: View {
    let mode: RemoteMouseMode
    // Always use the existing callback: it releases input, resets reason 3 and waits for fresh context.
    let onModeChange: (RemoteMouseMode) -> Void
    var enabled = true
    @Environment(\.dynamicTypeSize) private var typeSize
    private var presentation: RemoteTouchPresentation { RemoteTouchPresentation(mode: mode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 8) { modes }
            } else {
                HStack(spacing: 8) { modes }
            }
            Text(presentation.helper).font(.footnote)
                .foregroundStyle(Color(uiColor: SessionInk.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color(uiColor: SessionInk.text))
    }

    private var modes: some View {
        ForEach([RemoteMouseMode.auto, .direct], id: \.self) { choice in
            let selected = choice == .auto ? presentation.trackpadSelected : !presentation.trackpadSelected
            let title = choice == .auto ? "Trackpad" : "Direct"
            Button {
                if !selected { onModeChange(choice) }
            } label: {
                Text(title).font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 8)
                    .background(Color(uiColor: selected ? SessionInk.accent : SessionInk.raised)
                        .opacity(selected ? 0.16 : 1),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(uiColor: selected ? SessionInk.accent : SessionInk.hairline),
                            lineWidth: selected ? 1.5 : 0.5))
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            .accessibilityLabel(title)
            .accessibilityValue(selected ? "Selected" : "Not selected")
            .accessibilityIdentifier(choice == .auto ? "session.touch.trackpad" : "session.touch.direct")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

struct RemoteMouseExtras: View {
    let mode: RemoteMouseMode
    let onModeChange: (RemoteMouseMode) -> Void
    let onMiddleClick: () -> Void
    var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onMiddleClick) {
                Text("Middle click").font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 8)
                    .background(Color(uiColor: SessionInk.raised),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Middle click")
            .accessibilityHint("Presses and releases the middle mouse button at the current pointer")
            .accessibilityIdentifier("session.input.middle-click")
            if mode != .direct {
                Toggle(isOn: Binding(get: { mode == .trackpad }, set: {
                    onModeChange(RemoteTouchPresentation.advancedChoice(enabled: $0))
                })) {
                    Text("Use Trackpad for Pencil and mouse")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
                .frame(minHeight: 44)
                .tint(Color(uiColor: SessionInk.accent))
                .accessibilityIdentifier("session.input.all-device-trackpad")
                Text("Pencil and mouse point directly unless you enable this option.")
                    .font(.footnote).foregroundStyle(Color(uiColor: SessionInk.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(Color(uiColor: SessionInk.text))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}
