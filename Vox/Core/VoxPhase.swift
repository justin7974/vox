import Foundation

enum VoxPhase: Equatable {
    case idle
    case recording
    case transcribing
    case postProcessing
    case pasting
    case editWindow
    case error(VoxError)

    static func == (lhs: VoxPhase, rhs: VoxPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.recording, .recording): return true
        case (.transcribing, .transcribing): return true
        case (.postProcessing, .postProcessing): return true
        case (.pasting, .pasting): return true
        case (.editWindow, .editWindow): return true
        case (.error, .error): return true
        default: return false
        }
    }
}

class VoxStateMachine {
    private(set) var phase: VoxPhase = .idle

    @discardableResult
    func transition(to newPhase: VoxPhase) -> Bool {
        guard isValid(from: phase, to: newPhase) else {
            NSLog("Vox: Invalid transition: \(phase) -> \(newPhase)")
            return false
        }
        NSLog("Vox: Phase: \(phase) -> \(newPhase)")
        phase = newPhase
        return true
    }

    private func isValid(from: VoxPhase, to: VoxPhase) -> Bool {
        if case .error = from, to == .idle { return true }
        if case .error = to { return true }

        switch (from, to) {
        case (.idle, .recording):               return true
        case (.recording, .idle):               return true
        case (.recording, .transcribing):       return true
        case (.transcribing, .idle):            return true
        case (.transcribing, .postProcessing):  return true
        case (.postProcessing, .pasting):       return true
        case (.pasting, .idle):                 return true
        case (.pasting, .editWindow):           return true
        case (.editWindow, .recording):         return true
        case (.editWindow, .idle):              return true
        default:                                return false
        }
    }
}
