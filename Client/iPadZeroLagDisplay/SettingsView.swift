import SwiftUI

// MARK: - SettingsView

/// Settings for the ScreenCasting iPad client, grouped by how often they are used.
///
/// ## State Ownership
///   Client intent and Host effective state are distinct published values in
///   `NetworkManager`; Host reports never move these controls.
@MainActor public struct SettingsView: View {

    // MARK: Dependencies
    @ObservedObject var networkManager: NetworkManager

    // MARK: Local UI State
    @Environment(\.dismiss) private var dismiss

    /// Client-owned desired values. Host reports are displayed separately.
    @State private var draftBitrate: Double = 20.0
    @State private var draftAudioEnabled = true
    @State private var draftAdaptiveBitrateEnabled = false
    @State private var draftResolution = DisplayPreference.defaultValue.resolution
    @State private var draftRefreshHz: UInt32 = DisplayPreference.defaultValue.refreshHz
    @State private var draftOrientationMode: DisplayOrientationMode = .automatic
    @State private var showDisconnectConfirmation = false
    @State private var showForgetConfirmation = false
    @State private var showDeleteLogsConfirmation = false
    @State private var showAdvanced = false
    @State private var isTransferPresented = false
    @State private var isDeletingClientLogs = false
    @State private var clientLogDeletionMessage: String?
    @AppStorage(ClientPreferenceKeys.showPerformanceHUD)
    private var showPerformanceHUD: Bool = true
    @AppStorage(ClientPreferenceKeys.gameModeEnabled)
    private var gameModeEnabled: Bool = false
    @AppStorage(ClientPreferenceKeys.clientDebugLoggingEnabled)
    private var clientDebugLoggingEnabled: Bool = false

    private let rowBackground = Color(uiColor: SessionInk.surface)
    private let secondary = Color(uiColor: SessionInk.secondary)
    /// Switches and controls share the one signal-blue accent.
    private let switchTint = Color(uiColor: SessionInk.accent)
    private var supportsAudioAndAuto: Bool {
        ClientStreamSettingsPreference.supportsAudioAndAuto(remote: networkManager.isRemoteControlSession)
    }

    // MARK: Body

    public var body: some View {
        NavigationStack {
            Form {
                displaySection
                streamSection
                ClipboardSection(manager: networkManager, pasteboard: networkManager.remoteClipboardPasteboard)
                Section {
                    Button {
                        isTransferPresented = true
                    } label: {
                        HStack {
                            Label("Send or open files", systemImage: "arrow.left.arrow.right")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(secondary)
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(Color(uiColor: SessionInk.text))
                    }
                } header: {
                    Text("File transfer")
                }
                .listRowBackground(rowBackground)
                connectionSection
                advancedSection
            }
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: SessionInk.canvas))
            .sheet(isPresented: $isTransferPresented) {
                TransferCenterSheet(networkManager: networkManager)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Color(uiColor: SessionInk.accent))
        .trustedHostForgetAlert(networkManager, visible: !isTransferPresented)
        .onReceive(networkManager.$desiredBitrateMbps) { newMbps in
            draftBitrate = newMbps
        }
        .onReceive(networkManager.$desiredAudioEnabled) { enabled in
            draftAudioEnabled = enabled
        }
        .onReceive(networkManager.$desiredAdaptiveBitrateEnabled) { enabled in
            draftAdaptiveBitrateEnabled = enabled
        }
        // @Published emits before the property changes, so sync from the emitted value.
        .onReceive(networkManager.$displayCapabilities) { capabilities in
            synchronizeDisplayDraft(preference: networkManager.displayPreference, capabilities: capabilities)
        }
        .onReceive(networkManager.$displayPreference) { preference in
            synchronizeDisplayDraft(preference: preference, capabilities: networkManager.displayCapabilities)
        }
        .onChange(of: networkManager.displayConfigurationFailureMessage) { _, message in
            // A rejected orientation must not stay selected while the PC keeps the old one.
            if message != nil {
                synchronizeDisplayDraft(preference: networkManager.displayPreference,
                                        capabilities: networkManager.displayCapabilities)
            }
        }
        .onChange(of: clientDebugLoggingEnabled) { _, enabled in
            networkManager.setClientDebugLoggingEnabled(enabled)
        }
        .onAppear {
            draftBitrate = networkManager.desiredBitrateMbps
            draftAudioEnabled = networkManager.desiredAudioEnabled
            draftAdaptiveBitrateEnabled = networkManager.desiredAdaptiveBitrateEnabled
            synchronizeDisplayDraft(preference: networkManager.displayPreference,
                                    capabilities: networkManager.displayCapabilities)
        }
    }

    // MARK: - Sections

    private var displaySection: DisplaySection {
        DisplaySection(owner: self)
    }

    private var streamSection: StreamSection {
        StreamSection(owner: self)
    }

    private var connectionSection: ConnectionSection {
        ConnectionSection(owner: self)
    }

    private var advancedSection: AdvancedSection {
        AdvancedSection(owner: self)
    }

    /// A timing in words and colour together, so the colour never carries the meaning alone.
    private func latencyRow(_ title: String, _ ms: Double) -> some View {
        let reading = SettingsCopy.latency(ms)
        let color: Color = switch reading.level {
        case .good: Color(uiColor: SessionInk.positive)
        case .fair: Color(uiColor: SessionInk.warning)
        case .slow: Color(uiColor: SessionInk.danger)
        case .none: secondary
        }
        return LabeledContent(title) {
            Text(ms > 0 ? String(format: "%.1f ms · %@", ms, reading.word) : reading.word)
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    // MARK: - Private Helpers

    /// The orientation the Host's preference already holds; picking it again is not a change.
    private var currentOrientationMode: DisplayOrientationMode? {
        guard let capabilities = networkManager.displayCapabilities else { return nil }
        return networkManager.displayPreference.reconciled(with: capabilities).orientationMode
    }

    private func synchronizeDisplayDraft(preference stored: DisplayPreference, capabilities: DisplayCapabilities?) {
        guard let capabilities else { return }
        let preference = stored.reconciled(with: capabilities)
        draftResolution = preference.resolution
        draftRefreshHz = preference.refreshHz
        draftOrientationMode = preference.orientationMode
    }

    private func applyDisplaySettings() {
        networkManager.applyDisplayPreference(DisplayPreference(
            width: draftResolution.width,
            height: draftResolution.height,
            refreshHz: draftRefreshHz,
            orientationMode: draftOrientationMode))
    }

    private func saveDesiredSettings() {
        networkManager.setDesiredStreamSettings(
            bitrateMbps: draftBitrate,
            audioEnabled: draftAudioEnabled,
            adaptiveBitrateEnabled: draftAdaptiveBitrateEnabled)
    }

    private func deleteClientLogs() {
        isDeletingClientLogs = true
        clientLogDeletionMessage = nil
        networkManager.deleteClientDebugLogs { result in
            isDeletingClientLogs = false
            switch result {
            case .success(let count):
                clientLogDeletionMessage = count == 0
                    ? "No old logs to delete."
                    : "Deleted \(count) log files."
            case .failure(let error):
                clientLogDeletionMessage =
                    "Couldn't delete the logs: \(error.localizedDescription)"
            }
        }
    }

    // Nominal view types bound metadata expansion across independently rendered sections.
    @MainActor private struct DisplaySection: View {
        let owner: SettingsView
        var body: some View {
            Section {
                if owner.networkManager.displayCapabilities != nil {
                    // Only a user's pick sends a request; drafts synced from the PC never do.
                    Picker("Orientation", selection: Binding(
                        get: { owner.draftOrientationMode },
                        set: { mode in
                            owner.draftOrientationMode = mode
                            if mode != owner.currentOrientationMode { owner.applyDisplaySettings() }
                        })) {
                        ForEach(DisplayOrientationMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(owner.networkManager.isDisplayConfigurationPending)
                    if owner.networkManager.isDisplayConfigurationPending {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Applying…").foregroundStyle(owner.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    } else if let effective = owner.networkManager.effectiveDisplayState {
                        Text(SettingsCopy.nowShowing(width: effective.width, height: effective.height,
                                                     refreshHz: effective.refreshHz,
                                                     portrait: effective.orientation == .portrait))
                            .font(.footnote)
                            .foregroundStyle(owner.secondary)
                    }
                    if let failure = owner.networkManager.displayConfigurationFailureMessage {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Color(uiColor: SessionInk.warning))
                    }
                } else {
                    Text("Connect to your PC to change the display.")
                        .foregroundStyle(owner.secondary)
                }
                Toggle("Game mode", isOn: owner.$gameModeEnabled).tint(owner.switchTint)
                Toggle("Show frame rate on screen", isOn: owner.$showPerformanceHUD).tint(owner.switchTint)
            } header: {
                Text("Display")
            } footer: {
                Text("Game mode streams up to 120 frames a second for fast motion. Off keeps a steady 60.")
            }
            .listRowBackground(owner.rowBackground)
        }
    }

    @MainActor private struct StreamSection: View {
        let owner: SettingsView
        var body: some View {
            let manualFallback = owner.networkManager.legacyAutomaticBitrateUnavailable
            Section {
                AdaptiveQualityControls(network:owner.networkManager)
                Toggle("Automatic bitrate", isOn: Binding(
                    get: { owner.draftAdaptiveBitrateEnabled && owner.supportsAudioAndAuto && !manualFallback },
                    set: { value in
                        guard owner.supportsAudioAndAuto, !manualFallback else { return }
                        owner.draftAdaptiveBitrateEnabled = value
                        owner.saveDesiredSettings()
                    }))
                    .tint(owner.switchTint)
                    .disabled(!owner.supportsAudioAndAuto || manualFallback)
                if !owner.draftAdaptiveBitrateEnabled || !owner.supportsAudioAndAuto || manualFallback {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Bitrate")
                            Spacer()
                            Text(String(format: "%.0f Mbps", owner.draftBitrate))
                                .monospacedDigit()
                                .foregroundStyle(owner.secondary)
                        }
                        .accessibilityHidden(true) // The slider below reads the same label and value.
                        // Client desired bitrate is authoritative; Host reports the effective value.
                        Slider(value: owner.$draftBitrate, in: 3...100, step: 1) {
                            Text("Bitrate")
                        } minimumValueLabel: {
                            Text("3").font(.caption).foregroundStyle(owner.secondary).accessibilityHidden(true)
                        } maximumValueLabel: {
                            Text("100").font(.caption).foregroundStyle(owner.secondary).accessibilityHidden(true)
                        } onEditingChanged: { editing in
                            if !editing { owner.saveDesiredSettings() }
                        }
                        .accessibilityValue(String(format: "%.0f megabits per second", owner.draftBitrate))
                    }
                }
                Toggle("Sound from the PC", isOn: Binding(
                    get: { owner.draftAudioEnabled && owner.supportsAudioAndAuto },
                    set: { value in
                        if !owner.supportsAudioAndAuto { return }
                        owner.draftAudioEnabled = value
                        owner.saveDesiredSettings()
                    }))
                    .tint(owner.switchTint)
                    .disabled(!owner.supportsAudioAndAuto)
            } header: {
                Text("Stream quality")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !owner.supportsAudioAndAuto {
                        Text(ClientStreamSettingsPreference.remoteUnsupportedReason)
                    }
                    if !owner.networkManager.isRemoteControlSession || owner.networkManager.effectiveQualitySummary == nil {
                        Text(SettingsCopy.pcUsing(adaptive: owner.networkManager.isAdaptiveBitrate,
                                                  mbps: owner.networkManager.effectiveBitrateMbps,
                                                  audio: owner.networkManager.effectiveAudioEnabled))
                    }
                    if !owner.networkManager.settingsApplyStatus.isEmpty {
                        Text(owner.networkManager.settingsApplyStatus)
                    }
                }
            }
            .listRowBackground(owner.rowBackground)
        }
    }

    @MainActor private struct ClipboardSection: View {
        @ObservedObject var manager: NetworkManager
        @ObservedObject var pasteboard: RemoteClipboardPasteboard

        var body: some View {
            Section {
                Toggle("Sync clipboard with PC", isOn: Binding(
                    get: { manager.remoteClipboardEnabled }, set: { manager.setRemoteClipboardEnabled($0) }))
                Toggle("Automatically send copied items to the PC", isOn: Binding(
                    get: { manager.automaticClipboardSending }, set: { manager.setAutomaticClipboardSending($0) }))
                if !manager.isRemoteControlSession, pasteboard.canSend {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Send clipboard to PC")
                        RemoteClipboardPasteButton(pasteboard: pasteboard).frame(height: 44)
                    }
                }
            } header: {
                Text("Clipboard")
            } footer: {
                Text("Copied passwords may be sent to the PC when automatic sending is on. Automatic sending uses your iPad paste permission.")
            }
            .listRowBackground(Color(uiColor: SessionInk.surface))
        }
    }

    @MainActor private struct ConnectionSection: View {
        let owner: SettingsView
        var body: some View {
            Section {
                Button(role: .destructive) {
                    owner.showDisconnectConfirmation = true
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
                .confirmationDialog("Disconnect from your PC?", isPresented: owner.$showDisconnectConfirmation,
                                    titleVisibility: .visible) {
                    Button("Disconnect", role: .destructive) {
                        owner.networkManager.stop()
                        owner.dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                }
                Button(role: .destructive) {
                    owner.showForgetConfirmation = true
                } label: {
                    Label("Forget this PC", systemImage: "trash")
                }
                .confirmationDialog("Forget this PC?", isPresented: owner.$showForgetConfirmation,
                                    titleVisibility: .visible) {
                    Button("Forget PC", role: .destructive) {
                        owner.networkManager.forgetCurrentTrustedHost()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Next time you connect, you'll enter the PC's PIN again.")
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Forget this PC to pair again with a new PIN.")
            }
            .listRowBackground(owner.rowBackground)
        }
    }

    @MainActor private struct AdvancedSection: View {
        let owner: SettingsView
        var body: some View {
            Section {
                DisclosureGroup("Advanced", isExpanded: owner.$showAdvanced) {
                    owner.latencyRow("Frame receive", owner.networkManager.lastFrameReceiveDurationMs)
                    owner.latencyRow("Decode", owner.networkManager.lastDecodeLatencyMs)
                    LabeledContent("Bitrate in use",
                                   value: String(format: "%.0f Mbps", owner.networkManager.effectiveBitrateMbps))
                    LabeledContent("Video received",
                                   value: String(format: "%.1f Mbps", owner.networkManager.hudTelemetry.videoRxMbps))
                    Toggle("Debug logging", isOn: owner.$clientDebugLoggingEnabled).tint(owner.switchTint)
                    Text("Writes detailed logs for troubleshooting. Leave it off day to day.")
                        .font(.footnote)
                        .foregroundStyle(owner.secondary)
                    Button(role: .destructive) {
                        owner.showDeleteLogsConfirmation = true
                    } label: {
                        Text(owner.isDeletingClientLogs ? "Deleting logs…" : "Delete logs")
                    }
                    .disabled(owner.isDeletingClientLogs)
                    .confirmationDialog("Delete the iPad's logs?", isPresented: owner.$showDeleteLogsConfirmation,
                                        titleVisibility: .visible) {
                        Button("Delete logs", role: .destructive) {
                            owner.deleteClientLogs()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Deletes saved diagnostic and telemetry logs. If debug logging is on, the current log is kept.")
                    }
                    if let clientLogDeletionMessage = owner.clientLogDeletionMessage {
                        Text(clientLogDeletionMessage)
                            .font(.footnote)
                            .foregroundStyle(owner.secondary)
                    }
                }
            }
            .listRowBackground(owner.rowBackground)
        }
    }
}

/// Explicit consent is separate from legacy AutoBitrate and the saved manual target.
@MainActor private struct AdaptiveQualityControls: View {
    @ObservedObject var network: NetworkManager
    var body: some View {
        Toggle("Auto quality", isOn: Binding(get: { network.autoQualityEnabled }, set: { network.setAutoQualityEnabled($0) }))
            .disabled(!network.adaptiveQualityAvailable)
        if network.adaptiveQualityAvailable {
            Text(network.savedAutoQualityEnabled
                ? "Auto remembered for this PC." : "Your quality choice is saved for this PC.")
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            Text(network.adaptiveQualityUnavailableReason).font(.footnote).foregroundStyle(.secondary)
            if network.savedAutoQualityEnabled {
                Text("Auto is saved for this PC. Using Manual for this connection.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        if let summary = network.effectiveQualitySummary {
            Text(summary).font(.footnote).foregroundStyle(.secondary)
                .accessibilityLabel("Effective quality: " + summary)
        }
    }
}

// MARK: - Plain wording

enum SettingsCopy {
    enum Level: Equatable { case good, fair, slow, none }

    static func nowShowing(width: UInt32, height: UInt32, refreshHz: UInt32, portrait: Bool) -> String {
        "Now showing \(width) × \(height) at \(refreshHz) Hz, \(portrait ? "portrait" : "landscape")"
    }

    static func pcUsing(adaptive: Bool, mbps: Double, audio: Bool) -> String {
        "The PC is using \(adaptive ? "Auto, " : "")\(String(format: "%.0f", mbps)) Mbps, audio \(audio ? "on" : "off")"
    }

    /// Thresholds match the old telemetry colours: under 10 ms good, under 20 ms fair.
    static func latency(_ ms: Double) -> (word: String, level: Level) {
        switch ms {
        case ...0: ("No data yet", .none)
        case ..<10: ("Good", .good)
        case ..<20: ("Fair", .fair)
        default: ("Slow", .slow)
        }
    }
}
