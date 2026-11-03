import SwiftUI
import UIKit

/// Neutral ink shared with the Host Control Panel; one accent per meaning (control, problem, disconnect).
enum SessionInk {
    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    static let surface = rgb(0x171717)
    static let raised = rgb(0x262625)
    static let hairline = rgb(0x3A3A38)
    static let text = rgb(0xEDEDED)
    static let secondary = rgb(0xA3A3A0)
    static let positive = rgb(0x97C459)
    static let warning = rgb(0xFAC775)
    static let danger = rgb(0xF09595)
    static let dangerFill = rgb(0xE24B4A)
    static let onDanger = rgb(0x1F0A0A)
}

private extension Color {
    init(ink: UIColor) { self.init(uiColor: ink) }
}

/// The one visible handle in every session. The pill names the PC (or mirrored screen), the link and control;
/// the panel holds Screens, Keyboard, control, Files, Settings and Disconnect. Touches on it stay on the iPad.
struct SessionPanelOverlay: View {
    @ObservedObject var networkManager: NetworkManager
    let hostLabel: String
    @Binding var isOpen: Bool
    let onFiles: () -> Void
    let onSettings: () -> Void

    @State private var switchingTo: UInt64?
    @State private var failedFrom: String?
    @State private var permissionAsked = false
    @State private var lastInteraction = Date()
    @State private var dragOffset: CGFloat = 0
    @State private var disconnectArming = DisconnectArming()
    @State private var disconnectTick = 0
    @AppStorage("ScreenCasting.client.screenPickerOffset") private var storedOffset: Double = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    private var picker: ScreenPickerSnapshot {
        .make(catalogue: networkManager.mirrorMonitorCatalogue, state: networkManager.mirrorControlState,
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
                    // Dims after a few idle seconds so it stays out of the way of the PC picture.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let recent = context.date.timeIntervalSince(lastInteraction) < 3
                        // Control on keeps the pill legible: it says touches now drive the PC.
                        pill(maxX: proxy.size.width)
                            .opacity(isOpen || recent || session.reconnecting ? 1 : session.control == .on ? 0.75 : 0.45)
                            .animation(.easeOut(duration: 0.4), value: recent)
                    }
                    if isOpen {
                        panel(width: min(440, proxy.size.width - 24), maxHeight: max(160, proxy.size.height - 102))
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .offset(x: clampedOffset(width: proxy.size.width))
                .padding(.top, 12)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .onChange(of: isOpen) { _, open in
            lastInteraction = Date()
            disconnectArming.reset()
            if open { failedFrom = nil; networkManager.refreshMirrorScreens() }
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
                    Image(systemName: icon(s.icon))
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
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .gesture(DragGesture(minimumDistance: 8)
            .onChanged { dragOffset = $0.translation.width; lastInteraction = Date() }
            .onEnded { value in
                storedOffset = Double(clamp(CGFloat(storedOffset) + value.translation.width, width: maxX))
                dragOffset = 0
            })
        .accessibilityLabel(s.reconnecting ? s.reconnectingText
            : "\(s.title)\(s.transport.map { ", \($0)" } ?? "")\(s.isMirror ? ". \(controlText(s.control))" : "")")
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .accessibilityHint("Opens screens, keyboard, files, settings and disconnect")
    }

    // MARK: Panel

    private func panel(width: CGFloat, maxHeight: CGFloat) -> some View {
        let s = session
        let p = picker
        let middle = VStack(alignment: .leading, spacing: 14) {
            if s.isMirror { screens(p) }
            actions(s)
        }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(s.hostLabel).font(.headline)
                Spacer()
                if let transport = s.transport {
                    Text(transport).font(.footnote).foregroundStyle(Color(ink: SessionInk.secondary))
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
        .frame(maxHeight: maxHeight)
        .background(Color(ink: SessionInk.surface).opacity(0.97), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color(ink: SessionInk.hairline), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { lastInteraction = Date() }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { close() }
    }

    @ViewBuilder
    private func screens(_ p: ScreenPickerSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Screens on this PC").font(.footnote).foregroundStyle(Color(ink: SessionInk.secondary))
            Spacer()
            if p.phase == .ready && !p.isSwitching {
                Text("Tap a screen to show it").font(.caption).foregroundStyle(Color(ink: SessionInk.secondary))
            }
        }
        if p.phase == .locked { lockedBanner(p) }
        if let failedFrom {
            Text("Couldn't switch. Still showing \(failedFrom).")
                .font(.footnote).foregroundStyle(Color(ink: SessionInk.danger))
        }
        if p.phase == .loading && !networkManager.mirrorScreenPickerSupported && !p.isSwitching && switchingTo == nil {
            Text("This PC can't list its screens. Update ScreenCasting on the PC.")
                .font(.footnote).foregroundStyle(Color(ink: SessionInk.secondary))
        } else if p.phase == .loading {
            HStack(spacing: 10) {
                ProgressView().tint(Color(ink: SessionInk.text))
                Text(p.isSwitching || switchingTo != nil ? "Switching…" : "Screens appear once the picture is showing.")
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
            Text(permissionAsked ? "Asked. Tick \"Allow paired iPad to switch monitors\" on the PC."
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
            guard tile.status == .available, let catalogue = networkManager.mirrorMonitorCatalogue else { return }
            failedFrom = nil; switchingTo = tile.id; lastInteraction = Date()
            networkManager.requestMirrorMonitor(tile.id, catalogue: catalogue)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: tile.isBuiltIn ? "laptopcomputer" : "display").font(.title2)
                Text(tile.label).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if tile.status == .switching { ProgressView().controlSize(.mini).tint(Color(ink: SessionInk.text)) }
                    Text(statusText(tile.status)).font(.caption)
                        .foregroundStyle(Color(ink: selected ? SessionInk.text : SessionInk.secondary))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .padding(12)
            .background(Color(ink: selected ? SessionInk.raised : SessionInk.surface),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(ink: selected ? SessionInk.text : SessionInk.hairline), lineWidth: selected ? 1.5 : 0.5))
            .opacity(tile.status == .locked ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(tile.status != .available)
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
            if s.isMirror {
                actionButton(s.control == .on ? "Stop control" : "Ask control",
                             icon: s.control == .on ? "hand.raised.slash" : "hand.point.up.left") {
                    lastInteraction = Date()
                    if s.control == .on { networkManager.releaseMirrorControl() } else { networkManager.requestMirrorControl() }
                }
            }
            actionButton("Files", icon: "arrow.left.arrow.right") { close(); onFiles() }
            actionButton("Settings", icon: "gearshape") { close(); onSettings() }
        }
        return Group {
            if typeSize.isAccessibilitySize {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) { buttons }
            } else {
                HStack(spacing: 8) { buttons }
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(Color(ink: SessionInk.hairline)).frame(height: 0.5) }
    }

    private func actionButton(_ title: String, icon: String, enabled: Bool = true, hint: String? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.footnote).lineLimit(typeSize.isAccessibilitySize ? 2 : 1).minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color(ink: SessionInk.hairline), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
        .accessibilityHint(hint ?? "")
    }

    private func footer(_ s: SessionPanelSnapshot) -> some View {
        let armed = disconnectTick >= 0 && disconnectArming.isArmed(at: Date())
        let tip = Text(armed ? "Disconnect from \(s.hostLabel)?" : "3-finger tap opens this panel")
            .font(.caption)
            .foregroundStyle(Color(ink: armed ? SessionInk.danger : SessionInk.secondary))
        let button = Button {
            lastInteraction = Date()
            if disconnectArming.tap(at: Date()) {
                close()
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
