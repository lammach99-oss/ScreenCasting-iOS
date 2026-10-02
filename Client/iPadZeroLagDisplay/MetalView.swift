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
@MainActor final class HardwareKeyboardMonitor {
    private(set) var isConnected = GCKeyboard.coalesced != nil
    var onChanged: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    init() {
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }
    func refresh() {
        let present = GCKeyboard.coalesced != nil
        guard present != isConnected else { return }
        isConnected = present; onChanged?(present)
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
    private let hardwareMonitor = HardwareKeyboardMonitor()
    private var keyboardObservers: [NSObjectProtocol] = []
    private var fadeTask: Task<Void, Never>?
    private var keyboardFrame: CGRect?
    private(set) var keyboardMode: RemoteKeyboardMode = .none
    private var keyboardActive = false
    private var softwareRequested = false
    private var keyboardGeneration: UInt64?
    private var lastKeyboardAuthorityDiagnostic: String?
    private var lastSoftwareResponderResult: Bool?
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
        keyboardButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        keyboardButton.tintColor = .white
        keyboardButton.layer.cornerRadius = 12
        keyboardButton.accessibilityLabel = "Software keyboard"
        keyboardButton.addTarget(self, action: #selector(toggleSoftwareKeyboard), for: .touchUpInside)
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
            self.softwareRequested = false
            self.applyRemoteKeyboardMode(.softwareAvailable)
        }
        hardwareMonitor.onChanged = { [weak self] present in self?.hardwarePresenceChanged(present) }
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification,
                     UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification] {
            keyboardObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.handleKeyboardNotification(note) }
            })
        }

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
        if window == nil { retireDirectPointer(); retireRemoteKeyboard() }
        else { hardwareMonitor.refresh(); updateKeyboardAuthority() }
        setNeedsLayout()
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        keyboardButton.frame = FloatingKeyboardPlacement.frame(bounds: bounds, safeArea: safeAreaInsets, keyboard: keyboardFrame)

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
        // Never carry an old software-open intent across attach or detach.
        softwareRequested = false
        applyRemoteKeyboardMode(RemoteKeyboardMode.resolve(active: keyboardActive && UIApplication.shared.applicationState == .active, hardware: present, requested: false))
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
        if mode != .softwareOpen {
            softwareRequested = false
            keyboardFrame = nil
            softwareTextView.deactivateAndDiscardComposition()
            setNeedsLayout()
        }
        keyboardButton.isHidden = mode == .none || mode == .hardware
        touchView.keyboardCaptureEnabled = mode == .hardware
        if mode == .softwareOpen {
            softwareTextView.deliveryEnabled = true
            if window != nil && !softwareTextView.isFirstResponder {
                lastSoftwareResponderResult = softwareTextView.becomeFirstResponder()
                recordKeyboardAuthority(reason: "software_responder_attempt")
            }
        }
        if changed {
            if keyboardButton.isHidden { fadeTask?.cancel(); fadeTask = nil }
            else { restartKeyboardFade() }
            recordKeyboardAuthority(reason: "mode_changed", previousMode: previousMode)
        }
    }
    fileprivate func recordKeyboardAuthority(reason: String, previousMode: RemoteKeyboardMode? = nil) {
        let line = "[KEYBOARD_AUTHORITY] reason=\(reason) gc_keyboard_present=\(GCKeyboard.coalesced != nil ? 1 : 0) hardware_monitor=\(hardwareMonitor.isConnected ? 1 : 0) keyboard_active=\(keyboardActive ? 1 : 0) software_requested=\(softwareRequested ? 1 : 0) old_mode=\(previousMode ?? keyboardMode) new_mode=\(keyboardMode) software_first_responder=\(softwareTextView.isFirstResponder ? 1 : 0) responder_result=\(lastSoftwareResponderResult.map { $0 ? "success" : "failure" } ?? "not_attempted") keyboard_button_hidden=\(keyboardButton.isHidden ? 1 : 0)"
        guard line != lastKeyboardAuthorityDiagnostic else { return }
        lastKeyboardAuthorityDiagnostic = line
        touchView.diagnosticSink?(line)
    }
    @objc private func toggleSoftwareKeyboard() {
        guard keyboardMode == .softwareAvailable || keyboardMode == .softwareOpen else {
            recordKeyboardAuthority(reason: "software_toggle_blocked")
            return
        }
        softwareRequested = !softwareRequested
        updateKeyboardAuthority()
        restartKeyboardFade()
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
    private func handleKeyboardNotification(_ note: Notification) {
        recordKeyboardAuthority(reason: note.name.rawValue)
        if note.name == UIApplication.willResignActiveNotification {
            retireDirectPointer()
            softwareRequested = false; applyRemoteKeyboardMode(.none); return
        }
        if note.name == UIApplication.didBecomeActiveNotification {
            softwareRequested = false; hardwareMonitor.refresh(); updateKeyboardAuthority(); return
        }
        guard keyboardMode == .softwareOpen else { return }
        if note.name == UIResponder.keyboardWillHideNotification {
            keyboardFrame = nil; softwareRequested = false
            applyRemoteKeyboardMode(.softwareAvailable)
        } else if softwareTextView.isFirstResponder,
                  let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let window {
            keyboardFrame = convert(window.convert(frame, from: window.screen.coordinateSpace), from: window)
        }
        setNeedsLayout()
    }
    deinit {
        fadeTask?.cancel()
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

    public static func dismantleUIView(_ uiView: ConnectedPresentationContainer, coordinator: Coordinator) {
        uiView.retireDirectPointer()
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
        let pencilInput = onPencilInput
        touchView.onPencilInput = { [weak container] packet in
            pencilInput?(packet)
            if packet.pointerFlags == 1 || packet.pointerFlags == 4 {
                container?.recordKeyboardAuthority(reason: packet.pointerFlags == 1 ? "pencil_down" : "pencil_up")
            }
        }
        let sendTouchEvent = onSendTouchEvent
        touchView.onSendTouchEvent = { type, x, y, pressure in
            sendTouchEvent?(type, x, y, pressure)
        }
        touchView.onKeyboardInput = onKeyboardInput
        container.onTextCommit = onTextCommit
        touchView.diagnosticSink = { [weak networkManager] line in networkManager?.recordDiagnosticLine(line) }
        container.configureRemoteKeyboard(active: remoteKeyboardActive, generation: networkManager.remoteKeyboardGeneration)
        container.configureClientCursor(ownership: networkManager.cursorOwnershipState,
            generation: networkManager.remoteKeyboardGeneration, active: remoteKeyboardActive)
        touchView.onDirectTouchContact = onDirectTouchContact
        touchView.configureDirectTouch(active: remoteKeyboardActive, generation: networkManager.remoteKeyboardGeneration)
        touchView.onPointerInput = onPointerInput
        let openSettings = onOpenSettings
        touchView.onOpenSettings = { [weak container] in
            container?.retireDirectPointer()
            container?.configureRemoteKeyboard(active: false, generation: networkManager.remoteKeyboardGeneration)
            openSettings?()
        }
        touchView.inputGeometryContext = coordinator.inputGeometryContext
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

    public final class Coordinator {
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
