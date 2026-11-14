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

/// The one visible handle in every session. The pill names the PC (or mirrored screen), the link and control;
/// the panel holds Screens, Keyboard, control, Files, Settings and Disconnect. Touches on it stay on the iPad.
@MainActor struct SessionPanelOverlay: View {
    @ObservedObject var networkManager: NetworkManager
    let hostLabel: String
    @Binding var isOpen: Bool
    @ObservedObject var remoteInput: RemoteSessionInputState
    let onFiles: () -> Void
    let onSettings: () -> Void
    let onGestures: () -> Void

    @State private var switchingTo: UInt64?
    @State private var failedFrom: String?
    @State private var permissionAsked = false
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
                         permissionAsked: permissionAsked)
        }
        return .make(catalogue: networkManager.mirrorMonitorCatalogue, state: networkManager.mirrorControlState,
              switchingTo: switchingTo, switchPending: networkManager.mirrorMonitorSwitchPending,
              pickerSupported: networkManager.mirrorScreenPickerSupported, permissionAsked: permissionAsked)
    }

    private var session: SessionPanelSnapshot {
        .make(hostLabel: hostLabel, transport: networkManager.transferSnapshot.transport,
              connection: networkManager.connectionState, control: picker.control, mirrorLabel: picker.currentLabel)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                if isOpen {
                    // Tapping outside closes the panel; while it is open nothing reaches the PC.
                    Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { close() }
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
                        .animation(.easeOut(duration: 0.3), value: mode)
                    }
                    if isOpen {
                        // Sized to its content; only very large text or many screens reach the cap and scroll.
                        panel(width: min(420, proxy.size.width - 24), maxHeight: max(160, proxy.size.height - 102))
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .offset(x: clampedOffset(width: proxy.size.width))
                .padding(.top, 12)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: isOpen) { _, open in
            lastInteraction = Date()
            disconnectArming.reset()
            if open {
                failedFrom = nil
                if networkManager.isRemoteControlSession { networkManager.refreshRemoteScreens() }
                else { networkManager.refreshMirrorScreens() }
            }
        }
        .onChange(of: networkManager.captureTargetState.session) { _, _ in
            switchingTo=nil;failedFrom=nil;permissionAsked=false
        }
        .onChange(of: networkManager.captureTargetState.catalogue?.allowed) { _, allowed in
            if allowed == true { permissionAsked=false }
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
            HStack(spacing: 8) {
                if s.reconnecting {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(s.reconnectingText).lineLimit(1)
                } else {
                    Image(systemName: icon(s.icon)).foregroundStyle(Color(ink: SessionInk.accent))
                    Text(s.title).fontWeight(.semibold).lineLimit(1).frame(maxWidth: 220)
                    if let transport = s.transport {
                        Text("· \(transport)").foregroundStyle(Color(ink: SessionInk.secondary))
                    }
                    if s.isMirror {
                        Rectangle().fill(Color(ink: SessionInk.hairline)).frame(width: 1, height: 14)
                        controlBadge(s.control, compact: true)
                    }
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .foregroundStyle(Color(ink: SessionInk.secondary))
                }
            }
            .font(.subheadline)
            .foregroundStyle(Color(ink: s.reconnecting ? SessionInk.warning : SessionInk.text))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(Color(ink: SessionInk.surface).opacity(0.94), in: Capsule())
            .overlay(Capsule().stroke(Color(ink: SessionInk.hairline), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .gesture(moveAlongTop(maxX: maxX))
        .accessibilityLabel(pillLabel(s))
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .accessibilityHint("Opens screens, keyboard, files, settings and disconnect")
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
                .frame(width: 96, height: 22)
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
            : "\(s.title)\(s.transport.map { ", \($0)" } ?? "")\(s.isMirror ? ". \(controlText(s.control))" : "")"
    }

    // MARK: Panel

    private func panel(width: CGFloat, maxHeight: CGFloat) -> some View {
        let s = session
        let p = picker
        let middle = VStack(alignment: .leading, spacing: 14) {
            if ScreenPickerSnapshot.shouldShowPicker(remote: networkManager.isRemoteControlSession,
                mirror: s.isMirror, acceptedFeatures: networkManager.remoteMonitorState.enabled ? 7 : 0,
                typedSources: networkManager.captureTargetState.enabled) { screens(p) }
            actions(s)
            if remoteInput.usesScanKeyboard {
                let generation = remoteInput.generation
                RemoteSpecialKeyBar(keyboard: Binding(
                    get: { remoteInput.keyboard },
                    set: { value in
                        if remoteInput.keyboardEnabled && value.token == remoteInput.token {
                            remoteInput.keyboard = value
                        }
                    }), sendKey: { remoteInput.emitKey($0, generation: generation) },
                    remoteCommand: { networkManager.sendRemoteCommand($0) },
                    releaseKeys: { remoteInput.suspend(reason: 4) })
                    .disabled(!remoteInput.keyboardEnabled)
                    .opacity(remoteInput.keyboardEnabled ? 1 : 0.45)
            }
            if remoteInput.usesEnhancedPointer {
                RemoteMouseControls(mode: remoteInput.mouseMode,
                    onModeChange: { remoteInput.changeMouseMode($0) },
                    onMiddleClick: { remoteInput.middleClick() }, enabled: remoteInput.pointerEnabled)
            }
        }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(s.hostLabel).font(.headline).lineLimit(1)
                Spacer()
                if let transport = s.transport {
                    Label(transport, systemImage: transport == "USB-C" ? "cable.connector" : "wifi")
                        .font(.footnote).foregroundStyle(Color(ink: SessionInk.secondary))
                }
            }
            if s.reconnecting {
                Label(s.reconnectingText, systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(Color(ink: SessionInk.warning))
            }
            // Large text or many screens scroll; the header and Disconnect stay put.
            ViewThatFits(in: .vertical) {
                middle
                ScrollView { middle }.scrollBounceBehavior(.basedOnSize)
            }
            footer(s)
        }
        .foregroundStyle(Color(ink: SessionInk.text))
        .padding(16)
        .frame(width: width)
        .background(Color(ink: SessionInk.surface).opacity(0.96), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color(ink: SessionInk.hairline), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { lastInteraction = Date() }
        // The cap goes outside the background: a capped frame takes the whole cap, which left a tall empty panel.
        .frame(maxHeight: maxHeight, alignment: .top)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { close() }
    }

    @ViewBuilder
    private func screens(_ p: ScreenPickerSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Screens on this PC").font(.footnote).foregroundStyle(Color(ink: SessionInk.secondary))
            Spacer()
            if p.phase == .ready && !p.isSwitching && (!networkManager.isRemoteControlSession || p.control == .on) {
                Text("Tap a screen to show it").font(.caption).foregroundStyle(Color(ink: SessionInk.secondary))
            }
        }
        if p.phase == .locked { lockedBanner(p) }
        if networkManager.isRemoteControlSession, p.phase != .locked,
           let message = networkManager.remoteMonitorState.selectionStatus(inputReady: networkManager.remoteInputReady,
                controlEnabled: monitorControlEnabled) {
            Text(message).font(.footnote)
                .foregroundStyle(Color(ink: networkManager.remoteMonitorState.issue == .failed ||
                    networkManager.remoteMonitorState.issue == .denied ? SessionInk.danger : SessionInk.warning))
        }
        if !networkManager.isRemoteControlSession, networkManager.captureTargetState.enabled,
           let message=networkManager.captureTargetState.statusMessage {
            Text(message).font(.footnote).foregroundStyle(Color(ink: SessionInk.warning))
                .accessibilityLabel(message)
        }
        if !networkManager.isRemoteControlSession, networkManager.captureTargetState.enabled,
           !p.isSwitching, networkManager.captureTargetState.listUnavailable ||
            networkManager.captureTargetState.catalogue?.state == 0 || networkManager.captureTargetState.catalogue?.state == 3 {
            Button("Refresh sources") { networkManager.refreshMirrorScreens() }
                .buttonStyle(.bordered).frame(minHeight: 44)
        }
        if let failedFrom {
            Text("Couldn't switch. Still showing \(failedFrom).")
                .font(.footnote).foregroundStyle(Color(ink: SessionInk.danger))
        }
        if p.phase == .loading && !networkManager.isRemoteControlSession &&
            !networkManager.captureTargetState.enabled && !networkManager.mirrorScreenPickerSupported && !p.isSwitching && switchingTo == nil {
            Text("This PC can't list its screens. Update ScreenCasting on the PC.")
                .font(.footnote).foregroundStyle(Color(ink: SessionInk.secondary))
        } else if p.phase == .loading {
            HStack(spacing: 10) {
                ProgressView().tint(Color(ink: SessionInk.accent))
                Text(networkManager.isRemoteControlSession ? "Loading screens..." :
                    (p.isSwitching || switchingTo != nil ? "Switching\u{2026}" : "Screens appear once the picture is showing."))
                    .font(.footnote).foregroundStyle(Color(ink: SessionInk.secondary))
            }
            .frame(maxWidth: .infinity, minHeight: 72)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
                ForEach(p.tiles) { tile in tileView(tile) }
            }
        }
    }

    private func lockedBanner(_ p: ScreenPickerSnapshot) -> some View {
        let amber = Color(ink: SessionInk.warning)
        return HStack(spacing: 10) {
            Image(systemName: "lock").foregroundStyle(amber).accessibilityHidden(true)
            Text(networkManager.isRemoteControlSession
                 ? networkManager.remoteMonitorState.statusMessage ?? "Screens are unavailable."
                 : networkManager.captureTargetState.enabled && networkManager.captureTargetState.catalogue?.state != 1
                    ? networkManager.captureTargetState.statusMessage ?? "Sources are unavailable. Refresh sources."
                 : permissionAsked ? "Asked. Tick \"Allow paired iPad to switch monitors\" on the PC."
                 : networkManager.mirrorScreenPickerSupported ? "Switching is off on the PC."
                 : "Turn on monitor switching on the PC.")
                .font(.footnote).foregroundStyle(amber)
            Spacer(minLength: 4)
            if p.canAskPermission {
                Button("Ask PC to allow") {
                    permissionAsked = true; lastInteraction = Date()
                    networkManager.requestMirrorSwitchPermission()
                }
                .buttonStyle(.bordered).tint(amber).frame(minHeight: 44)
            }
        }
        .padding(10)
        .background(amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func tileView(_ tile: ScreenPickerTile) -> some View {
        let selected = tile.status == .showing
        return Button {
            if networkManager.isRemoteControlSession {
                guard tile.canSelect, monitorControlEnabled, let catalogue = networkManager.remoteMonitorState.catalogue else { return }
                lastInteraction = Date()
                networkManager.requestRemoteMonitor(tile.id, catalogue: catalogue)
                return
            }
            if networkManager.captureTargetState.enabled {
                guard tile.canSelect, let catalogue=networkManager.captureTargetState.catalogue else { return }
                failedFrom=nil;lastInteraction=Date()
                networkManager.requestCaptureTarget(tile.id, catalogue: catalogue)
                return
            }
            guard tile.status == .available, let catalogue = networkManager.mirrorMonitorCatalogue else { return }
            failedFrom = nil; switchingTo = tile.id; lastInteraction = Date()
            networkManager.requestMirrorMonitor(tile.id, catalogue: catalogue)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: tile.isExtend ? "rectangle.on.rectangle" : tile.isBuiltIn ? "laptopcomputer" : "display").font(.title2)
                    .foregroundStyle(Color(ink: selected ? SessionInk.accent : SessionInk.secondary))
                Text(tile.label).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if tile.status == .switching { ProgressView().controlSize(.mini).tint(Color(ink: SessionInk.accent)) }
                    Text(statusText(tile.status)).font(.caption)
                        .foregroundStyle(Color(ink: selected ? SessionInk.text : SessionInk.secondary))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .padding(12)
            .background(selected ? Color(ink: SessionInk.accent).opacity(0.16) : Color(ink: SessionInk.raised),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(ink: selected ? SessionInk.accent : SessionInk.hairline), lineWidth: selected ? 1.5 : 0.5))
            .opacity(tile.status == .locked ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!tile.canSelect)
        .accessibilityLabel("\(tile.label), \(statusText(tile.status))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func actions(_ s: SessionPanelSnapshot) -> some View {
        // Mirrored keys reach the PC only under granted control; view-only typing would vanish.
        let canType = !s.isMirror || s.control == .on
        let buttons = Group {
            actionButton("Keyboard", icon: "keyboard", enabled: canType,
                         hint: canType ? nil : "Ask for control first to type on the PC") {
                close()
                DispatchQueue.main.async { NotificationCenter.default.post(name: .sessionPanelToggleKeyboard, object: nil) }
            }
            if s.isMirror && !networkManager.isRemoteControlSession {
                actionButton(s.control == .on ? "Stop control" : "Ask control",
                             icon: s.control == .on ? "hand.raised.slash" : "hand.point.up.left") {
                    lastInteraction = Date()
                    if s.control == .on { remoteInput.suspend(reason: 1); networkManager.releaseMirrorControl() } else { networkManager.requestMirrorControl() }
                }
            }
            actionButton("Files", icon: "arrow.left.arrow.right") { close(); onFiles() }
            actionButton("Settings", icon: "gearshape") { close(); onSettings() }
        }
        return VStack(spacing: 8) {
            if networkManager.isRemoteControlSession { remoteActions }
            if typeSize.isAccessibilitySize {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) { buttons }
            } else {
                HStack(spacing: 8) { buttons }
            }
        }
    }

    /// Remote control service only: keys the iPad cannot send, and power.
    private var remoteActions: some View {
        HStack(spacing: 8) {
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
                Image(systemName: icon).font(.title3).foregroundStyle(Color(ink: SessionInk.accent))
                Text(title).font(.footnote.weight(.medium)).lineLimit(typeSize.isAccessibilitySize ? 2 : 1).minimumScaleFactor(0.8)
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
            Image(systemName: control == .on ? "hand.point.up.left" : "eye")
            Text(compact ? (control == .on ? "Control on" : "View only") : controlText(control))
        }
        .foregroundStyle(Color(ink: control == .on ? SessionInk.positive : SessionInk.secondary))
    }

    // MARK: Behavior

    private func open() { isOpen = true }

    private func close() {
        withAnimation(.easeOut(duration: 0.2)) { isOpen = false }
        lastInteraction = Date()
    }

    /// A switch ends when the Host's list names the target as showing, or the pending state clears without it.
    private func settle(_ catalogue: MirrorMonitorCatalogue?) {
        guard let target = switchingTo, let catalogue else { return }
        if catalogue.selected == target {
            switchingTo = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { close() }
        } else if !networkManager.mirrorMonitorSwitchPending {
            failedFrom = catalogue.monitors.first { $0.id == catalogue.selected }?.label ?? "the current screen"
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

    private func statusText(_ status: ScreenPickerTile.Status) -> String {
        switch status {
        case .showing: "Showing now"
        case .available: "Tap to show"
        case .switching: "Switching…"
        case .locked: "Not available"
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
