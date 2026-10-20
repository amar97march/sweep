import CryptoKit
import Foundation
import Testing
@testable import SweepScanners

@Suite struct YaraTests {
    private func matches(_ rules: String, _ data: Data) -> [String] {
        let set = YaraRuleSet(source: rules)
        #expect(set.skipped.isEmpty, "skipped: \(set.skipped)")
        return set.matches(data)
    }

    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    /// A fake 64-bit Mach-O: magic + filler + payload.
    private func macho(_ payload: String) -> Data {
        Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01]) + Data(repeating: 0, count: 24) + Data(payload.utf8)
    }

    @Test func textModifiers() {
        let rules = """
            rule plain { strings: $a = "evil" condition: $a }
            rule nocase { strings: $a = "EVIL" nocase condition: $a }
            rule wide { strings: $a = "evil" wide condition: $a }
            rule word { strings: $a = "evil" fullword condition: $a }
            rule xored { strings: $a = "evil" xor condition: $a }
            rule b64 { strings: $a = "evil payload" base64 condition: $a }
            """
        #expect(matches(rules, bytes("some evil text")) == ["plain", "nocase", "word", "xored"])
        #expect(matches(rules, bytes("some EvIl")) == ["nocase"])
        #expect(matches(rules, Data("xe\u{0}v\u{0}i\u{0}l\u{0}x".utf8)) == ["wide"])
        #expect(matches(rules, bytes("devilish")).contains("plain"))
        #expect(!matches(rules, bytes("devilish")).contains("word"))
        let key: UInt8 = 0x5A
        #expect(matches(rules, Data("..evil..".utf8.map { $0 ^ key })) == ["xored"])
        for prefix in ["", "x", "xy"] {
            let encoded = Data((prefix + "evil payload!").utf8).base64EncodedString()
            #expect(matches(rules, bytes("data=" + encoded)).contains("b64"), "prefix \(prefix)")
        }
    }

    @Test func hexStrings() {
        let rules = """
            rule wildcard { strings: $a = { 48 8B ?? 4? } condition: $a }
            rule alternatives { strings: $a = { 31 ( C0 | DB | 00 44 ) 90 } condition: $a }
            rule jump { strings: $a = { AA [2-4] BB } condition: $a }
            rule unbounded { strings: $a = { AA [-] CC } condition: $a }
            """
        #expect(matches(rules, Data([0x00, 0x48, 0x8B, 0x12, 0x4F])) == ["wildcard"])
        #expect(matches(rules, Data([0x48, 0x8B, 0x12, 0x5F])).isEmpty)
        #expect(matches(rules, Data([0x31, 0xDB, 0x90])) == ["alternatives"])
        #expect(matches(rules, Data([0x31, 0x00, 0x44, 0x90])) == ["alternatives"])
        #expect(matches(rules, Data([0xAA, 1, 2, 3, 0xBB])) == ["jump"])
        #expect(matches(rules, Data([0xAA, 1, 0xBB])).isEmpty)
        #expect(matches(rules, Data([0xAA] + [UInt8](repeating: 7, count: 500) + [0xCC])) == ["unbounded"])
    }

    @Test func conditions() {
        let rules = """
            private rule Macho { condition: uint32(0) == 0xfeedfacf or uint32(0) == 0xcafebabe }
            rule small_macho { strings: $a = "payload" condition: Macho and filesize < 1KB and $a }
            rule header { condition: uint32be(0) == 0xcffaedfe and uint8(uint8(4)) == 0x00 }
            rule at_offset { strings: $a = "payload" condition: $a at 32 }
            rule in_range { strings: $a = "payload" condition: $a in (0..100) }
            rule counted { strings: $a = "ab" condition: #a == 3 and @a[2] == 35 }
            rule two_of { strings: $x1 = "one" $x2 = "two" $x3 = "three" condition: 2 of ($x*) }
            rule none_of { strings: $a = "zzz" condition: none of them }
            rule for_of { strings: $a1 = "pay" $a2 = "nope" condition: for any of ($a*) : ( $ at 32 ) }
            rule for_in { condition: for all i in (0..1) : ( uint8(i + 2) == 0xED or uint8(i + 2) == 0xFE ) }
            """
        let data = macho("payload ab ab ab one two")
        let found = Set(matches(rules, data))
        #expect(found == ["small_macho", "header", "at_offset", "in_range", "two_of", "none_of", "for_of", "for_in"])

        let counted = macho("ab abab")
        #expect(matches(rules, counted).contains("counted"))
        #expect(!matches(rules, bytes("payload")).contains("small_macho"))  // not Mach-O
    }

    @Test func hashConditions() {
        let data = bytes("known bad file")
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let rules = """
            import "hash"
            rule known { condition: filesize < 100 and hash.sha256(0, filesize) == "\(digest.uppercased())" }
            """
        #expect(matches(rules, data) == ["known"])
        #expect(matches(rules, bytes("other file")).isEmpty)
    }

    @Test func commentsAndMetaAreIgnored() {
        let rules = """
            /* block comment */
            rule commented : tag1 tag2
            {
                meta:
                    description = "test"  // trailing comment
                    score = 10
                strings:
                    $a = { 41 42 // inline comment
                           43 }
                condition:
                    $a
            }
            """
        #expect(matches(rules, bytes("xxABCxx")) == ["commented"])
    }

    @Test func unsupportedRulesAreSkippedNotMisread() {
        let set = YaraRuleSet(source: """
            import "pe"
            rule uses_pe { condition: pe.number_of_sections > 2 }
            rule fine { strings: $a = "ok" condition: $a }
            rule percent { strings: $a = "x" $b = "y" condition: 50% of them }
            """)
        #expect(set.rules.map(\.name) == ["fine"])
        #expect(Set(set.skipped.map(\.name)) == ["uses_pe", "percent"])
        #expect(set.matches(Data("ok".utf8)) == ["fine"])
    }

    /// Apple's XProtect rules, read in place (never copied into the project).
    static let xprotect = ["/var/protected/xprotect/XProtect.bundle/Contents/Resources/XProtect.yara",
                           "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Resources/XProtect.yara"]
        .first(where: FileManager.default.isReadableFile)

    @Test(.enabled(if: xprotect != nil)) func compilesNearlyAllXProtectRules() throws {
        let source = try String(contentsOfFile: Self.xprotect!, encoding: .utf8)
        let set = YaraRuleSet(source: source)
        let total = set.rules.count + set.skipped.count
        #expect(total > 100)
        #expect(Double(set.rules.count) / Double(total) > 0.95, "skipped \(set.skipped.count): \(set.skipped.prefix(5))")
    }

    @Test(.enabled(if: xprotect != nil && ProcessInfo.processInfo.environment["SWEEP_PROFILE_YARA"] != nil))
    func profileSlowRules() throws {
        let set = YaraRuleSet(source: try String(contentsOfFile: Self.xprotect!, encoding: .utf8))
        let data = try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/ssh"), options: .mappedIfSafe)
        let profile = set.profile(data)
        print("total \(profile.reduce(0) { $0 + $1.seconds }) s for \(data.count) bytes")
        for (name, seconds) in profile.prefix(12) {
            let rule = set.rules.first { $0.name == name }!
            print(String(format: "%.4f", seconds), name, rule.strings.values.map { p -> String in
                switch p.body { case .hex(let t): "hex(\(t.count), atom \(p.atom?.bytes.count ?? 0))"; case .text(let b): "text(\(b.count)\(p.nocase ? ",nocase" : "")\(p.wide ? ",wide" : "")\(p.xor != nil ? ",xor" : ""))"; case .regex: "regex" }
            }.prefix(6).joined(separator: " "))
        }
    }

    @Test(.enabled(if: xprotect != nil)) func macOSToolsAreNotFlagged() throws {
        let set = YaraRuleSet(source: try String(contentsOfFile: Self.xprotect!, encoding: .utf8))
        let tools = ["/bin", "/usr/bin"].flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).map { folder + "/" + $0 }
        }.prefix(150)
        var flagged: [String] = []
        let start = Date()
        for path in tools {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
                  data.count < 20_000_000 else { continue }
            let hits = set.matches(data)
            if !hits.isEmpty { flagged.append("\(path): \(hits)") }
        }
        #expect(flagged.isEmpty, "false positives: \(flagged)")
        print("XProtect scan of \(tools.count) macOS tools took \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
    }
}
