import SwiftUI
import MetalKit
import UIKit
import GameController

/// Resolves the size that both UIKit presentation surfaces receive from their
/// shared SwiftUI container. An incomplete proposal must stay incomplete: the
/// old 10-point fallback from `replacingUnspecifiedDimensions()` could shrink a
/// representable before the fullscreen container finished its layout.
enum FullscreenSurfaceLayout {
    static func exactSize(width: CGFloat?, height: CGFloat?) -> CGSize? {
        guard let width, let height, width >= 0, height >= 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    static func edgeToEdgeFrame(
        proposedBounds: CGRect,
        safeAreaInsets _: EdgeInsets
    ) -> CGRect {
        // The GeometryReader is already outside the safe area. UIKit may
        // continue reporting non-zero insets for system gestures; adding
        // those values again enlarges the Metal/touch container beyond the
        // actual window and changes its aspect ratio.
        proposedBounds
    }
}

public struct PresentationSurfaceGeometry: Equatable {
    let screenBounds: CGRect
    let windowBounds: CGRect
    let rootBounds: CGRect
    let streamContainerBounds: CGRect
    let metalBounds: CGRect
    let touchBounds: CGRect
    let safeAreaInsets: UIEdgeInsets
}

public struct MetalView: UIViewRepresentable {
    @ObservedObject var networkManager: NetworkManager
    public var onFrameRendered: (() -> Void)?
    public var onContentViewportChanged: ((VideoContentViewport?) -> Void)?
    var onGeometrySnapshotChanged: ((RendererGeometrySnapshot) -> Void)?

    public init(
        networkManager: NetworkManager,
        onFrameRendered: (() -> Void)? = nil,
        onContentViewportChanged: ((VideoContentViewport?) -> Void)? = nil,
        onGeometrySnapshotChanged: ((RendererGeometrySnapshot) -> Void)? = nil
    ) {
        self.networkManager = networkManager
        self.onFrameRendered = onFrameRendered
        self.onContentViewportChanged = onContentViewportChanged
        self.onGeometrySnapshotChanged = onGeometrySnapshotChanged
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            onFrameRendered: onFrameRendered,
            onContentViewportChanged: onContentViewportChanged,
            onGeometrySnapshotChanged: onGeometrySnapshotChanged)
    }

    public func makeUIView(context: Context) -> MTKView {
        let metalView = MTKView()
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        if let renderer = Renderer(metalView: metalView) {
            context.coordinator.renderer = renderer
            renderer.diagnosticSink = { [weak networkManager] line in
                networkManager?.recordDiagnosticLine(line)
            }
            renderer.beginSession(
                generation: networkManager.decoder.currentSessionGeneration)
            renderer.onFrameRendered = { [weak coordinator = context.coordinator, weak networkManager] sequence, generation in
                networkManager?.recordRenderCompletion(
                    sequence: sequence,
                    generation: generation)
                coordinator?.onFrameRendered?()
            }
            renderer.onDrawableCommitted = { [weak networkManager] sequence, generation in
                networkManager?.recordDrawableCommitted(
                    sequence: sequence,
                    generation: generation)
            }
            renderer.onFrameDropped = {
                [weak networkManager] sequence, generation in
                networkManager?.recordRenderDrop(
                    sequence: sequence,
                    generation: generation)
            }
            renderer.onContentViewportChanged = { [weak coordinator = context.coordinator] viewport in
                coordinator?.onContentViewportChanged?(viewport)
            }
            renderer.onGeometrySnapshotChanged = { [weak coordinator = context.coordinator] snapshot in
                coordinator?.onGeometrySnapshotChanged?(snapshot)
            }

            // Connect VideoToolbox Decoded PixelBuffers directly into Metal Renderer
            networkManager.decoder.onSessionBegan = { [weak renderer] generation in
                renderer?.beginSession(generation: generation)
            }
            networkManager.decoder.onFrameDecoded = {
                [weak renderer] pixelBuffer, sequence, generation in
                renderer?.updateFrame(
                    pixelBuffer,
                    sequence: sequence,
                    generation: generation)
            }
        }

        return metalView
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MTKView,
        context: Context
    ) -> CGSize? {
        FullscreenSurfaceLayout.exactSize(
            width: proposal.width,
            height: proposal.height)
    }

    public func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.onFrameRendered = onFrameRendered
        context.coordinator.onContentViewportChanged = onContentViewportChanged
        context.coordinator.onGeometrySnapshotChanged = onGeometrySnapshotChanged

        // MTKView owns its drawable lifetime. Keep automatic resizing enabled
        // and give it the screen scale once it has a window; this keeps its
        // bounds and drawable size aligned with the shared fullscreen rect.
        uiView.autoResizeDrawable = true
        if let screen = uiView.window?.screen {
            uiView.contentScaleFactor = screen.scale
        }
    }

    public class Coordinator {
        var renderer: Renderer?
        var onFrameRendered: (() -> Void)?
        var onContentViewportChanged: ((VideoContentViewport?) -> Void)?
        var onGeometrySnapshotChanged: ((RendererGeometrySnapshot) -> Void)?

        init(
            onFrameRendered: (() -> Void)?,
            onContentViewportChanged: ((VideoContentViewport?) -> Void)?,
            onGeometrySnapshotChanged: ((RendererGeometrySnapshot) -> Void)?
        ) {
            self.onFrameRendered = onFrameRendered
            self.onContentViewportChanged = onContentViewportChanged
            self.onGeometrySnapshotChanged = onGeometrySnapshotChanged
        }
    }
}

/// One UIKit container for the two surfaces that make up a connected stream.
/// SwiftUI previously hosted each representable independently. They shared a
/// proposed frame, but not an actual UIKit layout contract. Pinning both views
/// to this container removes that ambiguity while retaining the existing Metal
/// renderer, decoder callbacks, and Pencil touch implementation.
enum FloatingKeyboardPlacement {
    static let fadeSeconds = 3
    static let dimOpacity: CGFloat = 0.30
    static func frame(bounds: CGRect, safeArea: UIEdgeInsets, keyboard: CGRect?) -> CGRect {
        let margin: CGFloat = 12
        var frame = CGRect(x: max(bounds.minX + safeArea.left, bounds.maxX - safeArea.right - margin - 48),
                           y: max(bounds.minY + safeArea.top, bounds.maxY - safeArea.bottom - margin - 48), width: 48, height: 48)
        if let keyboard, frame.intersects(keyboard) {
            frame.origin.y = max(bounds.minY + safeArea.top, keyboard.minY - margin - 48)
        }
        return frame
    }
}
/// What tapped the floating keyboard button; iPadOS treats a Pencil tap as handwriting intent.
extension Notification.Name {
    /// The session panel's Keyboard button; the presentation container owns the keyboard responder.
    static let sessionPanelToggleKeyboard = Notification.Name("ScreenCasting.sessionPanelToggleKeyboard")
}

enum KeyboardTapSource: String {
    case pencil, finger, pointer, panel, unknown
    init(touchType: UITouch.TouchType?) {
        switch touchType {
        case .some(.pencil): self = .pencil
        case .some(.direct): self = .finger
        case .some(.indirectPointer): self = .pointer
        default: self = .unknown
        }
    }
}

/// Explains a keyboard that iPadOS withheld; sits above the keyboard button and takes no touches.
final class KeyboardHintLabel: UILabel {
    static let pencilText = "Apple Pencil is set for handwriting, so iPad hid the keyboard. " +
        "Tap the keyboard button with your finger, or turn off Scribble in Settings › Apple Pencil."
    private let insets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false
        numberOfLines = 0
        font = .preferredFont(forTextStyle: .footnote)
        adjustsFontForContentSizeCategory = true
        textColor = SessionInk.text
        backgroundColor = SessionInk.surface.withAlphaComponent(0.96)
        layer.borderColor = SessionInk.hairline.cgColor
        layer.borderWidth = 0.5
        layer.cornerRadius = 12
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { nil }
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let inner = super.sizeThatFits(CGSize(width: size.width - insets.left - insets.right, height: size.height))
        return CGSize(width: inner.width + insets.left + insets.right, height: inner.height + insets.top + insets.bottom)
    }
    func frame(above button: CGRect, bounds: CGRect, safeArea: UIEdgeInsets) -> CGRect {
        let margin: CGFloat = 12
        let size = sizeThatFits(CGSize(width: max(120, min(360, bounds.width - 2 * margin)), height: .greatestFiniteMagnitude))
        return CGRect(x: max(bounds.minX + safeArea.left + margin, button.maxX - size.width),
                      y: max(bounds.minY + safeArea.top + margin, button.minY - 8 - size.height),
                      width: size.width, height: size.height)
    }
}

@MainActor final class HardwareKeyboardMonitor {
    private(set) var isConnected = false
    private let candidatePresence: () -> Bool
    var onChanged: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    init(candidatePresence: @escaping () -> Bool = { GCKeyboard.coalesced != nil }) {
        self.candidatePresence = candidatePresence
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(disconnected: name == .GCKeyboardDidDisconnect) }
            })
        }
    }
    func refresh(disconnected: Bool = false) {
        // Candidate presence (including the observed Pencil false-positive) is not authority.
        guard isConnected && (disconnected || !candidatePresence()) else { return }
        isConnected = false; onChanged?(false)
    }
    func recordKeyActivity() {
        guard !isConnected else { return }
        isConnected = true; onChanged?(true)
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

struct ClientCursorState {
    private(set) var normalizedPosition = CGPoint(x: 0.5, y: 0.5)
    private(set) var ownership: CursorOwnershipState?
    private(set) var generation: UInt64?
    mutating func configure(ownership: CursorOwnershipState?, generation: UInt64) {
        if self.generation != generation {
            self.generation = generation
            normalizedPosition = CGPoint(x: 0.5, y: 0.5)
        }
        self.ownership = ownership
    }
    mutating func update(_ point: CGPoint) {
        normalizedPosition = CGPoint(x: max(0, min(1, point.x)), y: max(0, min(1, point.y)))
    }
    var visible: Bool { ownership == .clientActive }
}

public final class ConnectedPresentationContainer: UIView {
    let metalView = MTKView()
    let touchView = PencilUIKitView()
    let softwareTextView = RemoteSoftwareKeyboardTextView(frame: .zero, textContainer: nil)
    private var clientCursor = ClientCursorState()
    let keyboardButton = UIButton(type: .system)
    let keyboardHintLabel = KeyboardHintLabel()
    /// iPadOS keeps the keyboard hidden while it expects Pencil handwriting (Scribble).
    var pencilInputExpected: @MainActor () -> Bool = { UIScribbleInteraction.isPencilInputExpected }
    var keyboardWithheldDelay: TimeInterval = 0.6
    private(set) var softwareKeyboardWithheld = false
    private static let maximumWithheldRetries = 2
    private var withheldRetries = 0
    private var withheldCheckTask: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    private var lastKeyboardTapSource = KeyboardTapSource.unknown
    private let hardwareMonitor = HardwareKeyboardMonitor()
    private var keyboardObservers: [NSObjectProtocol] = []
    private var fadeTask: Task<Void, Never>?
    private var keyboardFrame: CGRect?
    private(set) var keyboardMode: RemoteKeyboardMode = .none
    private var keyboardActive = false
    private var softwareRequested = false
   private var softwareNativeVisible = false
   private var softwareNativeSuppressed = false
   private var softwareShowAttempts = 0
   private var softwareKeyboardHideInProgress = false
   private var softwareKeyboardRecoveryAttemptedForHide = false
   private var softwareKeyboardRecoveryGeneration: UInt64?
   private var keyboardGeneration: UInt64?
   private var lastKeyboardAuthorityDiagnostic: String?
    private var lastSoftwareResponderResult: Bool?
    #if targetEnvironment(simulator)
    var softwareResponderAcquisitionForTesting: (() -> Bool)?
    #endif
    var onTextCommit: ((String) -> Void)?
    var onGeometryChanged: ((PresentationSurfaceGeometry) -> Void)?
    private var publishedGeometry: PresentationSurfaceGeometry?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        clipsToBounds = true
        softwareTextView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        addSubview(softwareTextView)
        keyboardButton.setImage(UIImage(systemName: "keyboard"), for: .normal)
        keyboardButton.backgroundColor = SessionInk.surface.withAlphaComponent(0.94)
        keyboardButton.tintColor = SessionInk.accent
        keyboardButton.layer.borderColor = SessionInk.hairline.cgColor
        keyboardButton.layer.borderWidth = 0.5
        keyboardButton.layer.cornerRadius = 12
        keyboardButton.accessibilityLabel = "Keyboard"
        keyboardButton.addTarget(self, action: #selector(toggleSoftwareKeyboard(_:forEvent:)), for: .touchUpInside)
        keyboardButton.isHidden = true
        softwareTextView.onEmission = { [weak self] emission in
            guard let self, self.keyboardMode == .softwareOpen, self.softwareTextView.deliveryEnabled else { return }
            switch emission {
            case .text(let text): self.onTextCommit?(text)
            case .key(let vk):
                self.touchView.onKeyboardInput?(KeyboardInputCommand(action: .keyDown, virtualKey: vk))
                self.touchView.onKeyboardInput?(KeyboardInputCommand(action: .keyUp, virtualKey: vk))
            }
        }
        softwareTextView.onDismiss = { [weak self] in
            guard let self, self.keyboardMode == .softwareOpen else { return }
            guard !self.preserveRequestedSoftwareKeyboard else { return }
            self.softwareRequested = false
            self.applyRemoteKeyboardMode(.softwareAvailable)
        }
        softwareTextView.preserveOnSystemResign = { [weak self] in
            self?.preserveRequestedSoftwareKeyboard == true
        }
        softwareTextView.onPreservedSystemResponderLoss = { [weak self] in
            self?.reconcileKeyboardResponderOwnershipAfterSoftwareShowAttempt(softwareResponderAcquired: false)
        }
        hardwareMonitor.onChanged = { [weak self] present in self?.hardwarePresenceChanged(present) }
        touchView.onHardwareKeyActivity = { [weak self] in self?.hardwareMonitor.recordKeyActivity() }
        softwareTextView.onHardwarePresses = { [weak self] presses, action in
            self?.touchView.unhandledHardwarePresses(presses, action: action) ?? presses
        }
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification,
                     UIResponder.keyboardDidHideNotification, UIResponder.keyboardDidShowNotification,
                     UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification] {
            keyboardObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.handleKeyboardNotification(note) }
            })
        }
        keyboardObservers.append(NotificationCenter.default.addObserver(forName: .sessionPanelToggleKeyboard, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.toggleSoftwareKeyboard(source: .panel) }
        })

        // The container owns the one runtime rectangle used by both surfaces.
        // Explicit edge constraints prevent UIKit from retaining a provisional
        // UIViewRepresentable size during fullscreen and rotation layout.
        metalView.translatesAutoresizingMaskIntoConstraints = false
        touchView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metalView)
        addSubview(touchView)
        // UIButton owns only its 48pt target, above the unchanged remote touch surface.
        bringSubviewToFront(softwareTextView)
        addSubview(keyboardButton)
        addSubview(keyboardHintLabel)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            touchView.leadingAnchor.constraint(equalTo: leadingAnchor),
            touchView.trailingAnchor.constraint(equalTo: trailingAnchor),
            touchView.topAnchor.constraint(equalTo: topAnchor),
            touchView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { retireRemotePointerInputs(); retireRemoteKeyboard() }
        else { hardwareMonitor.refresh(); updateKeyboardAuthority() }
        setNeedsLayout()
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        keyboardButton.frame = FloatingKeyboardPlacement.frame(bounds: bounds, safeArea: safeAreaInsets, keyboard: keyboardFrame)
        if !keyboardHintLabel.isHidden {
            keyboardHintLabel.frame = keyboardHintLabel.frame(above: keyboardButton.frame, bounds: bounds, safeArea: safeAreaInsets)
        }

        let scale = window?.screen.scale ?? traitCollection.displayScale
        guard scale > 0 else { return }

        metalView.contentScaleFactor = scale
        metalView.drawableSize = CGSize(
            width: metalView.bounds.width * scale,
            height: metalView.bounds.height * scale)

        let geometry = PresentationSurfaceGeometry(
            screenBounds: window?.screen.bounds ?? .zero,
            windowBounds: window?.bounds ?? .zero,
            rootBounds: window?.rootViewController?.view.bounds ?? .zero,
            streamContainerBounds: bounds,
            metalBounds: metalView.bounds,
            touchBounds: touchView.bounds,
            safeAreaInsets: window?.safeAreaInsets ?? safeAreaInsets)
        guard geometry != publishedGeometry else { return }
        publishedGeometry = geometry
        onGeometryChanged?(geometry)
    }
    func retireDirectPointer() {
        touchView.configureDirectTouch(active: false, generation: keyboardGeneration ?? 0)
    }

    func retireRemotePointerInputs() {
        retireDirectPointer()
        touchView.configureExternalPointer(active: false, generation: keyboardGeneration ?? 0)
    }

    func configureClientCursor(ownership: CursorOwnershipState?, generation: UInt64, active: Bool) {
        clientCursor.configure(ownership: ownership, generation: generation)
    }

    func retireRemoteKeyboard() {
        keyboardActive = false
        softwareRequested = false
        applyRemoteKeyboardMode(.none)
    }
   func configureRemoteKeyboard(active: Bool, generation: UInt64) {
       if keyboardGeneration != generation {
           softwareNativeVisible = false
           softwareNativeSuppressed = false
           softwareShowAttempts = 0
           softwareKeyboardHideInProgress = false
           softwareKeyboardRecoveryAttemptedForHide = false
           softwareKeyboardRecoveryGeneration = generation
           softwareRequested = false
           applyRemoteKeyboardMode(.none)
           keyboardGeneration = generation
       }
        keyboardActive = active
        if !active { softwareRequested = false }
        hardwareMonitor.refresh()
        updateKeyboardAuthority()
    }
    func hardwarePresenceChanged(_ present: Bool) {
        applyRemoteKeyboardMode(RemoteKeyboardMode.resolve(active: keyboardActive && UIApplication.shared.applicationState == .active, hardware: present, requested: softwareRequested))
    }
    private func updateKeyboardAuthority() {
        let active = keyboardActive && UIApplication.shared.applicationState == .active
        applyRemoteKeyboardMode(RemoteKeyboardMode.resolve(active: active, hardware: hardwareMonitor.isConnected, requested: softwareRequested))
    }
    func applyRemoteKeyboardMode(_ mode: RemoteKeyboardMode) {
        let previousMode = keyboardMode
        let changed = mode != keyboardMode
        // Update authority before callbacks caused by responder loss.
        keyboardMode = mode
        if mode == .softwareOpen { softwareRequested = true }
        if mode != .softwareOpen {
            softwareKeyboardHideInProgress = false
            softwareKeyboardRecoveryAttemptedForHide = false
            softwareNativeVisible = false
            softwareNativeSuppressed = false
            softwareRequested = false
            keyboardFrame = nil
            softwareTextView.deactivateAndDiscardComposition()
            clearSoftwareKeyboardWithheld()
            setNeedsLayout()
        }
        keyboardButton.isHidden = mode == .none
        touchView.hardwareKeyActivityEnabled = mode != .none
        touchView.softwareResponderOwnsInput = mode == .softwareOpen && softwareTextView.isFirstResponder
        touchView.passiveKeyboardCaptureEnabled = mode == .softwareAvailable ||
            (mode == .softwareOpen && !touchView.softwareResponderOwnsInput)
        touchView.keyboardCaptureEnabled = mode == .hardware || (mode != .none && hardwareMonitor.isConnected)
        if mode == .softwareOpen {
            softwareTextView.deliveryEnabled = true
        }
        if changed {
            if keyboardButton.isHidden { fadeTask?.cancel(); fadeTask = nil }
            else { restartKeyboardFade() }
            recordKeyboardAuthority(reason: "mode_changed", previousMode: previousMode)
        }
    }
    fileprivate func recordKeyboardAuthority(reason: String, previousMode: RemoteKeyboardMode? = nil) {
        let line = "[KEYBOARD_AUTHORITY] reason=\(reason) gc_keyboard_present=\(GCKeyboard.coalesced != nil ? 1 : 0) hardware_monitor=\(hardwareMonitor.isConnected ? 1 : 0) keyboard_active=\(keyboardActive ? 1 : 0) software_requested=\(softwareRequested ? 1 : 0) native_keyboard_visible=\(softwareNativeVisible ? 1 : 0) native_keyboard_suppressed=\(softwareNativeSuppressed ? 1 : 0) keyboard_frame=\(keyboardFrame.map { String(describing: $0) } ?? "none") show_attempt=\(softwareShowAttempts) old_mode=\(previousMode ?? keyboardMode) new_mode=\(keyboardMode) software_first_responder=\(softwareTextView.isFirstResponder ? 1 : 0) responder_result=\(lastSoftwareResponderResult.map { $0 ? "success" : "failure" } ?? "not_attempted") keyboard_button_hidden=\(keyboardButton.isHidden ? 1 : 0) keyboard_tap=\(lastKeyboardTapSource.rawValue) pencil_expected=\(pencilInputExpected() ? 1 : 0) keyboard_withheld=\(softwareKeyboardWithheld ? 1 : 0)"
        guard line != lastKeyboardAuthorityDiagnostic else { return }
        lastKeyboardAuthorityDiagnostic = line
        touchView.diagnosticSink?(line)
    }
    @objc private func toggleSoftwareKeyboard(_ sender: UIButton, forEvent event: UIEvent?) {
        toggleSoftwareKeyboard(source: KeyboardTapSource(touchType: event?.allTouches?.first?.type))
    }
    private func toggleSoftwareKeyboard(source: KeyboardTapSource) {
        lastKeyboardTapSource = source
        guard keyboardMode != .none else {
            recordKeyboardAuthority(reason: "software_toggle_blocked")
            return
        }
        // A withheld keyboard was never seen, so the tap means "try again", not "close".
        if softwareRequested && softwareKeyboardWithheld && withheldRetries < Self.maximumWithheldRetries {
            withheldRetries += 1
            retryWithheldSoftwareKeyboard()
            restartKeyboardFade()
            return
        }
        softwareRequested = !softwareRequested
        softwareNativeSuppressed = false
       updateKeyboardAuthority()
       if softwareRequested {
           softwareShowAttempts += 1
           softwareKeyboardHideInProgress = false
           softwareKeyboardRecoveryAttemptedForHide = false
           softwareKeyboardRecoveryGeneration = keyboardGeneration
           softwareTextView.reloadInputViews()
           let acquired = acquireSoftwareKeyboardResponder()
            lastSoftwareResponderResult = acquired
            reconcileKeyboardResponderOwnershipAfterSoftwareShowAttempt(softwareResponderAcquired: acquired)
            recordKeyboardAuthority(reason: acquired ? "native_show_request" : "native_show_request_failed")
            if acquired { scheduleWithheldCheck() }
        }
        restartKeyboardFade()
    }
    private func retryWithheldSoftwareKeyboard() {
        softwareShowAttempts += 1
        softwareNativeSuppressed = false
        softwareKeyboardWithheld = false
        hideKeyboardHint()
        softwareTextView.reloadInputViews()
        let acquired = softwareTextView.isFirstResponder
            ? softwareTextView.recyclePreservingComposition { self.acquireSoftwareKeyboardResponder() }
            : acquireSoftwareKeyboardResponder()
        lastSoftwareResponderResult = acquired
        reconcileKeyboardResponderOwnershipAfterSoftwareShowAttempt(softwareResponderAcquired: acquired)
        recordKeyboardAuthority(reason: acquired ? "native_show_retry" : "native_show_retry_failed")
        if acquired { scheduleWithheldCheck() }
    }
    /// The responder was taken but iPadOS may still not show the keyboard; look again shortly.
    private func scheduleWithheldCheck() {
        withheldCheckTask?.cancel()
        let attempt = softwareShowAttempts
        let generation = keyboardGeneration
        let delay = UInt64(max(0, keyboardWithheldDelay) * 1_000_000_000)
        withheldCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, self.softwareShowAttempts == attempt,
                  self.keyboardGeneration == generation, self.keyboardMode == .softwareOpen,
                  self.softwareRequested, !self.softwareNativeVisible else { return }
            if self.pencilInputExpected() || self.lastKeyboardTapSource == .pencil {
                self.softwareKeyboardWithheld = true
                self.showKeyboardHint(KeyboardHintLabel.pencilText)
            }
            self.recordKeyboardAuthority(reason: "native_keyboard_withheld")
        }
    }
    private func showKeyboardHint(_ text: String) {
        keyboardHintLabel.text = text
        keyboardHintLabel.isHidden = false
        setNeedsLayout()
        UIAccessibility.post(notification: .announcement, argument: text)
        hintTask?.cancel()
        hintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.hideKeyboardHint()
        }
    }
    private func hideKeyboardHint() {
        hintTask?.cancel(); hintTask = nil
        keyboardHintLabel.isHidden = true
    }
    private func clearSoftwareKeyboardWithheld() {
        withheldCheckTask?.cancel(); withheldCheckTask = nil
        softwareKeyboardWithheld = false
        withheldRetries = 0
        hideKeyboardHint()
    }
    private func acquireSoftwareKeyboardResponder() -> Bool {
        #if targetEnvironment(simulator)
        if let attempt = softwareResponderAcquisitionForTesting { return attempt() }
        #endif
        return softwareTextView.isFirstResponder ||
            (window != nil && softwareTextView.becomeFirstResponder())
    }
    private func reconcileKeyboardResponderOwnershipAfterSoftwareShowAttempt(softwareResponderAcquired: Bool) {
        touchView.softwareResponderOwnsInput = keyboardMode == .softwareOpen && softwareResponderAcquired
        touchView.passiveKeyboardCaptureEnabled = keyboardMode == .softwareAvailable ||
            (keyboardMode == .softwareOpen && !softwareResponderAcquired)
        if !softwareResponderAcquired { softwareNativeVisible = false }
    }
    private func restartKeyboardFade() {
        fadeTask?.cancel()
        keyboardButton.alpha = 1
        fadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.keyboardButton.alpha = FloatingKeyboardPlacement.dimOpacity
        }
    }
    private var preserveRequestedSoftwareKeyboard: Bool {
        keyboardActive && keyboardGeneration != nil && softwareRequested &&
            keyboardMode == .softwareOpen &&
            UIApplication.shared.applicationState == .active
    }

    private func handleKeyboardNotification(_ note: Notification) {
        defer { recordKeyboardAuthority(reason: note.name.rawValue) }
        if note.name == UIApplication.willResignActiveNotification {
            retireRemotePointerInputs()
            softwareRequested = false; applyRemoteKeyboardMode(.none); return
        }
        if note.name == UIApplication.didBecomeActiveNotification {
            softwareRequested = false; hardwareMonitor.refresh(); updateKeyboardAuthority(); return
        }
        guard keyboardMode == .softwareOpen else { return }
        if let screen = note.object as? UIScreen, screen !== window?.screen { return }
       if note.name == UIResponder.keyboardWillHideNotification || note.name == UIResponder.keyboardDidHideNotification {
           keyboardFrame = nil
           softwareNativeVisible = false
           if preserveRequestedSoftwareKeyboard {
               if !softwareKeyboardHideInProgress {
                   softwareKeyboardHideInProgress = true
                   softwareKeyboardRecoveryAttemptedForHide = false
                   softwareKeyboardRecoveryGeneration = keyboardGeneration
               }
               softwareNativeSuppressed = true
               if note.name == UIResponder.keyboardDidHideNotification,
                  !softwareKeyboardRecoveryAttemptedForHide,
                  softwareKeyboardRecoveryGeneration == keyboardGeneration {
                   softwareKeyboardRecoveryAttemptedForHide = true
                   let acquired: Bool
                   if softwareTextView.isFirstResponder {
                       acquired = softwareTextView.recyclePreservingComposition {
                           self.acquireSoftwareKeyboardResponder()
                       }
                   } else {
                       acquired = acquireSoftwareKeyboardResponder()
                   }
                   lastSoftwareResponderResult = acquired
                   reconcileKeyboardResponderOwnershipAfterSoftwareShowAttempt(softwareResponderAcquired: acquired)
                   recordKeyboardAuthority(reason: acquired ? "software_post_hide_recovery" : "software_post_hide_recovery_failed")
               }
           } else {
               softwareRequested = false
               applyRemoteKeyboardMode(.softwareAvailable)
           }
        } else {
            if let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
               let window {
                keyboardFrame = convert(window.convert(frame, from: window.screen.coordinateSpace), from: window)
            }
            softwareNativeVisible = keyboardFrame.map { frame in
                let visible = frame.intersection(bounds)
                return frame.origin.x.isFinite && frame.origin.y.isFinite &&
                    frame.width.isFinite && frame.height.isFinite &&
                    !visible.isNull && !visible.isEmpty
            } ?? false
            if softwareNativeVisible {
                softwareKeyboardHideInProgress = false
                softwareKeyboardRecoveryAttemptedForHide = false
                softwareNativeSuppressed = false
                clearSoftwareKeyboardWithheld()
            }
        }
        setNeedsLayout()
    }
    deinit {
        fadeTask?.cancel()
        withheldCheckTask?.cancel()
        hintTask?.cancel()
        keyboardObservers.forEach(NotificationCenter.default.removeObserver)
    }

}

public struct ConnectedPresentationSurface: UIViewRepresentable {
    @ObservedObject var networkManager: NetworkManager
    var gameModeEnabled: Bool
    public var onFrameRendered: (() -> Void)?
    public var onContentViewportChanged: ((VideoContentViewport?) -> Void)?
    var onGeometrySnapshotChanged: ((RendererGeometrySnapshot) -> Void)?
    var onPresentationGeometryChanged: ((PresentationSurfaceGeometry) -> Void)?
    var onTouchBoundsChanged: ((CGRect) -> Void)?
    var onPencilInput: ((PencilPacket) -> Void)?
    var onSendTouchEvent: ((TouchEventType, UInt16, UInt16, UInt8) -> Void)?
    var remoteKeyboardActive: Bool
    var onKeyboardInput: ((KeyboardInputCommand) -> Void)?
    var onTextCommit: ((String) -> Void)?
    var onDirectTouchContact: ((DirectTouchContactCommand) -> Void)?
    var onPointerInput: ((PointerInputCommand) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onGestureHint: ((GestureHint) -> Void)?

    public init(
        networkManager: NetworkManager,
        gameModeEnabled: Bool = false,
        remoteKeyboardActive: Bool = false,
        onKeyboardInput: ((KeyboardInputCommand) -> Void)? = nil,
        onTextCommit: ((String) -> Void)? = nil,
        onFrameRendered: (() -> Void)? = nil,
        onContentViewportChanged: ((VideoContentViewport?) -> Void)? = nil,
        onGeometrySnapshotChanged: ((RendererGeometrySnapshot) -> Void)? = nil,
        onPresentationGeometryChanged: ((PresentationSurfaceGeometry) -> Void)? = nil,
        onTouchBoundsChanged: ((CGRect) -> Void)? = nil,
        onPencilInput: ((PencilPacket) -> Void)? = nil,
        onSendTouchEvent: ((TouchEventType, UInt16, UInt16, UInt8) -> Void)? = nil,
        onDirectTouchContact: ((DirectTouchContactCommand) -> Void)? = nil,
        onPointerInput: ((PointerInputCommand) -> Void)? = nil,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.networkManager = networkManager
        self.gameModeEnabled = gameModeEnabled
        self.onFrameRendered = onFrameRendered
        self.onContentViewportChanged = onContentViewportChanged
        self.onGeometrySnapshotChanged = onGeometrySnapshotChanged
        self.onPresentationGeometryChanged = onPresentationGeometryChanged
        self.onTouchBoundsChanged = onTouchBoundsChanged
        self.onPencilInput = onPencilInput
        self.onSendTouchEvent = onSendTouchEvent
        self.remoteKeyboardActive = remoteKeyboardActive
        self.onKeyboardInput = onKeyboardInput
        self.onTextCommit = onTextCommit
        self.onDirectTouchContact = onDirectTouchContact
        self.onPointerInput = onPointerInput
        self.onOpenSettings = onOpenSettings
    }

    /// Reports recognised finger gestures for the first-use toasts.
    func gestureHints(_ handler: @escaping (GestureHint) -> Void) -> Self {
        var copy = self
        copy.onGestureHint = handler
        return copy
    }

    public static func dismantleUIView(_ uiView: ConnectedPresentationContainer, coordinator: Coordinator) {
        uiView.retireRemotePointerInputs()
        uiView.retireRemoteKeyboard()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeUIView(context: Context) -> ConnectedPresentationContainer {
        let container = ConnectedPresentationContainer(frame: .zero)
        configure(
            container,
            coordinator: context.coordinator,
            createRenderer: true)
        return container
    }

    public func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: ConnectedPresentationContainer,
        context: Context
    ) -> CGSize? {
        FullscreenSurfaceLayout.exactSize(
            width: proposal.width,
            height: proposal.height)
    }

    public func updateUIView(
        _ uiView: ConnectedPresentationContainer,
        context: Context
    ) {
        configure(
            uiView,
            coordinator: context.coordinator,
            createRenderer: false)
    }

    private func configure(
        _ container: ConnectedPresentationContainer,
        coordinator: Coordinator,
        createRenderer: Bool
    ) {
        let presentationMode: PresentationCadenceMode =
            gameModeEnabled ? .game : .office
        coordinator.renderer?.setPresentationMode(presentationMode)

        coordinator.onFrameRendered = onFrameRendered
        coordinator.onContentViewportChanged = onContentViewportChanged
        coordinator.onGeometrySnapshotChanged = onGeometrySnapshotChanged
        coordinator.onPresentationGeometryChanged = onPresentationGeometryChanged
        coordinator.onTouchBoundsChanged = onTouchBoundsChanged
        container.onGeometryChanged = { [weak coordinator] geometry in
            coordinator?.onPresentationGeometryChanged?(geometry)
        }
        container.setNeedsLayout()

        let touchView = container.touchView
        let binding = networkManager.mirrorInputRevision
        let ticket = networkManager.mirrorTicketAtRegistration
        let legacy = networkManager.permitsLegacyVirtualInput
        if coordinator.mirrorBindingRevision != binding || coordinator.mirrorBindingSession != networkManager.remoteKeyboardGeneration {
            touchView.retireMirrorInputScope()
            container.retireRemotePointerInputs()
            container.retireRemoteKeyboard() // Discards marked text before a new callback can acquire ownership.
            coordinator.mirrorBindingRevision = binding
            coordinator.mirrorBindingSession = networkManager.remoteKeyboardGeneration
        }
        let pencilInput = onPencilInput
        touchView.onPencilInput = { [weak container] packet in
            pencilInput?(packet)
            if packet.pointerFlags == 1 || packet.pointerFlags == 4 {
                container?.recordKeyboardAuthority(reason: packet.pointerFlags == 1 ? "pencil_down" : "pencil_up")
            }
        }
        let sendTouchEvent = onSendTouchEvent
        touchView.onSendTouchEvent = { [weak networkManager] type, x, y, pressure in
            if let ticket {
                networkManager?.sendMirrorInput(ticket: ticket, kind: .pencil,
                    payload: NetworkManager.mirrorPencilPayload(type: type, x: x, y: y, pressure: pressure))
            } else if legacy { sendTouchEvent?(type, x, y, pressure) }
        }
        let keyInput = onKeyboardInput
        touchView.onKeyboardInput = { [weak networkManager] command in
            if let ticket { networkManager?.sendMirrorInput(ticket: ticket, kind: .keyboard, payload: command.encode()) }
            else if legacy { keyInput?(command) }
        }
        let textInput = onTextCommit
        container.onTextCommit = { [weak networkManager] text in
            if let ticket {
                for command in TextCommitCommand.chunks(text) {
                    guard let bytes = command.encode() else { return }
                    networkManager?.sendMirrorInput(ticket: ticket, kind: .text, payload: bytes)
                }
            } else if legacy { textInput?(text) }
        }
        touchView.diagnosticSink = { [weak networkManager] line in networkManager?.recordDiagnosticLine(line) }
        container.configureRemoteKeyboard(active: remoteKeyboardActive, generation: networkManager.remoteKeyboardGeneration)
        container.configureClientCursor(ownership: networkManager.cursorOwnershipState,
            generation: networkManager.remoteKeyboardGeneration, active: remoteKeyboardActive)
        let directInput = onDirectTouchContact
        touchView.onDirectTouchContact = { [weak networkManager] command in
            if let ticket { networkManager?.sendMirrorInput(ticket: ticket, kind: .directTouch, payload: command.encode()) }
            else if legacy { directInput?(command) }
        }
        let admitted = remoteKeyboardActive && (ticket != nil || legacy)
        touchView.configureDirectTouch(active: admitted, generation: binding)
        touchView.configureExternalPointer(active: admitted, generation: binding)
        let pointerInput = onPointerInput
        touchView.onPointerInput = { [weak networkManager] command in
            if let ticket { networkManager?.sendMirrorInput(ticket: ticket, kind: .pointer, payload: command.encode()) }
            else if legacy { pointerInput?(command) }
        }
        let openSettings = onOpenSettings
        touchView.onOpenSettings = { [weak container] in
            container?.retireRemotePointerInputs()
            container?.configureRemoteKeyboard(active: false, generation: networkManager.remoteKeyboardGeneration)
            openSettings?()
        }
        touchView.inputGeometryContext = coordinator.inputGeometryContext
        touchView.onGestureHint = onGestureHint
        touchView.diagnosticSink = { [weak networkManager] line in
            networkManager?.recordDiagnosticLine(line)
        }
        touchView.onBoundsChanged = { [weak coordinator] bounds in
            coordinator?.onTouchBoundsChanged?(bounds)
        }

        let metalView = container.metalView
        // ConnectedPresentationContainer owns drawable sizing from its shared
        // bounds so the Metal surface and the touch surface cannot diverge.
        metalView.autoResizeDrawable = false
        if let screen = metalView.window?.screen {
            metalView.contentScaleFactor = screen.scale
        }

        guard createRenderer,
              let renderer = Renderer(
                  metalView: metalView,
                  presentationMode: presentationMode) else {
            return
        }

        coordinator.renderer = renderer
        coordinator.touchView = touchView
        renderer.diagnosticSink = { [weak networkManager] line in
            networkManager?.recordDiagnosticLine(line)
        }
        renderer.beginSession(generation: networkManager.decoder.currentSessionGeneration)
        renderer.onFrameRendered = { [weak coordinator, weak networkManager] sequence, generation in
            networkManager?.recordRenderCompletion(
                sequence: sequence,
                generation: generation)
            coordinator?.onFrameRendered?()
        }
        renderer.onDrawableCommitted = { [weak networkManager] sequence, generation in
            networkManager?.recordDrawableCommitted(
                sequence: sequence,
                generation: generation)
        }
        renderer.onFrameDropped = { [weak networkManager] sequence, generation in
            networkManager?.recordRenderDrop(
                sequence: sequence,
                generation: generation)
        }
        renderer.onContentViewportChanged = { [weak coordinator] viewport in
            coordinator?.touchView?.contentViewport = viewport
            coordinator?.onContentViewportChanged?(viewport)
        }
        renderer.onGeometrySnapshotChanged = {
            [weak coordinator, weak networkManager] snapshot in
            if let networkManager {
                let inputGeometryContext = InputGeometryDiagnosticContext(
                    sessionGeneration:
                        networkManager.decoder.currentSessionGeneration,
                    frameSize: snapshot.decodedFrameSize)
                coordinator?.inputGeometryContext = inputGeometryContext
                coordinator?.touchView?.inputGeometryContext =
                    inputGeometryContext
            }
            coordinator?.onGeometrySnapshotChanged?(snapshot)
        }

        networkManager.decoder.onSessionBegan = { [weak renderer] generation in
            renderer?.beginSession(generation: generation)
        }
        networkManager.decoder.onFrameDecoded = { [weak renderer] pixelBuffer, sequence, generation in
            renderer?.updateFrame(
                pixelBuffer,
                sequence: sequence,
                generation: generation)
        }
    }

    #if targetEnvironment(simulator)
    func configureInputForTesting(_ container: ConnectedPresentationContainer, coordinator: Coordinator) {
        configure(container, coordinator: coordinator, createRenderer: false)
    }
    #endif

    public final class Coordinator {
        var mirrorBindingRevision: UInt64?
        var mirrorBindingSession: UInt64?
        var renderer: Renderer?
        weak var touchView: PencilUIKitView?
        var inputGeometryContext: InputGeometryDiagnosticContext?
        var onFrameRendered: (() -> Void)?
        var onContentViewportChanged: ((VideoContentViewport?) -> Void)?
        var onGeometrySnapshotChanged: ((RendererGeometrySnapshot) -> Void)?
        var onPresentationGeometryChanged: ((PresentationSurfaceGeometry) -> Void)?
        var onTouchBoundsChanged: ((CGRect) -> Void)?
    }
}

/// A wrapper matching the name expected by ContentView
public struct MetalVideoView: View {
    @ObservedObject var networkManager: NetworkManager
    public var onFrameRendered: (() -> Void)?
    public var onContentViewportChanged: ((VideoContentViewport?) -> Void)?
    var onGeometrySnapshotChanged: ((RendererGeometrySnapshot) -> Void)?

    public init(
        networkManager: NetworkManager,
        onFrameRendered: (() -> Void)? = nil,
        onContentViewportChanged: ((VideoContentViewport?) -> Void)? = nil,
        onGeometrySnapshotChanged: ((RendererGeometrySnapshot) -> Void)? = nil
    ) {
        self.networkManager = networkManager
        self.onFrameRendered = onFrameRendered
        self.onContentViewportChanged = onContentViewportChanged
        self.onGeometrySnapshotChanged = onGeometrySnapshotChanged
    }

    public var body: some View {
        MetalView(
            networkManager: networkManager,
            onFrameRendered: onFrameRendered,
            onContentViewportChanged: onContentViewportChanged,
            onGeometrySnapshotChanged: onGeometrySnapshotChanged)
    }
}
