import SwiftUI
import UIKit

/// Midnight ink: blue-black surfaces, one signal-blue accent for main actions, and one colour per meaning
/// (control on, problem, disconnect).
enum SessionInk {
    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    static let canvas = rgb(0x0B1020)
    static let surface = rgb(0x121A2E)
    static let raised = rgb(0x1C2640)
    static let hairline = rgb(0x2C3858)
    static let text = rgb(0xEEF2FF)
    static let secondary = rgb(0xA7B1CF)
    static let accent = rgb(0x7B93FF)
    static let onAccent = rgb(0x0B1020)
    static let positive = rgb(0x6EE7A8)
    static let warning = rgb(0xFFC870)
    static let danger = rgb(0xFF8F8F)
    static let dangerFill = rgb(0xF25C5C)
    static let onDanger = rgb(0x1F0A0A)

    /// WCAG 2 contrast ratio between two opaque colours.
    static func contrast(_ a: UIColor, _ b: UIColor) -> CGFloat {
        func luminance(_ c: UIColor) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &alpha)
            let linear = [r, g, b].map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

private extension Color {
    init(ink: UIColor) { self.init(uiColor: ink) }
}

struct SessionHeaderPresentation {
    enum ControlAction: Equatable { case ask, stop }

    let session: SessionPanelSnapshot
    let canRequestControl: Bool
    let permissionAsked: Bool

    var status: String {
        if session.reconnecting { return session.reconnectingText }
        let control = session.control == .on ? "You're in control" : "View only"
        return session.transport.map { "\($0) · \(control)" } ?? control
    }

    func pillStatus(isOpen: Bool) -> String? { isOpen ? nil : status }

    var controlAction: ControlAction? {
        guard !session.reconnecting, session.kind != .wholePCRemote else { return nil }
        if session.control == .on { return .stop }
        return session.control == .viewOnly && canRequestControl && !permissionAsked ? .ask : nil
    }
}

struct SessionInputPresentation {
    let control: ScreenPickerSnapshot.Control
    let canType: Bool
    let canPoint: Bool

    var showsKeyboard: Bool { control == .on && canType }
    var showsTouch: Bool { control == .on && canPoint }
}

enum SessionScreenPresentation {
    static func showsSwitchRow(kind: SessionPanelKind, cycle: ScreenCyclePresentation) -> Bool {
        (kind == .castingMirror || kind == .wholePCRemote) &&
            cycle.count > 1 && cycle.position != nil && cycle.enabled
    }
}

struct SessionConnectionPresentation {
    enum Action: Equatable {
        case change(ConnectionRoute, faster: Bool)
        case ask(ConnectionRoute)
        case waiting(String, showsProgress: Bool)
        case reconnect
        case refresh

        var title: String {
            switch self {
            case let .change(route, faster): "Switch to \(route.label)\(faster ? " (faster)" : "")"
            case let .ask(route): "Ask PC to switch to \(route.label)"
            case let .waiting(message, _): message
            case .reconnect: "Reconnect over Wi-Fi"
            case .refresh: "Refresh connection status"
            }
        }
    }

    let state: ConnectionSwitchState
    let streamingRoute: ConnectionRoute?
    let hasWifiEndpoint: Bool
    var screenSwitchInProgress = false

    var outcome: String? { state.operationOutcome }

    var activeRoute: ConnectionRoute? {
        guard let streamingRoute else { return nil }
        if state.actualRoute != .unknown { return state.actualRoute }
        return state.pending == nil && !state.offersReconnect ? streamingRoute : nil
    }

    var action: Action? {
        if state.pending != nil { return .waiting(state.message, showsProgress: true) }
        if state.offersReconnect { return hasWifiEndpoint ? .reconnect : nil }
        if state.needsRefresh { return .refresh }
        if state.phase == .permissionRequired { return .waiting(state.message, showsProgress: false) }
        guard state.enabled, let activeRoute, let snapshot = state.snapshot,
               activeRoute == snapshot.current, state.routeSelectionReady else { return nil }
        let target: ConnectionRoute = activeRoute == .usb ? .wifi : .usb
        let availability = target == .usb ? snapshot.usb : snapshot.wifi
        guard target != .wifi || hasWifiEndpoint,
              availability == .available || target == .usb && availability == .detectedUnverified else { return nil }
        if screenSwitchInProgress { return .waiting("Wait for the screen switch to finish.", showsProgress: false) }
        if !snapshot.allowed { return .ask(target) }
        return .change(target, faster: target == .usb && availability == .available && snapshot.recommended == .usb)
    }
}

/// One session shell: current Screen, route and control, then the same ordered panel sections.
/// Touches on the panel stay on the iPad.
@MainActor struct SessionPanelOverlay: View {
    @EnvironmentObject private var inputSession: IPadInputSession
    @ObservedObject var networkManager: NetworkManager
    let hostLabel: String
    @Binding var isOpen: Bool
    @ObservedObject var remoteInput: RemoteSessionInputState
    let tailnetTarget: Bool
    let performance: SessionPerformanceReadout?
    let onPillHeightChange: (CGFloat) -> Void
    let onFiles: () -> Void
    let onSettings: () -> Void
    let onGestures: () -> Void

    @State private var moreInputExpanded = false
    @State private var inputBarVisible = false
    @State private var rememberedPhysical = ConfirmedPhysicalScreen()
    @State private var requestedScreen: UInt64?
    @State private var pillHeight: CGFloat = 44
    @State private var awaitingSwitchAnnouncement = false
    @AccessibilityFocusState private var switchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var switchingTo: UInt64?
    @State private var failedSelection = false
    @State private var controlPermissionAsked = false
    @State private var lastInteraction = Date()
    @State private var confirmRestart = false
    @State private var dragOffset: CGFloat = 0
    @State private var disconnectArming = DisconnectArming()
    @State private var disconnectTick = 0
    @AppStorage("ScreenCasting.client.screenPickerOffset") private var storedOffset: Double = 0
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    #if targetEnvironment(simulator)
    var voiceOverForTesting: Bool? = nil
    #endif

    private var usesVoiceOver: Bool {
        #if targetEnvironment(simulator)
        return voiceOverForTesting ?? voiceOver
        #else
        return voiceOver
        #endif
    }

    private var monitorControlEnabled: Bool {
        networkManager.remoteMonitorState.isSourceRecovery ? remoteInput.monitorControlAvailable : remoteInput.pointerEnabled
    }
    private var picker: ScreenPickerSnapshot {
        if networkManager.isRemoteControlSession {
            return .make(remote: networkManager.remoteMonitorState, inputReady: networkManager.remoteInputReady,
                         controlEnabled: monitorControlEnabled)
        }
        if networkManager.captureTargetState.enabled {
            return .make(captureTargets: networkManager.captureTargetState, state: networkManager.mirrorControlState,
                         permissionAsked: networkManager.screenSwitchPermissionPending,
                         legacyInputAvailable: networkManager.permitsLegacyVirtualInput)
        }
        return .make(catalogue: networkManager.mirrorMonitorCatalogue, state: networkManager.mirrorControlState,
              switchingTo: switchingTo, switchPending: networkManager.mirrorMonitorSwitchPending,
              pickerSupported: networkManager.mirrorScreenPickerSupported, permissionAsked: networkManager.screenSwitchPermissionPending,
              legacyInputAvailable: networkManager.permitsLegacyVirtualInput)
    }

    private var kind: SessionPanelKind {
        .make(remote: networkManager.isRemoteControlSession, targets: networkManager.captureTargetState,
              legacy: networkManager.mirrorControlState, catalogue: networkManager.mirrorMonitorCatalogue)
    }

    private var session: SessionPanelSnapshot {
        // Opening the panel pauses surface input. Panel input still uses the shared session's capabilities.
        let canUseRemoteInput = networkManager.isRemoteControlSession && (inputSession.canPoint || inputSession.canType)
        let control: ScreenPickerSnapshot.Control = canUseRemoteInput
            ? .on : picker.control
        return .make(hostLabel: hostLabel, transport: networkManager.transferSnapshot.transport,
                     connection: networkManager.connectionState, control: control, mirrorLabel: picker.currentLabel,
                     kind: kind, tailnet: tailnetTarget)
    }

    private var headerPresentation: SessionHeaderPresentation {
        let mirror = networkManager.mirrorControlState
        let canRequest = scenePhase == .active && !networkManager.captureInputBlocked && (mirror?.epoch ?? 0) > 0 &&
            (mirror?.source ?? 0) > 0 && (mirror?.mode == .viewOnly || mirror?.mode == .awaitingPresentation)
        return SessionHeaderPresentation(session: session, canRequestControl: canRequest,
                                         permissionAsked: controlPermissionAsked)
    }

    private var inputPresentation: SessionInputPresentation {
        SessionInputPresentation(control: session.control,
            canType: inputSession.canType && !networkManager.captureInputBlocked,
            canPoint: inputSession.canPoint && !networkManager.captureInputBlocked)
    }

    private var connectionPresentation: SessionConnectionPresentation {
        let route: ConnectionRoute? = switch session.transport ?? "" {
        case "USB": .usb
        case "Wi-Fi": .wifi
        default: nil
        }
        return SessionConnectionPresentation(state: networkManager.connectionSwitchState,
            streamingRoute: session.reconnecting ? nil : route, hasWifiEndpoint: networkManager.hasReconnectTarget,
            screenSwitchInProgress: picker.isSwitching)
    }

    private var cycle: ScreenCyclePresentation {
        let p = picker
        let reason: String?
        if let screenSwitchBlockedReason { reason = screenSwitchBlockedReason }
        else if p.phase == .loading { reason = "Loading screens..." }
        else if networkManager.isRemoteControlSession && p.control != .on {
            reason = "Turn Control on to choose a screen."
        } else if p.phase == .locked {
            if networkManager.captureTargetState.enabled && networkManager.captureTargetState.catalogue?.state != 1 {
                reason = screenWords(networkManager.captureTargetState.statusMessage ?? "Screens are unavailable. Refresh screens.")
            } else if networkManager.isRemoteControlSession {
                reason = screenWords(networkManager.remoteMonitorState.statusMessage ?? "Screens are unavailable.")
            } else { reason = "Screen switching is off on the PC." }
        } else { reason = nil }
        return p.cycle(kind: kind, disabledReason: reason)
    }

    private var modeChoices: CaptureModePresentation {
        .make(targets: networkManager.captureTargetState, kind: kind, lastPhysicalId: rememberedPhysical.id,
              switchBlockedReason: screenSwitchBlockedReason)
    }

    private var routeSwitchInProgress: Bool { networkManager.connectionSwitchState.pending != nil }

    private var screenSwitchBlockedReason: String? {
        if routeSwitchInProgress { return "Wait for the connection switch to finish." }
        if networkManager.captureTargetState.enabled && networkManager.isDisplayConfigurationPending {
            return "Wait for the display change to finish."
        }
        return nil
    }

    var body: some View {
        OverlaySurface(owner: self)
        .environment(\.colorScheme, .dark)
        .tint(Color(ink: SessionInk.accent))
        .onPreferenceChange(SessionPillHeightKey.self) { height in
            pillHeight = height
            onPillHeightChange(height)
        }
        .onChange(of: isOpen) { _, open in
            lastInteraction = Date()
            disconnectArming.reset()
            if open {
                failedSelection = false
                refreshScreens()
            }
        }
        .onAppear { rememberedPhysical.observe(networkManager.captureTargetState) }
        .onChange(of: networkManager.captureTargetState) { _, targets in rememberedPhysical.observe(targets) }
        .onChange(of: picker.isSwitching) { wasSwitching, switching in
            if wasSwitching && !switching { finishSwitch() }
        }
        .onChange(of: networkManager.captureTargetState.session) { _, _ in
            switchingTo=nil;controlPermissionAsked=false
            failedSelection=false
            requestedScreen=nil;awaitingSwitchAnnouncement=false
        }
        .onChange(of: picker.control) { _, control in
            if control == .on { controlPermissionAsked = false }
        }
        .onChange(of: networkManager.mirrorMonitorCatalogue) { _, catalogue in settle(catalogue) }
        .onChange(of: networkManager.mirrorMonitorSwitchPending) { _, pending in if !pending { settle(networkManager.mirrorMonitorCatalogue) } }
    }

    // MARK: Pill

    private func pill(maxX: CGFloat) -> SessionPill {
        SessionPill(owner: self, maxX: maxX)
    }

    private var pillTitle: PillTitle {
        PillTitle(owner: self)
    }

    /// The idle pill: a slim bar at the top edge, green while touches drive the PC. Tapping it opens the panel.
    private func handle(maxX: CGFloat) -> SessionHandle {
        SessionHandle(owner: self, maxX: maxX)
    }

    private func moveAlongTop(maxX: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { dragOffset = $0.translation.width; lastInteraction = Date() }
            .onEnded { value in
                storedOffset = Double(clamp(CGFloat(storedOffset) + value.translation.width, width: maxX))
                dragOffset = 0
            }
    }

    private func pillLabel(_ s: SessionPanelSnapshot) -> String {
        if isOpen { return s.title }
        return s.reconnecting ? s.reconnectingText
            : "\(s.title)\(s.transport.map { ", \($0)" } ?? "")\(". " + controlText(s.control))"
    }

    // MARK: Panel

    private func panel(width: CGFloat, maxHeight: CGFloat) -> PanelContent {
        PanelContent(owner: self, width: width, maxHeight: maxHeight)
    }

    private var panelSections: PanelSections {
        PanelSections(owner: self)
    }

    private var panelHeader: PanelHeader {
        PanelHeader(owner: self)
    }

    private var routeAndControl: RouteAndControl {
        RouteAndControl(owner: self)
    }

    private func separator() -> some View {
        Rectangle().fill(Color(ink: SessionInk.hairline)).frame(height: 0.5).accessibilityHidden(true)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.footnote).foregroundStyle(Color(ink: SessionInk.secondary))
            .accessibilityAddTraits(.isHeader)
    }

    private var screens: ScreenSection {
        ScreenSection(owner: self)
    }

    private var switchScreenButton: ScreenSwitchButton {
        ScreenSwitchButton(owner: self)
    }

    private var castingModes: ModeChoices {
        ModeChoices(owner: self)
    }

    private var modeButtons: ModeButtons {
        ModeButtons(owner: self)
    }

    private func modeButton(_ title: String, choice: CaptureModeChoice, identifier: String) -> ModeButton {
        ModeButton(owner: self, title: title, choice: choice, identifier: identifier)
    }

    private var screenHasFailure: Bool {
        failedSelection || networkManager.remoteMonitorState.issue == .failed ||
            networkManager.remoteMonitorState.issue == .denied || networkManager.captureTargetState.issue == .failed ||
            networkManager.captureTargetState.issue == .timedOut || networkManager.captureTargetState.unknownOutcome
    }

    private var screenNotice: ScreenNotice? {
        let p = picker
        let targets = networkManager.captureTargetState
        let remote = networkManager.isRemoteControlSession
        let remoteCatalogueUnavailable = remote &&
            (networkManager.remoteMonitorState.catalogue?.state == 0 || networkManager.remoteMonitorState.issue == .unavailable)
        let canRefresh = remote ? networkManager.remoteMonitorState.enabled
            : targets.enabled || networkManager.mirrorScreenPickerSupported
        if p.isSwitching { return ScreenNotice("Switching…", showsProgress: true) }
        if !remote, let notice = ScreenNotice.typedCatalogueNotice(for: targets) { return notice }
        if let screenSwitchBlockedReason { return ScreenNotice(screenSwitchBlockedReason) }
        if p.canAskPermission {
            let noAnswer = networkManager.screenSwitchPermissionNotice
            return ScreenNotice(noAnswer ?? "The PC must allow screen changes.", action: .askPermission,
                                isFailure: noAnswer != nil)
        }
        if remoteCatalogueUnavailable {
            return ScreenNotice(canRefresh ? "Can't read the PC's screens." : "Can't read the PC's screens. Stop and restart the session.",
                action: canRefresh ? .refresh : nil)
        }
        if !remote && networkManager.screenSwitchPermissionPending { return ScreenNotice(CastingPermissionCopy.requestSent) }
        if targets.unknownOutcome && modeChoices.extend.selected && modeChoices.extend.enabled {
            return ScreenNotice("Couldn't switch screens.", action: .recoverExtend, isFailure: true)
        }
        if (kind == .castingUnknown || networkManager.remoteMonitorState.isSourceRecovery) && cycle.enabled &&
            cycle.position == nil {
            return ScreenNotice("Couldn't switch screens.", action: .recover, isFailure: true)
        }
        if screenHasFailure && (canRefresh || failedSelection) {
            return ScreenNotice("Couldn't switch screens.", action: canRefresh ? .retry : nil, isFailure: true)
        }
        if remote && networkManager.remoteMonitorState.needsCatalogueRefresh {
            return ScreenNotice("Can't read the PC's screens.", action: canRefresh ? .refresh : nil)
        }
        if remote {
            return networkManager.remoteMonitorState.statusMessage.map { ScreenNotice(screenWords($0)) }
        }
        if let message = targets.statusMessage { return ScreenNotice(screenWords(message)) }
        if p.phase == .loading {
            return ScreenNotice(canRefresh ? "Loading screens…" : "This PC can't list its screens. Update ScreenCasting on the PC.")
        }
        if let explanation = modeChoices.explanation { return ScreenNotice(explanation) }
        if p.phase == .locked { return ScreenNotice(p.selectionDisabledReason ?? "Screen switching is off on the PC.") }
        return nil
    }

    private func refreshScreens() {
        if networkManager.isRemoteControlSession { networkManager.refreshRemoteScreens() }
        else if !networkManager.captureTargetState.requiresRestart { networkManager.refreshMirrorScreens() }
    }

    private func changeCastingControl(_ action: SessionHeaderPresentation.ControlAction) {
        lastInteraction = Date()
        switch action {
        case .stop:
            remoteInput.suspend(reason: 1)
            networkManager.releaseMirrorControl()
            controlPermissionAsked = false
        case .ask:
            networkManager.requestMirrorControl()
            controlPermissionAsked = true
        }
    }

    private func screenWords(_ message: String) -> String {
        message.replacingOccurrences(of: "display source", with: "screen")
            .replacingOccurrences(of: "Sources", with: "Screens")
            .replacingOccurrences(of: "sources", with: "screens")
            .replacingOccurrences(of: "Source", with: "Screen")
            .replacingOccurrences(of: "source", with: "screen")
    }

    private func cycleScreen() {
        guard cycle.enabled, let targetId = cycle.nextTargetId else { return }
        requestScreen(targetId)
    }

    private func requestScreen(_ targetId: UInt64) {
        guard screenSwitchBlockedReason == nil else { return }
        let p = picker
        if networkManager.isRemoteControlSession {
            guard p.tiles.contains(where: { $0.id == targetId && $0.canSelect }), monitorControlEnabled,
                  let catalogue = networkManager.remoteMonitorState.catalogue else { return }
            networkManager.requestRemoteMonitor(targetId, catalogue: catalogue)
        } else if networkManager.captureTargetState.enabled {
            guard p.tiles.contains(where: { $0.id == targetId && $0.canSelect }),
                  let catalogue = networkManager.captureTargetState.catalogue else { return }
            networkManager.requestCaptureTarget(targetId, catalogue: catalogue)
        } else {
            guard p.tiles.contains(where: { $0.id == targetId && $0.canSelect }),
                  let catalogue = networkManager.mirrorMonitorCatalogue else { return }
            switchingTo = targetId
            networkManager.requestMirrorMonitor(targetId, catalogue: catalogue)
        }
        failedSelection = false; lastInteraction = Date(); requestedScreen = targetId
        switchFocused = false; awaitingSwitchAnnouncement = true
    }

    private func finishSwitch() {
        guard awaitingSwitchAnnouncement else { return }
        awaitingSwitchAnnouncement = false
        // Typed source catalogue IDs are scoped to each revision. The terminal
        // result already correlated the request and confirmed its presentation.
        let legacyIDMismatch = !networkManager.captureTargetState.enabled &&
            picker.tiles.first(where: { $0.status == .showing })?.id != requestedScreen
        let failed = failedSelection || networkManager.remoteMonitorState.issue != nil ||
            networkManager.captureTargetState.issue != nil || networkManager.captureTargetState.unknownOutcome ||
            legacyIDMismatch
        let message = failed ? "Couldn't switch screens."
            : "Showing \(cycle.currentLabel)."
        requestedScreen = nil
        UIAccessibility.post(notification: .announcement, argument: message)
        switchFocused = true
    }

    private var tools: ToolsSection {
        ToolsSection(owner: self)
    }

    private var touchSection: TouchSection {
        TouchSection(owner: self)
    }

    private var moreInput: MoreInputSection {
        MoreInputSection(owner: self)
    }

    private var connectionPicker: ConnectionSection {
        ConnectionSection(owner: self)
    }

    /// Remote control service only: keys the iPad cannot send, and power.
    private var remoteActions: RemoteActionsSection {
        RemoteActionsSection(owner: self)
    }

    private func actionButton(_ title: String, icon: String, compact: Bool = false, hint: String? = nil,
                              action: @escaping () -> Void) -> PanelActionButton {
        PanelActionButton(title: title, icon: icon, compact: compact, hint: hint, action: action)
    }

    private func footer(_ s: SessionPanelSnapshot) -> PanelFooter {
        PanelFooter(owner: self, s: s)
    }

    // MARK: Behavior

    private func open() { isOpen = true }

    private func close() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { isOpen = false }
        lastInteraction = Date()
    }

    /// A switch ends when the Host's list names the target as showing, or the pending state clears without it.
    private func settle(_ catalogue: MirrorMonitorCatalogue?) {
        guard let target = switchingTo, let catalogue else { return }
        if catalogue.selected == target {
            switchingTo = nil; failedSelection = false
        } else if !networkManager.mirrorMonitorSwitchPending {
            failedSelection = true
            switchingTo = nil
        }
    }

    private func icon(_ icon: SessionPanelSnapshot.Icon) -> String {
        switch icon {
        case .extended: "rectangle.on.rectangle"
        case .monitor: "display"
        case .laptop: "laptopcomputer"
        }
    }

    private func controlText(_ control: ScreenPickerSnapshot.Control) -> String {
        switch control {
        case .on: "Remote control is on"
        case .viewOnly: "View only"
        case .unavailable: "Control unavailable"
        }
    }

    private func clampedOffset(width: CGFloat) -> CGFloat { clamp(CGFloat(storedOffset) + dragOffset, width: width) }
    private func clamp(_ x: CGFloat, width: CGFloat) -> CGFloat {
        let limit = max(0, width / 2 - 240)
        return min(max(x, -limit), limit)
    }

    // Concrete boundaries stop Swift metadata from expanding the entire panel at first open.
    // The owner retains all state/focus locations; child views do not re-own that state.
    @MainActor private struct OverlaySurface: View {
        let owner: SessionPanelOverlay
        var body: some View {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    if owner.isOpen {
                        // Tapping outside closes the panel; while it is open nothing reaches the PC.
                        Color(ink: SessionInk.canvas).opacity(0.001).contentShape(Rectangle()).onTapGesture { owner.close() }
                    }
                    VStack(spacing: 10) {
                        // After a few idle seconds the pill shrinks to a slim handle so the top of the PC stays visible.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            // VoiceOver keeps the full pill: swapping views every idle cycle would drop its focus.
                            let mode = SessionPillPresentation.make(isOpen: owner.isOpen || owner.usesVoiceOver,
                                                                    idleFor: context.date.timeIntervalSince(owner.lastInteraction),
                                                                    reconnecting: owner.session.reconnecting)
                            ZStack(alignment: .top) {
                                if mode == .full || owner.networkManager.clipboardMissedCopyNotice != nil {
                                    owner.pill(maxX: proxy.size.width).transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                                } else {
                                    owner.handle(maxX: proxy.size.width).transition(.opacity)
                                }
                            }
                            .animation(owner.reduceMotion ? nil : .easeOut(duration: 0.3), value: mode)
                        }
                        .background(GeometryReader { pillProxy in
                            Color.clear.preference(key: SessionPillHeightKey.self, value: pillProxy.size.height)
                        })
                        if owner.isOpen {
                            // Sized to its content; only very large text or many screens reach the cap and scroll.
                            owner.panel(width: min(420, proxy.size.width - 24),
                                  maxHeight: max(120, proxy.size.height - owner.pillHeight - 34 - (owner.inputSession.dragState == .latched ? 80 : 0)))
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .offset(x: owner.clampedOffset(width: proxy.size.width))
                    .padding(.top, 12)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .overlay(alignment: .bottom) {
                    VStack(spacing: 8) {
                        SessionDraggingChip()
                        if owner.inputBarVisible && !owner.isOpen {
                            SessionInputBar(onClose: { owner.inputBarVisible = false })
                                .frame(maxHeight: max(44, proxy.size.height * 0.45))
                        }
                    }
                    .frame(maxWidth: min(620, max(0, proxy.size.width - 24)))
                    .padding(.bottom, max(12, proxy.safeAreaInsets.bottom))
                }
            }
        }
    }

    @MainActor private struct PanelContent: View {
        let owner: SessionPanelOverlay
        let width: CGFloat
        let maxHeight: CGFloat
        var body: some View {
            Group {
                if owner.typeSize.isAccessibilitySize {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            owner.panelHeader
                            owner.panelSections
                            owner.footer(owner.session)
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        owner.panelHeader
                        ViewThatFits(in: .vertical) {
                            owner.panelSections.fixedSize(horizontal: false, vertical: true)
                            ScrollView { owner.panelSections }.scrollBounceBehavior(.basedOnSize)
                        }
                        owner.footer(owner.session)
                    }
                }
            }
            .foregroundStyle(Color(ink: SessionInk.text))
            .padding(14)
            .frame(width: width)
            .background(Color(ink: SessionInk.surface).opacity(0.96), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color(ink: SessionInk.hairline), lineWidth: 0.5))
            .shadow(color: Color(ink: SessionInk.canvas).opacity(0.45), radius: 24, y: 12)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .onTapGesture { owner.lastInteraction = Date() }
            .frame(maxHeight: maxHeight, alignment: .top)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { owner.close() }
        }
    }

    @MainActor private struct PanelSections: View {
        let owner: SessionPanelOverlay
        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                if let notice = owner.networkManager.clipboardMissedCopyNotice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(Color(ink: SessionInk.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if ScreenPickerSnapshot.shouldShowPicker(remote: owner.networkManager.isRemoteControlSession,
                    mirror: !owner.networkManager.isRemoteControlSession, acceptedFeatures: owner.networkManager.remoteMonitorState.enabled ? 7 : 0,
                    typedSources: owner.networkManager.captureTargetState.enabled) { owner.screens }
                if !owner.networkManager.isRemoteControlSession { owner.connectionPicker }
                owner.tools
                owner.touchSection
                if owner.networkManager.isRemoteControlSession { owner.remoteActions }
            }
        }
    }

    @MainActor private struct PanelHeader: View {
        let owner: SessionPanelOverlay
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(owner.session.hostLabel).font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    if let route = owner.session.transport {
                        Image(systemName: route == "USB" ? "cable.connector" : "wifi")
                            .font(.subheadline)
                            .foregroundStyle(Color(ink: SessionInk.secondary))
                            .accessibilityHidden(true)
                    }
                }
                owner.routeAndControl
                if let performance = owner.performance, performance.showsInPanel { performance }
                if owner.headerPresentation.controlAction == .ask {
                    CastingControlSection(owner: owner, action: .ask)
                } else if owner.controlPermissionAsked && owner.session.control != .on && !owner.session.reconnecting {
                    Text(CastingPermissionCopy.requestSent).font(.footnote)
                        .foregroundStyle(Color(ink: SessionInk.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @MainActor private struct ScreenSection: View {
        let owner: SessionPanelOverlay
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                owner.sectionTitle("Screen")
                owner.castingModes
                if SessionScreenPresentation.showsSwitchRow(kind: owner.kind, cycle: owner.cycle) {
                    if !owner.networkManager.isRemoteControlSession { owner.separator() }
                    owner.switchScreenButton
                }
                if let notice = owner.screenNotice { ScreenStatus(owner: owner, notice: notice) }
            }
        }
    }

    @MainActor private struct ScreenSwitchButton: View {
        let owner: SessionPanelOverlay
        var body: some View {
            Button { owner.cycleScreen() } label: {
                Group {
                    if owner.typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) { title; screen }
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { title; Spacer(minLength: 8); screen.fixedSize() }
                            VStack(alignment: .leading, spacing: 8) { title; screen }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch screen")
            .accessibilityValue(owner.cycle.accessibilityValue)
            .accessibilityHint(owner.cycle.hint)
            .accessibilityIdentifier("session.switch-screen")
            .accessibilityFocused(owner.$switchFocused)
        }

        private var title: some View { Text("Showing").font(.subheadline.weight(.semibold)) }
        private var screen: some View {
            HStack(spacing: 8) {
                Text(owner.cycle.currentLabel).fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.right").accessibilityHidden(true)
            }
            .font(.footnote).foregroundStyle(Color(ink: SessionInk.secondary))
        }
    }

    @MainActor private struct ModeChoices: View {
        let owner: SessionPanelOverlay
        @ViewBuilder var body: some View {
            if !owner.networkManager.isRemoteControlSession {
                owner.modeButtons
            }
        }
    }

    @MainActor private struct ModeButtons: View {
        let owner: SessionPanelOverlay
        var body: some View {
            SessionSegmentLayout {
                owner.modeButton("Extend", choice: owner.modeChoices.extend, identifier: "session.mode.extend")
                owner.modeButton("Mirror", choice: owner.modeChoices.mirror, identifier: "session.mode.mirror")
            }
        }
    }

    @MainActor private struct ModeButton: View {
        let owner: SessionPanelOverlay
        let title: String
        let choice: CaptureModeChoice
        let identifier: String
        var body: some View {
            Button {
                guard choice.enabled, let id = choice.targetId else { return }
                owner.requestScreen(id)
            } label: {
                SessionSegmentLabel(title: title, selected: choice.selected, enabled: choice.enabled)
            }
            .buttonStyle(.plain)
            .disabled(!choice.enabled)
            .accessibilityLabel(title)
            .accessibilityValue(choice.selected ? "Selected" : "Not selected")
            .accessibilityAddTraits(choice.selected ? .isSelected : [])
            .accessibilityHint(owner.modeChoices.explanation ?? "")
            .accessibilityIdentifier(identifier)
        }
    }

    struct ScreenNotice {
        enum Action: Equatable {
            case askPermission, refresh, retry, recover, recoverExtend

            var title: String {
                switch self {
                case .askPermission: "Ask PC to allow"
                case .refresh: "Refresh"
                case .retry, .recover, .recoverExtend: "Try again"
                }
            }
        }

        let message: String
        let action: Action?
        let showsProgress: Bool
        let isFailure: Bool

        static func typedCatalogueNotice(for targets: CaptureTargetState) -> Self? {
            if targets.requiresRestart {
                return Self("Screens are unavailable. Stop and restart the session.", isFailure: true)
            }
            if targets.listUnavailable {
                return Self("Can't read the PC's screens.", action: .refresh, isFailure: true)
            }
            return nil
        }

        init(_ message: String, action: Action? = nil, showsProgress: Bool = false, isFailure: Bool = false) {
            self.message = message
            self.action = action
            self.showsProgress = showsProgress
            self.isFailure = isFailure
        }
    }

    @MainActor private struct ScreenStatus: View {
        let owner: SessionPanelOverlay
        let notice: ScreenNotice

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if notice.showsProgress {
                        ProgressView().tint(Color(ink: SessionInk.warning)).accessibilityHidden(true)
                    }
                    Text(notice.message).font(.footnote).fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(Color(ink: notice.isFailure ? SessionInk.danger : SessionInk.warning))
                }
                if let action = notice.action {
                    Button {
                        switch action {
                        case .askPermission:
                            owner.lastInteraction = Date()
                            owner.networkManager.requestMirrorSwitchPermission()
                        case .refresh, .retry:
                            owner.failedSelection = false
                            owner.refreshScreens()
                        case .recover:
                            owner.cycleScreen()
                        case .recoverExtend:
                            let choice = owner.modeChoices.extend
                            if choice.enabled, let id = choice.targetId { owner.requestScreen(id) }
                        }
                    } label: {
                        Text(action.title).font(.footnote).frame(minWidth: 44, minHeight: 44)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint(action == .askPermission ? "Shows an approval pop-up on the PC" : "")
                }
            }
        }
    }

    @MainActor private struct CastingControlSection: View {
        let owner: SessionPanelOverlay
        let action: SessionHeaderPresentation.ControlAction

        var body: some View {
            if action == .ask {
                Button { owner.changeCastingControl(.ask) } label: {
                    Text("Ask for control").font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(Color(ink: SessionInk.onAccent))
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Ask control")
            } else {
                Button { owner.changeCastingControl(.stop) } label: {
                    Text("Stop control").font(.footnote).fixedSize(horizontal: false, vertical: true)
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        .foregroundStyle(Color(ink: SessionInk.accent))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @MainActor private struct ToolsSection: View {
        let owner: SessionPanelOverlay
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                owner.sectionTitle("Tools")
                SessionActionLayout(accessibility: owner.typeSize.isAccessibilitySize) {
                    if owner.inputPresentation.showsKeyboard {
                        owner.actionButton("Keyboard", icon: "keyboard", compact: true) {
                            guard owner.inputSession.canType, !owner.networkManager.captureInputBlocked else { return }
                            owner.close()
                            owner.inputBarVisible = true
                            owner.inputSession.showSoftwareKeyboard()
                        }
                    }
                    owner.actionButton("Files", icon: "arrow.left.arrow.right", compact: true) { owner.close(); owner.onFiles() }
                    owner.actionButton("Settings", icon: "gearshape", compact: true) { owner.close(); owner.onSettings() }
                }
            }
        }
    }

    @MainActor private struct TouchSection: View {
        let owner: SessionPanelOverlay
        var body: some View {
            if owner.inputPresentation.showsTouch {
                VStack(alignment: .leading, spacing: 8) {
                    owner.sectionTitle("Touch")
                    RemoteMouseControls()
                    owner.separator()
                    owner.moreInput
                }
            }
        }
    }

    @MainActor private struct MoreInputSection: View {
        let owner: SessionPanelOverlay
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Button { owner.moreInputExpanded.toggle() } label: {
                    HStack(spacing: 8) {
                        Text("More input").font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down").rotationEffect(.degrees(owner.moreInputExpanded ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(owner.moreInputExpanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("session.more-input")
                if owner.moreInputExpanded {
                    Toggle("Scroll inertia", isOn: Binding(get: { owner.inputSession.scrollInertiaEnabled },
                                                           set: { owner.inputSession.setScrollInertia($0) }))
                        .font(.subheadline).frame(minHeight: 44).disabled(!owner.inputSession.canPoint)
                    Toggle("Reverse scroll direction", isOn: Binding(get: { owner.inputSession.reverseScrollEnabled },
                                                                      set: { owner.inputSession.setReverseScroll($0) }))
                        .font(.subheadline).frame(minHeight: 44).disabled(!owner.inputSession.canPoint)
                    Text("Inertia affects finger wheel scrolling. Reverse affects wheel direction. Windows controls native one-finger touch pan.")
                        .font(.footnote).foregroundStyle(Color(ink: SessionInk.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                    owner.actionButton("Gesture help", icon: "hand.draw", compact: true,
                                       hint: "Shows the touch and Pencil gestures") { owner.close(); owner.onGestures() }
                    AccessiblePointerControls()
                    RemoteMouseExtras()
                }
            }
        }
    }

    @MainActor private struct ConnectionSection: View {
        let owner: SessionPanelOverlay

        var body: some View {
            let presentation = owner.connectionPresentation
            if presentation.activeRoute != nil || presentation.outcome != nil || presentation.action != nil {
                VStack(alignment: .leading, spacing: 8) {
                    owner.sectionTitle("Connection")
                    if let route = presentation.activeRoute { activeRow(route) }
                    if let outcome = presentation.outcome {
                        Text(outcome).font(.footnote).fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(Color(ink: SessionInk.secondary))
                    }
                    if let action = presentation.action {
                        if presentation.activeRoute != nil { owner.separator() }
                        nextAction(action)
                    }
                }
            }
        }

        private func activeRow(_ route: ConnectionRoute) -> some View {
            let title = Label(route.label, systemImage: route == .usb ? "cable.connector" : "wifi")
                .font(.subheadline.weight(.semibold))
            let status = Text("Connected").font(.footnote).foregroundStyle(Color(ink: SessionInk.secondary))
            return Group {
                if owner.typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) { title; status }
                } else {
                    HStack(spacing: 8) { title; Spacer(minLength: 8); status }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(route.label + ", Connected")
            .accessibilityAddTraits(.isSelected)
        }

        @ViewBuilder private func nextAction(_ action: SessionConnectionPresentation.Action) -> some View {
            if case let .waiting(message, showsProgress) = action {
                HStack(spacing: 8) {
                    if showsProgress { ProgressView().tint(Color(ink: SessionInk.accent)) }
                    Text(message).font(.footnote).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color(ink: SessionInk.secondary))
                .accessibilityElement(children: .combine)
            } else {
                Button {
                    switch action {
                    case let .change(route, _):
                        owner.lastInteraction = Date()
                        owner.networkManager.requestConnectionRoute(route) { owner.remoteInput.suspend(reason: 1) }
                    case let .ask(route):
                        owner.networkManager.requestConnectionRoute(route, askPC: true)
                    case .reconnect:
                        owner.networkManager.reconnectConnectionOverWifi()
                    case .refresh:
                        owner.networkManager.refreshConnectionStatus()
                    case .waiting:
                        break
                    }
                } label: {
                    Text(action.title).font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityHint(switchHint(action))
            }
        }

        private func switchHint(_ action: SessionConnectionPresentation.Action) -> String {
            if case let .change(route, _) = action { return "Switch to " + route.label }
            return ""
        }
    }

    @MainActor private struct RemoteClipboardSection: View {
        @ObservedObject var manager: NetworkManager
        @ObservedObject var pasteboard: RemoteClipboardPasteboard

        var body: some View {
            if pasteboard.supported {
                Toggle("Sync clipboard with PC", isOn: Binding(
                    get: { manager.remoteClipboardEnabled },
                    set: { manager.setRemoteClipboardEnabled($0) }))
                    .font(.subheadline)
                    .tint(Color(ink: SessionInk.accent))
                    .frame(minHeight: 44)
                if manager.remoteClipboardEnabled {
                    if pasteboard.reason == .hostDisallowed {
                        Text("Clipboard sync is off on the PC.")
                            .font(.footnote)
                            .foregroundStyle(Color(ink: SessionInk.secondary))
                    }
                    if pasteboard.canSend {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Send clipboard to PC").font(.subheadline)
                            RemoteClipboardPasteButton(pasteboard: pasteboard)
                                .frame(height: 44)
                        }
                    }
                    if let notice = pasteboard.transferNotice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(Color(ink: SessionInk.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @MainActor private struct RemoteActionsSection: View {
        let owner: SessionPanelOverlay
        var body: some View {
            RemoteClipboardSection(manager: owner.networkManager, pasteboard: owner.networkManager.remoteClipboardPasteboard)
            if let status = owner.networkManager.remoteAudioStatus {
                Toggle("Play PC audio on iPad", isOn: Binding(
                    get: { owner.networkManager.remoteAudioPreferred },
                    set: { owner.networkManager.setRemoteAudioPreferred($0) }))
                    .font(.subheadline)
                    .tint(Color(ink: SessionInk.accent))
                    .frame(minHeight: 44)
                if !status.isEmpty {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(Color(ink: SessionInk.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if owner.networkManager.remoteSecureDesktopSupported {
                Toggle("Control Windows security screens", isOn: Binding(
                    get: { owner.networkManager.remoteSecureDesktopControl },
                    set: { owner.networkManager.setRemoteSecureControl($0) }))
                    .font(.subheadline)
                    .tint(Color(ink: SessionInk.accent))
                    .frame(minHeight: 44)
            }
            if !owner.session.reconnecting {
                SessionActionLayout(accessibility: owner.typeSize.isAccessibilitySize) {
                    if owner.networkManager.remoteSecureDesktopCanSas {
                        owner.actionButton("Ctrl+Alt+Del", icon: "lock.shield", hint: "Opens the Windows security screen") {
                            owner.lastInteraction = Date()
                            owner.networkManager.sendRemoteCommand(.secureAttention)
                        }
                    }
                    owner.actionButton("Lock PC", icon: "lock") {
                        owner.lastInteraction = Date()
                        owner.networkManager.sendRemoteCommand(.lock)
                    }
                    owner.actionButton("Restart PC", icon: "arrow.clockwise") { owner.confirmRestart = true }
                }
                .confirmationDialog("Restart the PC?", isPresented: owner.$confirmRestart, titleVisibility: .visible) {
                    Button("Restart", role: .destructive) { owner.networkManager.sendRemoteCommand(.restart, confirmed: true) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Unsaved work on the PC may ask to be saved. The iPad reconnects when the PC is back.")
                }
            }
        }
    }

    @MainActor private struct PanelFooter: View {
        let owner: SessionPanelOverlay
        let s: SessionPanelSnapshot

        var body: some View {
            let armed = owner.disconnectTick >= 0 && owner.disconnectArming.isArmed(at: Date())
            VStack(alignment: .trailing, spacing: 8) {
                owner.separator()
                if armed {
                    Text("Disconnect from \(s.hostLabel)?").font(.footnote)
                        .foregroundStyle(Color(ink: SessionInk.danger))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(role: .destructive) {
                    owner.lastInteraction = Date()
                    if owner.disconnectArming.tap(at: Date()) {
                        owner.close()
                        owner.remoteInput.suspend(reason: 1)
                        owner.networkManager.stop()
                    } else {
                        owner.disconnectTick += 1
                        UIAccessibility.post(notification: .announcement,
                            argument: "Disconnect from \(s.hostLabel)? Activate again within 4 seconds.")
                        DispatchQueue.main.asyncAfter(deadline: .now() + DisconnectArming.window + 0.1) {
                            owner.disconnectTick += 1
                        }
                    }
                } label: {
                    Text(armed ? "Disconnect now" : "Disconnect")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(Color(ink: armed ? SessionInk.onDanger : SessionInk.danger))
                        .padding(.horizontal, 14)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(armed ? Color(ink: SessionInk.dangerFill) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(armed ? "Ends the session with \(s.hostLabel)" : "Asks to confirm before ending the session")
            }
        }
    }

    @MainActor private struct PanelActionButton: View {
        let title: String
        let icon: String
        let compact: Bool
        let hint: String?
        let action: () -> Void
        var body: some View {
            Button(action: action) {
                VStack(spacing: 8) {
                    Image(systemName: icon).accessibilityHidden(true)
                        .font(compact ? .subheadline : .title3).foregroundStyle(Color(ink: SessionInk.accent))
                    Text(title).font(.footnote.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                }
                .frame(minWidth: 44, maxWidth: .infinity, minHeight: compact ? 44 : 60)
                .background(compact ? Color.clear : Color(ink: SessionInk.raised),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(hint ?? "")
        }
    }

    @MainActor private struct RouteAndControl: View {
        let owner: SessionPanelOverlay
        var body: some View {
            if owner.headerPresentation.controlAction == .stop {
                if owner.typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        status
                        CastingControlSection(owner: owner, action: .stop)
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            status.fixedSize()
                            Spacer(minLength: 8)
                            CastingControlSection(owner: owner, action: .stop).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            status
                            CastingControlSection(owner: owner, action: .stop)
                        }
                    }
                }
            } else {
                status
            }
        }

        private var status: some View {
            Text(owner.headerPresentation.status).font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Color(ink: owner.session.reconnecting ? SessionInk.warning : SessionInk.secondary))
        }
    }

    @MainActor private struct PillTitle: View {
        let owner: SessionPanelOverlay
        var body: some View {
            HStack(spacing: 8) {
                if !owner.isOpen {
                    Image(systemName: owner.icon(owner.session.icon)).accessibilityHidden(true)
                        .foregroundStyle(Color(ink: SessionInk.accent))
                }
                Text(owner.session.title).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down").font(.caption.weight(.bold)).accessibilityHidden(true)
                    .rotationEffect(.degrees(owner.isOpen ? 180 : 0))
                    .foregroundStyle(Color(ink: SessionInk.secondary))
            }
        }
    }

    @MainActor private struct SessionPill: View {
        let owner: SessionPanelOverlay
        let maxX: CGFloat
        var body: some View {
            let s = owner.session
            let missedCopy = owner.networkManager.clipboardMissedCopyNotice
            return Button {
                owner.isOpen ? owner.close() : owner.open()
            } label: {
                Group {
                    if let status = owner.headerPresentation.pillStatus(isOpen: owner.isOpen)
                        .map({ missedCopy ?? $0 }) {
                        if s.reconnecting {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.triangle.2.circlepath").accessibilityHidden(true)
                                Text(status).fixedSize(horizontal: false, vertical: true)
                            }
                        } else if owner.typeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 8) { owner.pillTitle; pillStatus(status) }
                        } else {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) { owner.pillTitle; pillStatus(status) }.fixedSize(horizontal: true, vertical: false)
                                VStack(alignment: .leading, spacing: 8) { owner.pillTitle; pillStatus(status) }
                            }
                        }
                    } else {
                        owner.pillTitle
                    }
                }
                .frame(maxWidth: max(44, min(392, maxX - 52)))
                .font(.subheadline)
                .foregroundStyle(Color(ink: s.reconnecting && !owner.isOpen ? SessionInk.warning : SessionInk.text))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(minWidth: 44, minHeight: 44)
                .background(Color(ink: SessionInk.surface).opacity(0.94), in: Capsule())
                .overlay(Capsule().stroke(Color(ink: SessionInk.hairline), lineWidth: 0.5))
                .shadow(color: Color(ink: SessionInk.canvas).opacity(0.35), radius: 10, y: 4)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .gesture(owner.moveAlongTop(maxX: maxX))
            .accessibilityLabel(owner.pillLabel(s))
            .accessibilityValue(owner.isOpen ? "Expanded" : (missedCopy ?? "Collapsed"))
            .accessibilityHint("Opens screens, keyboard, files, settings and disconnect")
        }

        private func pillStatus(_ status: String) -> some View {
            Text(status).font(.footnote).foregroundStyle(Color(ink: SessionInk.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @MainActor private struct SessionHandle: View {
        let owner: SessionPanelOverlay
        let maxX: CGFloat
        var body: some View {
            let s = owner.session
            return Button { owner.open() } label: {
                // A dark backing keeps the bar visible over a white PC title bar.
                Capsule()
                    .fill(Color(ink: s.control == .on ? SessionInk.positive : SessionInk.text))
                    .frame(width: 56, height: 5)
                    .frame(width: 66, height: 13)
                    .background(Color(ink: SessionInk.canvas).opacity(0.72), in: Capsule())
                    .overlay(Capsule().stroke(Color(ink: SessionInk.hairline), lineWidth: 0.5))
                    .frame(width: 96, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(y: -8)
            .gesture(owner.moveAlongTop(maxX: maxX))
            .accessibilityLabel(owner.pillLabel(s))
            .accessibilityValue("Collapsed")
            .accessibilityHint("Opens screens, keyboard, files, settings and disconnect")
        }
    }

    #if targetEnvironment(simulator)
    /// Eagerly exercise the otherwise collapsed input controls in the hosting regression test.
    func expandedInputForTesting(voiceOver: Bool = false) -> Self {
        var view = self
        view._moreInputExpanded = State(initialValue: true)
        view.voiceOverForTesting = voiceOver
        return view
    }
    #endif
}

/// Shared styling for exclusive choices in the session panel.
struct SessionSegmentLayout<Segments: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    private let segments: Segments

    init(@ViewBuilder segments: () -> Segments) {
        self.segments = segments()
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 0) { segments }
            } else {
                HStack(spacing: 0) { segments }
            }
        }
        .background(Color(ink: SessionInk.raised), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SessionSegmentLabel: View {
    let title: String
    let selected: Bool
    let enabled: Bool

    var body: some View {
        Text(title).font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Color(ink: selected ? SessionInk.onAccent : enabled ? SessionInk.text : SessionInk.secondary))
            .padding(.horizontal, 8)
            .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
            .background(selected ? Color(ink: SessionInk.accent) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// Reflows actions from three columns to two, then one at accessibility sizes.
struct SessionActionLayout: Layout {
    let accessibility: Bool
    private let gap: CGFloat = 8

    init(accessibility: Bool) { self.accessibility = accessibility }

    private func columnCount(width: CGFloat, subviews: Subviews) -> Int {
        SessionPanelLayout.actionColumns(width: Double(width),
            idealWidths: subviews.map { Double($0.sizeThatFits(.unspecified).width) },
            accessibility: accessibility)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? 388
        let columns = columnCount(width: width, subviews: subviews)
        let cellWidth = max(0, (width - CGFloat(columns - 1) * gap) / CGFloat(columns))
        var height: CGFloat = 0
        for start in stride(from: 0, to: subviews.count, by: columns) {
            let row = subviews[start..<min(start + columns, subviews.count)]
            height += row.map { $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height }.max() ?? 0
            if start + columns < subviews.count { height += gap }
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columnCount(width: bounds.width, subviews: subviews)
        let cellWidth = max(0, (bounds.width - CGFloat(columns - 1) * gap) / CGFloat(columns))
        var y = bounds.minY
        for start in stride(from: 0, to: subviews.count, by: columns) {
            let end = min(start + columns, subviews.count)
            let rowHeight = subviews[start..<end].map {
                $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height
            }.max() ?? 0
            for index in start..<end {
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(index - start) * (cellWidth + gap), y: y),
                    anchor: .topLeading, proposal: ProposedViewSize(width: cellWidth, height: rowHeight))
            }
            y += rowHeight + gap
        }
    }
}

/// Formatting only: these are rendered FPS, local receive-stage timing and received video throughput.
/// Zero rates remain real rates; an absent or unrepresentable receive timing is never displayed as zero.
struct SessionTelemetryPresentation: Equatable {
    let fpsValue: String
    let frameReceiveValue: String
    let videoRxValue: String
    let isIdle: Bool
    let hasFrames: Bool
    private static let locale = Locale(identifier: "en_US_POSIX")

    init(fps: Double, frameReceiveMs: Double, videoRxMbps: Double) {
        hasFrames = fps.isFinite && fps > 0
        let hasTraffic = videoRxMbps.isFinite && videoRxMbps > 0
        let idle = !hasFrames && !hasTraffic
        isIdle = idle
        fpsValue = Self.formatFPS(fps)
        videoRxValue = Self.decimal(videoRxMbps, maximum: 9999.9, limit: "9999.9+")
        let timing = !idle && frameReceiveMs > 0
            ? Self.decimal(frameReceiveMs, maximum: 999.9, limit: "999.9+") : "-"
        frameReceiveValue = timing == "0.0" ? "-" : timing
    }

    var visibleText: String { "\(fpsValue) FPS  \(frameReceiveValue) ms  \(videoRxValue) Mbps" }
    var accessibilityLabel: String {
        let frames = fpsValue == "-" ? "Frame rate, unavailable" : Self.spoken(fpsValue, unit: "frames per second")
        return "\(frames). Frame receive, \(Self.spoken(frameReceiveValue, unit: "milliseconds")). " +
            "Video RX, \(Self.spoken(videoRxValue, unit: "megabits per second"))."
    }

    private static func formatFPS(_ value: Double) -> String {
        guard value.isFinite && value >= 0 else { return "-" }
        if value == 0 { return "0" }
        if value.rounded() > 999 { return "999+" }
        if value < 10 && (value * 10).rounded() < 100 {
            return String(format: "%.1f", locale: locale, value)
        }
        return String(format: "%.0f", locale: locale, value)
    }

    private static func decimal(_ value: Double, maximum: Double, limit: String) -> String {
        guard value.isFinite && value >= 0 else { return "-" }
        if value > maximum { return limit }
        return String(format: "%.1f", locale: locale, value)
    }

    private static func spoken(_ value: String, unit: String) -> String {
        if value == "-" { return "unavailable" }
        if value.hasSuffix("+") { return "over \(value.dropLast()) \(unit)" }
        return "\(value) \(unit)"
    }
}

/// One text-only component for casting, whole-PC remote and the open panel's existing header slot.
struct SessionPerformanceReadout: View {
    let fps: Double
    let frameReceiveMs: Double
    let videoRxMbps: Double
    var showsInPanel: Bool { presentation.hasFrames }
    private var presentation: SessionTelemetryPresentation {
        SessionTelemetryPresentation(fps: fps, frameReceiveMs: frameReceiveMs, videoRxMbps: videoRxMbps)
    }

    var body: some View {
        SessionPerformanceLine(presentation: presentation)
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityIdentifier("session.performance")
            .allowsHitTesting(false)
    }
}

private struct SessionPerformanceLine: View {
    let presentation: SessionTelemetryPresentation
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .caption2) private var pointSize: CGFloat = 11
    private var digitWidth: CGFloat { pointSize * 0.64 }

    init(presentation: SessionTelemetryPresentation) { self.presentation = presentation }

    var body: some View {
        HStack(spacing: 8) {
            field(presentation.fpsValue, unit: "FPS", columns: 4)
            field(presentation.frameReceiveValue, unit: "ms", columns: 6)
            field(presentation.videoRxValue, unit: "Mbps", columns: 7)
        }
        .font(.system(size: pointSize, weight: .semibold, design: .monospaced))
        .monospacedDigit()
        .fixedSize(horizontal: true, vertical: true)
        // Opaque, sub-point glyph shadows work with Reduce Transparency too. No material or panel blur.
        .shadow(color: Color(ink: SessionInk.canvas), radius: 0.5, x: 0, y: 0)
        .shadow(color: Color(ink: SessionInk.canvas), radius: 0.5, x: 0, y: 1)
        .animation(nil, value: presentation)
    }

    private func field(_ value: String, unit: String, columns: Int) -> some View {
        HStack(spacing: 3) {
            inkText(value, secondary: presentation.isIdle)
                .frame(width: digitWidth * CGFloat(columns), alignment: .trailing)
            inkText(unit, secondary: true).fontWeight(.medium)
        }
    }

    private func inkText(_ text: String, secondary: Bool) -> some View {
        Text(text)
            .foregroundStyle(Color(ink: secondary && contrast != .increased ? SessionInk.secondary : SessionInk.text))
            .background {
                // Increase Contrast permits backing behind this text run only, never its field or row.
                if contrast == .increased { Color(ink: SessionInk.canvas) }
            }
    }
}

private struct SessionPillHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 44
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Intentional capture silence: same bare-text language as telemetry, no blocking panel.
struct CaptureAvailabilityNotice: View {
    let message: String?
    @State private var announcement = CaptureAvailabilityAnnouncement()
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if let message {
                Text(message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(ink: SessionInk.text))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .shadow(color: Color(ink: SessionInk.canvas), radius: 0.5, x: 0, y: 1)
                    .background {
                        if contrast == .increased { Color(ink: SessionInk.canvas) }
                    }
                    .accessibilityIdentifier("session.captureAvailability")
            }
        }
        .allowsHitTesting(false)
        .onAppear { announce() }
        .onChange(of: message) { _, _ in announce() }
    }
    private func announce() {
        if let text = announcement.update(message) {
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }
}
