import Foundation
@main struct DictionaryThreadingTests {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vox327-dictionary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let bad = Data("{broken".utf8), file = dir.appendingPathComponent("dictionary.json")
        try bad.write(to:file)
        let dictionary = DictionaryService(directory:dir.path)
        DispatchQueue.concurrentPerform(iterations:200) { index in
            if index % 3 == 0 { _ = dictionary.terms }
            else if index % 3 == 1 { _ = dictionary.addTerm("Fixture") }
            else { _ = dictionary.lastError }
        }
        precondition(dictionary.lastError != nil)
        let after = try Data(contentsOf:file)
        precondition(after == bad)
        print("PASS: 200 concurrent dictionary/error-state operations, corrupt bytes unchanged")
    }
}
