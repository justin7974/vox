import Foundation

enum VoxMode {
    case dictation
    case launcher
}

enum VoxPhase: Equatable {
    // === Shared ===
    case idle
    case recording(VoxMode)

    // === Dictation ===
    case transcribing
    case postProcessing
    case pasting
    case editWindow

    // === Launcher ===
    case matchingIntent
    case executingAction
    case showingResult

    // === Error ===
    case error(VoxError)

    static func == (lhs: VoxPhase, rhs: VoxPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.recording(let a), .recording(let b)): return a == b
        case (.transcribing, .transcribing): return true
        case (.postProcessing, .postProcessing): return true
        case (.pasting, .pasting): return true
        case (.editWindow, .editWindow): return true
        case (.matchingIntent, .matchingIntent): return true
        case (.executingAction, .executingAction): return true
        case (.showingResult, .showingResult): return true
        case (.error, .error): return true
        default: return false
        }
    }
}

class VoxStateMachine {
    private(set) var phase: VoxPhase = .idle

    func transition(to newPhase: VoxPhase) {
        guard isValid(from: phase, to: newPhase) else {
            NSLog("Vox: Invalid transition: \(phase) -> \(newPhase)")
            return
        }
        NSLog("Vox: Phase: \(phase) -> \(newPhase)")
        phase = newPhase
    }

    private func isValid(from: VoxPhase, to: VoxPhase) -> Bool {
        if case .error = from, to == .idle { return true }
        if case .error = to { return true }

        switch (from, to) {
        case (.idle, .recording):                       return true
        case (.recording, .idle):                       return true
        case (.recording(.dictation), .transcribing):   return true
        case (.transcribing, .idle):                    return true
        case (.transcribing, .postProcessing):          return true
        case (.postProcessing, .pasting):               return true
        case (.pasting, .idle):                         return true
        case (.pasting, .editWindow):                   return true
        case (.editWindow, .recording(.dictation)):     return true
        case (.editWindow, .idle):                      return true
        case (.recording(.launcher), .transcribing):    return true
        case (.transcribing, .matchingIntent):          return true
        case (.matchingIntent, .executingAction):       return true
        case (.matchingIntent, .idle):                  return true
        case (.executingAction, .showingResult):        return true
        case (.executingAction, .idle):                 return true
        case (.showingResult, .idle):                   return true
        default:                                        return false
        }
    }
}
