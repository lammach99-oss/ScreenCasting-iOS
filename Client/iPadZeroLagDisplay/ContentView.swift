import SwiftUI
import Foundation
import os
import UIKit

enum ClientPreferenceKeys {
    static let showPerformanceHUD = "ScreenCasting.client.showPerformanceHUD"
    static let gameModeEnabled = "ScreenCasting.client.gameModeEnabled.v1"
    static let clientDebugLoggingEnabled =
        "ScreenCasting.client.debugLoggingEnabled.v1"
}

enum ClientDebugLoggingPreference {
    static func load(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(
            forKey: ClientPreferenceKeys.clientDebugLoggingEnabled) as? Bool ?? false
    }
}

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

private extension Color {
    static let inkCanvas = Color(uiColor: SessionInk.canvas)
    static let inkSurface = Color(uiColor: SessionInk.surface)
    static let inkRaised = Color(uiColor: SessionInk.raised)
    static let inkHairline = Color(uiColor: SessionInk.hairline)
    static let inkText = Color(uiColor: SessionInk.text)
    static let inkSecondary = Color(uiColor: SessionInk.secondary)
    static let inkWarning = Color(uiColor: SessionInk.warning)
    static let inkDanger = Color(uiColor: SessionInk.danger)
    static let inkAccent = Color(uiColor: SessionInk.accent)
    static let inkOnAccent = Color(uiColor: SessionInk.onAccent)
}

@MainActor struct PINEntryView: View {
    @Binding var pin: String
    let authFailed: Bool
    let failureReason: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool
    @State private var shakeAttempts: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture { } // Consume taps to block dismissal

            VStack(spacing: 24) {
                PINHeading(owner: self)

                PINProgress(owner: self)

                // Invisible SecureField capturing keyboard input
                SecureField("", text: $pin)
                    .keyboardType(.numberPad)
                    .focused($isFocused)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .accessibilityLabel("PIN")
                    .onChange(of: pin) { _, newValue in
                        if newValue.count > 4 {
                            pin = String(newValue.prefix(4))
                        }
                        let filtered = newValue.filter(\.isNumber)
                        if filtered != newValue { pin = filtered }
                    }

                Button(action: { isFocused = true }) {
                    Text("Show the number pad")
                        .font(.footnote)
                        .foregroundStyle(Color.inkSecondary)
                        .frame(minHeight: 44)
                }

                if authFailed {
                    Label(failureReason, systemImage: "exclamationmark.triangle")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.inkDanger)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.inkDanger.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }

                PINActions(owner: self)
            }
            .padding(28)
            .frame(maxWidth: 360)
            .background(Color.inkSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.inkHairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.4), radius: 30, x: 0, y: 10)
            .accessibilityAddTraits(.isModal)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
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
    @MainActor private struct PINHeading: View {
        let owner: PINEntryView
        var body: some View {
            VStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.inkText)
                    .accessibilityHidden(true)
                Text("Enter pairing PIN")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.inkText)
                Text("Type the 4-digit PIN shown on your Windows PC.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.inkSecondary)
            }
        }
    }

    @MainActor private struct PINProgress: View {
        let owner: PINEntryView
        var body: some View {
            HStack(spacing: 20) {
                ForEach(0..<4, id: \.self) { index in
                    ZStack {
                        Circle()
                            .stroke(index < owner.pin.count ? Color.inkAccent : Color.inkHairline, lineWidth: 2)
                            .frame(width: 22, height: 22)
                        if index < owner.pin.count {
                            Circle()
                                .fill(Color.inkAccent)
                                .frame(width: 12, height: 12)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.2, dampingFraction: 0.7), value: owner.pin.count)
                }
            }
            .modifier(ShakeEffect(animatableData: owner.shakeAttempts))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(owner.pin.count) of 4 digits entered")
        }
    }

    @MainActor private struct PINActions: View {
        let owner: PINEntryView
        var body: some View {
            VStack(spacing: 8) {
                Button(action: owner.onSubmit) {
                    Text("Confirm PIN")
                        .font(.headline)
                        .foregroundStyle(owner.pin.count == 4 ? Color.inkOnAccent : Color.inkSecondary)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(owner.pin.count == 4 ? Color.inkAccent : Color.inkRaised,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(owner.pin.count != 4)
                .animation(.easeInOut(duration: 0.2), value: owner.pin.count)

                Button(action: owner.onCancel) {
                    Text("Cancel")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
    }

}

// MARK: - Wi-Fi Host Identity Confirmation

struct HostIdentityConfirmationView: View {
    let identityCode: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture { }

            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.inkWarning)
                        .accessibilityHidden(true)
                    Text("Verify your Windows PC")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.inkText)
                    Text("Compare this code with the one on the PC. Continue only if they match.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.inkSecondary)
                }

                Text(identityCode)
                    .font(.system(.title2, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color.inkWarning)
                    .tracking(1.5)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .background(Color.inkWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel("Identity code \(identityCode)")

                VStack(spacing: 8) {
                    Button(action: onConfirm) {
                        Text("The codes match")
                            .font(.headline)
                            .foregroundStyle(Color.inkOnAccent)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Color.inkAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.subheadline)
                            .foregroundStyle(Color.inkSecondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 360)
            .background(Color.inkSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.inkHairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.4), radius: 30, x: 0, y: 10)
            .accessibilityAddTraits(.isModal)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

// MARK: - ContentView

@MainActor public struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    private static let geometryLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iPadZeroLagDisplay.client",
        category: "presentation")

    @StateObject private var networkManager: NetworkManager
    @StateObject private var streamManager: StreamManager
    @StateObject private var discoveryManager = DiscoveryManager()
    @StateObject private var remoteInput = RemoteSessionInputState()
    @StateObject private var inputSession = IPadInputSession()

    // PIN State
    @State private var enteredPIN: String = ""
    @State private var showConnectSheet: Bool = false
    @State private var hostIP: String = ""
    @State private var showIPEntry = false
    @State private var recentRemoteHosts: [RecentRemoteHost] = []
    @State private var copiedIP = false
    /// The current attempt is USB-C, so the status line never borrows the last Wi-Fi PC.
    @State private var usbChosen = false
    @State private var isWifiBrowsing = false
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The last Wi-Fi PC by name or typed address; Reconnect uses the matching saved target.
    @AppStorage("ScreenCasting.client.lastWifiHostLabel") private var lastWifiHostLabel = ""
    @AppStorage("ScreenCasting.client.remoteControlMode") private var remoteControlMode = false

    // UI States
    @AppStorage(ClientPreferenceKeys.showPerformanceHUD)
    private var isHudVisible: Bool = true
    @AppStorage(ClientPreferenceKeys.gameModeEnabled)
    private var gameModeEnabled: Bool = false
    @State private var renderedContentViewport: VideoContentViewport?
    @State private var rendererGeometrySnapshot: RendererGeometrySnapshot?
    @State private var presentationGeometry: PresentationSurfaceGeometry?
    @State private var lastGeometrySnapshotLine = ""
    @State private var isSettingsPresented = false
    @State private var isTransferPresented = false
    @State private var isSessionPanelOpen = false
    @State private var sessionPillHeight: CGFloat = 44
    @State private var showGestureGuide = false
    @State private var gestureToast: GestureToast?
    @AppStorage("ScreenCasting.client.gestureGuideSeen.v1") private var gestureGuideSeen = false
    private let gestureToasts = GestureToastLedger()
    /// What the session pill calls the PC: the discovered name or typed address of the last connect.
    @AppStorage("ScreenCasting.client.lastHostLabel") private var lastHostLabel = ""
    @State private var rootSurfaceSize: CGSize = .zero

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
        .environmentObject(inputSession)
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .background {
            RootGeometryObserver(owner: self)
        }
        .modifier(SessionLifecycle(owner: self))
        .animation(.easeInOut(duration: 0.3), value: streamManager.isConnected)
        // PIN entry overlay: shown when awaiting PIN or after auth failure
        .overlay {
            AuthenticationOverlay(owner: self)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isPINPhase)
        .onChange(of: networkManager.connectionState) { _, newState in
            if newState == .awaitingPIN, enteredPIN.count == 4 {
                networkManager.sendAuthPIN(enteredPIN)
            }
            if newState == .streaming { enteredPIN = "" }
            updateWifiBrowsing(for: newState)
        }
        .onChange(of: connectStatus.text) { _, text in
            if !streamManager.isConnected { UIAccessibility.post(notification: .announcement, argument: text) }
        }
        .onChange(of: remoteInputConfiguration) { old, value in
            inputSession.engine.setHardwareCaptureEnabled(value.active && !networkManager.captureInputBlocked)
            if value.requiresRetirement(comparedTo: old) { inputSession.releaseAll() }
            remoteInput.bind(networkManager)
            remoteInput.configure(value)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                networkManager.applicationDidBecomeActive()
                updateDisplayOrientation(for: rootSurfaceSize)
            case .inactive:
                inputSession.releaseAll()
                remoteInput.suspend(reason: 0)
                networkManager.applicationWillResignActive()
            case .background:
                inputSession.releaseAll()
                remoteInput.suspend(reason: 2)
                networkManager.applicationDidEnterBackground()
            @unknown default:
                break
            }
        }
        .onChange(of: isSheetPresented) { _, open in
            networkManager.setMirrorInputSettingsPresented(open)
        }
        .onChange(of: streamManager.isConnected) { _, connected in
            if !connected { isSessionPanelOpen = false; showGestureGuide = false; gestureToast = nil }
            offerGestureGuideIfNew()
        }
        .onChange(of: networkManager.mirrorControlState?.mode) { _, _ in offerGestureGuideIfNew() }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView(networkManager: networkManager)
        }
        .sheet(isPresented: $isTransferPresented) {
            TransferCenterSheet(networkManager: networkManager)
        }
    }

    // MARK: - Computed Helpers

    /// Settings and File Transfer both pause local input to the PC while they cover the stream.
    private var isSheetPresented: Bool { isSettingsPresented || isTransferPresented }

    private var isHostIdentityPhase: Bool {
        networkManager.connectionState == .awaitingHostIdentity
    }

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

    private var normalizedManualHost: String? {
        RemoteHostAddress.parse(hostIP)?.host
    }

    private func updateDisplayOrientation(for size: CGSize) {
        rootSurfaceSize = size
        guard let orientation = DisplayOrientationResolver.resolve(
            width: size.width,
            height: size.height) else { return }
        networkManager.updateInterfaceOrientation(orientation)
    }

    // MARK: - Layers

    @ViewBuilder
    private var backgroundLayer: some View {
        if streamManager.isConnected {
            connectedVideoSurface
        } else {
            Color.inkCanvas
                .ignoresSafeArea()
        }
    }

    // The decoder/renderer owns the viewport it actually draws. Keep the
    // Metal and UIKit touch surfaces in one full-window container so that the
    // same normalized viewport describes both surfaces.
    private var remoteInputConfiguration: RemoteSessionInputConfiguration {
        RemoteSessionInputConfiguration(remote: networkManager.isRemoteControlSession,
            connected: streamManager.isConnected,
            active: scenePhase == .active && !isSheetPresented && !showGestureGuide && !isSessionPanelOpen,
            generation: networkManager.remoteKeyboardGeneration,
            features: networkManager.remoteInputFeatures, context: networkManager.remoteInputContext,
            ready: networkManager.remoteInputReady, revision: networkManager.remoteInputRevision)
    }

    @ViewBuilder
    private var connectedVideoSurface: ConnectedVideoSurface {
        ConnectedVideoSurface(owner: self)
    }

    /// Touches reach the PC: an extended display, or a mirrored screen under granted control.
    private var touchReachesPC: Bool {
        let state = networkManager.mirrorControlState
        return state?.geometry == nil || state?.mode == .active
    }

    /// The gesture card greets the first session in which its gestures actually work, once.
    private func offerGestureGuideIfNew() {
        guard streamManager.isConnected, !gestureGuideSeen, !showGestureGuide,
              !isSheetPresented, touchReachesPC else { return }
        showGestureGuide = true
    }

    /// Toasts only while the gesture is new, and never when touches cannot reach the PC (view-only mirror).
    private func showGestureToast(_ hint: GestureHint) {
        guard touchReachesPC, !isSessionPanelOpen, !showGestureGuide,
              let text = gestureToasts.toast(for: hint) else { return }
        let toast = GestureToast(hint: hint, text: text)
        gestureToast = toast
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if gestureToast == toast { gestureToast = nil }
        }
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
    private var foregroundLayer: ForegroundLayer {
        ForegroundLayer(owner: self)
    }

    // MARK: - Disconnected Dashboard

    private var connectStatus: ConnectScreenStatus {
        if let operation = ConnectScreenStatus.connectionChange(networkManager.connectionSwitchState) { return operation }
        let hostLabel = lastHostLabel.isEmpty ? lastWifiHostLabel : lastHostLabel
        return .make(state: networkManager.connectionState,
                     pcName: hostLabel,
                     discoveredCount: discoveryManager.discoveredHosts.count,
                     reconnectAttempt: networkManager.autoReconnectAttempt,
                     usb: usbChosen,
                     canRetry: networkManager.hasReconnectTarget,
                     tailnetTarget: RemoteHostAddress.parse(hostLabel)?.isTailnet ?? false)
    }

    private func setWifiBrowsing(_ on: Bool) {
        guard on != isWifiBrowsing else { return }
        isWifiBrowsing = on
        if on { discoveryManager.startBrowsing() } else { discoveryManager.stopBrowsing() }
    }

    /// Wi-Fi discovery pauses only while the iPad waits for, or runs, a USB-C session.
    private func updateWifiBrowsing(for state: ConnectionState) {
        switch state {
        case .listening: setWifiBrowsing(false)
        case .idle, .disconnected: setWifiBrowsing(true)
        case .connecting, .awaitingHostIdentity, .awaitingPIN, .authFailed, .streaming: setWifiBrowsing(!usbChosen)
        }
    }

    private func startUSB() {
        usbChosen = true
        enteredPIN = ""
        lastHostLabel = ""
        networkManager.startListening(port: 42042)
    }

    /// Stacks a row vertically at accessibility text sizes so text is not squeezed beside its button.
    private var rowLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
    }

    private var hasIPv4Address: Bool {
        let parts = streamManager.localIPAddress.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// A connect, reconnect or USB wait is already running.
    private var isConnectBusy: Bool { connectStatus.action == .cancel || connectStatus.action == .stop }

    private var lastWifiName: String { lastWifiHostLabel.isEmpty ? "your PC" : lastWifiHostLabel }

    private var disconnectedDashboard: DisconnectedDashboard {
        DisconnectedDashboard(owner: self)
    }

    private var iPadAddressChip: some View {
        Button {
            UIPasteboard.general.string = streamManager.localIPAddress
            copiedIP = true
            UIAccessibility.post(notification: .announcement, argument: "Copied")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedIP = false }
        } label: {
            Label(copiedIP ? "Copied" : "This iPad \(streamManager.localIPAddress)",
                  systemImage: copiedIP ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(Color.inkSecondary)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .overlay(Capsule().stroke(Color.inkHairline, lineWidth: 0.5))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasIPv4Address)
        .accessibilityLabel(copiedIP ? "Copied" : "This iPad's address \(streamManager.localIPAddress)")
        .accessibilityHint("Copies the address")
    }

    private var statusLine: StatusLine {
        StatusLine(owner: self)
    }

    private var reconnectButton: some View {
        Button {
            usbChosen = false
            enteredPIN = ""
            lastHostLabel = lastWifiHostLabel
            networkManager.reconnectLastPC()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise").font(.title3).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reconnect to \(lastWifiName)").font(.headline).lineLimit(2)
                    Text("Wi-Fi · last used").font(.caption)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").accessibilityHidden(true)
            }
            .foregroundStyle(Color.inkOnAccent)
            .padding(.horizontal, 16)
            .frame(minHeight: 64)
            .background(Color.inkAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isConnectBusy)
        .accessibilityHint("Connects to the PC you used last")
    }

    private var discoveredPCs: DiscoveredPCs {
        DiscoveredPCs(owner: self)
    }

    private var usbCard: some View {
        let listening = networkManager.connectionState == .listening
        return rowLayout {
            Image(systemName: "cable.connector").font(.title3).foregroundStyle(Color.inkAccent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("USB-C cable").font(.subheadline.weight(.semibold))
                Text(ConnectScreenStatus.connectionRecommendation(networkManager.connectionSwitchState))
                    .font(.caption).foregroundStyle(Color.inkSecondary)
                Text(listening ? "Waiting. On the PC, pick USB-C Direct. This iPad shows as \(UIDevice.current.name)."
                     : "Plug in, tap Start, then pick USB-C Direct on the PC.")
                    .font(.caption)
                    .foregroundStyle(Color.inkSecondary)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Button(listening ? "Stop" : "Start") {
                if listening { networkManager.stop() } else { startUSB() }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(listening ? Color.inkText : Color.inkAccent)
            .disabled(isConnectBusy && !listening)
        }
        .padding(14)
        .background(Color.inkSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var ipEntry: AddressEntry {
        AddressEntry(owner: self)
    }

    // MARK: - Streaming HUD

    private var streamingHUD: some View {
        GeometryReader { proxy in
            let safeArea = presentationGeometry?.safeAreaInsets ?? .zero
            let safeTop = max(proxy.safeAreaInsets.top, safeArea.top)
            let safeTrailing = max(proxy.safeAreaInsets.trailing, safeArea.right)
            if isHudVisible && !isSessionPanelOpen {
                VStack {
                    HStack {
                        Spacer(minLength: 0)
                        SessionPerformanceReadout(fps: Double(streamManager.currentFPS),
                            frameReceiveMs: Double(streamManager.frameReceiveMs), videoRxMbps: networkManager.hudTelemetry.videoRxMbps)
                    }
                    Spacer(minLength: 0)
                }
                // Clear both the safe-area top and the measured expanded bar / collapsed grabber.
                .padding(.top, max(safeTop + 8, sessionPillHeight + 24))
                .padding(.trailing, safeTrailing + 8)
                .padding(.leading, max(proxy.safeAreaInsets.leading, safeArea.left) + 8)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
    }


    @MainActor private struct SessionLifecycle: ViewModifier {
        let owner: ContentView
        func body(content: Content) -> some View {
            content
                .onAppear {
                    owner.remoteInput.bind(owner.networkManager)
                    owner.remoteInput.configure(owner.remoteInputConfiguration)
                    owner.recentRemoteHosts = RecentRemoteHostStore.load()
                    UIApplication.shared.isIdleTimerDisabled = true
                    owner.setWifiBrowsing(true)
                    owner.networkManager.setDesiredPipelineMode(
                        owner.gameModeEnabled ? .game : .office)
                    owner.networkManager.applicationDidBecomeActive()
                }
                .onChange(of: owner.gameModeEnabled) { _, enabled in
                    owner.networkManager.setDesiredPipelineMode(
                        enabled ? .game : .office)
                }
                .onChange(of: owner.isSessionPanelOpen) { _, open in
                    owner.inputSession.panelPresentationChanged(open, surfaceActive:
                        owner.streamManager.isConnected && owner.scenePhase == .active && !owner.isSheetPresented && !owner.showGestureGuide)
                }
                .onDisappear {
                    owner.inputSession.releaseAll()
                    UIApplication.shared.isIdleTimerDisabled = false
                    owner.setWifiBrowsing(false)
                }
        }
    }

    @MainActor private struct AuthenticationOverlay: View {
        let owner: ContentView
        @ViewBuilder var body: some View {
            if owner.isHostIdentityPhase {
                HostIdentityConfirmationView(
                    identityCode: owner.networkManager.hostIdentityCode ?? "Unavailable",
                    onConfirm: {
                        owner.networkManager.confirmHostIdentity()
                    },
                    onCancel: {
                        owner.enteredPIN = ""
                        owner.networkManager.stop()
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(10)
            } else if owner.isPINPhase {
                PINEntryView(
                    pin: owner.$enteredPIN,
                    authFailed: owner.isAuthFailed,
                    failureReason: owner.authFailureReason,
                    onSubmit: {
                        owner.networkManager.sendAuthPIN(owner.enteredPIN)
                    },
                    onCancel: {
                        owner.enteredPIN = ""
                        owner.networkManager.stop()
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(10)
            }
        }
    }

    @MainActor private struct RootGeometryObserver: View {
        let owner: ContentView
        var body: some View {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        owner.updateDisplayOrientation(for: proxy.size)
                    }
                    .onChange(of: proxy.size) { _, size in
                        owner.updateDisplayOrientation(for: size)
                    }
            }
        }
    }

    @MainActor private struct RecentHosts: View {
        let owner: ContentView
        @ViewBuilder var body: some View {
            if !owner.recentRemoteHosts.isEmpty {
                Text("Recent").font(.footnote).foregroundStyle(Color.inkSecondary)
                VStack(spacing: 0) {
                    ForEach(Array(owner.recentRemoteHosts.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            owner.usbChosen = false
                            owner.enteredPIN = ""
                            owner.remoteControlMode = entry.remoteControl
                            owner.hostIP = entry.host
                            owner.lastHostLabel = entry.host
                            owner.lastWifiHostLabel = entry.host
                            owner.recentRemoteHosts = RecentRemoteHostStore.record(host: entry.host, remoteControl: entry.remoteControl)
                            owner.networkManager.connect(to: entry.host, port: entry.port)
                        } label: {
                            owner.rowLayout {
                                Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(Color.inkAccent)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.host).font(.subheadline.weight(.semibold))
                                        .lineLimit(owner.typeSize.isAccessibilitySize ? nil : 2)
                                    Text(entry.remoteControl ? "Whole PC" : "Casting display")
                                        .font(.caption).foregroundStyle(Color.inkSecondary)
                                }
                                if !owner.typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                                Image(systemName: "chevron.right").foregroundStyle(Color.inkSecondary).accessibilityHidden(true)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, owner.typeSize.isAccessibilitySize ? 10 : 0)
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(owner.isConnectBusy)
                        .accessibilityHint("Connects to this PC using the saved mode")
                        .contextMenu {
                            Button("Forget", role: .destructive) {
                                owner.networkManager.forgetTrustedHost(host: entry.host, port: entry.port)
                                owner.recentRemoteHosts = RecentRemoteHostStore.remove(host: entry.host, remoteControl: entry.remoteControl)
                            }
                            .disabled(owner.isConnectBusy)
                        }
                        if index < owner.recentRemoteHosts.count - 1 {
                            Rectangle().fill(Color.inkHairline).frame(height: 0.5)
                        }
                    }
                }
                .background(Color.inkSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
    // Nominal view types bound metadata expansion across independently rendered sections.
    @MainActor private struct ForegroundLayer: View {
        let owner: ContentView
        @ViewBuilder var body: some View {
            if owner.streamManager.isConnected {
                ZStack {
                    owner.streamingHUD
                    VStack {
                        CaptureAvailabilityNotice(message: owner.networkManager.captureAvailabilityNotice)
                            .padding(.top, owner.sessionPillHeight + (owner.isHudVisible && !owner.isSessionPanelOpen ? 48 : 24))
                            .padding(.horizontal, 24)
                        if owner.networkManager.effectiveQualitySummary?.contains("text sharpness reduced") == true {
                            Text("text sharpness reduced")
                                .font(.caption.weight(.semibold)).foregroundStyle(Color.inkText)
                                .shadow(color: .inkCanvas, radius: 0.5, x: 0, y: 1)
                                .accessibilityIdentifier("session.reducedSharpness")
                        }
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    SessionPanelOverlay(
                        networkManager: owner.networkManager,
                        hostLabel: SessionPanelSnapshot.sessionHost(current: owner.lastHostLabel, lastWifi: owner.lastWifiHostLabel,
                                                                    usb: owner.usbChosen),
                        isOpen: owner.$isSessionPanelOpen,
                        remoteInput: owner.remoteInput,
                        tailnetTarget: RemoteHostAddress.parse(owner.hostIP.isEmpty ? owner.lastWifiHostLabel : owner.hostIP)?.isTailnet ?? false,
                        performance: owner.isHudVisible ? SessionPerformanceReadout(fps: Double(owner.streamManager.currentFPS),
                            frameReceiveMs: Double(owner.streamManager.frameReceiveMs), videoRxMbps: owner.networkManager.hudTelemetry.videoRxMbps) : nil,
                        onPillHeightChange: { owner.sessionPillHeight = $0 },
                        onFiles: { owner.isTransferPresented = true },
                        onSettings: { owner.isSettingsPresented = true },
                        onGestures: { owner.showGestureGuide = true })
                    VStack {
                        Spacer()
                        if let toast = owner.gestureToast {
                            GestureToastView(hint: toast.hint, text: toast.text)
                                .padding(.bottom, 28)
                                .transition(.opacity)
                        }
                    }
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.2), value: owner.gestureToast)
                    if owner.showGestureGuide {
                        GestureGuideCard(mode: .input(owner.inputSession.touchMode), onDone: {
                            owner.gestureGuideSeen = true
                            owner.showGestureGuide = false
                        })
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: owner.showGestureGuide)
            } else {
                owner.disconnectedDashboard
            }
        }
    }

    @MainActor private struct ConnectedVideoSurface: View {
        let owner: ContentView
        @ViewBuilder var body: some View {
            GeometryReader { proxy in
                let frame = FullscreenSurfaceLayout.edgeToEdgeFrame(
                    proposedBounds: proxy.frame(in: .local),
                    safeAreaInsets: proxy.safeAreaInsets)

                ConnectedPresentationSurface(
                    networkManager: owner.networkManager,
                    gameModeEnabled: owner.gameModeEnabled,
                    remoteKeyboardActive: owner.streamManager.isConnected && owner.scenePhase == .active && !owner.isSheetPresented && !owner.showGestureGuide && !owner.isSessionPanelOpen,
                    sessionInputActive: owner.streamManager.isConnected && owner.scenePhase == .active && !owner.isSheetPresented && !owner.showGestureGuide,
                    onKeyboardInput: { command in
                        owner.networkManager.sendKeyboardInput(command)
                    },
                    onTextCommit: { text in
                        owner.networkManager.sendTextCommit(text)
                    },
                    onFrameRendered: {
                        owner.streamManager.registerFrameRendered()
                    },
                    onContentViewportChanged: { viewport in
                        owner.renderedContentViewport = viewport
                    },
                    onGeometrySnapshotChanged: { snapshot in
                        owner.rendererGeometrySnapshot = snapshot
                        if let presentationGeometry = owner.presentationGeometry {
                            owner.emitGeometrySnapshot(snapshot, presentationGeometry)
                        }
                    },
                    onPresentationGeometryChanged: { geometry in
                        owner.presentationGeometry = geometry
                        if let rendererGeometrySnapshot = owner.rendererGeometrySnapshot {
                            owner.emitGeometrySnapshot(rendererGeometrySnapshot, geometry)
                        }
                    },
                    onTouchBoundsChanged: { _ in },
                    onPencilInput: { _ in },
                    onSendTouchEvent: { type, x, y, pressure in
                        owner.networkManager.sendTouchEvent(
                            type: type,
                            x: x,
                            y: y,
                            pressure: pressure)
                    },
                    onDirectTouchContact: { command in
                        owner.networkManager.sendDirectTouchContact(command)
                    },
                    onPointerInput: { command in
                        owner.networkManager.sendPointerInput(command)
                    },
                    onOpenSettings: {
                        // The 3-finger tap opens the session panel; Settings is one tap inside it.
                        owner.isSessionPanelOpen = true
                    })
                    .remoteSessionInput(owner.remoteInput)
                    .iPadInputSession(owner.inputSession)
                    .gestureHints { hint in owner.showGestureToast(hint) }
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .allowsHitTesting(true)
                    .ignoresSafeArea(.keyboard)
                    // This container has the committed drawable size. Publish
                    // it as an orientation source so capabilities-first startup
                    // cannot miss the initial portrait request.
                    .onAppear {
                        owner.updateDisplayOrientation(for: proxy.size)
                    }
                    .onChange(of: proxy.size) { _, size in
                        owner.updateDisplayOrientation(for: size)
                    }
            }
            .ignoresSafeArea(.container, edges: .all)
        }
    }

    @MainActor private struct DisconnectedDashboard: View {
        let owner: ContentView
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    owner.rowLayout {
                        Label {
                            Text("ScreenCasting").font(.headline)
                        } icon: {
                            Image(systemName: "rectangle.on.rectangle").foregroundStyle(Color.inkAccent)
                        }
                        if !owner.typeSize.isAccessibilitySize { Spacer() }
                        owner.iPadAddressChip
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        owner.statusLine
                        Text(ConnectScreenStatus.connectionRecommendation(owner.networkManager.connectionSwitchState))
                            .font(.footnote).foregroundStyle(Color.inkSecondary)
                            .accessibilityIdentifier("connectionRecommendation")
                        // Hidden, not faded, while a connect or USB wait runs: a faded card read as broken.
                        if owner.networkManager.connectionSwitchState.offersReconnect {
                            Button("Reconnect over Wi-Fi") {
                                owner.usbChosen = false; owner.enteredPIN = ""
                                owner.networkManager.reconnectConnectionOverWifi()
                            }
                            .buttonStyle(.bordered).controlSize(.large).tint(Color.inkAccent)
                            .frame(minHeight: 44)
                            .disabled(!owner.networkManager.hasReconnectTarget)
                        } else if owner.networkManager.hasReconnectTarget && !owner.isConnectBusy { owner.reconnectButton }
                        if owner.networkManager.hasReconnectTarget && !owner.isConnectBusy {
                            Button("Forget last PC", role: .destructive) { owner.networkManager.forgetTrustedHost() }
                                .buttonStyle(.bordered).frame(minHeight: 44)
                                .accessibilityHint("Removes this PC's saved trust so you can pair again")
                        }
                        owner.discoveredPCs
                        owner.usbCard
                        owner.ipEntry
                    }
                    .frame(maxWidth: 520, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
            }
            .foregroundStyle(Color.inkText)
            .accessibilityHidden(owner.isPINPhase || owner.isHostIdentityPhase)
            .transition(.opacity)
        }
    }

    @MainActor private struct StatusLine: View {
        let owner: ContentView
        var body: some View {
            let status = owner.connectStatus
                    let color: Color = status.tone == .warning ? .inkWarning : status.tone == .danger ? .inkDanger : .inkText
                    return owner.rowLayout {
                        HStack(alignment: .center, spacing: 10) {
                            Group {
                                switch status.tone {
                                case .busy: ProgressView().tint(Color.inkSecondary)
                                case .warning: Image(systemName: "arrow.triangle.2.circlepath")
                                case .danger: Image(systemName: "exclamationmark.triangle")
                                case .ready: Image(systemName: "checkmark.circle")
                                case .neutral: Image(systemName: "wifi")
                                }
                            }
                            .foregroundStyle(color)
                            .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(status.text).font(.subheadline).foregroundStyle(color)
                                if let detail = status.detail {
                                    Text(detail).font(.caption).foregroundStyle(Color.inkSecondary).lineLimit(2)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if !owner.typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                        // A USB wait is stopped from the USB-C card, so the status line does not repeat its Stop.
                        if status.action != .none && !(status.action == .stop && owner.networkManager.connectionState == .listening) {
                            Button(status.action == .retry ? "Retry" : status.action == .restartUSB ? "Start again"
                                   : status.action == .stop ? "Stop" : "Cancel") {
                                switch status.action {
                                case .retry:
                                    owner.usbChosen = false
                                    owner.enteredPIN = ""
                                    owner.networkManager.reconnectLastPC()
                                case .restartUSB:
                                    owner.startUSB()
                                case .cancel, .stop:
                                    owner.enteredPIN = ""
                                    owner.networkManager.stop()
                                case .none:
                                    break
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .tint(Color.inkAccent)
                        }
                    }
        }
    }

    @MainActor private struct DiscoveredPCs: View {
        let owner: ContentView
        var body: some View {
            let hosts = owner.discoveryManager.discoveredHosts
                    return VStack(alignment: .leading, spacing: 8) {
                        Text("PCs on this Wi-Fi").font(.footnote).foregroundStyle(Color.inkSecondary)
                        if hosts.isEmpty {
                            Text("None found yet. Open ScreenCasting on the PC and make sure both are on the same Wi-Fi.")
                                .font(.footnote)
                                .foregroundStyle(Color.inkSecondary)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.inkSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(hosts.enumerated()), id: \.element.id) { index, host in
                                    Button {
                                        owner.usbChosen = false
                                        owner.enteredPIN = ""
                                        owner.lastHostLabel = host.name
                                        owner.lastWifiHostLabel = host.name
                                        owner.networkManager.connect(to: host.endpoint)
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(Color.inkAccent)
                                                .accessibilityHidden(true)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(host.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                                if host.name == owner.lastWifiHostLabel {
                                                    Text("Last used").font(.caption).foregroundStyle(Color.inkSecondary)
                                                }
                                            }
                                            Spacer(minLength: 8)
                                            Image(systemName: "chevron.right").foregroundStyle(Color.inkSecondary).accessibilityHidden(true)
                                        }
                                        .padding(.horizontal, 14)
                                        .frame(minHeight: 56)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(owner.isConnectBusy)
                                    .accessibilityHint("Connects to this PC")
                                    if index < hosts.count - 1 {
                                        Rectangle().fill(Color.inkHairline).frame(height: 0.5)
                                    }
                                }
                            }
                            .background(Color.inkSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
        }
    }

    @MainActor private struct AddressEntry: View {
        let owner: ContentView
        var body: some View {
            DisclosureGroup(isExpanded: owner.$showIPEntry) {
                VStack(alignment: .leading, spacing: 8) {
                    RecentHosts(owner: owner)
                    owner.rowLayout {
                        TextField("192.168.1.20 or pc-name", text: owner.$hostIP)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(Color.inkRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.inkHairline, lineWidth: 0.5))
                            .accessibilityLabel("PC address")
                        Button("Connect") {
                            guard let host = owner.normalizedManualHost else { return }
                            owner.usbChosen = false
                            owner.enteredPIN = ""
                            owner.lastHostLabel = host
                            owner.lastWifiHostLabel = host
                            owner.recentRemoteHosts = RecentRemoteHostStore.record(host: host, remoteControl: owner.remoteControlMode)
                            owner.networkManager.connect(
                                to: host,
                                port: owner.remoteControlMode ? NetworkManager.remoteControlPort : 27015)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .tint(Color.inkAccent)
                        .disabled(owner.normalizedManualHost == nil || owner.isConnectBusy)
                    }
                    // Remote host service (SPEC-host-runtime): the PC's real screen, also at the
                    // sign-in screen, instead of the casting display.
                    Toggle("Control the whole PC", isOn: owner.$remoteControlMode)
                        .font(.subheadline)
                        .tint(Color.inkAccent)
                        .frame(minHeight: 44)
                        .accessibilityHint("Connects to the remote control service on port 27020")
                    if !owner.hostIP.isEmpty && owner.normalizedManualHost == nil {
                        Text("Enter an IP address or a PC name, like 100.64.0.10 or office-pc.")
                            .font(.caption)
                            .foregroundStyle(Color.inkWarning)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Connect by address").font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .tint(Color.inkSecondary)
        }
    }
}
