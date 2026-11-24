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
    @Environment(\.dynamicTypeSize) private var typeSize

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
                ClipboardSection(manager: networkManager, pasteboard: networkManager.remoteClipboardPasteboard,
                                 isTransferPresented: $isTransferPresented)
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

        private var performancePicker: some View {
            Picker("Frame rate", selection: owner.$gameModeEnabled) {
                Text("Smooth (60 fps)").accessibilityLabel("Smooth, 60 frames per second").tag(false)
                Text("Fast motion (120 fps)").accessibilityLabel("Fast motion, up to 120 frames per second").tag(true)
            }
            .accessibilityLabel("Frame rate")
            .frame(minHeight: 44)
        }

        var body: some View {
            Section {
                if owner.typeSize.isAccessibilitySize {
                    performancePicker.pickerStyle(.menu)
                } else {
                    performancePicker.pickerStyle(.segmented)
                }
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
                Toggle("Show frame rate on screen", isOn: owner.$showPerformanceHUD).tint(owner.switchTint)
            } header: {
                Text("Picture")
            } footer: {
                Text("Smooth keeps a steady 60 frames per second. Fast motion uses up to 120 for games and video.")
            }
            .listRowBackground(owner.rowBackground)
        }
    }

    @MainActor private struct StreamSection: View {
        let owner: SettingsView
        var body: some View {
            let manualFallback = owner.networkManager.legacyAutomaticBitrateUnavailable
            let automaticBitrate = owner.draftAdaptiveBitrateEnabled && owner.supportsAudioAndAuto && !manualFallback
            Section {
                AdaptiveQualityControls(network: owner.networkManager, switchTint: owner.switchTint)
                Toggle("Automatic bitrate", isOn: Binding(
                    get: { automaticBitrate },
                    set: { value in
                        guard owner.supportsAudioAndAuto, !manualFallback else { return }
                        owner.draftAdaptiveBitrateEnabled = value
                        owner.saveDesiredSettings()
                    }))
                    .tint(owner.switchTint)
                    .disabled(!owner.supportsAudioAndAuto || manualFallback)
                if SettingsCopy.showsBitrateSlider(autoQuality: owner.networkManager.autoQualityEnabled,
                                                  automaticBitrate: automaticBitrate) {
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
                        .frame(minHeight: 44)
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
                if !owner.networkManager.settingsApplyStatus.isEmpty {
                    Text(owner.networkManager.settingsApplyStatus)
                        .font(.footnote)
                        .foregroundStyle(owner.secondary)
                }
            } header: {
                Text("Quality")
            } footer: {
                if !owner.supportsAudioAndAuto {
                    Text(ClientStreamSettingsPreference.remoteUnsupportedReason)
                } else if automaticBitrate || owner.networkManager.autoQualityEnabled {
                    Text("Video adapts to your connection.")
                }
            }
            .listRowBackground(owner.rowBackground)
        }
    }

    @MainActor private struct ClipboardSection: View {
        @ObservedObject var manager: NetworkManager
        @ObservedObject var pasteboard: RemoteClipboardPasteboard
        @Binding var isTransferPresented: Bool

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
                Button {
                    isTransferPresented = true
                } label: {
                    HStack {
                        Text("Send or open files")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(uiColor: SessionInk.secondary))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(Color(uiColor: SessionInk.text))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
            } header: {
                Text("Clipboard & files")
            } footer: {
                Text("Automatic sending can copy passwords to your PC.")
            }
            .listRowBackground(Color(uiColor: SessionInk.surface))
        }
    }

    @MainActor private struct ConnectionSection: View {
        let owner: SettingsView
        var body: some View {
            Section {
                if owner.networkManager.isConnected {
                    if let code = owner.networkManager.hostIdentityCode {
                        LabeledContent("PC identity code", value: code)
                    }
                    let route = owner.networkManager.transferSnapshot.transport
                    if owner.networkManager.isRemoteControlSession {
                        LabeledContent("Connection type", value: "Network")
                    } else if route == "USB-C" || route == "Wi-Fi" {
                        LabeledContent("Connection type", value: route)
                    }
                }
                Button(role: .destructive) {
                    owner.showDisconnectConfirmation = true
                } label: {
                    Text("Disconnect").frame(minHeight: 44)
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
                    Text("Forget this PC").frame(minHeight: 44)
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
            }
            .listRowBackground(owner.rowBackground)
        }
    }

    @MainActor private struct AdvancedSection: View {
        let owner: SettingsView
        var body: some View {
            Section {
                DisclosureGroup("Connection details and logs", isExpanded: owner.$showAdvanced) {
                    if !owner.networkManager.isRemoteControlSession || owner.networkManager.effectiveQualitySummary == nil {
                        LabeledContent("PC is using", value: SettingsCopy.pcSettingsValue(
                            adaptive: owner.networkManager.isAdaptiveBitrate,
                            mbps: owner.networkManager.effectiveBitrateMbps,
                            audio: owner.networkManager.effectiveAudioEnabled))
                    }
                    if let summary = owner.networkManager.effectiveQualitySummary {
                        LabeledContent("Effective quality", value: summary)
                    }
                    owner.latencyRow("Receiving a frame", owner.networkManager.lastFrameReceiveDurationMs)
                    owner.latencyRow("Decoding a frame", owner.networkManager.lastDecodeLatencyMs)
                    LabeledContent("Bitrate in use",
                                   value: String(format: "%.0f Mbps", owner.networkManager.effectiveBitrateMbps))
                    LabeledContent("Video received",
                                   value: String(format: "%.1f Mbps", owner.networkManager.hudTelemetry.videoRxMbps))
                    Toggle("Debug logging", isOn: owner.$clientDebugLoggingEnabled).tint(owner.switchTint)
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
            } header: {
                Text("Troubleshooting")
            }
            .listRowBackground(owner.rowBackground)
        }
    }
}

/// Explicit consent is separate from legacy AutoBitrate and the saved manual target.
@MainActor private struct AdaptiveQualityControls: View {
    @ObservedObject var network: NetworkManager
    let switchTint: Color
    var body: some View {
        Toggle("Automatic quality", isOn: Binding(get: { network.autoQualityEnabled }, set: { network.setAutoQualityEnabled($0) }))
            .disabled(!network.adaptiveQualityAvailable)
            .tint(switchTint)
        if !network.adaptiveQualityAvailable {
            Text(network.adaptiveQualityUnavailableReason)
                .font(.footnote).foregroundStyle(.secondary)
            if network.savedAutoQualityEnabled {
                Text("Auto quality is saved for this PC. Using manual for this connection.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Plain wording

enum SettingsCopy {
    static func showsBitrateSlider(autoQuality: Bool, automaticBitrate: Bool) -> Bool {
        !autoQuality && !automaticBitrate
    }

    enum Level: Equatable { case good, fair, slow, none }

    static func nowShowing(width: UInt32, height: UInt32, refreshHz: UInt32, portrait: Bool) -> String {
        "Now showing \(width) × \(height) at \(refreshHz) Hz, \(portrait ? "portrait" : "landscape")"
    }

    static func pcUsing(adaptive: Bool, mbps: Double, audio: Bool) -> String {
        "The PC is using " + pcSettingsValue(adaptive: adaptive, mbps: mbps, audio: audio)
    }

    static func pcSettingsValue(adaptive: Bool, mbps: Double, audio: Bool) -> String {
        "\(adaptive ? "Auto, " : "")\(String(format: "%.0f", mbps)) Mbps, audio \(audio ? "on" : "off")"
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
