import SwiftUI

struct SessionWindowsShortcut: Identifiable {
    let title: String
    let label: String
    let usage: UInt16
    var shift = false
    var id: String { title }

    static let all: [Self] = [
        .init(title: "Win", label: "Windows Start", usage: 0),
        .init(title: "Win+Tab", label: "Windows task view", usage: 0x2b),
        .init(title: "Win+D", label: "Show desktop", usage: 0x07),
        .init(title: "Win+E", label: "Open File Explorer", usage: 0x08),
        .init(title: "Win+R", label: "Open Run", usage: 0x15),
        .init(title: "Win+Space", label: "Change Windows input language", usage: 0x2c),
        .init(title: "Win+H", label: "Windows voice typing", usage: 0x0b),
        .init(title: "Win+Shift+S", label: "Windows screenshot selection", usage: 0x16, shift: true)
    ]
}

/// Shared by Extend, controlled Mirror and whole-PC remote. Input policy stays in the session.
@MainActor struct SessionInputBar: View {
    @EnvironmentObject private var inputSession: IPadInputSession
    @Environment(\.dynamicTypeSize) private var typeSize
    let onClose: () -> Void
    @State private var shortcutsExpanded = false
    private let expandSpecialKeys: Bool

    init(onClose: @escaping () -> Void, expandedSections: Bool = false) {
        self.onClose = onClose
        self.expandSpecialKeys = expandedSections
        _shortcutsExpanded = State(initialValue: expandedSections)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text("Input").font(.headline).accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                Button(action: onClose) {
                    Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide input bar")
            }
            ScrollView { InputSections(owner: self) }
                .scrollBounceBehavior(.basedOnSize)
        }
        .padding(12)
        .foregroundStyle(Color(uiColor: SessionInk.text))
        .background(Color(uiColor: SessionInk.surface), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(Color(uiColor: SessionInk.hairline), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.input.bar")
    }

    @MainActor private struct InputSections: View {
        let owner: SessionInputBar
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                ModifierSection(owner: owner)
                RemoteSpecialKeyBar(expanded: owner.expandSpecialKeys, functionsExpanded: owner.expandSpecialKeys)
                WindowsShortcuts(owner: owner)
                Text("Command = Ctrl. Hardware keyboard uses the PC input method; the on-screen keyboard uses the iPad input method.")
                    .font(.footnote).foregroundStyle(Color(uiColor: SessionInk.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                Button { owner.inputSession.releaseAll() } label: {
                    SessionInputControlLabel(title: "Release all")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Release all")
                .accessibilityHint("Releases held touch, mouse buttons, keys and modifiers")
            }
        }
    }

    @MainActor private struct ModifierSection: View {
        let owner: SessionInputBar
        var body: some View {
            Group {
                if !owner.inputSession.canType {
                    Text(owner.inputSession.unavailableReason ?? "Ask for control first to type on the PC.")
                        .font(.footnote).foregroundStyle(Color(uiColor: SessionInk.warning))
                        .fixedSize(horizontal: false, vertical: true)
                }
                SessionActionLayout(accessibility: owner.typeSize.isAccessibilitySize) {
                    ForEach(Array(IPadModifier.allCases.enumerated()), id: \.offset) { entry in
                        SessionModifierButton(session: owner.inputSession, modifier: entry.element)
                    }
                }
            }
        }
    }

    @MainActor private struct WindowsShortcuts: View {
        let owner: SessionInputBar
        var body: some View {
            DisclosureGroup(isExpanded: owner.$shortcutsExpanded) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: owner.typeSize.isAccessibilitySize ? 180 : 100), spacing: 8)], spacing: 8) {
                    ForEach(SessionWindowsShortcut.all) { shortcut in
                        owner.shortcutButton(shortcut)
                    }
                }
            } label: {
                Text("Windows shortcuts").font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }
        }
    }

    private func shortcutButton(_ shortcut: SessionWindowsShortcut) -> some View {
        Button {
            guard inputSession.canType else { return }
            inputSession.tapWindowsShortcut(hidUsage: shortcut.usage, shift: shortcut.shift)
        } label: { SessionInputControlLabel(title: shortcut.title) }
        .buttonStyle(.plain)
        .disabled(!inputSession.canType).opacity(inputSession.canType ? 1 : 0.45)
        .accessibilityLabel(shortcut.title + ", " + shortcut.label)
    }
}

/// These methods are also the deterministic activation seam for assistive technologies and tests.
@MainActor struct SessionModifierButton: View {
    @ObservedObject var session: IPadInputSession
    let modifier: IPadModifier

    static func title(for modifier: IPadModifier) -> String {
        switch modifier {
        case .control: return "Ctrl"
        case .alt: return "Alt"
        case .shift: return "Shift"
        case .win: return "Win"
        }
    }

    static func value(for state: IPadModifierState) -> String {
        switch state {
        case .off: return "Off"
        case .oneShot: return "One-shot"
        case .locked: return "Locked"
        }
    }

    static func nextState(after state: IPadModifierState) -> IPadModifierState {
        switch state {
        case .off: return .oneShot
        case .oneShot, .locked: return .off
        }
    }

    func activate() {
        let next = Self.nextState(after: session.modifierState(modifier))
        guard session.canType || next == .off else { return }
        session.setModifier(modifier, next)
    }

    func useOnce() {
        guard session.canType else { return }
        session.setModifier(modifier, .oneShot)
    }

    func lock() {
        guard session.canType else { return }
        session.setModifier(modifier, .locked)
    }

    func turnOff() { session.setModifier(modifier, .off) }

    var body: some View {
        let state = session.modifierState(modifier)
        Button(action: activate) {
            VStack(spacing: 4) {
                Text(Self.title(for: modifier)).font(.subheadline.weight(.semibold))
                Text(Self.value(for: state)).font(.caption)
            }
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center).padding(8)
            .frame(minWidth: 44, maxWidth: .infinity, minHeight: 60)
            .background(Color(uiColor: state == .off ? SessionInk.raised : SessionInk.accent)
                .opacity(state == .off ? 1 : 0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(uiColor: state == .off ? SessionInk.hairline : SessionInk.accent),
                        lineWidth: state == .off ? 0.5 : 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .highPriorityGesture(TapGesture(count: 2).onEnded { lock() })
        .disabled(!session.canType && state == .off)
        .opacity(session.canType ? 1 : 0.45)
        .accessibilityLabel(modifier == .win ? "Windows modifier" : Self.title(for: modifier) + " modifier")
        .accessibilityValue(Self.value(for: state))
        .accessibilityHint("Tap to use once or turn off. Double tap to lock. Actions offer explicit states.")
        .accessibilityAddTraits(state == .off ? [] : .isSelected)
        .accessibilityAction { activate() }
        .accessibilityAction(named: Text("Use once")) { useOnce() }
        .accessibilityAction(named: Text("Lock")) { lock() }
        .accessibilityAction(named: Text("Turn off")) { turnOff() }
    }
}

/// Kept outside both panel and input-bar visibility so closing either cannot hide an active latch.
@MainActor struct SessionDraggingChip: View {
    @EnvironmentObject private var inputSession: IPadInputSession

    var body: some View {
        if inputSession.dragState == .latched {
            Button { inputSession.releaseDrag() } label: {
                Text("Dragging - Release").font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(minWidth: 44, minHeight: 44)
                    .foregroundStyle(Color(uiColor: SessionInk.warning))
                    .background(Color(uiColor: SessionInk.surface), in: Capsule())
                    .overlay(Capsule().stroke(Color(uiColor: SessionInk.warning), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dragging - Release")
            .accessibilityValue("Dragging")
            .accessibilityHint("Releases the held touch contact or left mouse button")
            .accessibilityIdentifier("session.input.drag-release")
        }
    }
}
