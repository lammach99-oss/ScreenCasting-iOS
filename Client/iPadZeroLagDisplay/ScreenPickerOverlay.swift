import SwiftUI

/// Floating screen picker over a mirrored PC screen: which PC screen the iPad shows, and whether it may
/// control it. Shown only while mirroring a physical monitor. Touches on the pill and panel stay on the iPad.
struct ScreenPickerOverlay: View {
    @ObservedObject var networkManager: NetworkManager

    @State private var isOpen = false
    @State private var switchingTo: UInt64?
    @State private var failedFrom: String?
    @State private var permissionAsked = false
    @State private var lastInteraction = Date()
    @State private var dragOffset: CGFloat = 0
    @AppStorage("ScreenCasting.client.screenPickerOffset") private var storedOffset: Double = 0

    private var snapshot: ScreenPickerSnapshot {
        .make(catalogue: networkManager.mirrorMonitorCatalogue, state: networkManager.mirrorControlState,
              switchingTo: switchingTo, switchPending: networkManager.mirrorMonitorSwitchPending,
              pickerSupported: networkManager.mirrorScreenPickerSupported, permissionAsked: permissionAsked)
    }

    var body: some View {
        if networkManager.mirrorControlState?.geometry != nil {
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    if isOpen {
                        // Tapping outside closes the panel; while it is open nothing reaches the PC.
                        Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { close() }
                    }
                    VStack(spacing: 10) {
                        // Dims after a few idle seconds so it stays out of the way of the PC picture.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            pill(maxX: proxy.size.width)
                                .opacity(isOpen || context.date.timeIntervalSince(lastInteraction) < 3 ? 1 : 0.45)
                                .animation(.easeOut(duration: 0.4), value: context.date.timeIntervalSince(lastInteraction) < 3)
                        }
                        if isOpen { panel.transition(.opacity.combined(with: .move(edge: .top))) }
                    }
                    .offset(x: clampedOffset(width: proxy.size.width))
                    .padding(.top, 12)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
            .onChange(of: networkManager.mirrorMonitorCatalogue) { _, catalogue in settle(catalogue) }
            .onChange(of: networkManager.mirrorMonitorSwitchPending) { _, pending in if !pending { settle(networkManager.mirrorMonitorCatalogue) } }
            .onChange(of: networkManager.mirrorMonitorCatalogue?.allowed) { _, allowed in if allowed == true { permissionAsked = false } }
        }
    }

    // MARK: Pill

    private func pill(maxX: CGFloat) -> some View {
        let s = snapshot
        return Button {
            isOpen ? close() : open()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: s.tiles.first(where: { $0.status == .showing })?.isBuiltIn == true ? "laptopcomputer" : "display")
                    .font(.system(size: 14, weight: .semibold))
                Text(s.currentLabel ?? "Screens")
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1).frame(maxWidth: 220)
                Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: 14)
                controlBadge(s.control, compact: true)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 180 : 0)).foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark)
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .gesture(DragGesture(minimumDistance: 8)
            .onChanged { dragOffset = $0.translation.width; lastInteraction = Date() }
            .onEnded { value in
                storedOffset = Double(clamp(CGFloat(storedOffset) + value.translation.width, width: maxX))
                dragOffset = 0
            })
        .accessibilityLabel("Screens. Showing \(s.currentLabel ?? "PC screen"). \(controlText(s.control))")
        .accessibilityHint("Opens the list of PC screens")
    }

    // MARK: Panel

    private var panel: some View {
        let s = snapshot
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Screens on this PC").font(.system(size: 15, weight: .semibold))
                Spacer()
                if s.phase == .ready && !s.isSwitching {
                    Text("Tap a screen to show it").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
            }
            if s.phase == .locked { lockedBanner(s) }
            if let failedFrom {
                Text("Couldn't switch. Still showing \(failedFrom).")
                    .font(.system(size: 13)).foregroundStyle(Color(red: 0.94, green: 0.63, blue: 0.6))
            }
            if s.phase == .loading {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(s.isSwitching || switchingTo != nil ? "Switching…" : "Screens appear once the picture is showing.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                    ForEach(s.tiles) { tile in tileView(tile) }
                }
            }
            if s.control != .unavailable {
                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                HStack {
                    controlBadge(s.control, compact: false)
                    Spacer()
                    Button(s.control == .on ? "Stop control" : "Ask for control") {
                        lastInteraction = Date()
                        if s.control == .on { networkManager.releaseMirrorControl() } else { networkManager.requestMirrorControl() }
                    }
                    .buttonStyle(.bordered).tint(.white).controlSize(.small)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(width: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { lastInteraction = Date() }
    }

    private func lockedBanner(_ s: ScreenPickerSnapshot) -> some View {
        let amber = Color(red: 0.9, green: 0.75, blue: 0.5)
        return HStack(spacing: 10) {
            Image(systemName: "lock").foregroundStyle(amber)
            Text(permissionAsked ? "Asked. Tick \"Allow paired iPad to switch monitors\" on the PC."
                 : networkManager.mirrorScreenPickerSupported ? "Switching is off on the PC."
                 : "Turn on monitor switching on the PC.")
                .font(.system(size: 13)).foregroundStyle(amber)
            Spacer(minLength: 4)
            if s.canAskPermission {
                Button("Ask PC to allow") {
                    permissionAsked = true; lastInteraction = Date()
                    networkManager.requestMirrorSwitchPermission()
                }
                .buttonStyle(.bordered).tint(amber).controlSize(.small)
            }
        }
        .padding(10)
        .background(amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func tileView(_ tile: ScreenPickerTile) -> some View {
        let selected = tile.status == .showing
        return Button {
            guard tile.status == .available, let catalogue = networkManager.mirrorMonitorCatalogue else { return }
            failedFrom = nil; switchingTo = tile.id; lastInteraction = Date()
            networkManager.requestMirrorMonitor(tile.id, catalogue: catalogue)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: tile.isBuiltIn ? "laptopcomputer" : "display").font(.system(size: 24, weight: .regular))
                Text(tile.label).font(.system(size: 14, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if tile.status == .switching { ProgressView().controlSize(.mini).tint(.white) }
                    Text(statusText(tile.status)).font(.system(size: 12))
                        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .padding(12)
            .background(Color.white.opacity(selected ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(selected ? 0.85 : 0.14), lineWidth: selected ? 2 : 1))
            .opacity(tile.status == .locked ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(tile.status != .available)
        .accessibilityLabel("\(tile.label), \(statusText(tile.status))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func controlBadge(_ control: ScreenPickerSnapshot.Control, compact: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: control == .on ? "hand.point.up.left" : "eye")
            Text(compact ? (control == .on ? "Control on" : "View only") : controlText(control))
        }
        .font(.system(size: compact ? 13 : 14, weight: compact ? .semibold : .regular))
        .foregroundStyle(control == .on ? Color(red: 0.53, green: 0.82, blue: 0.64) : Color.white.opacity(0.75))
    }

    // MARK: Behavior

    private func open() {
        isOpen = true; failedFrom = nil; lastInteraction = Date()
        networkManager.refreshMirrorScreens()
    }

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
