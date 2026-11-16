import SwiftUI

/// A local positioning alternative: every move goes through the authorized session.
@MainActor struct AccessiblePointerControls: View {
    @EnvironmentObject private var inputSession: IPadInputSession
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var coarse = true

    static func positionValue(_ target: CGPoint) -> String {
        func percent(_ value: CGFloat) -> Int {
            guard value.isFinite else { return 50 }
            return Int((min(1, max(0, value)) * 100).rounded())
        }
        return "Horizontal \(percent(target.x)) percent, vertical \(percent(target.y)) percent"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pointer position").font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(Self.positionValue(inputSession.accessibleTarget)).font(.footnote)
                .foregroundStyle(Color(uiColor: SessionInk.secondary))
                .accessibilityIdentifier("session.pointer.position")
            Toggle("Large steps", isOn: $coarse)
                .font(.subheadline).frame(minHeight: 44)
                .tint(Color(uiColor: SessionInk.accent))
                .accessibilityValue(coarse ? "Coarse" : "Fine")
            SessionActionLayout(accessibility: typeSize.isAccessibilitySize) {
                nudge("Up", direction: .up)
                nudge("Down", direction: .down)
                nudge("Left", direction: .left)
                nudge("Right", direction: .right)
            }
            // Buttons support Switch Control; separate axes also support VoiceOver adjustment.
            adjustableAxis("Horizontal position", negative: .left, positive: .right)
            adjustableAxis("Vertical position", negative: .up, positive: .down)
        }
        .foregroundStyle(Color(uiColor: SessionInk.text))
        .disabled(!inputSession.canPoint).opacity(inputSession.canPoint ? 1 : 0.45)
    }

    private func move(_ direction: IPadNudgeDirection) {
        guard inputSession.canPoint else { return }
        inputSession.moveAccessibleTarget(direction, coarse: coarse)
    }

    private func nudge(_ title: String, direction: IPadNudgeDirection) -> some View {
        Button { move(direction) } label: { SessionInputControlLabel(title: title) }
            .buttonStyle(.plain)
            .accessibilityLabel("Move pointer \(title.lowercased())")
            .accessibilityValue(Self.positionValue(inputSession.accessibleTarget))
            .accessibilityHint(coarse ? "Moves by a large step" : "Moves by a small step")
    }

    private func adjustableAxis(_ title: String, negative: IPadNudgeDirection,
                                positive: IPadNudgeDirection) -> some View {
        Text(title).font(.footnote)
            .frame(minHeight: 44, alignment: .leading)
            .accessibilityLabel(title)
            .accessibilityValue(Self.positionValue(inputSession.accessibleTarget))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: move(positive)
                case .decrement: move(negative)
                @unknown default: break
                }
            }
    }
}

/// Shared label geometry uses the panel's existing colours, corners and semantic fonts.
struct SessionInputControlLabel: View {
    let title: String
    var selected = false

    var body: some View {
        Text(title).font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .padding(8)
            .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(Color(uiColor: SessionInk.text))
            .background(Color(uiColor: selected ? SessionInk.accent : SessionInk.raised)
                .opacity(selected ? 0.16 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(uiColor: selected ? SessionInk.accent : SessionInk.hairline),
                        lineWidth: selected ? 1.5 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
