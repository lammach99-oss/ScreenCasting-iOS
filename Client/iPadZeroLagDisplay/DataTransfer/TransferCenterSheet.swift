import SwiftUI
import UniformTypeIdentifiers

struct TransferCenterSheet: View {
    @ObservedObject var networkManager: NetworkManager
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var exportFile: ExportFile?
    @State private var localError: String?
    private struct ExportFile: Identifiable { let id = UUID(); let url: URL }
    private let background = Color(red: 15/255, green: 23/255, blue: 42/255)
    private var state: DataTransferManager.Snapshot { networkManager.transferSnapshot }

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Label(networkManager.isConnected ? "Connected to PC" : "PC disconnected", systemImage: networkManager.isConnected ? "checkmark.circle.fill" : "wifi.slash")
                            .foregroundStyle(networkManager.isConnected ? Color.green : Color.gray)
                        ViewThatFits(in: .horizontal) {
                            HStack { sendButton; receivedButton { reader.scrollTo("received", anchor: .top) } }
                            VStack(alignment: .leading) { sendButton; receivedButton { reader.scrollTo("received", anchor: .top) } }
                        }
                        if !networkManager.isConnected {
                            Text("Connect to your PC before sending or accepting files. Saved files remain available.").foregroundStyle(.secondary)
                        }
                        if let localError { Label(localError, systemImage: "exclamationmark.triangle").foregroundStyle(.yellow) }
                        if state.phase == .awaitingDecision { incoming }
                        else if state.count > 0 { transfer }
                        received.id("received")
                    }.padding(24).frame(maxWidth: 700, alignment: .leading).frame(maxWidth: .infinity)
                }
            }
            .background(background)
            .navigationTitle("File Transfer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close File Transfer")
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data,.content], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): localError=nil; networkManager.sendTransferFiles(urls)
            case .failure: localError="Files could not be opened. Choose them again."
            }
        }
        .sheet(item: $exportFile) { TransferExporter(url: $0.url) }
    }
    private var sendButton: some View {
        Button { importing=true } label: { Label("Send to PC", systemImage: "arrow.up.doc").frame(minHeight: 44) }
            .buttonStyle(.borderedProminent).tint(.cyan)
            .disabled(!networkManager.isConnected || TransferPresentation.active(state.phase))
    }
    private func receivedButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label("Received Files (\(state.received.count))", systemImage: "tray.and.arrow.down").frame(minHeight: 44) }
            .buttonStyle(.bordered)
    }
    private var incoming: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Incoming from PC", systemImage: "arrow.down.doc").font(.headline)
            Text(state.name).font(.title3).fixedSize(horizontal: false, vertical: true)
            Text("\(state.count) files · \(TransferPresentation.size(state.total))").foregroundStyle(.secondary)
            Text("Received files stay in ScreenCasting until saved to Files.").font(.subheadline).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { consentButtons }
                VStack(alignment: .leading) { consentButtons }
            }
        }.padding(18).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
    @ViewBuilder private var consentButtons: some View {
        Button { networkManager.decideTransfer(true) } label: { Label("Accept", systemImage: "checkmark").frame(minHeight: 44) }
            .buttonStyle(.borderedProminent).disabled(!networkManager.isConnected)
        Button(role: .destructive) { networkManager.decideTransfer(false) } label: { Label("Decline", systemImage: "xmark").frame(minHeight: 44) }
            .buttonStyle(.bordered)
    }
    private var transfer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(state.outgoing ? "Sending to PC" : "Receiving from PC", systemImage: state.outgoing ? "arrow.up.doc" : "arrow.down.doc").font(.headline)
            Text(state.name).font(.title3).fixedSize(horizontal: false, vertical: true)
            Text("\(min(state.index+1,state.count)) of \(state.count) files · \(TransferPresentation.size(state.total))").foregroundStyle(.secondary)
            Text(state.phase.rawValue).font(.headline)
            if state.phase == .failed {
                Label(TransferPresentation.failure(state), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(TransferPresentation.nextAction(state)).font(.subheadline)
                DisclosureGroup("Diagnostics") {
                    Text("Stage: \(state.stage)\nReason: \(state.failure?.reason ?? "UNKNOWN")\n\(state.failure?.domain ?? "Transfer") / \(state.failure?.code ?? 0)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
            } else if TransferPresentation.active(state.phase) {
                ProgressView(value: TransferPresentation.progress(state))
                    .accessibilityLabel(state.outgoing ? "Sending progress" : "Receiving progress")
                Text("\(TransferPresentation.size(state.bytes)) of \(TransferPresentation.size(state.total))").font(.subheadline).foregroundStyle(.secondary)
                Button("Cancel transfer", role: .destructive) { networkManager.cancelTransfer() }.frame(minHeight: 44)
            }
        }.padding(18).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
    private var received: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Received Files", systemImage: "tray.full").font(.headline)
            Text("\(state.retainedCount) of 256 files · \(TransferPresentation.size(state.retainedBytes)) of 8 GB retained")
                .font(.subheadline).foregroundStyle(.secondary)
            if state.received.isEmpty { Text("Verified files received from your PC will appear here.").foregroundStyle(.secondary) }
            ForEach(state.received, id: \.self) { url in
                VStack(alignment: .leading, spacing: 6) {
                    Text(url.lastPathComponent).fixedSize(horizontal: false, vertical: true)
                    Button { exportFile=ExportFile(url:url) } label: { Label("Save to Files", systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                        .accessibilityLabel("Save \(url.lastPathComponent) to Files")
                    Divider()
                }
            }
            Text("Files remain in app storage after export. Saving to Files creates a copy; nothing is deleted automatically.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
