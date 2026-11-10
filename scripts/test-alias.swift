// test-alias.swift — Standalone test runner for AliasService logic.
//
// Run: swiftc scripts/test-alias.swift Vox/Services/{AliasService,JSONBackupStore}.swift -o /tmp/test-alias && /tmp/test-alias
//
// Covers (per @鹰眼 spec v2 review):
//   - word-boundary, substring, regex match modes
//   - case sensitivity
//   - non-overlapping ranges, longer-first preference
//   - alias chain prevention (single-pass)
//   - invalid regex skipped (doesn't poison other aliases)
//   - empty / no-op aliases skipped

import Foundation

@main
struct TestAlias {
    static func main() { runTests() }
}

var passed = 0
var failed = 0

func assertEq(_ actual: String, _ expected: String, _ name: String, file: String = #file, line: Int = #line) {
    if actual == expected {
        passed += 1
        // print("  ✓ \(name)")
    } else {
        failed += 1
        print("  ✗ \(name)")
        print("      expected: \(expected)")
        print("      actual:   \(actual)")
        print("      at \(file):\(line)")
    }
}

func test(_ name: String, _ block: () -> Void) {
    print("• \(name)")
    block()
}

// Helper to keep tests terse. Defaults match common Latin word-boundary case-insensitive.
func A(from: String, to: String, matchMode: AliasService.MatchMode = .word, caseSensitive: Bool = false) -> AliasService.Alias {
    AliasService.Alias.make(from: from, to: to, matchMode: matchMode, caseSensitive: caseSensitive)
}

func runTests() {

// ── Match modes ──────────────────────────────────────────────────────────

test("word-boundary case-insensitive matches whole token") {
    let r = AliasService.apply("the cloud code is great",
        aliases: [A(from: "cloud code", to: "Claude Code")])
    assertEq(r, "the Claude Code is great", "basic word match")
}

test("word-boundary does NOT match partial token") {
    let r = AliasService.apply("clouds are nice",
        aliases: [A(from: "cloud", to: "Claude")])
    assertEq(r, "clouds are nice", "no false match in 'clouds'")
}

test("substring mode matches inside larger token") {
    let r = AliasService.apply("clouds are nice",
        aliases: [A(from: "cloud", to: "Claude", matchMode: .substring)])
    assertEq(r, "Claudes are nice", "substring matches in 'clouds'")
}

test("substring mode for CJK") {
    let r = AliasService.apply("我用鸿杉投资了 MiniMax",
        aliases: [A(from: "鸿杉", to: "红杉", matchMode: .substring, caseSensitive: true)])
    assertEq(r, "我用红杉投资了 MiniMax", "CJK substring replacement")
}

test("case-sensitive word match") {
    let r = AliasService.apply("CLOUD code",
        aliases: [A(from: "cloud", to: "Claude", matchMode: .word, caseSensitive: true)])
    assertEq(r, "CLOUD code", "case-sensitive: CLOUD does not match cloud")

    let r2 = AliasService.apply("cloud code",
        aliases: [A(from: "cloud", to: "Claude", matchMode: .word, caseSensitive: true)])
    assertEq(r2, "Claude code", "case-sensitive: cloud matches cloud")
}

test("regex mode") {
    let r = AliasService.apply("v1.2.3 release",
        aliases: [A(from: "v\\d+\\.\\d+\\.\\d+", to: "VERSION", matchMode: .regex)])
    assertEq(r, "VERSION release", "regex match")
}

// ── Non-overlapping ranges ───────────────────────────────────────────────

test("longer alias wins over shorter when both match same region") {
    let r = AliasService.apply("the cloud code project",
        aliases: [
            A(from: "cloud", to: "WRONG"),
            A(from: "cloud code", to: "Claude Code"),
        ])
    assertEq(r, "the Claude Code project", "longer 'cloud code' wins, 'cloud' inside skipped")
}

test("two non-overlapping aliases both apply") {
    let r = AliasService.apply("MiniMax and 鸿杉",
        aliases: [
            A(from: "MiniMax", to: "MiniMax"),  // no-op (skipped at load), use real diff
            A(from: "鸿杉", to: "红杉", matchMode: .substring, caseSensitive: true),
        ])
    assertEq(r, "MiniMax and 红杉", "second alias applied; first is no-op")
}

test("multiple matches of same alias all replaced") {
    let r = AliasService.apply("cloud code is good cloud code",
        aliases: [A(from: "cloud code", to: "Claude Code")])
    assertEq(r, "Claude Code is good Claude Code", "multiple non-overlapping replacements")
}

// ── Alias chain prevention (single pass over original text) ──────────────

test("alias chain does NOT propagate (single pass)") {
    // A: cloud -> Claude, B: Claude -> Claude Code
    // Input "cloud" should produce "Claude" not "Claude Code"
    let r = AliasService.apply("the cloud is here",
        aliases: [
            A(from: "cloud", to: "Claude"),
            A(from: "Claude", to: "Claude Code", caseSensitive: true),
        ])
    // After A: "the Claude is here". B's match against ORIGINAL is none.
    // Single pass: only direct matches against original text apply.
    assertEq(r, "the Claude is here", "no chain: cloud→Claude does not feed Claude→Claude Code")
}

// ── Invalid regex isolation ─────────────────────────────────────────────

test("invalid regex does not poison other aliases") {
    let r = AliasService.apply("cloud code is great",
        aliases: [
            A(from: "[unclosed", to: "BAD", matchMode: .regex),  // invalid
            A(from: "cloud code", to: "Claude Code"),
        ])
    assertEq(r, "Claude Code is great", "valid alias still applies despite invalid sibling")
}

// ── Edge cases ──────────────────────────────────────────────────────────

test("empty input returns empty") {
    let r = AliasService.apply("", aliases: [A(from: "x", to: "y")])
    assertEq(r, "", "empty input")
}

test("empty aliases list returns input unchanged") {
    let r = AliasService.apply("hello world", aliases: [])
    assertEq(r, "hello world", "no aliases")
}

test("from === to no-op (skipped at load)") {
    // Direct apply with from===to: still safe (no infinite loop, just replaces 'x' with 'x')
    let r = AliasService.apply("xyz", aliases: [A(from: "x", to: "x")])
    assertEq(r, "xyz", "from==to no-op")
}

// ── Default seed sanity ─────────────────────────────────────────────────

test("seed: cloud code → Claude Code (case-insensitive)") {
    let seed = [A(from: "cloud code", to: "Claude Code", matchMode: .word, caseSensitive: false)]
    assertEq(AliasService.apply("Cloud Code rocks", aliases: seed),
        "Claude Code rocks", "Cloud Code variant")
    assertEq(AliasService.apply("CLOUD CODE rocks", aliases: seed),
        "Claude Code rocks", "CLOUD CODE variant")
}

test("[CRITICAL REGRESSION] seed does NOT touch 'cloud computing'") {
    let seed = [A(from: "cloud code", to: "Claude Code", matchMode: .word, caseSensitive: false)]
    assertEq(AliasService.apply("we use cloud computing", aliases: seed),
        "we use cloud computing", "default seed leaves unrelated 'cloud' alone")
}

// ── Summary ─────────────────────────────────────────────────────────────

print("\n=== Results: \(passed) passed, \(failed) failed ===")
exit(failed == 0 ? 0 : 1)

}  // end runTests

