import SwiftUI

/// A finger gesture worth confirming with a short toast while it is new.
enum GestureHint: String, Equatable {
    case rightClick, drag, zoom, scroll

    var toastText: String {
        switch self {
        case .rightClick: "Right-click"
        case .drag: "Dragging"
        case .zoom: "Zoom"
        case .scroll: "Scrolling"
        }
    }

    var symbol: String {
        switch self {
        case .rightClick: "cursorarrow.click.2"
        case .drag: "hand.draw"
        case .zoom: "hand.pinch"
        case .scroll: "arrow.up.arrow.down"
        }
    }

    /// Right-click, pinch and the start of a drag each arrive as one batch per gesture. Scrolling is
    /// reported where the swipe is classified, so wheel steps here never count.
    static func from(_ outputs: [DirectTouchGestureOutput]) -> GestureHint? {
        var downs: Set<UInt64> = []
        for output in outputs {
            switch output {
            case .pointer(.rightClick, _, _): return .rightClick
            case .pointer(.zoomWheel, _, _): return .zoom
            case .directTouch(.down, let id, _, _): downs.insert(id)
            case .directTouch(.update, let id, _, _) where downs.contains(id): return .drag
            default: break
            }
        }
        return nil
    }
}

/// One toast on screen; a new one replaces it, and its own timer only clears itself.
struct GestureToast: Equatable {
    let id = UUID()
    let hint: GestureHint
    let text: String
}

/// Counts toasts per gesture across launches; each gesture gets three, then none.
struct GestureToastLedger {
    static let limit = 3
    private static let key = "ScreenCasting.client.gestureToastCounts.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The toast text while this gesture is still new; counts the toast it returns.
    func toast(for hint: GestureHint) -> String? {
        var counts = defaults.dictionary(forKey: Self.key) as? [String: Int] ?? [:]
        let shown = counts[hint.rawValue, default: 0]
        guard shown < Self.limit else { return nil }
        counts[hint.rawValue] = shown + 1
        defaults.set(counts, forKey: Self.key)
        return hint.toastText
    }
}

enum GestureGuideMode: Equatable {
    // Kept for existing presentation callers; new help follows the shared session's selected mode.
    case casting
    case remote(RemoteMouseMode)
    case input(IPadTouchMode)

    var touchMode: IPadTouchMode {
        switch self {
        case .casting: return .direct
        case .remote(let mode): return mode == .direct ? .direct : .trackpad
        case .input(let mode): return mode
        }
    }
}

struct GestureGuideItem: Equatable {
    let symbol: String
    let gesture: String
    let result: String
}

/// Both transports use the same gestures. Direct is native Windows touch, never mouse emulation.
enum GestureGuideContent {
    static func items(for mode: GestureGuideMode) -> [GestureGuideItem] {
        let direct = mode.touchMode == .direct
        return [
            .init(symbol: "hand.point.up.left", gesture: "Finger move",
                  result: direct ? "Native Windows touch movement" : "Relative mouse movement"),
            .init(symbol: "hand.tap", gesture: "Tap", result: direct ? "Touch tap" : "Left click"),
            .init(symbol: "hand.tap", gesture: "Double tap", result: direct ? "Two touch taps" : "Double click"),
            .init(symbol: "hand.raised", gesture: "Stationary hold",
                  result: direct ? "Native Windows press-and-hold; no extra right click" : "Right click; cancels the left tap"),
            .init(symbol: "hand.draw", gesture: "Double-tap then move",
                  result: direct ? "Native touch sequence; the app decides manipulation" : "Mouse drag until lift"),
            .init(symbol: "cursorarrow.click.2", gesture: "Two-finger tap",
                  result: direct ? "Cancel touch, then Right click" : "Right click"),
            .init(symbol: "arrow.up.arrow.down", gesture: "Two-finger pan",
                  result: direct ? "Cancel touch, then smooth wheel with bounded inertia" : "Smooth wheel with bounded inertia"),
            .init(symbol: "hand.pinch", gesture: "Pinch",
                  result: direct ? "Cancel touch, then Anchored Ctrl-wheel" : "Anchored Ctrl-wheel"),
            .init(symbol: "hand.draw", gesture: "Drag control",
                  result: direct ? "Arm/latch a native touch contact" : "Latch the left mouse button"),
            .init(symbol: "hand.tap", gesture: "Next tap while dragging", result: "Release only; no extra click"),
            .init(symbol: "applepencil", gesture: "Pencil",
                  result: "Precise absolute mouse; tip drags with left button"),
            .init(symbol: "computermouse", gesture: "External pointer",
                  result: direct ? "Absolute mouse; real buttons" : "Relative mouse; real buttons"),
            .init(symbol: "hand.raised", gesture: "Three/four fingers or system gestures",
                  result: "No new PC shortcut; iPad system gestures stay on the iPad")
        ]
    }

    static func helper(for mode: GestureGuideMode) -> String {
        let touch = mode.touchMode == .direct
            ? "Direct sends Windows touch. Windows and the target app handle pan, press-and-hold and selection. "
            : "Trackpad moves the PC mouse pointer. Hold still to right click. "
        return touch + "Command = Ctrl. Hardware keyboard uses the PC input method; the on-screen keyboard uses the iPad input method. " +
            "Win is available from the input bar and Windows shortcuts. iPadOS may reserve hardware shortcuts."
    }

    static func pencil(for mode: GestureGuideMode) -> String {
        return "Pencil always points absolutely, in Direct and Trackpad. Hover moves the PC pointer; tip down/up holds/releases the left button. " +
            "Double-tap or squeeze arms the next touch as right-click for 5 seconds; repeat to cancel. The armed notice appears over the picture. " +
            "These gestures follow the enabled/disabled preference in iPad settings. " +
            "No Windows pen, pressure or tilt. Hover or tip takes priority; fingers resume 400 ms after it leaves, and resting fingers must lift first. " +
            "Requires an updated PC host with enhanced pointer support. " +
            "Open the software keyboard from session panel > Tools > Keyboard."
    }
}

/// The gesture card follows the current input engine and selected touch behavior.
@MainActor struct GestureGuideCard: View {
    @EnvironmentObject private var inputSession: IPadInputSession
    let mode: GestureGuideMode
    let onDone: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    private var currentMode: GestureGuideMode { .input(inputSession.touchMode) }
    private var gestures: [GestureGuideItem] { GestureGuideContent.items(for: currentMode) }

    var body: some View {
        ZStack {
            // Covers the stream: while the card is open no touch reaches the PC.
            Color(uiColor: SessionInk.canvas).opacity(0.55).contentShape(Rectangle()).onTapGesture {}
                .ignoresSafeArea()
                .accessibilityHidden(true)
            GeometryReader { proxy in
                ScrollView {
                    card.frame(width: max(0, min(520, proxy.size.width - 32)))
                        .frame(maxWidth: .infinity, minHeight: max(0, proxy.size.height - 48))
                        .padding(.vertical, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .onAppear { UIAccessibility.post(notification: .screenChanged, argument: nil) }
    }

    private var card: GuideCard {
        GuideCard(owner: self)
    }

    private var footer: GuideFooter {
        GuideFooter(owner: self)
    }

    // Nominal view types bound metadata expansion across independently rendered sections.
    @MainActor private struct GuideCard: View {
        let owner: GestureGuideCard
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                GuideHeading(owner: owner)
                GuideGestures(owner: owner)
                GuidePencil(owner: owner)
                owner.footer
            }
            .foregroundStyle(Color(uiColor: SessionInk.text))
            .padding(20)
            .background(Color(uiColor: SessionInk.surface), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color(uiColor: SessionInk.hairline), lineWidth: 0.5))
            .shadow(color: Color(uiColor: SessionInk.canvas).opacity(0.45), radius: 24, y: 12)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { owner.onDone() }
        }
    }

    @MainActor private struct GuideHeading: View {
        let owner: GestureGuideCard
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text("Control your PC by touch").font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(GestureGuideContent.helper(for: owner.currentMode))
                    .font(.subheadline).foregroundStyle(Color(uiColor: SessionInk.secondary))
            }
        }
    }

    @MainActor private struct GuideGestures: View {
        let owner: GestureGuideCard
        var body: some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: owner.typeSize.isAccessibilitySize ? 220 : 140), spacing: 8)], spacing: 8) {
                ForEach(owner.gestures, id: \.gesture) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Image(systemName: item.symbol).font(.title2).foregroundStyle(Color(uiColor: SessionInk.accent))
                            .accessibilityHidden(true)
                        Text(item.gesture).font(.subheadline.weight(.semibold))
                        Text(item.result).font(.caption).foregroundStyle(Color(uiColor: SessionInk.secondary))
                    }
                    .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
                    .padding(10)
                    .background(Color(uiColor: SessionInk.raised), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @MainActor private struct GuidePencil: View {
        let owner: GestureGuideCard
        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "applepencil").font(.title3).foregroundStyle(Color(uiColor: SessionInk.accent))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Pencil").font(.subheadline.weight(.semibold))
                    Text(GestureGuideContent.pencil(for: owner.currentMode))
                        .font(.caption).foregroundStyle(Color(uiColor: SessionInk.secondary))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: SessionInk.raised), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    @MainActor private struct GuideFooter: View {
        let owner: GestureGuideCard
        var body: some View {
            let hint = Text("Find this again: session panel > Touch > More input > Gesture help")
                .font(.caption).foregroundStyle(Color(uiColor: SessionInk.secondary))
            let done = Button(action: owner.onDone) {
                Text("Got it")
                    .font(.headline)
                    .foregroundStyle(Color(uiColor: SessionInk.onAccent))
                    .padding(.horizontal, 22)
                    .frame(minHeight: 44)
                    .background(Color(uiColor: SessionInk.accent), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            return Group {
                if owner.typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) { hint; done }
                } else {
                    HStack { hint; Spacer(minLength: 8); done }
                }
            }
        }
    }
}

/// A short confirmation at the bottom of the stream; it takes no touches.
struct GestureToastView: View {
    let hint: GestureHint
    let text: String

    var body: some View {
        Label(text, systemImage: hint.symbol)
            .font(.subheadline)
            .foregroundStyle(Color(uiColor: SessionInk.text))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color(uiColor: SessionInk.surface).opacity(0.94), in: Capsule())
            .overlay(Capsule().stroke(Color(uiColor: SessionInk.hairline), lineWidth: 0.5))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
