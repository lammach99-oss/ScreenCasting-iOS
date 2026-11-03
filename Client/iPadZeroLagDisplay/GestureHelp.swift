import Foundation

/// A finger gesture worth confirming with a short toast while it is new.
enum GestureHint: String, Equatable {
    case rightClick, drag, zoom, scroll

    var toastText: String { "" }

    static func from(_ outputs: [DirectTouchGestureOutput]) -> GestureHint? { nil }
}

/// Counts toasts per gesture across launches; each gesture gets three, then none.
struct GestureToastLedger {
    static let limit = 3
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func toast(for hint: GestureHint) -> String? { nil }
}
