import SwiftUI

@MainActor struct PairSwitcherRow: View {
    @ObservedObject var focus: FocusCoordinator
    let scene: String
    @Environment(\.scenePhase) private var phase
    var body: some View {
        let selected = focus.model.selected
        let alternate = selected.alternate
        let slot = focus.model[alternate]
        let name = PairSession.shared.name(alternate)
        VStack(alignment: .leading, spacing: 8) {
            Text(PairSession.shared.name(selected)).font(.headline)
            Text(PairPanelModel.label(focus.model[selected].phase)).font(.caption)
            Button {
                PairSession.shared.select(scene: scene)
            } label: {
                HStack {
                    if phase == .active, let bytes = focus.thumbnail(for: alternate), let image = UIImage(data: bytes) {
                        Image(uiImage: image).resizable().scaledToFit().frame(width: 60, height: 44)
                    } else {
                        Image(systemName: "desktopcomputer").frame(width: 60, height: 44).background(Color.black)
                    }
                    VStack(alignment: .leading) {
                        Text(name)
                        Text(PairPanelModel.label(slot.phase)).font(.caption)
                    }
                    if focus.model.inFlight != nil { ProgressView() }
                }.frame(minHeight: 44)
            }
            .accessibilityLabel(PairPanelModel.switchLabel(name))
            .accessibilityValue(PairPanelModel.label(slot.phase))
            .disabled(PairPanelModel.tapTarget(focus.model, scene: scene) == nil)
            if slot.phase == .offline {
                Button { PairSession.shared.retry(alternate) } label: {
                    Text("Retry \(name)").frame(minHeight: 44)
                }
            } else if slot.phase == .refused {
                Text(PairPanelModel.reason(slot.lastError))
            }
        }
    }
}

@MainActor struct SecondPCChooser: View {
    let primary: NetworkManager
    let firstName: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var issue: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Recent remote hosts") {
                    ForEach(PairPanelModel.recent(RecentRemoteHostStore.load())) { entry in
                        Button(entry.host) { add(entry.host) }.frame(minHeight: 44)
                    }
                }
                Section("Remote control address") {
                    RemoteAddressField(address: $text)
                    Button("Connect") { add(text) }.disabled(PairPanelModel.address(text) == nil)
                }
                if let issue { Text(issue) }
            }
            .navigationTitle("Add second PC")
            .toolbar { Button("Cancel") { dismiss() } }
        }
    }

    private func add(_ value: String) {
        issue = PairSession.shared.add(primary: primary, text: value, firstName: firstName)
        if issue == nil { dismiss() }
    }
}
