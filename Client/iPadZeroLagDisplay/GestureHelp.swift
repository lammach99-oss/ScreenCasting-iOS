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

/// The gesture card: shown once on the first session, and again from the session panel's Gestures button.
struct GestureGuideCard: View {
    let onDone: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private struct Item { let symbol: String; let gesture: String; let result: String }
    private let gestures: [Item] = [
        Item(symbol: "hand.tap", gesture: "Tap", result: "Click"),
        Item(symbol: "arrow.up.arrow.down", gesture: "Swipe one finger", result: "Scroll"),
        Item(symbol: "hand.draw", gesture: "Hold, then move", result: "Drag or select"),
        Item(symbol: "cursorarrow.click.2", gesture: "Two-finger tap", result: "Right-click"),
        Item(symbol: "hand.pinch", gesture: "Pinch", result: "Zoom in or out"),
        Item(symbol: "rectangle.topthird.inset.filled", gesture: "Three-finger tap", result: "Open the session panel"),
    ]

    var body: some View {
        ZStack {
            // Covers the stream: while the card is open no touch reaches the PC.
            Color.black.opacity(0.55).contentShape(Rectangle()).onTapGesture {}
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
                Text("Fingers act like a mouse. Apple Pencil acts like a pen.")
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
                    Text("Writes and clicks with pressure. Fingers are ignored while the Pencil touches the screen. " +
                         "To open the keyboard after using the Pencil, tap the keyboard button with a finger.")
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
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { onDone() }
    }

    private var footer: some View {
        let hint = Text("Find this again: session panel › Gestures")
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
