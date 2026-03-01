import Foundation

enum VoxError: Error, LocalizedError {
    case noConfig
    case emptyTranscription
    case sttFailed(String)
    case llmFailed(String)
    case pasteFailed
    case actionFailed(String)
    case intentMatchFailed(String)
    case invalidTransition(from: String, to: String)

    var errorDescription: String? {
        switch self {
        case .noConfig:                     return "No configuration found"
        case .emptyTranscription:           return "Could not recognize speech"
        case .sttFailed(let msg):           return "STT error: \(msg)"
        case .llmFailed(let msg):           return "LLM error: \(msg)"
        case .pasteFailed:                  return "Failed to paste text"
        case .actionFailed(let msg):        return "Action error: \(msg)"
        case .intentMatchFailed(let msg):   return "Intent match error: \(msg)"
        case .invalidTransition(let f, let t): return "Invalid state: \(f) -> \(t)"
        }
    }
}
