import SwiftUI

struct SessionSpecialKey: Identifiable {
    let title: String
    let label: String
    let usage: UInt16
    var id: UInt16 { usage }

    static let standard: [Self] = [
        .init(title: "Esc", label: "Escape", usage: 0x29),
        .init(title: "Tab", label: "Tab", usage: 0x2b),
        .init(title: "Enter", label: "Enter", usage: 0x28),
        .init(title: "Backspace", label: "Backspace", usage: 0x2a),
        .init(title: "Left", label: "Left arrow", usage: 0x50),
        .init(title: "Up", label: "Up arrow", usage: 0x52),
        .init(title: "Down", label: "Down arrow", usage: 0x51),
        .init(title: "Right", label: "Right arrow", usage: 0x4f),
        .init(title: "Home", label: "Home", usage: 0x4a),
        .init(title: "End", label: "End", usage: 0x4d),
        .init(title: "Page up", label: "Page up", usage: 0x4b),
        .init(title: "Page down", label: "Page down", usage: 0x4e),
        .init(title: "Delete", label: "Delete forward", usage: 0x4c)
    ]
    static let functions: [Self] = (1...12).map {
        Self(title: "F\($0)", label: "F\($0)", usage: UInt16(0x39 + $0))
    }
}

/// Reuses the panel's key styling; all keyboard ownership belongs to IPadInputSession.
@MainActor struct RemoteSpecialKeyBar: View {
    @EnvironmentObject private var inputSession: IPadInputSession
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var expanded = false
    @State private var functionsExpanded = false

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 180 : 100), spacing: 8)]
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(SessionSpecialKey.standard) { key in keyButton(key) }
                }
                DisclosureGroup(isExpanded: $functionsExpanded) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(SessionSpecialKey.functions) { key in keyButton(key) }
                    }
                } label: {
                    Text("F1-F12").font(.subheadline).frame(minHeight: 44)
                }
                .accessibilityLabel("Function keys F1 through F12")
            }
        } label: {
            Text("Special keys").font(.subheadline.weight(.semibold)).frame(minHeight: 44)
        }
        .foregroundStyle(Color(uiColor: SessionInk.text))
    }

    private func keyButton(_ key: SessionSpecialKey) -> some View {
        Button {
            guard inputSession.canType else { return }
            inputSession.tapKey(hidUsage: key.usage)
        } label: { SessionInputControlLabel(title: key.title) }
        .buttonStyle(.plain)
        .disabled(!inputSession.canType).opacity(inputSession.canType ? 1 : 0.45)
        .accessibilityLabel(key.label)
        .accessibilityHint("Sends \(key.label) to the PC")
    }
}
