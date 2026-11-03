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
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture { } // Consume taps to block dismissal

            VStack(spacing: 24) {
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

                HStack(spacing: 20) {
                    ForEach(0..<4, id: \.self) { index in
                        ZStack {
                            Circle()
                                .stroke(index < pin.count ? Color.inkAccent : Color.inkHairline, lineWidth: 2)
                                .frame(width: 22, height: 22)
                            if index < pin.count {
                                Circle()
                                    .fill(Color.inkAccent)
                                    .frame(width: 12, height: 12)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: pin.count)
                    }
                }
                .modifier(ShakeEffect(animatableData: shakeAttempts))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(pin.count) of 4 digits entered")

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

                VStack(spacing: 8) {
                    Button(action: onSubmit) {
                        Text("Confirm PIN")
                            .font(.headline)
                            .foregroundStyle(pin.count == 4 ? Color.inkSurface : Color.inkSecondary)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(pin.count == 4 ? Color.inkText : Color.inkRaised,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(pin.count != 4)
                    .animation(.easeInOut(duration: 0.2), value: pin.count)

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

public struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
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
    @State private var showIPEntry = false
    @State private var copiedIP = false
    /// The current attempt is USB-C, so the status line never borrows the last Wi-Fi PC.
    @State private var usbChosen = false
    @State private var isWifiBrowsing = false
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The last Wi-Fi PC by name or typed address; Reconnect uses the matching saved target.
    @AppStorage("ScreenCasting.client.lastWifiHostLabel") private var lastWifiHostLabel = ""

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
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        updateDisplayOrientation(for: proxy.size)
                    }
                    .onChange(of: proxy.size) { _, size in
                        updateDisplayOrientation(for: size)
                    }
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            setWifiBrowsing(true)
            networkManager.setDesiredPipelineMode(
                gameModeEnabled ? .game : .office)
            networkManager.applicationDidBecomeActive()
        }
        .onChange(of: gameModeEnabled) { _, enabled in
            networkManager.setDesiredPipelineMode(
                enabled ? .game : .office)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            setWifiBrowsing(false)
        }
        .animation(.easeInOut(duration: 0.3), value: streamManager.isConnected)
        // PIN entry overlay: shown when awaiting PIN or after auth failure
        .overlay {
            if isHostIdentityPhase {
                HostIdentityConfirmationView(
                    identityCode: networkManager.hostIdentityCode ?? "Unavailable",
                    onConfirm: {
                        networkManager.confirmHostIdentity()
                    },
                    onCancel: {
                        enteredPIN = ""
                        networkManager.stop()
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(10)
            } else if isPINPhase {
                PINEntryView(
                    pin: $enteredPIN,
                    authFailed: isAuthFailed,
                    failureReason: authFailureReason,
                    onSubmit: {
                        networkManager.sendAuthPIN(enteredPIN)
                    },
                    onCancel: {
                        enteredPIN = ""
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
            if newState == .streaming { enteredPIN = "" }
            updateWifiBrowsing(for: newState)
        }
        .onChange(of: connectStatus.text) { _, text in
            if !streamManager.isConnected { UIAccessibility.post(notification: .announcement, argument: text) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                networkManager.applicationDidBecomeActive()
                updateDisplayOrientation(for: rootSurfaceSize)
            case .inactive:
                networkManager.applicationWillResignActive()
            case .background:
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

    private var normalizedManualHost: String {
        hostIP.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateDisplayOrientation(for size: CGSize) {
        rootSurfaceSize = size
        guard let orientation = DisplayOrientationResolver.resolve(
            width: size.width,
            height: size.height) else { return }
        networkManager.updateInterfaceOrientation(orientation)
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
            Color.inkCanvas
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
                gameModeEnabled: gameModeEnabled,
                remoteKeyboardActive: streamManager.isConnected && scenePhase == .active && !isSheetPresented && !showGestureGuide,
                onKeyboardInput: { command in
                    networkManager.sendKeyboardInput(command)
                },
                onTextCommit: { text in
                    networkManager.sendTextCommit(text)
                },
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
                },
                onDirectTouchContact: { command in
                    networkManager.sendDirectTouchContact(command)
                },
                onPointerInput: { command in
                    networkManager.sendPointerInput(command)
                },
                onOpenSettings: {
                    // The 3-finger tap opens the session panel; Settings is one tap inside it.
                    isSessionPanelOpen = true
                })
                .gestureHints { hint in showGestureToast(hint) }
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(true)
                .ignoresSafeArea(.keyboard)
                // This container has the committed drawable size. Publish
                // it as an orientation source so capabilities-first startup
                // cannot miss the initial portrait request.
                .onAppear {
                    updateDisplayOrientation(for: proxy.size)
                }
                .onChange(of: proxy.size) { _, size in
                    updateDisplayOrientation(for: size)
                }
        }
        .ignoresSafeArea(.container, edges: .all)
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
    private var foregroundLayer: some View {
        if streamManager.isConnected {
            ZStack {
                streamingHUD
                SessionPanelOverlay(
                    networkManager: networkManager,
                    hostLabel: SessionPanelSnapshot.sessionHost(current: lastHostLabel, lastWifi: lastWifiHostLabel,
                                                                usb: usbChosen),
                    isOpen: $isSessionPanelOpen,
                    onFiles: { isTransferPresented = true },
                    onSettings: { isSettingsPresented = true },
                    onGestures: { showGestureGuide = true })
                VStack {
                    Spacer()
                    if let toast = gestureToast {
                        GestureToastView(hint: toast.hint, text: toast.text)
                            .padding(.bottom, 28)
                            .transition(.opacity)
                    }
                }
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.2), value: gestureToast)
                if showGestureGuide {
                    GestureGuideCard(onDone: {
                        gestureGuideSeen = true
                        showGestureGuide = false
                    })
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: showGestureGuide)
        } else {
            disconnectedDashboard
        }
    }

    // MARK: - Disconnected Dashboard

    private var connectStatus: ConnectScreenStatus {
        .make(state: networkManager.connectionState,
              pcName: lastHostLabel.isEmpty ? lastWifiHostLabel : lastHostLabel,
              discoveredCount: discoveryManager.discoveredHosts.count,
              reconnectAttempt: networkManager.autoReconnectAttempt,
              usb: usbChosen,
              canRetry: networkManager.hasReconnectTarget)
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

    private var disconnectedDashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                rowLayout {
                    Label {
                        Text("ScreenCasting").font(.headline)
                    } icon: {
                        Image(systemName: "rectangle.on.rectangle").foregroundStyle(Color.inkAccent)
                    }
                    if !typeSize.isAccessibilitySize { Spacer() }
                    iPadAddressChip
                }
                VStack(alignment: .leading, spacing: 16) {
                    statusLine
                    // Hidden, not faded, while a connect or USB wait runs: a faded card read as broken.
                    if networkManager.hasReconnectTarget && !isConnectBusy { reconnectButton }
                    discoveredPCs
                    usbCard
                    ipEntry
                }
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
        }
        .foregroundStyle(Color.inkText)
        .accessibilityHidden(isPINPhase || isHostIdentityPhase)
        .transition(.opacity)
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

    private var statusLine: some View {
        let status = connectStatus
        let color: Color = status.tone == .warning ? .inkWarning : status.tone == .danger ? .inkDanger : .inkText
        return rowLayout {
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
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            // A USB wait is stopped from the USB-C card, so the status line does not repeat its Stop.
            if status.action != .none && !(status.action == .stop && networkManager.connectionState == .listening) {
                Button(status.action == .retry ? "Retry" : status.action == .restartUSB ? "Start again"
                       : status.action == .stop ? "Stop" : "Cancel") {
                    switch status.action {
                    case .retry:
                        usbChosen = false
                        enteredPIN = ""
                        networkManager.reconnectLastPC()
                    case .restartUSB:
                        startUSB()
                    case .cancel, .stop:
                        enteredPIN = ""
                        networkManager.stop()
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

    private var discoveredPCs: some View {
        let hosts = discoveryManager.discoveredHosts
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
                            usbChosen = false
                            enteredPIN = ""
                            lastHostLabel = host.name
                            lastWifiHostLabel = host.name
                            networkManager.connect(to: host.endpoint)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(Color.inkAccent)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    if host.name == lastWifiHostLabel {
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
                        .disabled(isConnectBusy)
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

    private var usbCard: some View {
        let listening = networkManager.connectionState == .listening
        return rowLayout {
            Image(systemName: "cable.connector").font(.title3).foregroundStyle(Color.inkAccent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("USB-C cable").font(.subheadline.weight(.semibold))
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

    private var ipEntry: some View {
        DisclosureGroup(isExpanded: $showIPEntry) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("192.168.1.20", text: $hostIP)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                        .textContentType(.URL)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(Color.inkRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.inkHairline, lineWidth: 0.5))
                        .accessibilityLabel("PC IP address")
                    Button("Connect") {
                        usbChosen = false
                        enteredPIN = ""
                        lastHostLabel = normalizedManualHost
                        lastWifiHostLabel = normalizedManualHost
                        networkManager.connect(to: normalizedManualHost)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(Color.inkAccent)
                    .disabled(!isValidManualIPv4 || isConnectBusy)
                }
                if !hostIP.isEmpty && !isValidManualIPv4 {
                    Text("Enter an address like 192.168.1.20.")
                        .font(.caption)
                        .foregroundStyle(Color.inkWarning)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Connect by IP address").font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .tint(Color.inkSecondary)
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
                                Circle().fill(Color(uiColor: SessionInk.secondary)).frame(width: 6, height: 6)
                                Text(String(format: "%.1f FPS", streamManager.currentFPS))
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                            }
                            Color(uiColor: SessionInk.hairline).frame(width: 1, height: 14)
                            // This is a local receive-stage measurement, not RTT/ping.
                            HStack(spacing: 6) {
                                Image(systemName: "gauge.with.needle.fill")
                                    .foregroundColor(Color(uiColor: SessionInk.secondary)).font(.caption)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(String(format: "%.1f ms", streamManager.frameReceiveMs))
                                    Text("Frame receive")
                                        .font(.caption2)
                                        .foregroundColor(Color(uiColor: SessionInk.secondary))
                                }
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                            }
                            Color(uiColor: SessionInk.hairline).frame(width: 1, height: 14)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(String(format: "%.1f Mbps", networkManager.hudTelemetry.videoRxMbps))
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                Text("Video RX")
                                    .font(.caption2)
                                    .foregroundColor(Color(uiColor: SessionInk.secondary))
                            }
                        }
                        .foregroundColor(Color(uiColor: SessionInk.text))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color(uiColor: SessionInk.surface).opacity(0.94),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color(uiColor: SessionInk.hairline), lineWidth: 0.5))
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
