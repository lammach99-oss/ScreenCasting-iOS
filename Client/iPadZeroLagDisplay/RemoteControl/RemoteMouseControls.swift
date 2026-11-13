import SwiftUI

struct RemoteMouseControls: View {
    let mode: RemoteMouseMode
    // RI-F retires held input and sends reset before applying/persisting this choice.
    let onModeChange: (RemoteMouseMode) -> Void
    let onMiddleClick: () -> Void
    var enabled = true
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mouse").font(.footnote)
                .foregroundStyle(Color(uiColor: SessionInk.secondary))
            if typeSize.isAccessibilitySize {
                VStack(spacing: 8) { modes }
            } else {
                HStack(spacing: 8) { modes }
            }
            Button(action: onMiddleClick) {
                Text("Middle click").font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 8)
                    .background(Color(uiColor: SessionInk.raised),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Middle click on remote PC")
            .accessibilityHint("Presses and releases the middle mouse button")
        }
        .foregroundStyle(Color(uiColor: SessionInk.text))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private var modes: some View {
        ForEach(RemoteMouseMode.allCases, id: \.self) { choice in
            let selected = mode == choice
            Button {
                if !selected { onModeChange(choice) }
            } label: {
                Text(choice.title).font(.subheadline.weight(.semibold))
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
            .accessibilityLabel("Mouse mode, \(choice.title)")
            .accessibilityValue(selected ? "Selected" : "Not selected")
            .accessibilityHint(choice == .auto
                ? "Finger uses Trackpad. Pencil and external mouse use Direct."
                : choice == .trackpad ? "Move the remote cursor using relative motion"
                : "Point directly at the remote screen")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}
