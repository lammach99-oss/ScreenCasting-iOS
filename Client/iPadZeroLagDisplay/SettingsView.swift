import SwiftUI

// MARK: - SettingsView

/// Settings for the ScreenCasting iPad client, grouped by how often they are used.
///
/// ## State Ownership
///   Client intent and Host effective state are distinct published values in
///   `NetworkManager`; Host reports never move these controls.
public struct SettingsView: View {

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

    // MARK: Body

    public var body: some View {
        NavigationStack {
            Form {
                displaySection
                streamSection
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

    private var displaySection: some View {
        Section {
            if networkManager.displayCapabilities != nil {
                // Only a user's pick sends a request; drafts synced from the PC never do.
                Picker("Orientation", selection: Binding(
                    get: { draftOrientationMode },
                    set: { mode in
                        draftOrientationMode = mode
                        if mode != currentOrientationMode { applyDisplaySettings() }
                    })) {
                    ForEach(DisplayOrientationMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .disabled(networkManager.isDisplayConfigurationPending)
                if networkManager.isDisplayConfigurationPending {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Applying…").foregroundStyle(secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else if let effective = networkManager.effectiveDisplayState {
                    Text(SettingsCopy.nowShowing(width: effective.width, height: effective.height,
                                                 refreshHz: effective.refreshHz,
                                                 portrait: effective.orientation == .portrait))
                        .font(.footnote)
                        .foregroundStyle(secondary)
                }
                if let failure = networkManager.displayConfigurationFailureMessage {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Color(uiColor: SessionInk.warning))
                }
            } else {
                Text("Connect to your PC to change the display.")
                    .foregroundStyle(secondary)
            }
            Toggle("Game mode", isOn: $gameModeEnabled).tint(switchTint)
            Toggle("Show frame rate on screen", isOn: $showPerformanceHUD).tint(switchTint)
        } header: {
            Text("Display")
        } footer: {
            Text("Game mode streams up to 120 frames a second for fast motion. Off keeps a steady 60.")
        }
        .listRowBackground(rowBackground)
    }

    private var streamSection: some View {
        Section {
            Toggle("Automatic bitrate", isOn: Binding(
                get: { draftAdaptiveBitrateEnabled },
                set: { value in
                    draftAdaptiveBitrateEnabled = value
                    saveDesiredSettings()
                }))
                .tint(switchTint)
            if !draftAdaptiveBitrateEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Bitrate")
                        Spacer()
                        Text(String(format: "%.0f Mbps", draftBitrate))
                            .monospacedDigit()
                            .foregroundStyle(secondary)
                    }
                    .accessibilityHidden(true) // The slider below reads the same label and value.
                    // Client desired bitrate is authoritative; Host reports the effective value.
                    Slider(value: $draftBitrate, in: 3...100, step: 1) {
                        Text("Bitrate")
                    } minimumValueLabel: {
                        Text("3").font(.caption).foregroundStyle(secondary).accessibilityHidden(true)
                    } maximumValueLabel: {
                        Text("100").font(.caption).foregroundStyle(secondary).accessibilityHidden(true)
                    } onEditingChanged: { editing in
                        if !editing { saveDesiredSettings() }
                    }
                    .accessibilityValue(String(format: "%.0f megabits per second", draftBitrate))
                }
            }
            Toggle("Sound from the PC", isOn: Binding(
                get: { draftAudioEnabled },
                set: { value in
                    draftAudioEnabled = value
                    saveDesiredSettings()
                }))
                .tint(switchTint)
        } header: {
            Text("Stream quality")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(SettingsCopy.pcUsing(adaptive: networkManager.isAdaptiveBitrate,
                                          mbps: networkManager.effectiveBitrateMbps,
                                          audio: networkManager.effectiveAudioEnabled))
                if !networkManager.settingsApplyStatus.isEmpty {
                    Text(networkManager.settingsApplyStatus)
                }
            }
        }
        .listRowBackground(rowBackground)
    }

    private var connectionSection: some View {
        Section {
            Button(role: .destructive) {
                showDisconnectConfirmation = true
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
            .confirmationDialog("Disconnect from your PC?", isPresented: $showDisconnectConfirmation,
                                titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) {
                    networkManager.stop()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
            Button(role: .destructive) {
                showForgetConfirmation = true
            } label: {
                Label("Forget this PC", systemImage: "trash")
            }
            .confirmationDialog("Forget this PC?", isPresented: $showForgetConfirmation,
                                titleVisibility: .visible) {
                Button("Forget PC", role: .destructive) {
                    networkManager.forgetTrustedHost()
                    dismiss()
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
        .listRowBackground(rowBackground)
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                latencyRow("Frame receive", networkManager.lastFrameReceiveDurationMs)
                latencyRow("Decode", networkManager.lastDecodeLatencyMs)
                LabeledContent("Bitrate in use",
                               value: String(format: "%.0f Mbps", networkManager.effectiveBitrateMbps))
                LabeledContent("Video received",
                               value: String(format: "%.1f Mbps", networkManager.hudTelemetry.videoRxMbps))
                Toggle("Debug logging", isOn: $clientDebugLoggingEnabled).tint(switchTint)
                Text("Writes detailed logs for troubleshooting. Leave it off day to day.")
                    .font(.footnote)
                    .foregroundStyle(secondary)
                Button(role: .destructive) {
                    showDeleteLogsConfirmation = true
                } label: {
                    Text(isDeletingClientLogs ? "Deleting logs…" : "Delete logs")
                }
                .disabled(isDeletingClientLogs)
                .confirmationDialog("Delete the iPad's logs?", isPresented: $showDeleteLogsConfirmation,
                                    titleVisibility: .visible) {
                    Button("Delete logs", role: .destructive) {
                        deleteClientLogs()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Deletes saved diagnostic and telemetry logs. If debug logging is on, the current log is kept.")
                }
                if let clientLogDeletionMessage {
                    Text(clientLogDeletionMessage)
                        .font(.footnote)
                        .foregroundStyle(secondary)
                }
            }
        }
        .listRowBackground(rowBackground)
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
