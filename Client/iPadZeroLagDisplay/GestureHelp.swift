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
    case casting
    case remote(RemoteMouseMode)
}

struct GestureGuideItem: Equatable {
    let symbol: String
    let gesture: String
    let result: String
}

/// Copy follows the engine actually receiving touches; remote Direct still sends mouse input.
enum GestureGuideContent {
    static func items(for mode: GestureGuideMode) -> [GestureGuideItem] {
        switch mode {
        case .casting:
            return [
                GestureGuideItem(symbol: "hand.tap", gesture: "Tap", result: "Click"),
                GestureGuideItem(symbol: "arrow.up.arrow.down", gesture: "Swipe one finger", result: "Scroll"),
                GestureGuideItem(symbol: "hand.draw", gesture: "Hold, then move", result: "Drag or select"),
                GestureGuideItem(symbol: "cursorarrow.click.2", gesture: "Two-finger tap", result: "Right-click"),
                GestureGuideItem(symbol: "hand.pinch", gesture: "Pinch", result: "Zoom in or out"),
                GestureGuideItem(symbol: "rectangle.topthird.inset.filled", gesture: "Three-finger tap", result: "Open the session panel")
            ]
        case .remote(let mouseMode):
            return [
                GestureGuideItem(symbol: "hand.tap", gesture: "Tap", result: mouseMode == .direct ? "Click where you tap" : "Click at the pointer"),
                GestureGuideItem(symbol: "hand.draw", gesture: "Move one finger", result: mouseMode == .direct ? "Point at the screen position" : "Move the pointer"),
                GestureGuideItem(symbol: "arrow.up.arrow.down", gesture: "Move two fingers", result: "Scroll"),
                GestureGuideItem(symbol: "hand.draw", gesture: "Double-tap and hold", result: "Drag or select"),
                GestureGuideItem(symbol: "cursorarrow.click.2", gesture: "Two-finger tap", result: "Right-click")
            ]
        }
    }

    static func helper(for mode: GestureGuideMode) -> String {
        switch mode {
        case .casting: return "Fingers act like a mouse. Apple Pencil acts like a pen."
        case .remote: return "Touch controls the PC pointer. Direct sends mouse clicks, without pen pressure."
        }
    }

    static func pencil(for mode: GestureGuideMode) -> String {
        switch mode {
        case .casting:
            return "Writes and clicks with pressure. Fingers are ignored while the Pencil touches the screen. " +
                "To open the keyboard after using the Pencil, tap the keyboard button with a finger."
        case .remote(let mouseMode):
            return mouseMode == .trackpad ? "Pencil and mouse move the pointer using Trackpad. Change this in More input."
                : "Pencil and mouse point directly and send mouse input. They do not send pen pressure."
        }
    }
}

/// The gesture card follows the current input engine and selected touch behavior.
struct GestureGuideCard: View {
    let mode: GestureGuideMode
    let onDone: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    private var gestures: [GestureGuideItem] { GestureGuideContent.items(for: mode) }

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

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Control your PC by touch").font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(GestureGuideContent.helper(for: mode))
                    .font(.subheadline).foregroundStyle(Color(uiColor: SessionInk.secondary))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 220 : 140), spacing: 8)], spacing: 8) {
                ForEach(gestures, id: \.gesture) { item in
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
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "applepencil").font(.title3).foregroundStyle(Color(uiColor: SessionInk.accent))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Pencil").font(.subheadline.weight(.semibold))
                    Text(GestureGuideContent.pencil(for: mode))
                        .font(.caption).foregroundStyle(Color(uiColor: SessionInk.secondary))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: SessionInk.raised), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
            footer
        }
        .foregroundStyle(Color(uiColor: SessionInk.text))
        .padding(20)
        .background(Color(uiColor: SessionInk.surface), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color(uiColor: SessionInk.hairline), lineWidth: 0.5))
        .shadow(color: Color(uiColor: SessionInk.canvas).opacity(0.45), radius: 24, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { onDone() }
    }

    private var footer: some View {
        let hint = Text("Find this again: session panel > Gestures")
            .font(.caption).foregroundStyle(Color(uiColor: SessionInk.secondary))
        let done = Button(action: onDone) {
            Text("Got it")
                .font(.headline)
                .foregroundStyle(Color(uiColor: SessionInk.onAccent))
                .padding(.horizontal, 22)
                .frame(minHeight: 44)
                .background(Color(uiColor: SessionInk.accent), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) { hint; done }
            } else {
                HStack { hint; Spacer(minLength: 8); done }
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
