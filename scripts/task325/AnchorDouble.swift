import Foundation
final class InsertedTextAnchor {
    enum CaptureFailure: String {
        case valueUnavailable = "ax_value_unavailable"
        case permissionDenied = "ax_permission_denied"
    }
    static var supported = false
    static var failureReason = CaptureFailure.valueUnavailable
    static func capture(text: String, onFailure: (CaptureFailure) -> Void = { _ in }) -> InsertedTextAnchor? {
        if supported { return InsertedTextAnchor() }
        onFailure(failureReason); return nil
    }
    func select() -> Bool { true }
    func selectionIsValid() -> Bool { true }
}
