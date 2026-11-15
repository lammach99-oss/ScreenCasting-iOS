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

/// One session shell: current Screen, route and control, then the same ordered panel sections.
/// Touches on the panel stay on the iPad.
@MainActor struct SessionPanelOverlay: View {
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
    @State private var rememberedPhysical = ConfirmedPhysicalScreen()
    @State private var requestedScreen: UInt64?
    @State private var pillHeight: CGFloat = 44
    @State private var awaitingSwitchAnnouncement = false
    @AccessibilityFocusState private var switchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var switchingTo: UInt64?
    @State private var failedFrom: String?
    @State private var failedSelection = false
    @State private var permissionAsked = false
    @State private var controlPermissionAsked = false
    @State private var lastInteraction = Date()
    @State private var confirmRestart = false
    @State private var dragOffset: CGFloat = 0
    @State private var disconnectArming = DisconnectArming()
    @State private var disconnectTick = 0
    @AppStorage("ScreenCasting.client.screenPickerOffset") private var storedOffset: Double = 0
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

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
                         permissionAsked: permissionAsked, legacyInputAvailable: networkManager.permitsLegacyVirtualInput)
        }
        return .make(catalogue: networkManager.mirrorMonitorCatalogue, state: networkManager.mirrorControlState,
              switchingTo: switchingTo, switchPending: networkManager.mirrorMonitorSwitchPending,
              pickerSupported: networkManager.mirrorScreenPickerSupported, permissionAsked: permissionAsked,
              legacyInputAvailable: networkManager.permitsLegacyVirtualInput)
    }

    private var kind: SessionPanelKind {
        .make(remote: networkManager.isRemoteControlSession, targets: networkManager.captureTargetState,
              legacy: networkManager.mirrorControlState, catalogue: networkManager.mirrorMonitorCatalogue)
    }

    private var session: SessionPanelSnapshot {
        .make(hostLabel: hostLabel, transport: networkManager.transferSnapshot.transport,
              connection: networkManager.connectionState, control: picker.control, mirrorLabel: picker.currentLabel,
              kind: kind, tailnet: tailnetTarget)
    }

    private var cycle: ScreenCyclePresentation {
        let p = picker
        let reason: String?
        if p.phase == .loading { reason = "Loading screens..." }
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
        .make(targets: networkManager.captureTargetState, kind: kind, lastPhysicalId: rememberedPhysical.id)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                if isOpen {
                    // Tapping outside closes the panel; while it is open nothing reaches the PC.
                    Color(ink: SessionInk.canvas).opacity(0.001).contentShape(Rectangle()).onTapGesture { close() }
                }
                VStack(spacing: 10) {
                    // After a few idle seconds the pill shrinks to a slim handle so the top of the PC stays visible.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        // VoiceOver keeps the full pill: swapping views every idle cycle would drop its focus.
                        let mode = SessionPillPresentation.make(isOpen: isOpen || voiceOver,
                                                                idleFor: context.date.timeIntervalSince(lastInteraction),
                                                                reconnecting: session.reconnecting)
                        ZStack(alignment: .top) {
                            if mode == .full {
                                pill(maxX: proxy.size.width).transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                            } else {
                                handle(maxX: proxy.size.width).transition(.opacity)
                            }
                        }
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: mode)
                    }
                    .background(GeometryReader { pillProxy in
                        Color.clear.preference(key: SessionPillHeightKey.self, value: pillProxy.size.height)
                    })
                    if isOpen {
                        // Sized to its content; only very large text or many screens reach the cap and scroll.
                        panel(width: min(420, proxy.size.width - 24), maxHeight: max(120, proxy.size.height - pillHeight - 34))
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .offset(x: clampedOffset(width: proxy.size.width))
                .padding(.top, 12)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
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
                failedFrom = nil; failedSelection = false
                if networkManager.isRemoteControlSession { networkManager.refreshRemoteScreens() }
                else { networkManager.refreshMirrorScreens() }
            }
        }
        .onAppear { rememberedPhysical.observe(networkManager.captureTargetState) }
        .onChange(of: networkManager.captureTargetState) { _, targets in rememberedPhysical.observe(targets) }
        .onChange(of: picker.isSwitching) { wasSwitching, switching in
            if wasSwitching && !switching { finishSwitch() }
        }
        .onChange(of: networkManager.captureTargetState.session) { _, _ in
            switchingTo=nil;failedFrom=nil;permissionAsked=false;controlPermissionAsked=false
            failedSelection=false
            requestedScreen=nil;awaitingSwitchAnnouncement=false
        }
        .onChange(of: networkManager.captureTargetState.catalogue?.allowed) { _, allowed in
            if allowed == true { permissionAsked=false }
        }
        .onChange(of: picker.control) { _, control in
            if control == .on { controlPermissionAsked = false }
        }
        .onChange(of: networkManager.mirrorMonitorCatalogue) { _, catalogue in settle(catalogue) }
        .onChange(of: networkManager.mirrorMonitorSwitchPending) { _, pending in if !pending { settle(networkManager.mirrorMonitorCatalogue) } }
        .onChange(of: networkManager.mirrorMonitorCatalogue?.allowed) { _, allowed in if allowed == true { permissionAsked = false } }
    }

    // MARK: Pill

    private func pill(maxX: CGFloat) -> some View {
        let s = session
        return Button {
            isOpen ? close() : open()
        } label: {
            Group {
                if s.reconnecting {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath").accessibilityHidden(true)
                        Text(s.reconnectingText).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { pillTitle; routeAndControl }.fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 8) { pillTitle; routeAndControl }
                    }
                }
            }
            .frame(maxWidth: max(44, min(392, maxX - 52)))
            .font(.subheadline)
            .foregroundStyle(Color(ink: s.reconnecting ? SessionInk.warning : SessionInk.text))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(Color(ink: SessionInk.surface).opacity(0.94), in: Capsule())
            .overlay(Capsule().stroke(Color(ink: SessionInk.hairline), lineWidth: 0.5))
            .shadow(color: Color(ink: SessionInk.canvas).opacity(0.35), radius: 10, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .gesture(moveAlongTop(maxX: maxX))
        .accessibilityLabel(pillLabel(s))
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .accessibilityHint("Opens screens, keyboard, files, settings and disconnect")
    }

    private var pillTitle: some View {
        HStack(spacing: 8) {
            Image(systemName: icon(session.icon)).accessibilityHidden(true)
                .foregroundStyle(Color(ink: SessionInk.accent))
            Text(session.title).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.down").font(.caption.weight(.bold)).accessibilityHidden(true)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
                .foregroundStyle(Color(ink: SessionInk.secondary))
        }
    }

    /// The idle pill: a slim bar at the top edge, green while touches drive the PC. Tapping it opens the panel.
    private func handle(maxX: CGFloat) -> some View {
        let s = session
        return Button { open() } label: {
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
        .gesture(moveAlongTop(maxX: maxX))
        .accessibilityLabel(pillLabel(s))
        .accessibilityValue("Collapsed")
        .accessibilityHint("Opens screens, keyboard, files, settings and disconnect")
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
        s.reconnecting ? s.reconnectingText
            : "\(s.title)\(s.transport.map { ", \($0)" } ?? "")\(". " + controlText(s.control))"
    }

    // MARK: Panel

    private func panel(width: CGFloat, maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            panelHeader
            ViewThatFits(in: .vertical) {
                panelSections.fixedSize(horizontal: false, vertical: true)
                ScrollView { panelSections }.scrollBounceBehavior(.basedOnSize)
            }
            footer(session)
        }
        .foregroundStyle(Color(ink: SessionInk.text))
        .padding(16)
        .frame(width: width)
        .background(Color(ink: SessionInk.surface).opacity(0.96), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color(ink: SessionInk.hairline), lineWidth: 0.5))
        .shadow(color: Color(ink: SessionInk.canvas).opacity(0.45), radius: 24, y: 12)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { lastInteraction = Date() }
        .frame(maxHeight: maxHeight, alignment: .top)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { close() }
    }

    private var panelSections: some View {
        VStack(alignment: .leading, spacing: 14) {
            if ScreenPickerSnapshot.shouldShowPicker(remote: networkManager.isRemoteControlSession,
                mirror: !networkManager.isRemoteControlSession, acceptedFeatures: networkManager.remoteMonitorState.enabled ? 7 : 0,
                typedSources: networkManager.captureTargetState.enabled) { screens(picker) }
            if !networkManager.isRemoteControlSession { connectionPicker }
            if !networkManager.isRemoteControlSession && picker.control != .unavailable { castingControl }
            tools
            touchSection
            if networkManager.isRemoteControlSession { remoteActions }
        }
    }

    private var panelHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.hostLabel).font(.headline).fixedSize()
                    Spacer(minLength: 8)
                    routeAndControl.fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.hostLabel).font(.headline)
                    routeAndControl
                }
            }
            if session.reconnecting {
                Label(session.reconnectingText, systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(Color(ink: SessionInk.warning))
            }
            if let performance { performance }
        }
    }

    private var routeAndControl: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { routeLabel; controlBadge(session.control, compact: true) }
            VStack(alignment: .leading, spacing: 8) { routeLabel; controlBadge(session.control, compact: true) }
        }
        .font(.footnote)
    }

    @ViewBuilder private var routeLabel: some View {
        if let route = session.transport {
            Text(route).foregroundStyle(Color(ink: SessionInk.secondary))
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.footnote).foregroundStyle(Color(ink: SessionInk.secondary))
            .accessibilityAddTraits(.isHeader)
    }

    private func screens(_ p: ScreenPickerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Screen")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { switchScreenButton.fixedSize(horizontal: true, vertical: false); castingModes }
                VStack(alignment: .leading, spacing: 8) { switchScreenButton; castingModes }
            }
            screenStatus(p)
        }
    }

    private var switchScreenButton: some View {
        Button { cycleScreen() } label: {
            HStack(spacing: 8) {
                if cycle.pending { ProgressView().tint(Color(ink: SessionInk.warning)).accessibilityHidden(true) }
                else { Image(systemName: "display").accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Switch screen").font(.subheadline.weight(.semibold))
                    Text(cycle.detail).font(.footnote).foregroundStyle(Color(ink: SessionInk.secondary))
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(8)
            .background(Color(ink: SessionInk.raised), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(ink: SessionInk.hairline), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(!cycle.enabled)
        .opacity(cycle.enabled ? 1 : 0.6)
        .accessibilityLabel("Switch screen")
        .accessibilityValue(cycle.accessibilityValue)
        .accessibilityHint(cycle.hint)
        .accessibilityIdentifier("session.switch-screen")
        .accessibilityFocused($switchFocused)
    }

    @ViewBuilder private var castingModes: some View {
        if !networkManager.isRemoteControlSession {
            if typeSize.isAccessibilitySize {
                VStack(spacing: 8) { modeButtons }
            } else {
                HStack(spacing: 8) { modeButtons }
            }
        }
    }

    private var modeButtons: some View {
        Group {
            modeButton("Extend", choice: modeChoices.extend, identifier: "session.mode.extend")
            modeButton("Mirror", choice: modeChoices.mirror, identifier: "session.mode.mirror")
        }
    }

    private func modeButton(_ title: String, choice: CaptureModeChoice, identifier: String) -> some View {
        Button {
            guard choice.enabled, let id = choice.targetId else { return }
            requestScreen(id)
        } label: {
            Text(title).font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                .background(Color(ink: choice.selected ? SessionInk.accent : SessionInk.raised)
                    .opacity(choice.selected ? 0.16 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(ink: choice.selected ? SessionInk.accent : SessionInk.hairline), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(!choice.enabled)
        .accessibilityLabel(title)
        .accessibilityValue(choice.selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(choice.selected ? .isSelected : [])
        .accessibilityHint(modeChoices.explanation ?? "")
        .accessibilityIdentifier(identifier)
    }

    private func screenStatus(_ p: ScreenPickerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = screenMessage {
                Text(message).font(.footnote).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(Color(ink: screenHasFailure ? SessionInk.danger : SessionInk.warning))
            }
            if permissionAsked && !p.canAskPermission && p.phase == .locked {
                Text(CastingPermissionCopy.requestSent).font(.footnote).foregroundStyle(Color(ink: SessionInk.warning))
            }
            if p.canAskPermission {
                Button("Ask PC to allow") {
                    permissionAsked = true; lastInteraction = Date()
                    networkManager.requestMirrorSwitchPermission()
                }
                .buttonStyle(.bordered).frame(minHeight: 44)
                .accessibilityHint("Shows an approval pop-up on the PC")
            }
            if !networkManager.isRemoteControlSession, let explanation = modeChoices.explanation {
                Text(explanation).font(.footnote).foregroundStyle(Color(ink: SessionInk.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if networkManager.captureTargetState.enabled && !p.isSwitching &&
                (networkManager.captureTargetState.listUnavailable || networkManager.captureTargetState.needsCatalogueRefresh ||
                 networkManager.captureTargetState.catalogue?.state == 0 || networkManager.captureTargetState.catalogue?.state == 3) {
                Button("Refresh screens") { networkManager.refreshMirrorScreens() }
                    .buttonStyle(.bordered).frame(minHeight: 44)
            }
        }
    }

    private var screenHasFailure: Bool {
        failedSelection || networkManager.remoteMonitorState.issue == .failed ||
            networkManager.remoteMonitorState.issue == .denied || networkManager.captureTargetState.issue == .failed
    }

    private var screenMessage: String? {
        if cycle.pending { return cycle.reason }
        if failedSelection {
            if let failedFrom { return "Couldn't switch. Still showing \(failedFrom)." }
            return "Couldn't switch screens. Choose a screen to restore the picture."
        }
        if kind == .castingExtend { return cycle.reason }
        if networkManager.isRemoteControlSession {
            return networkManager.remoteMonitorState.selectionStatus(inputReady: networkManager.remoteInputReady,
                controlEnabled: monitorControlEnabled).map(screenWords) ?? cycle.reason
        }
        if networkManager.captureTargetState.enabled {
            return networkManager.captureTargetState.statusMessage.map(screenWords) ?? cycle.reason
        }
        if picker.phase == .loading && !networkManager.mirrorScreenPickerSupported {
            return "This PC can't list its screens. Update ScreenCasting on the PC."
        }
        return cycle.reason
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
        failedFrom = nil; failedSelection = false; lastInteraction = Date(); requestedScreen = targetId
        switchFocused = false; awaitingSwitchAnnouncement = true
    }

    private func finishSwitch() {
        guard awaitingSwitchAnnouncement else { return }
        awaitingSwitchAnnouncement = false
        let failed = failedSelection || networkManager.remoteMonitorState.issue != nil ||
            networkManager.captureTargetState.issue != nil || networkManager.captureTargetState.unknownOutcome ||
            picker.tiles.first(where: { $0.status == .showing })?.id != requestedScreen
        let message = failed ? "Couldn't switch screens."
            : "Showing \(cycle.currentLabel)."
        requestedScreen = nil
        UIAccessibility.post(notification: .announcement, argument: message)
        switchFocused = true
    }

    private var castingControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Control")
            actionButton(picker.control == .on ? "Stop control" : "Ask control",
                         icon: picker.control == .on ? "hand.raised.slash" : "hand.point.up.left",
                         enabled: picker.control == .on || !controlPermissionAsked) {
                lastInteraction = Date()
                if picker.control == .on {
                    remoteInput.suspend(reason: 1); networkManager.releaseMirrorControl(); controlPermissionAsked = false
                } else { networkManager.requestMirrorControl(); controlPermissionAsked = true }
            }
            if controlPermissionAsked && picker.control != .on {
                Text(CastingPermissionCopy.requestSent).font(.footnote)
                    .foregroundStyle(Color(ink: SessionInk.secondary))
            }
        }
    }

    private var tools: some View {
        let canType = networkManager.isRemoteControlSession ? (!remoteInput.usesScanKeyboard || remoteInput.keyboardEnabled)
            : picker.canType
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Tools")
            SessionActionLayout(accessibility: typeSize.isAccessibilitySize) {
                actionButton("Keyboard", icon: "keyboard", enabled: canType,
                             hint: canType ? nil : "Ask for control first to type on the PC") {
                    close()
                    DispatchQueue.main.async { NotificationCenter.default.post(name: .sessionPanelToggleKeyboard, object: nil) }
                }
                actionButton("Files", icon: "arrow.left.arrow.right") { close(); onFiles() }
                actionButton("Settings", icon: "gearshape") { close(); onSettings() }
            }
        }
    }

    private var touchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Touch")
            if remoteInput.usesEnhancedPointer {
                RemoteMouseControls(mode: remoteInput.mouseMode,
                    onModeChange: { remoteInput.changeMouseMode($0) }, enabled: remoteInput.pointerEnabled)
            } else {
                Text(networkManager.isRemoteControlSession ? "Use touch to point and click on the PC."
                     : "Tap to click. Swipe one finger to scroll. Hold, then move to drag. Use Pencil to write.")
                    .font(.footnote).foregroundStyle(Color(ink: SessionInk.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if remoteInput.usesScanKeyboard || remoteInput.usesEnhancedPointer { moreInput }
        }
    }

    private var moreInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { moreInputExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Text("More input").font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down").rotationEffect(.degrees(moreInputExpanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(moreInputExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("session.more-input")
            if moreInputExpanded {
                if remoteInput.usesScanKeyboard { specialKeys }
                if remoteInput.usesEnhancedPointer {
                    RemoteMouseExtras(mode: remoteInput.mouseMode,
                        onModeChange: { remoteInput.changeMouseMode($0) },
                        onMiddleClick: { remoteInput.middleClick() }, enabled: remoteInput.pointerEnabled)
                }
            }
        }
    }

    private var specialKeys: some View {
        let generation = remoteInput.generation
        return RemoteSpecialKeyBar(keyboard: Binding(
            get: { remoteInput.keyboard },
            set: { value in
                if remoteInput.keyboardEnabled && value.token == remoteInput.token { remoteInput.keyboard = value }
            }), sendKey: { remoteInput.emitKey($0, generation: generation) },
            releaseKeys: { remoteInput.suspend(reason: 4) })
            .disabled(!remoteInput.keyboardEnabled)
            .opacity(remoteInput.keyboardEnabled ? 1 : 0.45)
    }

    private var connectionPicker: some View {
        let state = networkManager.connectionSwitchState
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Connection")
            Text(state.recommendationText).font(.footnote)
                .foregroundStyle(Color(ink: SessionInk.secondary))
            ForEach([ConnectionRoute.usb, .wifi], id: \.rawValue) { route in
                let reason = state.disabledReason(for: route, hasWifiEndpoint: networkManager.hasReconnectTarget)
                Button {
                    lastInteraction = Date()
                    remoteInput.suspend(reason: 1)
                    networkManager.requestConnectionRoute(route)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: route == .usb ? "cable.connector" : "wifi").accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(route.label).font(.subheadline.weight(.semibold))
                                if state.snapshot?.recommended == route && !state.needsRefresh {
                                    Text("Recommended").font(.caption)
                                }
                            }
                            if let reason { Text(reason).font(.caption).fixedSize(horizontal: false, vertical: true) }
                        }
                        Spacer(minLength: 4)
                        if state.actualRoute == route {
                            Image(systemName: "checkmark").accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(Color(ink: SessionInk.text))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color(ink: SessionInk.raised), in: RoundedRectangle(cornerRadius: 10))
                .disabled(reason != nil)
                .opacity(reason == nil ? 1 : 0.6)
                .accessibilityLabel(route.label + (state.actualRoute == route ? ", Connected" : ""))
                .accessibilityHint(reason ?? ("Switch to " + route.label))
                .accessibilityAddTraits(state.actualRoute == route ? .isSelected : [])
            }
            HStack(spacing: 8) {
                if state.pending != nil { ProgressView().tint(Color(ink: SessionInk.accent)) }
                Text(state.message).font(.footnote).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Color(ink: state.offersReconnect ? SessionInk.warning : SessionInk.secondary))
            .accessibilityElement(children: .combine)
            if state.enabled && state.snapshot?.allowed == false && state.pending == nil && !state.offersReconnect {
                Button("Ask PC") {
                    let target: ConnectionRoute = state.actualRoute == .usb ? .wifi : .usb
                    networkManager.requestConnectionRoute(target, askPC: true)
                }
                .buttonStyle(.bordered).frame(minHeight: 44)
                .disabled(state.phase == .permissionRequired || state.needsRefresh)
            }
            if state.needsRefresh && state.pending == nil && !state.offersReconnect {
                Button("Refresh connection status") { networkManager.refreshConnectionStatus() }
                    .buttonStyle(.bordered).frame(minHeight: 44)
            }
            if state.offersReconnect {
                Button("Reconnect over Wi-Fi") { networkManager.reconnectConnectionOverWifi() }
                    .buttonStyle(.bordered).frame(minHeight: 44)
                    .disabled(!networkManager.hasReconnectTarget)
            }
        }
    }

    /// Remote control service only: keys the iPad cannot send, and power.
    private var remoteActions: some View {
        SessionActionLayout(accessibility: typeSize.isAccessibilitySize) {
            actionButton("Ctrl+Alt+Del", icon: "lock.shield", hint: "Opens the Windows security screen") {
                lastInteraction = Date()
                networkManager.sendRemoteCommand(.secureAttention)
            }
            actionButton("Lock PC", icon: "lock") {
                lastInteraction = Date()
                networkManager.sendRemoteCommand(.lock)
            }
            actionButton("Restart PC", icon: "arrow.clockwise") { confirmRestart = true }
        }
        .confirmationDialog("Restart the PC?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart", role: .destructive) { networkManager.sendRemoteCommand(.restart, confirmed: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsaved work on the PC may ask to be saved. The iPad reconnects when the PC is back.")
        }
    }

    private func actionButton(_ title: String, icon: String, enabled: Bool = true, hint: String? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).accessibilityHidden(true).font(.title3).foregroundStyle(Color(ink: SessionInk.accent))
                Text(title).font(.footnote.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(Color(ink: SessionInk.raised), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
        .accessibilityHint(hint ?? "")
    }

    private func footer(_ s: SessionPanelSnapshot) -> some View {
        let armed = disconnectTick >= 0 && disconnectArming.isArmed(at: Date())
        let tip = Group {
            if armed {
                Text("Disconnect from \(s.hostLabel)?").font(.caption).foregroundStyle(Color(ink: SessionInk.danger))
            } else {
                Button { close(); onGestures() } label: {
                    Label("Gestures", systemImage: "questionmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(Color(ink: SessionInk.secondary))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the touch and Pencil gestures")
            }
        }
        let button = Button {
            lastInteraction = Date()
            if disconnectArming.tap(at: Date()) {
                close()
                remoteInput.suspend(reason: 1)
                networkManager.stop()
            } else {
                disconnectTick += 1
                UIAccessibility.post(notification: .announcement,
                                     argument: "Disconnect from \(s.hostLabel)? Activate again within 4 seconds.")
                DispatchQueue.main.asyncAfter(deadline: .now() + DisconnectArming.window + 0.1) { disconnectTick += 1 }
            }
        } label: {
            Label(armed ? "Disconnect now" : "Disconnect", systemImage: "xmark.circle")
                .font(.subheadline.weight(.semibold))
                .fixedSize()
                .foregroundStyle(Color(ink: armed ? SessionInk.onDanger : SessionInk.danger))
                .padding(.horizontal, 12).frame(minHeight: 44)
                .background(armed ? Color(ink: SessionInk.dangerFill) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(ink: SessionInk.dangerFill).opacity(armed ? 0 : 0.6), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityHint(armed ? "Ends the session with \(s.hostLabel)" : "Asks to confirm before ending the session")
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { tip; button }
            } else {
                HStack(spacing: 10) { tip; Spacer(minLength: 8); button }
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(Color(ink: SessionInk.hairline)).frame(height: 0.5) }
    }

    private func controlBadge(_ control: ScreenPickerSnapshot.Control, compact: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: control == .on ? "hand.point.up.left" : "eye").accessibilityHidden(true)
            Text(compact && control == .on ? "Control on" : controlText(control))
        }
        .foregroundStyle(Color(ink: control == .on ? SessionInk.positive : SessionInk.secondary))
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
            failedFrom = catalogue.monitors.first { $0.id == catalogue.selected }?.label
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
    private static let locale = Locale(identifier: "en_US_POSIX")

    init(fps: Double, frameReceiveMs: Double, videoRxMbps: Double) {
        let hasFrames = fps.isFinite && fps > 0
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
