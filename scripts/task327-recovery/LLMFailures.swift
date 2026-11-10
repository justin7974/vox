import Foundation
struct FakeProvider: LLMProvider {
    let name = "fixture"
    let output: String
    func complete(userMessage: String, systemPrompt: String) async -> String { output }
}
@main struct LLMFailureTests {
    static func main() async {
        var failures = 0
        let service = LLMService(providerOverride: FakeProvider(output: ""))
        let raw = await service.process(rawText: "raw", customSystemPrompt: "fixture", applyAliases: true, onFailure: { failures += 1 })
        precondition(raw == "alias:raw" && failures == 1)
        let translated = await service.process(rawText: "raw", translateMode: true, customSystemPrompt: "fixture", requireLLM: true, onFailure: { failures += 1 })
        precondition(translated.isEmpty && failures == 2)
        let success = LLMService(providerOverride: FakeProvider(output: "polished"))
        let final = await success.process(rawText: "raw", customSystemPrompt: "fixture", onFailure: { failures += 1 })
        precondition(final == "polished" && failures == 2)
        let unconfigured = LLMService()
        let noLLM = await unconfigured.process(rawText: "raw", customSystemPrompt: "fixture", applyAliases: true, onFailure: { failures += 1 })
        precondition(noLLM == "alias:raw" && failures == 2)
        let required = await unconfigured.process(rawText: "raw", customSystemPrompt: "fixture", requireLLM: true, onFailure: { failures += 1 })
        precondition(required.isEmpty && failures == 3)
        print("PASS: 5 real LLMService failure/fallback callback checks; fake provider and config")
    }
}
