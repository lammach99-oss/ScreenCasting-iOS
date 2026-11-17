import Foundation
import SwiftUI
import UIKit

enum IPadTouchMode: String { case direct, trackpad }
enum IPadModifier: CaseIterable { case control, alt, shift, win }
enum IPadModifierState { case off, oneShot, locked }
enum IPadDragState { case idle, armed, latched }
enum IPadPointerButton { case left, right, middle }
enum IPadNudgeDirection { case up, down, left, right }

/// One scene owns one session. The transport closure is replaced only AFTER retirement.
@MainActor final class IPadInputSession: ObservableObject {
    @Published private(set) var canPoint: Bool = false
    @Published private(set) var canType: Bool = false
    @Published private(set) var canDirect: Bool = false
    @Published private(set) var unavailableReason: String?
    @Published private(set) var touchMode: IPadTouchMode
    @Published private(set) var dragState: IPadDragState = .idle
    @Published private(set) var scrollInertiaEnabled: Bool
    @Published private(set) var reverseScrollEnabled: Bool
    @Published private(set) var accessibleTarget: CGPoint = CGPoint(x: 0.5, y: 0.5)
    let engine: IPadInputEngine
    var requestSoftwareKeyboard: (() -> Void)?
    var retireQueuedInput: (() -> Void)?
    var clearTextHistory: (() -> Void)?
    private let automaticallyTicks: Bool
    private let defaults: UserDefaults
    var sourceSize: CGSize?
    var trackpadAvailable = true
    var accessibleLegacyPoint = CGPoint(x: 0.5, y: 0.5)
    private var identity: String?
    private var modifiers: [IPadModifier: IPadModifierState] = [:]
    private var sink: ((IPadInputEvent) -> Void)?
    private var tickTimer: Timer?
    static let touchModeKey = "ScreenCasting.client.input.touchMode.v2"
    static let inertiaKey = "ScreenCasting.client.input.scrollInertia.v1"
    static let reverseKey = "ScreenCasting.client.input.reverseScroll.v1"

    init(defaults: UserDefaults = .standard, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, automaticallyTicks: Bool = true) {
        self.defaults = defaults; self.automaticallyTicks = automaticallyTicks
        if let raw = defaults.string(forKey: Self.touchModeKey), let mode = IPadTouchMode(rawValue: raw) {
            touchMode = mode
        } else if defaults.object(forKey: RemoteMouseModeStore.key) != nil {
            touchMode = RemoteMouseModeStore.load(defaults: defaults).resolved(for: .finger) == .direct ? .direct : .trackpad
        } else { touchMode = .direct }
        scrollInertiaEnabled = defaults.object(forKey: Self.inertiaKey) as? Bool ?? true
        reverseScrollEnabled = defaults.bool(forKey: Self.reverseKey)
        engine = IPadInputEngine(clock: clock)
        engine.mode = touchMode; engine.inertiaEnabled = scrollInertiaEnabled; engine.reverseScroll = reverseScrollEnabled
        engine.emit = { [weak self] event in self?.sink?(event) }
        engine.consumedModifier = { [weak self] m in
            self?.objectWillChange.send(); self?.modifiers[m] = .off
        }
        engine.changed = { [weak self] in
            guard let self else { return }
            if self.dragState != self.engine.drag { self.dragState = self.engine.drag }
        }
    }

    /// Tests drive engine.tick directly. Production uses a single main-run-loop ticker.
    func configure(identity: String, point: Bool, type: Bool, direct: Bool, zoom: Bool,
                   reason: String?, sink: @escaping (IPadInputEvent) -> Void) {
        let replacingScope = self.identity != identity
        if replacingScope || (canPoint && !point) || (canType && !type) {
            releaseAll()
        }
        if replacingScope {
            accessibleLegacyPoint = CGPoint(x: 0.5,y: 0.5)
            if accessibleTarget != accessibleLegacyPoint { accessibleTarget = accessibleLegacyPoint }
        }
        self.identity = identity; self.sink = sink
        if canPoint != point { canPoint = point }
        if canType != type { canType = type }
        if canDirect != direct { canDirect = direct }
        let nextReason = reason ?? (touchMode == .direct && !direct ? "Direct touch requires an updated PC host" : nil)
        if unavailableReason != nextReason { unavailableReason = nextReason }
        engine.enabled = point && (touchMode == .direct || trackpadAvailable); engine.directAvailable = direct; engine.zoomAvailable = zoom
        engine.typeEnabled = type
        if automaticallyTicks && (point || type), tickTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { timer.invalidate(); return }; self.engine.tick()
                }
            }
            RunLoop.main.add(timer,forMode: .common); tickTimer = timer
        } else if !point && !type { tickTimer?.invalidate(); tickTimer = nil }
    }

    func modifierState(_ modifier: IPadModifier) -> IPadModifierState { modifiers[modifier] ?? .off }
    func setModifier(_ modifier: IPadModifier, _ state: IPadModifierState) {
        objectWillChange.send()
        modifiers[modifier] = state
        engine.setModifier(modifier, state)
    }
    func selectTouchMode(_ mode: IPadTouchMode) {
        guard touchMode != mode else { return }
        guard mode != .trackpad || trackpadAvailable else {
            unavailableReason = "Trackpad requires an updated PC host"; return
        }
        releaseAll(); touchMode = mode; engine.mode = mode
        defaults.set(mode.rawValue, forKey: Self.touchModeKey)
        unavailableReason = mode == .direct && !canDirect ? "Direct touch requires an updated PC host" : nil
    }
    func setScrollInertia(_ enabled: Bool) {
        scrollInertiaEnabled = enabled; engine.inertiaEnabled = enabled
        engine.cancelInertia(); defaults.set(enabled, forKey: Self.inertiaKey)
    }
    func setReverseScroll(_ enabled: Bool) {
        reverseScrollEnabled = enabled; engine.reverseScroll = enabled
        engine.cancelInertia(); defaults.set(enabled, forKey: Self.reverseKey)
    }
    func click(_ button: IPadPointerButton) {
        guard canPoint else { return }; clearTextHistory?()
        engine.withoutCommandRestoration {
            engine.click(button == .left ? 1 : button == .right ? 2 : 3, at: accessibleTarget)
        }
    }
    func beginDrag() {
        guard canPoint, touchMode != .direct || canDirect else { return }; clearTextHistory?()
        engine.withoutCommandRestoration { engine.armDrag() }
    }
    func releaseDrag() { engine.releaseDrag() }
    /// Panel controls keep their own authority; only physical surface typing is fenced.
    func panelPresentationChanged(_ open: Bool, surfaceActive: Bool = true) {
        engine.setHardwareCaptureEnabled(!open && surfaceActive)
        if open { releaseAll() }
    }
    func releaseAll() {
        tickTimer?.invalidate(); tickTimer = nil
        clearTextHistory?(); retireQueuedInput?(); engine.retire()
        objectWillChange.send(); modifiers.removeAll(); dragState = .idle
    }
    func tapKey(hidUsage: UInt16) {
        guard canType else { return }; clearTextHistory?()
        engine.withoutCommandRestoration { engine.tapKey(hidUsage) }
    }
    func tapWindowsShortcut(hidUsage: UInt16, shift: Bool) {
        guard canType else { return }; clearTextHistory?()
        engine.withoutCommandRestoration { engine.shortcut(hidUsage, shift: shift) }
    }
    func moveAccessibleTarget(_ direction: IPadNudgeDirection, coarse: Bool) {
        guard canPoint else { return }; clearTextHistory?()
        let step: CGFloat = coarse ? 0.05 : 0.005
        switch direction {
        case .up: accessibleTarget.y -= step
        case .down: accessibleTarget.y += step
        case .left: accessibleTarget.x -= step
        case .right: accessibleTarget.x += step
        }
        accessibleTarget.x = min(1, max(0, accessibleTarget.x)); accessibleTarget.y = min(1, max(0, accessibleTarget.y))
        engine.withoutCommandRestoration { engine.accessibleMove(to: accessibleTarget) }
    }
    func showSoftwareKeyboard() { guard canType else { return }; requestSoftwareKeyboard?() }
    static func preview() -> IPadInputSession { IPadInputSession(automaticallyTicks: false) }
}
