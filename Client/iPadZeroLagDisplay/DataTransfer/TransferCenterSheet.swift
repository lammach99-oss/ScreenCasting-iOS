import SwiftUI
import UniformTypeIdentifiers

struct TransferCenterSheet: View {
    @ObservedObject var networkManager: NetworkManager
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var exportFile: ExportFile?
    @State private var localError: String?
    @State private var exportLease: UUID?
    @State private var exportRequest: UUID?
    @State private var exportSheetActive = false
    @State private var visible = false
    @State private var clearDialogPresented = false
    @State private var clearApprovedID: UUID?
    private struct ExportFile: Identifiable { let id: UUID; let url: URL }
    private var retained: NetworkManager.ReceivedFilesViewState { networkManager.receivedFilesViewState }
    private func finishExport() {
        if let token = exportLease { networkManager.releaseReceivedFileExport(token) }
        exportLease = nil; exportSheetActive = false; exportRequest = nil
    }
    private func startExport(_ url: URL) {
        guard exportRequest == nil, exportLease == nil else { return }
        let request = UUID(); exportRequest = request
        networkManager.requestReceivedFileExport(url) { token in
            guard visible, exportRequest == request else {
                if let token { networkManager.releaseReceivedFileExport(token) }; return
            }
            exportRequest = nil
            guard let token else { localError = "This file is unavailable while another operation is active."; return }
            exportLease = token; exportFile = ExportFile(id: token, url: url)
        }
    }
    private let background = Color(red: 15/255, green: 23/255, blue: 42/255)
    private var state: DataTransferManager.Snapshot { networkManager.transferSnapshot }

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Label(networkManager.isConnected ? "Connected to PC · \(state.transport)" : "PC disconnected", systemImage: networkManager.isConnected ? "checkmark.circle.fill" : "wifi.slash")
                            .foregroundStyle(networkManager.isConnected ? Color.green : Color.gray)
                        ViewThatFits(in: .horizontal) {
                            HStack { sendButton; receivedButton { reader.scrollTo("received", anchor: .top) } }
                            VStack(alignment: .leading) { sendButton; receivedButton { reader.scrollTo("received", anchor: .top) } }
                        }
                        Toggle("Auto Accept incoming files", isOn: Binding(
                            get: { networkManager.autoAcceptIncomingFiles },
                            set: { networkManager.setAutoAcceptIncomingFiles($0) }))
                            .disabled(!networkManager.canEnableAutoAccept)
                            .accessibilityLabel("Auto Accept incoming files for this PC connection")
                            .frame(minHeight: 44)
                        Text("For this connection only; turns off when disconnected.")
                            .font(.footnote).foregroundStyle(.secondary)
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
        .onAppear { visible = true; networkManager.refreshReceivedFiles() }
        .onDisappear {
            visible = false; exportRequest = nil
            if let prompt = networkManager.receivedClearPrompt { networkManager.cancelClearReceivedFiles(id: prompt.id) }
            // A built picker owns its lease through UIKit completion/dismantle, even if this view disappears.
            if !exportSheetActive { finishExport() }
        }
        .sheet(item: $exportFile, onDismiss: { finishExport() }) { item in
            TransferExporter(url: item.url) {
                networkManager.releaseReceivedFileExport(item.id)
            }.onAppear { exportSheetActive = true }
        }
        .onChange(of: networkManager.receivedClearPrompt?.id) { _, newID in
            clearApprovedID = nil; clearDialogPresented = newID != nil
        }
        .confirmationDialog("Delete files stored in ScreenCasting?", isPresented: $clearDialogPresented, titleVisibility: .visible) {
            if let prompt = networkManager.receivedClearPrompt {
                Button("Delete \(prompt.count) Files", role: .destructive) {
                    clearApprovedID = prompt.id; networkManager.confirmClearReceivedFiles(id: prompt.id)
                }
                Button("Cancel", role: .cancel) { networkManager.cancelClearReceivedFiles(id: prompt.id) }
            }
        } message: {
            if let prompt = networkManager.receivedClearPrompt {
                Text("Delete \(prompt.count) files (\(TransferPresentation.size(prompt.bytes))) stored in ScreenCasting? Copies already saved to Files will not be affected.")
            }
        }
        .onChange(of: clearDialogPresented) { _, presented in
            guard !presented, let prompt = networkManager.receivedClearPrompt, clearApprovedID != prompt.id else { return }
            networkManager.cancelClearReceivedFiles(id: prompt.id)
        }
    }
    private var sendButton: some View {
        Button { importing=true } label: { Label("Send to PC", systemImage: "arrow.up.doc").frame(minHeight: 44) }
            .buttonStyle(.borderedProminent).tint(.cyan)
            .disabled(!networkManager.isConnected || TransferPresentation.active(state.phase))
    }
    private func receivedButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label("Received Files (\(retained.retainedCount))", systemImage: "tray.and.arrow.down").frame(minHeight: 44) }
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
            if let message = networkManager.receivedClearMessage {
                Text(message).foregroundStyle(.secondary).accessibilityLabel(message)
            }
            if !retained.loaded {
                Text(retained.storageWarning ?? "Loading saved files…").foregroundStyle(.secondary)
                Button("Refresh Received Files") { networkManager.refreshReceivedFiles() }.frame(minHeight: 44)
            } else {
                Text("\(retained.retainedCount) of 256 files · \(TransferPresentation.size(retained.retainedBytes)) of 8 GB retained")
                if retained.busy { Text("Cannot clear while a transfer or Save to Files is active.").foregroundStyle(.secondary) }
                Button(role: .destructive) { networkManager.requestClearReceivedFiles() } label: {
                    Label("Clear Received Files", systemImage: "trash").frame(minHeight: 44)
                }.disabled(retained.retainedCount == 0 || retained.busy || !retained.loaded)
                    .accessibilityLabel("Clear received files stored in ScreenCasting")
                ForEach(retained.files, id: \.self) { url in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(url.lastPathComponent).fixedSize(horizontal: false, vertical: true)
                        Text(TransferPresentation.size(retained.fileBytes[url] ?? 0)).font(.subheadline).foregroundStyle(.secondary)
                        Text(retained.eligibleNames.contains(url.lastPathComponent) ? "Verified received copy" : "Older/unclassified received file")
                            .font(.caption).foregroundStyle(.secondary)
                        Button { startExport(url) } label: {
                            Label("Save to Files", systemImage: "square.and.arrow.up").frame(minHeight: 44)
                        }.disabled(retained.busy || exportRequest != nil || exportLease != nil)
                            .accessibilityLabel("Save \(url.lastPathComponent) to Files")
                        Divider()
                    }
                }
            }
            Text("Saving to Files creates a separate copy. Clear removes files stored in ScreenCasting; exported copies stay untouched.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
