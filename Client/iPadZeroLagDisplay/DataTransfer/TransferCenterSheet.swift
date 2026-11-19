import SwiftUI
import UniformTypeIdentifiers

@MainActor struct TransferCenterSheet: View {
    @ObservedObject var networkManager: NetworkManager
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var importScope: NetworkManager.TransferActionScope?
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
    private let background = Color(uiColor: SessionInk.canvas)
    /// White on the accent fails contrast; prominent buttons use the dark on-accent ink.
    private let onAccent = Color(uiColor: SessionInk.onAccent)
    private var state: DataTransferManager.Snapshot { networkManager.transferSnapshot }

    var body: some View {
        NavigationStack {
            TransferSections(owner: self)
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
        .tint(Color(uiColor: SessionInk.accent))
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data,.content], allowsMultipleSelection: true) { result in
            let scope = importScope
            importScope = nil
            switch result {
            case .success(let urls):
                localError = nil
                if let scope { networkManager.sendTransferFiles(urls, scope: scope) }
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
        Button {
            importScope = networkManager.transferActionScope
            importing = true
        } label: { Label("Send to PC", systemImage: "arrow.up.doc").foregroundStyle(onAccent).frame(minHeight: 44) }
            .buttonStyle(.borderedProminent)
            .disabled(!canStart)
    }
    private var canStart: Bool {
        networkManager.isConnected && !TransferPresentation.active(state.phase) &&
            (!networkManager.isRemoteControlSession || (networkManager.remoteFileCanStart && !networkManager.remoteFileWaiting))
    }
    private var remoteActions: some View {
        VStack(alignment: .leading) {
            let scope = networkManager.transferActionScope
            Button { networkManager.requestRemoteFiles(scope: scope) } label: {
                Label("Request files", systemImage: "arrow.down.doc").frame(minHeight: 44)
            }
            .buttonStyle(.bordered).disabled(!canStart)
            if let status = networkManager.remoteFileStatus {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            } else if networkManager.remoteInputFeatures & RemoteFeatureNegotiation.remoteFileFeature == 0 {
                Text("This PC does not offer remote file transfer.").font(.footnote).foregroundStyle(.secondary)
            } else if !networkManager.remoteFileCanStart {
                Text("Turn on Control on the PC to transfer files.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("The person at the PC approves access and chooses files to send.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    private func receivedButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label("Received Files (\(retained.retainedCount))", systemImage: "tray.and.arrow.down").frame(minHeight: 44) }
            .buttonStyle(.bordered)
    }
    private var incoming: IncomingSection {
        IncomingSection(owner: self)
    }
    @ViewBuilder private var consentButtons: some View {
        let displayedConsent = state.consent
        Button { if let consent = displayedConsent { networkManager.decideTransfer(true, consent: consent) } } label: { Label("Accept", systemImage: "checkmark").foregroundStyle(onAccent).frame(minHeight: 44) }
            .buttonStyle(.borderedProminent).disabled(!networkManager.isConnected)
        Button(role: .destructive) { if let consent = displayedConsent { networkManager.decideTransfer(false, consent: consent) } } label: { Label("Decline", systemImage: "xmark").frame(minHeight: 44) }
            .buttonStyle(.bordered)
    }
    private var transfer: TransferSection {
        TransferSection(owner: self)
    }
    private var received: ReceivedSection {
        ReceivedSection(owner: self)
    }


    @MainActor private struct TransferSections: View {
        let owner: TransferCenterSheet
        var body: some View {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Label(owner.networkManager.isConnected ? "Connected to PC · \(owner.state.transport)" : "PC disconnected", systemImage: owner.networkManager.isConnected ? "checkmark.circle.fill" : "wifi.slash")
                            .foregroundStyle(Color(uiColor: owner.networkManager.isConnected ? SessionInk.positive : SessionInk.secondary))
                        ViewThatFits(in: .horizontal) {
                            HStack { owner.sendButton; owner.receivedButton { reader.scrollTo("received", anchor: .top) } }
                            VStack(alignment: .leading) { owner.sendButton; owner.receivedButton { reader.scrollTo("received", anchor: .top) } }
                        }
                        if owner.networkManager.isRemoteControlSession { owner.remoteActions }
                        else { CastingConsent(owner: owner) }
                        if !owner.networkManager.isConnected {
                            Text("Connect to your PC before sending or accepting files. Saved files remain available.").foregroundStyle(.secondary)
                        }
                        if let error = owner.localError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Color(uiColor: SessionInk.warning)) }
                        if owner.state.phase == .awaitingDecision { owner.incoming }
                        else if owner.state.count > 0 { owner.transfer }
                        else if owner.state.phase == .failed && owner.networkManager.isRemoteControlSession {
                            Text(TransferPresentation.failure(owner.state)).foregroundStyle(Color(uiColor: SessionInk.warning))
                        }
                        owner.received.id("received")
                    }.padding(24).frame(maxWidth: 700, alignment: .leading).frame(maxWidth: .infinity)
                }
            }
        }
    }
    @MainActor private struct CastingConsent: View {
        let owner: TransferCenterSheet
        var body: some View {
            VStack(alignment: .leading) {
                Toggle("Auto Accept incoming files", isOn: Binding(
                    get: { owner.networkManager.autoAcceptIncomingFiles },
                    set: { owner.networkManager.setAutoAcceptIncomingFiles($0) }))
                    .disabled(!owner.networkManager.canEnableAutoAccept)
                    .accessibilityLabel("Auto Accept incoming files for this PC connection")
                    .frame(minHeight: 44)
                Text("For this connection only; turns off when disconnected.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    // Nominal view types bound metadata expansion across independently rendered sections.
    @MainActor private struct IncomingSection: View {
        let owner: TransferCenterSheet
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Label("Incoming from PC", systemImage: "arrow.down.doc").font(.headline)
                Text(owner.state.name).font(.title3).fixedSize(horizontal: false, vertical: true)
                Text("\(owner.state.count) files · \(TransferPresentation.size(owner.state.total))").foregroundStyle(.secondary)
                Text("Received files stay in ScreenCasting until saved to Files.").font(.subheadline).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack { owner.consentButtons }
                    VStack(alignment: .leading) { owner.consentButtons }
                }
            }.padding(18).background(Color(uiColor: SessionInk.raised), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @MainActor private struct TransferSection: View {
        let owner: TransferCenterSheet
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Label(owner.state.outgoing ? "Sending to PC" : "Receiving from PC", systemImage: owner.state.outgoing ? "arrow.up.doc" : "arrow.down.doc").font(.headline)
                Text(owner.state.name).font(.title3).fixedSize(horizontal: false, vertical: true)
                Text("\(min(owner.state.index+1,owner.state.count)) of \(owner.state.count) files · \(TransferPresentation.size(owner.state.total))").foregroundStyle(.secondary)
                Text(owner.state.phase.rawValue).font(.headline)
                if owner.state.phase == .failed {
                    Label(TransferPresentation.failure(owner.state), systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color(uiColor: SessionInk.warning))
                    Text(TransferPresentation.nextAction(owner.state)).font(.subheadline)
                    DisclosureGroup("Diagnostics") {
                        Text("Stage: \(owner.state.stage)\nReason: \(owner.state.failure?.reason ?? "UNKNOWN")\n\(owner.state.failure?.domain ?? "Transfer") / \(owner.state.failure?.code ?? 0)")
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                } else if TransferPresentation.active(owner.state.phase) {
                    ProgressView(value: TransferPresentation.progress(owner.state))
                        .accessibilityLabel(owner.state.outgoing ? "Sending progress" : "Receiving progress")
                    Text("\(TransferPresentation.size(owner.state.bytes)) of \(TransferPresentation.size(owner.state.total))").font(.subheadline).foregroundStyle(.secondary)
                    let scope = owner.networkManager.transferActionScope
                    Button("Cancel transfer", role: .destructive) { owner.networkManager.cancelTransfer(scope: scope) }.frame(minHeight: 44)
                }
                if owner.state.retryCount > 0, owner.networkManager.isRemoteControlSession {
                    let scope = owner.networkManager.transferActionScope
                    Button("Resend missing files") { owner.networkManager.retryRemoteFiles(scope: scope) }
                        .disabled(!owner.canStart).frame(minHeight: 44)
                }
            }.padding(18).background(Color(uiColor: SessionInk.raised), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @MainActor private struct ReceivedSection: View {
        let owner: TransferCenterSheet
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Label("Received Files", systemImage: "tray.full").font(.headline)
                if let message = owner.networkManager.receivedClearMessage {
                    Text(message).foregroundStyle(.secondary).accessibilityLabel(message)
                }
                if !owner.retained.loaded {
                    Text(owner.retained.storageWarning ?? "Loading saved files…").foregroundStyle(.secondary)
                    Button("Refresh Received Files") { owner.networkManager.refreshReceivedFiles() }.frame(minHeight: 44)
                } else {
                    Text("\(owner.retained.retainedCount) of 256 files · \(TransferPresentation.size(owner.retained.retainedBytes)) of 8 GB retained")
                    if owner.retained.busy { Text("Cannot clear while a transfer or Save to Files is active.").foregroundStyle(.secondary) }
                    Button(role: .destructive) { owner.networkManager.requestClearReceivedFiles() } label: {
                        Label("Clear Received Files", systemImage: "trash").frame(minHeight: 44)
                    }.disabled(owner.retained.retainedCount == 0 || owner.retained.busy || !owner.retained.loaded)
                        .accessibilityLabel("Clear received files stored in ScreenCasting")
                    ForEach(owner.retained.files, id: \.self) { url in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(url.lastPathComponent).fixedSize(horizontal: false, vertical: true)
                            Text(TransferPresentation.size(owner.retained.fileBytes[url] ?? 0)).font(.subheadline).foregroundStyle(.secondary)
                            Text(owner.retained.eligibleNames.contains(url.lastPathComponent) ? "Verified received copy" : "Older/unclassified received file")
                                .font(.caption).foregroundStyle(.secondary)
                            Button { owner.startExport(url) } label: {
                                Label("Save to Files", systemImage: "square.and.arrow.up").frame(minHeight: 44)
                            }.disabled(owner.retained.busy || owner.exportRequest != nil || owner.exportLease != nil)
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
}
