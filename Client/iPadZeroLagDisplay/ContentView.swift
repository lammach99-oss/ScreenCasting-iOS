import SwiftUI
import Foundation
import os
import UIKit

// MARK: - PIN Shake Modifier

struct ShakeEffect: GeometryEffect {
    var amount: CGFloat = 10
    var shakesPerUnit = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = amount * sin(animatableData * .pi * CGFloat(shakesPerUnit))
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}

// MARK: - PIN Entry Overlay

struct PINEntryView: View {
    @Binding var pin: String
    let authFailed: Bool
    let failureReason: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool
    @State private var shakeAttempts: CGFloat = 0

    var body: some View {
        ZStack {
            // Blurred background
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture { } // Consume taps to block dismissal

            VStack(spacing: 28) {

                // Header
                VStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(
                            LinearGradient(colors: [.blue, .purple],
                                           startPoint: .topLeading,
                                           endPoint: .bottomTrailing)
                        )

                    Text("Enter Pairing PIN")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("Enter the 4-digit PIN displayed\non your Windows PC.")
                        .font(.system(size: 14))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.6))
                }

                // PIN Dots Indicator
                HStack(spacing: 20) {
                    ForEach(0..<4, id: \.self) { index in
                        ZStack {
                            Circle()
                                .stroke(
                                    index < pin.count
                                        ? Color.blue
                                        : Color.white.opacity(0.25),
                                    lineWidth: 2
                                )
                                .frame(width: 22, height: 22)

                            if index < pin.count {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 12, height: 12)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: pin.count)
                    }
                }
                .modifier(ShakeEffect(animatableData: shakeAttempts))

                // Invisible SecureField capturing keyboard input
                SecureField("", text: $pin)
                    .keyboardType(.numberPad)
                    .focused($isFocused)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .onChange(of: pin) { _, newValue in
                        // Clamp to 4 digits only
                        if newValue.count > 4 {
                            pin = String(newValue.prefix(4))
                        }
                        // Remove non-numeric characters
                        let filtered = newValue.filter(\.isNumber)
                        if filtered != newValue { pin = filtered }
                    }

                // Tap-to-focus hint button (also auto-focuses on appear)
                Button(action: { isFocused = true }) {
                    Text("Tap here to type PIN")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.35))
                }

                // Error message
                if authFailed {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 13))
                        Text(failureReason)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.red.opacity(0.9))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.12))
                    .cornerRadius(10)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }

                // Action Buttons
                VStack(spacing: 12) {
                    Button(action: onSubmit) {
                        Text("Confirm PIN")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                pin.count == 4
                                    ? LinearGradient(colors: [.blue, .purple],
                                                     startPoint: .leading,
                                                     endPoint: .trailing)
                                    : LinearGradient(colors: [.gray.opacity(0.4), .gray.opacity(0.3)],
                                                     startPoint: .leading,
                                                     endPoint: .trailing)
                            )
                            .cornerRadius(14)
                    }
                    .disabled(pin.count != 4)
                    .animation(.easeInOut(duration: 0.2), value: pin.count)

                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.45))
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 340)
            .background(.ultraThinMaterial)
            .cornerRadius(28)
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 30, x: 0, y: 10)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isFocused = true
            }
        }
        .onChange(of: authFailed) { _, newValue in
            if newValue {
                withAnimation(.default) {
                    shakeAttempts += 1
                }
                // Clear PIN after failed attempt so user can retype
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    pin = ""
                }
            }
        }
    }
}

// MARK: - ContentView

public struct ContentView: View {
    private static let geometryLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iPadZeroLagDisplay.client",
        category: "presentation")

    @StateObject private var networkManager: NetworkManager
    @StateObject private var streamManager: StreamManager
    @StateObject private var discoveryManager = DiscoveryManager()

    // PIN State
    @State private var enteredPIN: String = ""
    @State private var showConnectSheet: Bool = false
    @State private var hostIP: String = ""
    @State private var useUSBMode: Bool = false

    // UI States
    @State private var isHudVisible: Bool = true
    @State private var renderedContentViewport: VideoContentViewport?
    @State private var rendererGeometrySnapshot: RendererGeometrySnapshot?
    @State private var presentationGeometry: PresentationSurfaceGeometry?
    @State private var lastGeometrySnapshotLine = ""
    @State private var isSettingsPresented = false

    public init() {
        let netManager = NetworkManager()
        _networkManager = StateObject(wrappedValue: netManager)
        _streamManager  = StateObject(wrappedValue: StreamManager(networkManager: netManager))
    }

    // MARK: - Body

    public var body: some View {
        ZStack {

            // LAYER 1: Background Content
            backgroundLayer

            // LAYER 2: Foreground UI
            foregroundLayer
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            networkManager.updateInterfaceOrientation(currentInterfaceOrientation())
            discoveryManager.startBrowsing()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            discoveryManager.stopBrowsing()
            networkManager.stop()
        }
        .animation(.easeInOut(duration: 0.3), value: streamManager.isConnected)
        // PIN entry overlay: shown when awaiting PIN or after auth failure
        .overlay {
            if isPINPhase {
                PINEntryView(
                    pin: $enteredPIN,
                    authFailed: isAuthFailed,
                    failureReason: authFailureReason,
                    onSubmit: {
                        networkManager.sendAuthPIN(enteredPIN)
                    },
                    onCancel: {
                        networkManager.stop()
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(10)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isPINPhase)
        .onChange(of: networkManager.connectionState) { _, newState in
            if newState == .awaitingPIN, enteredPIN.count == 4 {
                networkManager.sendAuthPIN(enteredPIN)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIDevice.orientationDidChangeNotification)
        ) { _ in
            DispatchQueue.main.async {
                networkManager.updateInterfaceOrientation(
                    currentInterfaceOrientation())
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView(networkManager: networkManager)
        }
    }

    // MARK: - Computed Helpers

    private var isPINPhase: Bool {
        switch networkManager.connectionState {
        case .awaitingPIN, .authFailed: return true
        default: return false
        }
    }

    private var isAuthFailed: Bool {
        if case .authFailed = networkManager.connectionState { return true }
        return false
    }

    private var authFailureReason: String {
        if case .authFailed(let reason) = networkManager.connectionState { return reason }
        return ""
    }

    private var normalizedManualHost: String {
        hostIP.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func currentInterfaceOrientation() -> ClientDisplayOrientation {
        let activeScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return activeScene?.interfaceOrientation.isPortrait == true
            ? .portrait
            : .landscape
    }

    private var isValidManualIPv4: Bool {
        let octets = normalizedManualHost.split(
            separator: ".",
            omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard !octet.isEmpty,
                  octet.count <= 3,
                  octet.allSatisfy(\.isNumber),
                  let value = Int(octet),
                  (0...255).contains(value) else {
                return false
            }
            return true
        }
    }

    // MARK: - Layers

    @ViewBuilder
    private var backgroundLayer: some View {
        if streamManager.isConnected {
            connectedVideoSurface
        } else {
            // Premium Disconnected Background
            RadialGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.10, green: 0.15, blue: 0.28),
                    Color(red: 0.05, green: 0.07, blue: 0.12)
                ]),
                center: .center,
                startRadius: 10,
                endRadius: 600
            )
            .ignoresSafeArea()
        }
    }

    // The decoder/renderer owns the viewport it actually draws. Keep the
    // Metal and UIKit touch surfaces in one full-window container so that the
    // same normalized viewport describes both surfaces.
    @ViewBuilder
    private var connectedVideoSurface: some View {
        GeometryReader { proxy in
            let frame = FullscreenSurfaceLayout.edgeToEdgeFrame(
                proposedBounds: proxy.frame(in: .local),
                safeAreaInsets: proxy.safeAreaInsets)

            ConnectedPresentationSurface(
                networkManager: networkManager,
                onFrameRendered: {
                    streamManager.registerFrameRendered()
                },
                onContentViewportChanged: { viewport in
                    renderedContentViewport = viewport
                },
                onGeometrySnapshotChanged: { snapshot in
                    rendererGeometrySnapshot = snapshot
                    if let presentationGeometry {
                        emitGeometrySnapshot(snapshot, presentationGeometry)
                    }
                },
                onPresentationGeometryChanged: { geometry in
                    presentationGeometry = geometry
                    if let rendererGeometrySnapshot {
                        emitGeometrySnapshot(rendererGeometrySnapshot, geometry)
                    }
                },
                onTouchBoundsChanged: { _ in },
                onPencilInput: { _ in },
                onSendTouchEvent: { type, x, y, pressure in
                    networkManager.sendTouchEvent(
                        type: type,
                        x: x,
                        y: y,
                        pressure: pressure)
                })
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(true)
                // A single touch remains remote input. Only a deliberate
                // double tap presents local stream controls.
                .simultaneousGesture(
                    TapGesture(count: 2)
                        .onEnded {
                            isSettingsPresented = true
                        })
        }
        .ignoresSafeArea(.container, edges: .all)
    }

    private func emitGeometrySnapshot(
        _ snapshot: RendererGeometrySnapshot,
        _ geometry: PresentationSurfaceGeometry
    ) {
        let line = "[ScreenCasting][VIEW_GEOMETRY] " +
            "framePx=\(Int(snapshot.decodedFrameSize.width))x\(Int(snapshot.decodedFrameSize.height)) " +
            "screenBounds=\(format(rect: geometry.screenBounds)) " +
            "windowBounds=\(format(rect: geometry.windowBounds)) " +
            "rootBounds=\(format(rect: geometry.rootBounds)) " +
            "streamContainerBounds=\(format(rect: geometry.streamContainerBounds)) " +
            "metalBounds=\(format(rect: geometry.metalBounds)) " +
            "touchBounds=\(format(rect: geometry.touchBounds)) " +
            "drawableSize=\(format(size: snapshot.drawableSize)) " +
            "scale=\(format(value: snapshot.contentScaleFactor)) " +
            "contentRect=\(format(rect: snapshot.contentViewport.contentRect(in: geometry.metalBounds))) " +
            "contentRectNorm=\(format(rect: snapshot.contentViewport.rect)) " +
            "safeAreaInsets=\(format(insets: geometry.safeAreaInsets))"
        guard line != lastGeometrySnapshotLine else { return }
        lastGeometrySnapshotLine = line
        Self.geometryLogger.notice("\(line, privacy: .public)")
    }

    private func format(rect: CGRect) -> String {
        "(x=\(format(value: rect.origin.x)),y=\(format(value: rect.origin.y)),w=\(format(value: rect.width)),h=\(format(value: rect.height)))"
    }

    private func format(insets: UIEdgeInsets) -> String {
        "(t=\(format(value: insets.top)),l=\(format(value: insets.left)),b=\(format(value: insets.bottom)),r=\(format(value: insets.right)))"
    }

    private func format(size: CGSize) -> String {
        "\(format(value: size.width))x\(format(value: size.height))"
    }

    private func format(value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }

    @ViewBuilder
    private var foregroundLayer: some View {
        if streamManager.isConnected {
            streamingHUD
        } else {
            disconnectedDashboard
        }
    }

    // MARK: - Disconnected Dashboard

    private var disconnectedDashboard: some View {
        VStack(spacing: 24) {
            Spacer()

            // Hero Header Card
            VStack(spacing: 16) {
                Image(systemName: "ipad.and.display.lagfree")
                    .symbolEffect(.pulse, options: .repeating)
                    .font(.system(size: 60))
                    .foregroundStyle(
                        LinearGradient(colors: [.blue, .purple],
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing)
                    )
                    .padding(.bottom, 8)

                Text("ScreenCasting")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text("Native 60Hz iPad Receiver")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.gray)
            }
            .padding(32)
            .background(Color.white.opacity(0.04))
            .cornerRadius(24)
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.1), lineWidth: 1))

            // Connection Info Card
            VStack(spacing: 20) {
                connectionStatusRow
                Divider().background(Color.white.opacity(0.15))
                connectivityGuide
                localIPCard
                connectButton
            }
            .padding(28)
            .frame(maxWidth: 400)
            .background(Color.white.opacity(0.03))
            .cornerRadius(20)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 1))

            Spacer()
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private var connectionStatusRow: some View {
        HStack(spacing: 12) {
            connectionStatusIcon
            connectionStatusText
        }
    }

    @ViewBuilder
    private var connectionStatusIcon: some View {
        switch networkManager.connectionState {
        case .connecting:
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                .scaleEffect(1.2)
        case .disconnected(let reason) where !reason.isEmpty:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 18))
        default:
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                .scaleEffect(1.2)
        }
    }

    @ViewBuilder
    private var connectionStatusText: some View {
        switch networkManager.connectionState {
        case .idle:
            Text("Enter PC IP to connect securely.")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        case .listening:
            Text("USB listener ready on port 12345.")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.green)
        case .connecting:
            Text("Connecting & establishing TLS…")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        case .disconnected(let reason) where !reason.isEmpty:
            Text("Disconnected: \(reason)")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(.orange.opacity(0.9))
                .lineLimit(2)
        default:
            Text("Waiting for PC Connection…")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        }
    }

    private var connectivityGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            if useUSBMode {
                Label("1. Connect the iPad to the PC via USB-C", systemImage: "cable.connector")
                Label("2. Start the USB listener below", systemImage: "antenna.radiowaves.left.and.right")
                Label("3. Select USB-C Direct and Start on the PC", systemImage: "desktopcomputer")
            } else {
                Label("1. Open Host App on your Windows PC", systemImage: "desktopcomputer")
                Label("2. Note the PIN Code shown on screen", systemImage: "lock.badge.key.fill")
                Label("3. Enter PC IP below and tap Connect", systemImage: "network")
            }
        }
        .font(.system(size: 14))
        .foregroundColor(.white.opacity(0.8))
    }

    private var localIPCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("This iPad's IP Address")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.gray)
                Text(streamManager.localIPAddress)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.blue)
            }
            Spacer()
            Button(action: { UIPasteboard.general.string = streamManager.localIPAddress }) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
                    .padding(8)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
        }
        .padding(14)
        .background(Color.black.opacity(0.2))
        .cornerRadius(12)
    }

    private var connectButton: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection Transport")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.gray)

            Picker("Connection Transport", selection: $useUSBMode) {
                Text("Wi-Fi").tag(false)
                Text("USB-C Direct").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: useUSBMode) { _, usbSelected in
                networkManager.stop()
                if usbSelected {
                    discoveryManager.stopBrowsing()
                    networkManager.startListening(port: 12345)
                } else {
                    discoveryManager.startBrowsing()
                }
            }

            if useUSBMode {
                VStack(alignment: .leading, spacing: 5) {
                    Text("The Windows host connects through iproxy. No IP address is required.")
                    Text("USB identity: \(UIDevice.current.name)")
                    if let fingerprint = networkManager.usbServerFingerprint {
                        Text("Certificate: \(String(fingerprint.prefix(12)))")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    Text("The selected-device UDID hash and certificate pin are shown on the Windows host.")
                    Button("Reset USB Pairing") {
                        networkManager.resetUSBPairing()
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .disabled(networkManager.connectionState == .connecting)
                }
                .font(.system(size: 12))
                .foregroundColor(.blue.opacity(0.9))
            }

            TextField("PC IP Address", text: $hostIP)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .textContentType(.URL)
                .padding(12)
                .foregroundColor(.white)
                .background(Color.white.opacity(0.08))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .disabled(useUSBMode)
                .opacity(useUSBMode ? 0.45 : 1)

            if !useUSBMode && !hostIP.isEmpty && !isValidManualIPv4 {
                Text("Enter a valid IPv4 address, for example 172.20.10.2.")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }

            SecureField("4-digit PIN Code", text: $enteredPIN)
                .keyboardType(.numberPad)
                .padding(12)
                .foregroundColor(.white)
                .background(Color.white.opacity(0.08))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .onChange(of: enteredPIN) { _, newValue in
                    let digits = newValue.filter(\.isNumber)
                    enteredPIN = String(digits.prefix(4))
                }

            Button(action: {
                if useUSBMode {
                    networkManager.startListening(port: 12345)
                } else {
                    networkManager.connect(to: normalizedManualHost)
                }
            }) {
                Label(
                    useUSBMode ? "Start USB Listener" : "Connect with IP and PIN",
                    systemImage: useUSBMode ? "cable.connector" : "lock.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .leading,
                            endPoint: .trailing)
                    )
                    .cornerRadius(10)
            }
            .disabled(
                (!useUSBMode && !isValidManualIPv4) ||
                enteredPIN.count != 4 ||
                networkManager.connectionState == .connecting)

            if !useUSBMode {
                Divider().background(Color.white.opacity(0.15))

                HStack {
                    Text("Discovered PC Hosts")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.gray)
                    Spacer()
                    if discoveryManager.discoveredHosts.isEmpty {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }

                if discoveryManager.discoveredHosts.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 24))
                            .foregroundColor(.blue.opacity(0.8))
                        Text("Searching for ScreenCasting PCs on local Wi-Fi…")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(12)
                } else {
                    VStack(spacing: 8) {
                        ForEach(discoveryManager.discoveredHosts) { host in
                            Button(action: {
                                enteredPIN = ""
                                networkManager.connect(to: host.endpoint)
                            }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "desktopcomputer")
                                        .font(.system(size: 18))
                                        .foregroundColor(.blue)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(host.name)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.white)
                                        Text("Tap to connect securely")
                                            .font(.system(size: 11))
                                            .foregroundColor(.gray)
                                    }

                                    Spacer()

                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.blue)
                                }
                                .padding(12)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 1))
                            }
                            .disabled(networkManager.connectionState == .connecting)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Streaming HUD

    private var streamingHUD: some View {
        ZStack {
            // Stats HUD (Top-Right)
            if isHudVisible {
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 16) {
                            // FPS Pill
                            HStack(spacing: 6) {
                                Circle().fill(Color.green).frame(width: 8, height: 8)
                                    .symbolEffect(.pulse, options: .repeating)
                                Text(String(format: "%.1f FPS", streamManager.currentFPS))
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                            }
                            Color.white.opacity(0.2).frame(width: 1, height: 14)
                            // This is a local receive-stage measurement, not RTT/ping.
                            HStack(spacing: 6) {
                                Image(systemName: "gauge.with.needle.fill")
                                    .foregroundColor(.orange).font(.system(size: 12))
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(String(format: "%.1f ms", streamManager.frameReceiveMs))
                                    Text("Frame receive")
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundColor(.white.opacity(0.65))
                                }
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                            }
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial).cornerRadius(18)
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.12), lineWidth: 1))
                        .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
                        .padding(.top, 16).padding(.trailing, 16)
                    }
                    Spacer()
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
    }
}
