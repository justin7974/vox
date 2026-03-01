import Foundation

struct IntentMatch {
    let action: ActionDefinition
    let params: [String: String]
    let confidence: Double  // 0-1, below 0.7 = no match
}
