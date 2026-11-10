import Foundation

enum VoxPhase: Equatable {
    case idle
    case recording
    case transcribing
    case postProcessing
    case pasting
    case error(VoxError)

    fileprivate var logName: String {
        switch self {
        case .idle: return "idle"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .postProcessing: return "postProcessing"
        case .pasting: return "pasting"
        case .error: return "error"
        }
    }

    static func == (lhs: VoxPhase, rhs: VoxPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.recording, .recording): return true
        case (.transcribing, .transcribing): return true
        case (.postProcessing, .postProcessing): return true
        case (.pasting, .pasting): return true
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
            LogService.shared.error("Invalid transition: \(phase.logName) -> \(newPhase.logName)")
            return false
        }
        NSLog("Vox: Phase: \(phase.logName) -> \(newPhase.logName)")
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
        case (.postProcessing, .idle):          return true
        case (.pasting, .idle):                 return true
        default:                                return false
        }
    }
}
