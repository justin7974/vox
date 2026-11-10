import Foundation
final class InsertedTextAnchor {
    enum CaptureFailure: String { case valueUnavailable = "ax_value_unavailable" }
    static var supported = false
    static func capture(text: String, onFailure: (CaptureFailure) -> Void = { _ in }) -> InsertedTextAnchor? {
        if supported { return InsertedTextAnchor() }
        onFailure(.valueUnavailable); return nil
    }
    func select() -> Bool { true }
    func selectionIsValid() -> Bool { true }
}
