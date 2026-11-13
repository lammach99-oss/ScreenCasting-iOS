import SwiftUI
import UIKit

/// RI-F owns the binding shared with RemoteHardwareKeyboard and readiness gating.
/// sendKey must capture the originating connection generation; reset handling must
/// also send RemoteInputReset through the negotiated context when the link is up.
struct RemoteSpecialKeyBar: View {
    @Binding var keyboard: RemoteKeyboardState
    let sendKey: (RemoteScanKeyCommand) -> Void
    let remoteCommand: (RemoteHostCommand) -> Void
    let releaseKeys: () -> Void

    @State private var expanded = false
    @State private var functionsExpanded = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 140 : 76), spacing: 8)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                Label("Keys", systemImage: "keyboard")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(Color(uiColor: SessionInk.raised), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Keys")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows or hides remote special keys")
            .accessibilityAddTraits(.isButton)

            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        LazyVGrid(columns: columns, spacing: 8) {
                            keyButton("Esc", label: "Escape", usage: 0x29)
                            keyButton("Tab", label: "Tab", usage: 0x2b)
                            ForEach(RemoteKeyboardState.Modifier.allCases, id: \.self) { modifier in
                                modifierButton(modifier)
                            }
                            keyButton("Left", label: "Left arrow", usage: 0x50)
                            keyButton("Up", label: "Up arrow", usage: 0x52)
                            keyButton("Down", label: "Down arrow", usage: 0x51)
                            keyButton("Right", label: "Right arrow", usage: 0x4f)
                        }

                        Button { functionsExpanded.toggle() } label: {
                            Label("F1-F12", systemImage: "chevron.down")
                                .font(.footnote.weight(.medium))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Function keys F1 through F12")
                        .accessibilityValue(functionsExpanded ? "Expanded" : "Collapsed")
                        .accessibilityHint("Shows or hides function keys")
                        .accessibilityAddTraits(.isButton)

                        if functionsExpanded {
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(1...12, id: \.self) { number in
                                    keyButton("F\(number)", label: "F\(number)", usage: 0x39 + number)
                                }
                            }
                        }

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { commandButtons }
                            VStack(spacing: 8) { commandButtons }
                        }
                    }
                    .padding(12)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 280)
                .background(Color(uiColor: SessionInk.surface),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color(uiColor: SessionInk.hairline), lineWidth: 0.5))
            }
        }
        .foregroundStyle(Color(uiColor: SessionInk.text))
        .environment(\.colorScheme, .dark)
    }

    private func keyButton(_ title: String, label: String, usage: Int) -> some View {
        Button {
            guard let key = RemoteHardwareKeyboard.key(forUsage: usage) else { return }
            keyboard.tapKey(key).forEach(sendKey)
        } label: {
            keyLabel(title)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint("Sends \(label) to the remote PC")
        .accessibilityAddTraits(.isButton)
    }

    private func modifierButton(_ modifier: RemoteKeyboardState.Modifier) -> some View {
        let state = keyboard.modifierState(modifier)
        return Button {
            keyboard.tapModifier(modifier, at: ProcessInfo.processInfo.systemUptime).forEach(sendKey)
            UIAccessibility.post(notification: .announcement,
                                 argument: "\(modifier.rawValue), \(keyboard.modifierState(modifier).rawValue)")
        } label: {
            VStack(spacing: 4) {
                Text(modifier.rawValue).font(.footnote.weight(.medium))
                Text(state.rawValue).font(.caption)
            }
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .padding(8)
            .frame(minWidth: 44, maxWidth: .infinity, minHeight: 60)
            .background(Color(uiColor: state == .off ? SessionInk.raised : SessionInk.accent)
                .opacity(state == .off ? 1 : 0.16),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(uiColor: state == .off ? SessionInk.hairline : SessionInk.accent),
                        lineWidth: state == .off ? 0.5 : 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(modifier == .win ? "Windows modifier" : "\(modifier.rawValue) modifier")
        .accessibilityValue(state.rawValue)
        .accessibilityHint("Tap for the next key. Double tap within 300 milliseconds to lock. Tap again to release.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(state == .off ? [] : .isSelected)
        .accessibilityAction(named: Text("Lock modifier")) {
            keyboard.lockModifier(modifier).forEach(sendKey)
            UIAccessibility.post(notification: .announcement, argument: "\(modifier.rawValue), Locked")
        }
    }

    private var commandButtons: some View {
        Group {
            Button { remoteCommand(.secureAttention) } label: {
                keyLabel("Ctrl+Alt+Del")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ctrl Alt Delete")
            .accessibilityHint("Opens the Windows security screen using a remote command")
            .accessibilityAddTraits(.isButton)

            Button {
                releaseKeys()
            } label: {
                keyLabel("Release keys")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Release keys")
            .accessibilityHint("Releases all held remote keys and clears sticky modifiers")
            .accessibilityAddTraits(.isButton)
        }
    }

    private func keyLabel(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.medium))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
            .background(Color(uiColor: SessionInk.raised),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
