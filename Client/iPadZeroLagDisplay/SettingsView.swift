import SwiftUI

// MARK: - SettingsView

/// Full-screen Settings overlay for the ScreenCasting iPad client.
///
/// ## Responsibilities
///   1. Own the Client's desired bitrate and audio preferences.
///   2. Display Host-reported effective settings separately.
///   3. Persist and reconcile desired settings through `NetworkManager`.
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
    @State private var draftResolution = DisplayPreference.defaultValue.resolution
    @State private var draftRefreshHz: UInt32 = DisplayPreference.defaultValue.refreshHz
    @State private var draftOrientationMode: DisplayOrientationMode = .automatic
    @State private var showForgetConfirmation = false
    @AppStorage(ClientPreferenceKeys.showPerformanceHUD)
    private var showPerformanceHUD: Bool = true

    // MARK: Body

    public var body: some View {
        NavigationView {
            ZStack {
                // ── Background ───────────────────────────────────────────────
                Color(hex: "#0F172A").ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        settingsCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("Virtual Display", systemImage: "rectangle.on.rectangle")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white)

                                Divider().background(Color.white.opacity(0.12))

                                if let capabilities = networkManager.displayCapabilities {
                                    Text("Native 2388 x 1668 @ \(DisplayPreference.nativeRefreshHz) Hz source")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.85))

                                    Picker("Orientation", selection: $draftOrientationMode) {
                                        ForEach(DisplayOrientationMode.allCases, id: \.self) { mode in
                                            Text(mode.title).tag(mode)
                                        }
                                    }
                                    .pickerStyle(.menu)

                                    Button(action: applyDisplaySettings) {
                                        Text(networkManager.isDisplayConfigurationPending
                                             ? "Applying…"
                                             : "Apply Display Settings")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.white)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 11)
                                            .background(Color(hex: "#0EA5E9"))
                                            .cornerRadius(10)
                                    }
                                    .disabled(networkManager.isDisplayConfigurationPending)

                                    if let effective = networkManager.effectiveDisplayState {
                                        Text("Active: \(effective.width) × \(effective.height) @ \(effective.refreshHz) Hz, \(effective.orientation == .portrait ? "Portrait" : "Landscape")")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.white.opacity(0.65))
                                    }
                                    if let failure = networkManager.displayConfigurationFailureMessage {
                                        Text(failure)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.orange)
                                    }
                                } else {
                                    Text("Connect to the Host to load supported display modes.")
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.55))
                                }
                            }
                        }

                        // ── Streaming Settings Card ──────────────────────────
                        settingsCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("Stream Connection", systemImage: "network")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white)

                                Divider().background(Color.white.opacity(0.12))

                                Text("Disconnect only when you are finished with this remote session.")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.55))

                                Button(role: .destructive) {
                                    networkManager.stop()
                                    dismiss()
                                } label: {
                                    Label("Disconnect Stream", systemImage: "xmark.circle.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 11)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)

                                Button(role: .destructive) {
                                    showForgetConfirmation = true
                                } label: {
                                    Label("Forget This Host", systemImage: "trash.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 11)
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                            }
                        }

                        settingsCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("On-Screen Display", systemImage: "speedometer")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white)

                                Divider().background(Color.white.opacity(0.12))

                                Toggle("Show Performance HUD", isOn: $showPerformanceHUD)
                                    .tint(Color(hex: "#0EA5E9"))

                                Text("Shows FPS and frame receive timing while streaming.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.55))
                            }
                        }

                        settingsCard {
                            VStack(alignment: .leading, spacing: 16) {
                                Label("Bitrate Control", systemImage: "gauge.medium")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white)

                                Divider().background(Color.white.opacity(0.12))

                                // Client desired bitrate is authoritative; Host reports the effective value.
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Target Bitrate")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.85))
                                        Spacer()
                                        Text(String(format: "%.0f Mbps", draftBitrate))
                                            .font(.system(size: 18, weight: .bold,
                                                          design: .monospaced))
                                            .foregroundColor(Color(hex: "#38BDF8"))
                                            .animation(.easeInOut(duration: 0.15),
                                                       value: draftBitrate)
                                    }

                                    Slider(
                                        value: $draftBitrate,
                                        in: 3...50,
                                        step: 1,
                                        onEditingChanged: { editing in
                                            if !editing {
                                                saveDesiredSettings()
                                            }
                                        }
                                    )
                                    .tint(Color(hex: "#0EA5E9"))

                                    HStack {
                                        Text("3 Mbps")
                                            .font(.system(size: 10))
                                            .foregroundColor(.white.opacity(0.4))
                                        Spacer()
                                        Text("50 Mbps")
                                            .font(.system(size: 10))
                                            .foregroundColor(.white.opacity(0.4))
                                    }
                                }

                                Toggle("Audio", isOn: Binding(
                                    get: { draftAudioEnabled },
                                    set: { value in
                                        draftAudioEnabled = value
                                        saveDesiredSettings()
                                    }))
                                    .tint(Color(hex: "#0EA5E9"))
                                Text(
                                    String(
                                        format: "Host effective: %.0f Mbps • Audio %@",
                                        networkManager.effectiveBitrateMbps,
                                        networkManager.effectiveAudioEnabled ? "On" : "Off"))
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.55))
                                if !networkManager.settingsApplyStatus.isEmpty {
                                    Text(networkManager.settingsApplyStatus)
                                        .font(.system(size: 11, weight: .semibold))
                                }
                            }
                        }

                        // ── Network Telemetry Card ────────────────────────────
                        settingsCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("Network Telemetry (2 Hz)", systemImage: "waveform.path.ecg")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white)

                                Divider().background(Color.white.opacity(0.12))

                                HStack(spacing: 0) {
                                    telemetryTile(
                                        label:  "Frame Receive",
                                        value:  String(format: "%.1f ms",
                                                       networkManager.lastFrameReceiveDurationMs),
                                        color:  latencyColor(networkManager.lastFrameReceiveDurationMs)
                                    )
                                    Divider().frame(height: 40)
                                        .background(Color.white.opacity(0.1))
                                    telemetryTile(
                                        label:  "Decode Latency",
                                        value:  String(format: "%.1f ms",
                                                       networkManager.lastDecodeLatencyMs),
                                        color:  latencyColor(networkManager.lastDecodeLatencyMs)
                                    )
                                    Divider().frame(height: 40)
                                        .background(Color.white.opacity(0.1))
                                    telemetryTile(
                                        label:  "Active Bitrate",
                                        value:  String(format: "%.0f Mbps",
                                                       networkManager.effectiveBitrateMbps),
                                        color:  Color(hex: "#38BDF8")
                                    )
                                }
                            }
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color(hex: "#0EA5E9"))
                }
            }
        }
        .onReceive(networkManager.$desiredBitrateMbps) { newMbps in
            draftBitrate = newMbps
        }
        .onReceive(networkManager.$desiredAudioEnabled) { enabled in
            draftAudioEnabled = enabled
        }
        .onReceive(networkManager.$displayCapabilities) { _ in
            synchronizeDisplayDraft()
        }
        .onReceive(networkManager.$displayPreference) { _ in
            synchronizeDisplayDraft()
        }
        .onAppear {
            draftBitrate = networkManager.desiredBitrateMbps
            draftAudioEnabled = networkManager.desiredAudioEnabled
            synchronizeDisplayDraft()
        }
        .confirmationDialog(
            "Forget this trusted Host?",
            isPresented: $showForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget Host", role: .destructive) {
                networkManager.forgetTrustedHost()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next connection will require the Host PIN again.")
        }
    }

    // MARK: - Private Helpers

    private func synchronizeDisplayDraft() {
        guard let capabilities = networkManager.displayCapabilities else { return }
        let preference = networkManager.displayPreference.reconciled(with: capabilities)
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
            audioEnabled: draftAudioEnabled)
    }

    /// Returns a latency-based colour for the telemetry tiles (green → amber → red).
    private func latencyColor(_ ms: Double) -> Color {
        switch ms {
        case ..<10:  return Color(hex: "#10B981")   // green  — excellent
        case ..<20:  return Color(hex: "#F59E0B")   // amber  — moderate
        default:     return Color(hex: "#EF4444")   // red    — congested
        }
    }

    // MARK: - Reusable Sub-Views

    @ViewBuilder
    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading) { content() }
            .padding(16)
            .background(Color(hex: "#1E293B"))
            .cornerRadius(14)
            .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 3)
    }

    @ViewBuilder
    private func telemetryTile(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - ContentView integration example

extension ContentView {
    /// Shows the settings sheet from the HUD toolbar.
    /// Wire this to a gear icon button in your HUD overlay.
    @ViewBuilder
    func settingsButton(networkManager: NetworkManager) -> some View {
        // Example: add to your HUD's top-right corner
        // Button { showSettings = true } label: {
        //     Image(systemName: "gearshape.fill")
        //         .font(.system(size: 22))
        //         .foregroundColor(.white.opacity(0.8))
        // }
        // .sheet(isPresented: $showSettings) {
        //     SettingsView(networkManager: networkManager)
        // }
        EmptyView()
    }
}

// MARK: - Color(hex:) helper

private extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >>  8) & 0xFF) / 255
        let b = Double( int        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
