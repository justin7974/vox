import Foundation
// Same executable source runs against preserved dirty baseline and candidate.
// Custom URL scheme can only be handled by this in-process protocol, never the network.
final class OfflineHTTP: URLProtocol {
    static var response: [String:Any] = [:]
    static var calls = 0
    override class func canInit(with request:URLRequest)->Bool { request.url?.scheme == "vox-test" }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:Self.response))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct BaselineCompatible {
    static func main() async {
        var failed = 0
        func verify(_ result:Bool,_ name:String) { print("\(result ? "PASS" : "FAIL"): \(name)");if !result {failed += 1} }
        let a = AliasService.Alias.make
        verify(AliasService.apply("我用cloud code写",aliases:[a("cloud code","Claude Code",.word,false)]) == "我用Claude Code写", "CJK word adjacency")
        verify(AliasService.apply("C++",aliases:[a("C++","cpp",.word,false)]) == "cpp", "punctuated Latin alias")
        verify(AliasService.apply("abc",aliases:[a("^","X",.regex,false)]) == "abc", "zero-width regex")
        precondition(URLProtocol.registerClass(OfflineHTTP.self))
        OfflineHTTP.response = ["choices":[["finish_reason":"length","message":["content":"PRIVATE-RESULT"]]]]
        let open = await OpenAIProvider(baseURL:"vox-test://unit",apiKey:"fake",model:"test").complete(userMessage:"PRIVATE-INPUT",systemPrompt:"private")
        verify(open.isEmpty,"truncated OpenAI response")
        OfflineHTTP.response = ["stop_reason":"max_tokens","content":[["type":"text","text":"PRIVATE-RESULT"]]]
        let anth = await AnthropicProvider(baseURL:"vox-test://unit",apiKey:"fake",model:"test").complete(userMessage:"PRIVATE-INPUT",systemPrompt:"private")
        verify(anth.isEmpty,"truncated Anthropic response")
        verify(!LogService.messages.joined().contains("PRIVATE"),"API content privacy")
        precondition(OfflineHTTP.calls == 2,"offline HTTP path must actually run")
        print("baseline-compatible: \(6-failed)/6 passed")
        exit(failed == 0 ? 0 : 1)
    }
}
