import CryptoKit
import Foundation

/// A YARA-subset engine: enough of the language to run Apple's XProtect rules (read in place from the
/// user's Mac, never copied) and other public rule sets. Rules using anything unsupported are skipped and
/// counted, never evaluated wrongly.
public struct YaraRuleSet: Sendable {
    public struct Rule: Sendable {
        public let name: String
        public let isPrivate: Bool
        public let meta: [String: String]
        let strings: [String: StringPattern]
        let stringOrder: [String]
        let condition: Expr
    }

    public let rules: [Rule]
    /// Rules that couldn't be compiled, with the reason.
    public let skipped: [(name: String, reason: String)]
    let index: PatternIndex

    /// Compiles rules from source. Never throws: problem rules are skipped.
    public init(source: String) {
        var parser = YaraParser(source: source)
        let result = parser.parseFile()
        rules = result.rules
        skipped = result.skipped
        index = PatternIndex(rules: result.rules)
    }

    public var publicRules: [Rule] { rules.filter { !$0.isPrivate } }

    /// Seconds spent on each public rule for `data`, slowest first (for tuning).
    func profile(_ data: Data) -> [(name: String, seconds: Double)] {
        let byName = Dictionary(rules.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let context = MatchContext(data: data, rules: byName, index: index)
        return publicRules.map { rule in
            let start = DispatchTime.now().uptimeNanoseconds
            _ = context.evaluate(rule: rule)
            return (rule.name, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }.sorted { $0.seconds > $1.seconds }
    }

    /// Names of public rules that match `data`.
    public func matches(_ data: Data) -> [String] {
        let context = MatchContext(data: data, rules: Dictionary(rules.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }),
                                   index: index)
        return publicRules.compactMap { rule in context.evaluate(rule: rule) ? rule.name : nil }
    }
}

// MARK: - Model

indirect enum Expr: Sendable {
    case int(Int64)
    case text(String)
    case bool(Bool)
    case filesize
    case ruleRef(String)
    case stringMatch(String)                  // $a  (or "$" inside for-of)
    case stringAt(String, Expr)               // $a at expr
    case stringIn(String, Expr, Expr)         // $a in (lo..hi)
    case stringCount(String)                  // #a
    case stringOffset(String, Expr)           // @a[i]
    case readInt(bits: Int, bigEndian: Bool, Expr)
    case hash(String, Expr, Expr)             // hash.sha256(offset, size)
    case unary(String, Expr)
    case binary(String, Expr, Expr)
    /// Flat `a or b or c …` / `a and b and c …`, so long chains (hash lists) don't nest thousands deep.
    case anyTrue([Expr])
    case allTrue([Expr])
    case of(Quantifier, [String])             // N of ($a*)
    case forOf(Quantifier, [String], Expr)    // for any of ($a*) : (...)
    case forIn(Quantifier, String, Expr, Expr, Expr)  // for all i in (lo..hi) : (...)
    case variable(String)
}

enum Quantifier: Sendable {
    case any, all, none, count(Int)

    func satisfied(_ hits: Int, of total: Int) -> Bool {
        switch self {
        case .any: hits >= 1
        case .all: hits == total && total > 0
        case .none: hits == 0
        case .count(let n): hits >= n
        }
    }
}

struct StringPattern: Sendable {
    /// Unique per parsed string, to find its key in the rule.
    var identity = UUID()
    enum Body: Sendable {
        case text([UInt8])
        case hex([HexToken])
        case regex(String, caseInsensitive: Bool, dotAll: Bool)
    }

    var body: Body
    /// For hex patterns: the longest run of fully known bytes, and its distance from the pattern start.
    var atom: (bytes: [UInt8], offset: Int)?
    var ascii = false, wide = false, nocase = false, fullword = false
    var xor: ClosedRange<Int>?
    var base64 = false, base64wide = false
}

enum HexToken: Sendable {
    case byte(UInt8, mask: UInt8)
    case alternatives([[HexToken]])
    case jump(min: Int, max: Int?)
}

// MARK: - Lexer

struct YaraToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case identifier, variable, count, offset, length, number, string, regex, hex, symbol, end
    }
    var kind: Kind
    var text: String
    var number: Int64 = 0
}

struct YaraLexer {
    let scalars: [UInt8]
    var index = 0

    init(_ source: String) { scalars = Array(source.utf8) }

    mutating func skipTrivia() {
        while index < scalars.count {
            let c = scalars[index]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { index += 1; continue }
            if c == UInt8(ascii: "/"), index + 1 < scalars.count {
                if scalars[index + 1] == UInt8(ascii: "/") {
                    while index < scalars.count && scalars[index] != 0x0A { index += 1 }
                    continue
                }
                if scalars[index + 1] == UInt8(ascii: "*") {
                    index += 2
                    while index + 1 < scalars.count && !(scalars[index] == UInt8(ascii: "*") && scalars[index + 1] == UInt8(ascii: "/")) { index += 1 }
                    index = min(index + 2, scalars.count)
                    continue
                }
            }
            break
        }
    }

    /// Reads the raw text of a hex string body (`{ ... }`), comments removed.
    mutating func rawHex() -> String {
        // index is at "{"
        index += 1
        var out = ""
        while index < scalars.count && scalars[index] != UInt8(ascii: "}") {
            if scalars[index] == UInt8(ascii: "/"), index + 1 < scalars.count, scalars[index + 1] == UInt8(ascii: "/") {
                while index < scalars.count && scalars[index] != 0x0A { index += 1 }
                continue
            }
            if scalars[index] == UInt8(ascii: "/"), index + 1 < scalars.count, scalars[index + 1] == UInt8(ascii: "*") {
                index += 2
                while index + 1 < scalars.count && !(scalars[index] == UInt8(ascii: "*") && scalars[index + 1] == UInt8(ascii: "/")) { index += 1 }
                index += 2
                continue
            }
            out.append(Character(UnicodeScalar(scalars[index])))
            index += 1
        }
        index += 1
        return out
    }

    mutating func next(regexAllowed: Bool) -> YaraToken {
        skipTrivia()
        guard index < scalars.count else { return YaraToken(kind: .end, text: "") }
        let c = scalars[index]
        func isIdent(_ b: UInt8) -> Bool { (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F }

        if c == UInt8(ascii: "\"") {
            index += 1
            var bytes: [UInt8] = []
            while index < scalars.count && scalars[index] != UInt8(ascii: "\"") {
                if scalars[index] == UInt8(ascii: "\\"), index + 1 < scalars.count {
                    index += 1
                    switch scalars[index] {
                    case UInt8(ascii: "n"): bytes.append(0x0A)
                    case UInt8(ascii: "t"): bytes.append(0x09)
                    case UInt8(ascii: "r"): bytes.append(0x0D)
                    case UInt8(ascii: "x"):
                        let hex = String(decoding: scalars[(index + 1)..<min(index + 3, scalars.count)], as: UTF8.self)
                        bytes.append(UInt8(hex, radix: 16) ?? 0)
                        index += 2
                    default: bytes.append(scalars[index])
                    }
                } else {
                    bytes.append(scalars[index])
                }
                index += 1
            }
            index += 1
            return YaraToken(kind: .string, text: String(decoding: bytes, as: UTF8.self), number: 0)
                .withBytes(bytes)
        }
        if c == UInt8(ascii: "/") && regexAllowed {
            index += 1
            var body = ""
            while index < scalars.count && scalars[index] != UInt8(ascii: "/") {
                if scalars[index] == UInt8(ascii: "\\"), index + 1 < scalars.count {
                    body.append("\\")
                    index += 1
                }
                body.append(Character(UnicodeScalar(scalars[index])))
                index += 1
            }
            index += 1
            var flags = ""
            while index < scalars.count, scalars[index] == UInt8(ascii: "i") || scalars[index] == UInt8(ascii: "s") {
                flags.append(Character(UnicodeScalar(scalars[index])))
                index += 1
            }
            return YaraToken(kind: .regex, text: body + "\u{0}" + flags)
        }
        if c == UInt8(ascii: "$") || c == UInt8(ascii: "#") || c == UInt8(ascii: "@") || c == UInt8(ascii: "!") && index + 1 < scalars.count && isIdent(scalars[index + 1]) {
            let start = index
            index += 1
            while index < scalars.count && (isIdent(scalars[index]) || scalars[index] == UInt8(ascii: "*")) { index += 1 }
            let text = String(decoding: scalars[start..<index], as: UTF8.self)
            let kind: YaraToken.Kind = c == UInt8(ascii: "$") ? .variable : c == UInt8(ascii: "#") ? .count : c == UInt8(ascii: "@") ? .offset : .length
            return YaraToken(kind: kind, text: text)
        }
        if c >= 0x30 && c <= 0x39 {
            let start = index
            var value: Int64 = 0
            if c == UInt8(ascii: "0"), index + 1 < scalars.count, scalars[index + 1] == UInt8(ascii: "x") || scalars[index + 1] == UInt8(ascii: "X") {
                index += 2
                let digits = index
                while index < scalars.count, let _ = UInt8(String(UnicodeScalar(scalars[index])), radix: 16) { index += 1 }
                value = Int64(String(decoding: scalars[digits..<index], as: UTF8.self), radix: 16) ?? 0
            } else {
                while index < scalars.count && scalars[index] >= 0x30 && scalars[index] <= 0x39 { index += 1 }
                value = Int64(String(decoding: scalars[start..<index], as: UTF8.self)) ?? 0
                if index + 1 < scalars.count {
                    let suffix = String(decoding: scalars[index..<index + 2], as: UTF8.self)
                    if suffix == "KB" { value *= 1024; index += 2 } else if suffix == "MB" { value *= 1024 * 1024; index += 2 }
                }
            }
            return YaraToken(kind: .number, text: String(decoding: scalars[start..<index], as: UTF8.self), number: value)
        }
        if isIdent(c) {
            let start = index
            while index < scalars.count && (isIdent(scalars[index]) || scalars[index] == UInt8(ascii: ".")) && !(scalars[index] == UInt8(ascii: ".") && index + 1 < scalars.count && scalars[index + 1] == UInt8(ascii: ".")) {
                index += 1
            }
            return YaraToken(kind: .identifier, text: String(decoding: scalars[start..<index], as: UTF8.self))
        }
        for symbol in ["..", "==", "!=", "<=", ">=", "<<", ">>"] {
            let bytes = Array(symbol.utf8)
            if index + 1 < scalars.count && scalars[index] == bytes[0] && scalars[index + 1] == bytes[1] {
                index += 2
                return YaraToken(kind: .symbol, text: symbol)
            }
        }
        index += 1
        return YaraToken(kind: .symbol, text: String(UnicodeScalar(c)))
    }
}

private extension YaraToken {
    func withBytes(_ bytes: [UInt8]) -> YaraToken {
        var token = self
        // Keep raw bytes losslessly: Latin-1 maps each byte to one character.
        token.text = String(bytes.map { Character(UnicodeScalar($0)) })
        return token
    }
}

// MARK: - Parser

struct YaraParseError: Error { let message: String }

struct YaraParser {
    var lexer: YaraLexer
    var current: YaraToken
    var regexAllowed = false

    init(source: String) {
        lexer = YaraLexer(source)
        current = lexer.next(regexAllowed: false)
    }

    mutating func advance() { current = lexer.next(regexAllowed: regexAllowed) }

    mutating func expect(_ text: String) throws {
        guard current.text == text else { throw YaraParseError(message: "expected \(text), found \(current.text)") }
        advance()
    }

    mutating func parseFile() -> (rules: [YaraRuleSet.Rule], skipped: [(String, String)]) {
        var rules: [YaraRuleSet.Rule] = []
        var skipped: [(String, String)] = []
        while current.kind != .end {
            if current.text == "import" || current.text == "include" {
                advance(); advance()
                continue
            }
            var isPrivate = false
            while current.text == "private" || current.text == "global" {
                if current.text == "private" { isPrivate = true }
                advance()
            }
            guard current.text == "rule" else { advance(); continue }
            advance()
            let name = current.text
            do {
                rules.append(try parseRule(name: name, isPrivate: isPrivate))
            } catch let error as YaraParseError {
                skipped.append((name, error.message))
                skipToRuleEnd()
            } catch {
                skipped.append((name, "\(error)"))
                skipToRuleEnd()
            }
        }
        return (rules, skipped)
    }

    /// After a failure, move past the closing brace of the current rule.
    mutating func skipToRuleEnd() {
        regexAllowed = false
        while current.kind != .end {
            if current.kind == .identifier && current.text == "rule" { return }
            if current.text == "condition" {
                // Conditions don't contain braces; the next "}" closes the rule.
                while current.kind != .end && current.text != "}" { advance() }
                advance()
                return
            }
            advance()
        }
    }

    mutating func parseRule(name: String, isPrivate: Bool) throws -> YaraRuleSet.Rule {
        advance()
        if current.text == ":" {
            advance()
            while current.kind == .identifier { advance() }
        }
        try expect("{")
        var meta: [String: String] = [:]
        var strings: [String: StringPattern] = [:]
        var order: [String] = []
        var condition: Expr?
        while current.text != "}" && current.kind != .end {
            let section = current.text
            advance()
            try expect(":")
            switch section {
            case "meta":
                while current.kind == .identifier && !["strings", "condition"].contains(current.text) {
                    let key = current.text
                    advance()
                    try expect("=")
                    if current.text == "-" { advance() }
                    meta[key] = current.text
                    advance()
                }
            case "strings":
                while current.kind == .variable {
                    let id = current.text
                    advance()
                    guard current.text == "=" else { throw YaraParseError(message: "expected = after \(id)") }
                    // Peek at the raw character to handle hex blocks and regexes.
                    lexer.skipTrivia()
                    let pattern: StringPattern
                    if lexer.index < lexer.scalars.count && lexer.scalars[lexer.index] == UInt8(ascii: "{") {
                        let tokens = try HexParser.parse(lexer.rawHex())
                        pattern = StringPattern(body: .hex(tokens), atom: HexMatcher.atom(tokens))
                        advance()
                    } else {
                        regexAllowed = true
                        advance()
                        regexAllowed = false
                        switch current.kind {
                        case .string: pattern = StringPattern(body: .text(current.text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }))
                        case .regex:
                            let parts = current.text.split(separator: "\u{0}", omittingEmptySubsequences: false)
                            let flags = parts.count > 1 ? String(parts[1]) : ""
                            pattern = StringPattern(body: .regex(String(parts[0]), caseInsensitive: flags.contains("i"), dotAll: flags.contains("s")))
                        default: throw YaraParseError(message: "bad string \(id)")
                        }
                        advance()
                    }
                    var configured = pattern
                    try parseModifiers(&configured)
                    strings[id] = configured
                    order.append(id)
                }
            case "condition":
                condition = try parseOr()
            default:
                throw YaraParseError(message: "unknown section \(section)")
            }
        }
        try expect("}")
        guard let condition else { throw YaraParseError(message: "no condition") }
        return YaraRuleSet.Rule(name: name, isPrivate: isPrivate, meta: meta, strings: strings, stringOrder: order, condition: condition)
    }

    mutating func parseModifiers(_ pattern: inout StringPattern) throws {
        while current.kind == .identifier {
            switch current.text {
            case "ascii": pattern.ascii = true
            case "wide": pattern.wide = true
            case "nocase": pattern.nocase = true
            case "fullword": pattern.fullword = true
            case "private": break
            case "xor":
                pattern.xor = 0...255
                advance()
                if current.text == "(" {
                    advance()
                    let low = Int(current.number); advance()
                    var high = low
                    if current.text == "-" { advance(); high = Int(current.number); advance() }
                    try expect(")")
                    pattern.xor = low...high
                }
                continue
            case "base64": pattern.base64 = true
            case "base64wide": pattern.base64wide = true
            default: return
            }
            advance()
        }
    }

    // Precedence: or < and < not < comparison < bitwise < shift < additive < multiplicative < unary.

    mutating func parseOr() throws -> Expr {
        var operands = [try parseAnd()]
        while current.text == "or" { advance(); operands.append(try parseAnd()) }
        return operands.count == 1 ? operands[0] : .anyTrue(operands)
    }

    mutating func parseAnd() throws -> Expr {
        var operands = [try parseNot()]
        while current.text == "and" { advance(); operands.append(try parseNot()) }
        return operands.count == 1 ? operands[0] : .allTrue(operands)
    }

    mutating func parseNot() throws -> Expr {
        if current.text == "not" { advance(); return .unary("not", try parseNot()) }
        return try parseComparison()
    }

    mutating func parseComparison() throws -> Expr {
        let left = try parseBitwise()
        if ["==", "!=", "<", "<=", ">", ">="].contains(current.text) && current.kind == .symbol {
            let op = current.text
            advance()
            return .binary(op, left, try parseBitwise())
        }
        if current.text == "contains" || current.text == "matches" || current.text == "icontains" {
            throw YaraParseError(message: "\(current.text) is not supported")
        }
        return left
    }

    mutating func parseBitwise() throws -> Expr {
        var left = try parseShift()
        while current.kind == .symbol && ["|", "^", "&"].contains(current.text) {
            let op = current.text
            advance()
            left = .binary(op, left, try parseShift())
        }
        return left
    }

    mutating func parseShift() throws -> Expr {
        var left = try parseAdditive()
        while current.kind == .symbol && ["<<", ">>"].contains(current.text) {
            let op = current.text
            advance()
            left = .binary(op, left, try parseAdditive())
        }
        return left
    }

    mutating func parseAdditive() throws -> Expr {
        var left = try parseMultiplicative()
        while current.kind == .symbol && ["+", "-"].contains(current.text) {
            let op = current.text
            advance()
            left = .binary(op, left, try parseMultiplicative())
        }
        return left
    }

    mutating func parseMultiplicative() throws -> Expr {
        var left = try parseUnary()
        while current.kind == .symbol && ["*", "\\", "%"].contains(current.text) {
            let op = current.text
            advance()
            left = .binary(op, left, try parseUnary())
        }
        return left
    }

    mutating func parseUnary() throws -> Expr {
        if current.kind == .symbol && current.text == "-" { advance(); return .unary("-", try parseUnary()) }
        if current.kind == .symbol && current.text == "~" { advance(); return .unary("~", try parseUnary()) }
        return try parsePrimary()
    }

    mutating func parseRange() throws -> (Expr, Expr) {
        try expect("(")
        let low = try parseOr()
        try expect("..")
        let high = try parseOr()
        try expect(")")
        return (low, high)
    }

    mutating func parseStringSet() throws -> [String] {
        if current.text == "them" { advance(); return ["$*"] }
        try expect("(")
        var set: [String] = []
        while current.text != ")" {
            guard current.kind == .variable else { throw YaraParseError(message: "unsupported set member \(current.text)") }
            set.append(current.text)
            advance()
            if current.text == "," { advance() }
        }
        try expect(")")
        return set
    }

    mutating func parseQuantifier() throws -> Quantifier? {
        switch current.text {
        case "any": advance(); return .any
        case "all": advance(); return .all
        case "none": advance(); return Quantifier.none
        default:
            if current.kind == .number {
                let saved = (lexer, current)
                let n = Int(current.number)
                advance()
                if current.text == "of" || current.text == "%" {
                    if current.text == "%" { throw YaraParseError(message: "percent quantifiers are not supported") }
                    return .count(n)
                }
                (lexer, current) = saved
            }
            return nil
        }
    }

    mutating func parsePrimary() throws -> Expr {
        let token = current
        if token.text == "for" {
            advance()
            guard let quantifier = try parseQuantifier() else { throw YaraParseError(message: "bad for quantifier") }
            if current.text == "of" {
                advance()
                let set = try parseStringSet()
                try expect(":")
                try expect("(")
                let body = try parseOr()
                try expect(")")
                return .forOf(quantifier, set, body)
            }
            guard current.kind == .identifier else { throw YaraParseError(message: "bad for loop") }
            let variable = current.text
            advance()
            try expect("in")
            let (low, high) = try parseRange()
            try expect(":")
            try expect("(")
            let body = try parseOr()
            try expect(")")
            return .forIn(quantifier, variable, low, high, body)
        }
        if let quantifier = try parseQuantifier() {
            try expect("of")
            return .of(quantifier, try parseStringSet())
        }
        switch token.kind {
        case .number:
            advance()
            return .int(token.number)
        case .string:
            advance()
            return .text(token.text)
        case .variable:
            advance()
            if current.text == "at" {
                advance()
                return .stringAt(token.text, try parseUnary())
            }
            if current.text == "in" {
                advance()
                let (low, high) = try parseRange()
                return .stringIn(token.text, low, high)
            }
            return .stringMatch(token.text)
        case .count:
            advance()
            if current.text == "in" { throw YaraParseError(message: "#x in range is not supported") }
            return .stringCount("$" + token.text.dropFirst())
        case .offset:
            advance()
            var index: Expr = .int(1)
            if current.text == "[" {
                advance()
                index = try parseOr()
                try expect("]")
            }
            return .stringOffset("$" + token.text.dropFirst(), index)
        case .identifier:
            advance()
            switch token.text {
            case "filesize": return .filesize
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "entrypoint": throw YaraParseError(message: "entrypoint is not supported")
            case "uint8", "uint16", "uint32", "uint8be", "uint16be", "uint32be", "int8", "int16", "int32", "int16be", "int32be":
                try expect("(")
                let offset = try parseOr()
                try expect(")")
                let bits = Int(token.text.filter(\.isNumber)) ?? 8
                return .readInt(bits: bits, bigEndian: token.text.hasSuffix("be"), offset)
            case "hash.sha256", "hash.sha1", "hash.md5":
                try expect("(")
                let offset = try parseOr()
                try expect(",")
                let size = try parseOr()
                try expect(")")
                return .hash(String(token.text.dropFirst(5)), offset, size)
            default:
                if token.text.contains(".") { throw YaraParseError(message: "module \(token.text) is not supported") }
                if current.text == "(" { throw YaraParseError(message: "function \(token.text) is not supported") }
                return token.text.count == 1 ? .variable(token.text) : .ruleRef(token.text)
            }
        case .symbol where token.text == "(":
            advance()
            let inner = try parseOr()
            try expect(")")
            return inner
        default:
            throw YaraParseError(message: "unexpected \(token.text)")
        }
    }
}

enum HexParser {
    static func parse(_ text: String) throws -> [HexToken] {
        var chars = Array(text.filter { !$0.isWhitespace })[...]
        return try parseSequence(&chars, closing: nil)
    }

    private static func parseSequence(_ chars: inout ArraySlice<Character>, closing: Character?) throws -> [HexToken] {
        var tokens: [HexToken] = []
        while let c = chars.first {
            if c == closing || c == "|" { break }
            if c == "[" {
                chars.removeFirst()
                var spec = ""
                while let d = chars.first, d != "]" { spec.append(d); chars.removeFirst() }
                chars.removeFirst()
                if spec == "-" {
                    tokens.append(.jump(min: 0, max: nil))
                } else if let dash = spec.firstIndex(of: "-") {
                    let low = Int(spec[..<dash]) ?? 0
                    let highText = spec[spec.index(after: dash)...]
                    tokens.append(.jump(min: low, max: highText.isEmpty ? nil : Int(highText)))
                } else {
                    let n = Int(spec) ?? 0
                    tokens.append(.jump(min: n, max: n))
                }
            } else if c == "(" {
                chars.removeFirst()
                var options: [[HexToken]] = []
                while true {
                    options.append(try parseSequence(&chars, closing: ")"))
                    guard let next = chars.first else { throw YaraParseError(message: "unclosed (") }
                    chars.removeFirst()
                    if next == ")" { break }
                }
                tokens.append(.alternatives(options))
            } else {
                guard chars.count >= 2 else { throw YaraParseError(message: "odd hex string") }
                let high = chars.removeFirst(), low = chars.removeFirst()
                func nibble(_ ch: Character) throws -> (UInt8, UInt8) {
                    if ch == "?" { return (0, 0) }
                    guard let v = ch.hexDigitValue else { throw YaraParseError(message: "bad hex \(ch)") }
                    return (UInt8(v), 0xF)
                }
                let (hv, hm) = try nibble(high), (lv, lm) = try nibble(low)
                tokens.append(.byte(hv << 4 | lv, mask: hm << 4 | lm))
            }
        }
        return tokens
    }
}

// MARK: - Matching

/// Per-file evaluation state: string matches and private-rule results are computed once, on demand.
final class MatchContext {
    let data: Data
    let rules: [String: YaraRuleSet.Rule]
    private var ruleResults: [String: Bool] = [:]
    private var matchCache: [String: [Int]] = [:]
    private var lowered: [UInt8]?
    private var latin1: String?
    private var bindings: [String: Int64] = [:]
    private var hashCache: [String: String] = [:]
    private var currentString: String?
    private var currentRule: YaraRuleSet.Rule!
    static let maxMatches = 1_000

    let index: PatternIndex?
    private var indexHits: [String: [Int]]?

    init(data: Data, rules: [String: YaraRuleSet.Rule], index: PatternIndex? = nil) {
        self.data = data
        self.rules = rules
        self.index = index
    }

    /// Positions of every indexed pattern in this file, found in one pass (computed on first use).
    private func indexed(_ key: String) -> [Int]? {
        guard let index, index.keys.contains(key) else { return nil }
        if indexHits == nil { indexHits = index.scan(data) }
        return indexHits?[key] ?? []
    }

    func evaluate(rule: YaraRuleSet.Rule) -> Bool {
        if let cached = ruleResults[rule.name] { return cached }
        let saved = currentRule
        currentRule = rule
        let result = truthy(evaluate(rule.condition))
        currentRule = saved
        ruleResults[rule.name] = result
        return result
    }

    enum Value { case int(Int64), bool(Bool), text(String), undefined }

    func truthy(_ value: Value) -> Bool {
        switch value {
        case .bool(let b): b
        case .int(let i): i != 0
        case .text(let s): !s.isEmpty
        case .undefined: false
        }
    }

    func integer(_ value: Value) -> Int64? {
        switch value {
        case .int(let i): i
        case .bool(let b): b ? 1 : 0
        default: nil
        }
    }

    func evaluate(_ expr: Expr) -> Value {
        switch expr {
        case .int(let i): return .int(i)
        case .text(let s): return .text(s)
        case .bool(let b): return .bool(b)
        case .filesize: return .int(Int64(data.count))
        case .variable(let name): return bindings[name].map { .int($0) } ?? .undefined
        case .ruleRef(let name):
            guard let rule = rules[name] else { return .undefined }
            return .bool(evaluate(rule: rule))
        case .stringMatch(let id): return .bool(exists(resolve(id)))
        case .stringAt(let id, let at):
            guard let position = integer(evaluate(at)) else { return .undefined }
            return .bool(offsets(of: resolve(id)).contains(Int(position)))
        case .stringIn(let id, let low, let high):
            guard let lo = integer(evaluate(low)), let hi = integer(evaluate(high)) else { return .undefined }
            return .bool(offsets(of: resolve(id)).contains { Int64($0) >= lo && Int64($0) <= hi })
        case .stringCount(let id): return .int(Int64(offsets(of: resolve(id)).count))
        case .stringOffset(let id, let index):
            guard let i = integer(evaluate(index)) else { return .undefined }
            let found = offsets(of: resolve(id))
            return i >= 1 && Int(i) <= found.count ? .int(Int64(found[Int(i) - 1])) : .undefined
        case .readInt(let bits, let bigEndian, let offsetExpr):
            guard let offset = integer(evaluate(offsetExpr)), offset >= 0 else { return .undefined }
            let width = bits / 8
            guard Int(offset) + width <= data.count else { return .undefined }
            var value: UInt64 = 0
            data.withUnsafeBytes { raw in
                for k in 0..<width {
                    let byte = UInt64(raw[Int(offset) + (bigEndian ? k : width - 1 - k)])
                    value = value << 8 | byte
                }
            }
            return .int(Int64(value))
        case .hash(let kind, let offsetExpr, let sizeExpr):
            guard let offset = integer(evaluate(offsetExpr)), let size = integer(evaluate(sizeExpr)),
                  offset >= 0, size >= 0, Int(offset + size) <= data.count else { return .undefined }
            // Many rules hash the same whole file; compute each digest once.
            let key = "\(kind):\(offset):\(size)"
            if let cached = hashCache[key] { return .text(cached) }
            let slice = data[data.startIndex + Int(offset)..<data.startIndex + Int(offset + size)]
            let digest: String
            switch kind {
            case "sha256": digest = SHA256.hash(data: slice).map { String(format: "%02x", $0) }.joined()
            case "sha1": digest = Insecure.SHA1.hash(data: slice).map { String(format: "%02x", $0) }.joined()
            default: digest = Insecure.MD5.hash(data: slice).map { String(format: "%02x", $0) }.joined()
            }
            hashCache[key] = digest
            return .text(digest)
        case .unary(let op, let operand):
            let value = evaluate(operand)
            switch op {
            case "not": return .bool(!truthy(value))
            case "-": return integer(value).map { .int(-$0) } ?? .undefined
            default: return integer(value).map { .int(~$0) } ?? .undefined
            }
        case .anyTrue(let operands):
            for operand in operands where truthy(evaluate(operand)) { return .bool(true) }
            return .bool(false)
        case .allTrue(let operands):
            for operand in operands where !truthy(evaluate(operand)) { return .bool(false) }
            return .bool(true)
        case .binary(let op, let lhs, let rhs):
            let left = evaluate(lhs), right = evaluate(rhs)
            if case .text(let a) = left, case .text(let b) = right {
                switch op {
                case "==": return .bool(a.lowercased() == b.lowercased())
                case "!=": return .bool(a.lowercased() != b.lowercased())
                default: return .undefined
                }
            }
            guard let a = integer(left), let b = integer(right) else { return op == "!=" ? .bool(false) : .undefined }
            switch op {
            case "==": return .bool(a == b)
            case "!=": return .bool(a != b)
            case "<": return .bool(a < b)
            case "<=": return .bool(a <= b)
            case ">": return .bool(a > b)
            case ">=": return .bool(a >= b)
            case "+": return .int(a &+ b)
            case "-": return .int(a &- b)
            case "*": return .int(a &* b)
            case "\\": return b == 0 ? .undefined : .int(a / b)
            case "%": return b == 0 ? .undefined : .int(a % b)
            case "&": return .int(a & b)
            case "|": return .int(a | b)
            case "^": return .int(a ^ b)
            case "<<": return .int(a << b)
            case ">>": return .int(a >> b)
            default: return .undefined
            }
        case .of(let quantifier, let set):
            let ids = expand(set)
            var hits = 0
            for (index, id) in ids.enumerated() {
                let remaining = ids.count - index
                switch quantifier {
                case .all where hits < index: return .bool(false)
                case .any where hits > 0, .none where hits > 0: return .bool(quantifier.satisfied(hits, of: ids.count))
                case .count(let n) where hits >= n: return .bool(true)
                case .count(let n) where hits + remaining < n: return .bool(false)
                default: break
                }
                if exists(id) { hits += 1 }
            }
            return .bool(quantifier.satisfied(hits, of: ids.count))
        case .forOf(let quantifier, let set, let body):
            let ids = expand(set)
            let saved = currentString
            var hits = 0
            for id in ids {
                currentString = id
                if truthy(evaluate(body)) { hits += 1 }
            }
            currentString = saved
            return .bool(quantifier.satisfied(hits, of: ids.count))
        case .forIn(let quantifier, let name, let low, let high, let body):
            guard let lo = integer(evaluate(low)), let hi = integer(evaluate(high)), hi >= lo, hi - lo < 100_000 else { return .undefined }
            let saved = bindings[name]
            var hits = 0
            for i in lo...hi {
                bindings[name] = i
                if truthy(evaluate(body)) { hits += 1 }
            }
            bindings[name] = saved
            return .bool(quantifier.satisfied(hits, of: Int(hi - lo + 1)))
        }
    }

    private func resolve(_ id: String) -> String { id == "$" ? (currentString ?? "$") : id }

    private func expand(_ set: [String]) -> [String] {
        let all = currentRule.stringOrder
        return set.flatMap { member -> [String] in
            if member.hasSuffix("*") {
                let prefix = String(member.dropLast())
                return all.filter { $0.hasPrefix(prefix) }
            }
            return [member]
        }
    }

    /// Offsets where string `id` of the current rule matches (at most `maxMatches`).
    func offsets(of id: String) -> [Int] {
        let key = currentRule.name + "\u{0}" + id
        if let cached = matchCache[key] { return cached }
        guard let pattern = currentRule.strings[id] else { return [] }
        let found = search(pattern, limit: Self.maxMatches)
        matchCache[key] = found
        existsCache[key] = !found.isEmpty
        return found
    }

    /// Whether string `id` matches anywhere; stops at the first hit.
    func exists(_ id: String) -> Bool {
        let key = currentRule.name + "\u{0}" + id
        if let cached = existsCache[key] { return cached }
        if let cached = matchCache[key] { return !cached.isEmpty }
        guard let pattern = currentRule.strings[id] else { return false }
        let found = !search(pattern, limit: 1).isEmpty
        existsCache[key] = found
        return found
    }

    private var existsCache: [String: Bool] = [:]

    private func search(_ pattern: StringPattern, limit: Int) -> [Int] {
        let key = currentRule.name + "\u{0}" + (currentRule.strings.first { $0.value.identity == pattern.identity }?.key ?? "")
        if let hits = indexed(key) {
            switch pattern.body {
            case .text(let bytes):
                let wideLength = bytes.count * 2
                var result: [Int] = []
                for offset in hits {
                    if pattern.fullword {
                        // Hits from the wide variant are twice as long; check the boundary for each length that fits.
                        let ascii = isWordBoundary(offset, length: bytes.count, wide: false)
                        let wide = pattern.wide && isWordBoundary(offset, length: wideLength, wide: true)
                        if !ascii && !wide { continue }
                    }
                    result.append(offset)
                    if result.count >= limit { break }
                }
                return result
            case .hex(let tokens):
                return data.withUnsafeBytes { raw -> [Int] in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    var result: [Int] = []
                    for start in hits where start >= 0 && HexMatcher.match(tokens[...], bytes, start) != nil {
                        result.append(start)
                        if result.count >= limit { break }
                    }
                    return result
                }
            case .regex:
                break
            }
        }
        switch pattern.body {
        case .text(let bytes):
            var variants: [[UInt8]] = []
            let wantASCII = pattern.ascii || !pattern.wide
            if pattern.base64 || pattern.base64wide {
                variants = Base64Patterns.variants(of: bytes)
                if pattern.base64wide { variants = variants.map(Self.widen) }
            } else {
                if wantASCII { variants.append(bytes) }
                if pattern.wide { variants.append(Self.widen(bytes)) }
            }
            var result: [Int] = []
            if let keys = pattern.xor, !pattern.nocase {
                // One pass per variant: the key is fixed by the first byte, the rest must agree.
                for variant in variants where !variant.isEmpty {
                    result += xorFind(variant, keys: keys, limit: limit - result.count)
                    if result.count >= limit { break }
                }
                return result.sorted()
            }
            if let keys = pattern.xor {
                variants = variants.flatMap { variant in keys.map { key in variant.map { $0 ^ UInt8(key) } } }
            }
            for variant in variants where !variant.isEmpty {
                let needle = pattern.nocase ? variant.map(Self.lower) : variant
                for offset in find(needle, inLowered: pattern.nocase, limit: pattern.fullword ? Self.maxMatches : limit) {
                    if pattern.fullword && !isWordBoundary(offset, length: needle.count, wide: variant.count == bytes.count * 2 && pattern.wide) { continue }
                    result.append(offset)
                    if result.count >= limit { break }
                }
                if result.count >= limit { break }
            }
            return result.sorted()
        case .hex(let tokens):
            return HexMatcher.find(tokens, atom: pattern.atom, in: data, limit: limit)
        case .regex(let source, let caseInsensitive, let dotAll):
            var options: NSRegularExpression.Options = []
            if caseInsensitive || pattern.nocase { options.insert(.caseInsensitive) }
            if dotAll { options.insert(.dotMatchesLineSeparators) }
            guard let regex = try? NSRegularExpression(pattern: source, options: options) else { return [] }
            if latin1 == nil { latin1 = String(data: data, encoding: .isoLatin1) ?? "" }
            let text = latin1!
            return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
                .prefix(limit).map(\.range.location)
        }
    }

    static func widen(_ bytes: [UInt8]) -> [UInt8] { bytes.flatMap { [$0, 0] } }

    /// Offsets where `pattern` XOR some single-byte key in `keys` appears.
    private func xorFind(_ pattern: [UInt8], keys: ClosedRange<Int>, limit: Int) -> [Int] {
        data.withUnsafeBytes { raw -> [Int] in
            let bytes = raw.bindMemory(to: UInt8.self)
            let length = pattern.count
            guard length > 0, bytes.count >= length else { return [] }
            var result: [Int] = []
            var i = 0
            let last = bytes.count - length
            while i <= last {
                let key = bytes[i] ^ pattern[0]
                if keys.contains(Int(key)) {
                    var j = 1
                    while j < length && bytes[i + j] ^ pattern[j] == key { j += 1 }
                    if j == length {
                        result.append(i)
                        if result.count >= limit { break }
                    }
                }
                i += 1
            }
            return result
        }
    }
    static func lower(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5A ? byte + 32 : byte }

    private func find(_ needle: [UInt8], inLowered: Bool, limit: Int) -> [Int] {
        if inLowered, lowered == nil { lowered = data.map(Self.lower) }
        var result: [Int] = []
        let search: (UnsafeRawBufferPointer) -> Void = { haystack in
            guard let base = haystack.baseAddress, needle.count <= haystack.count else { return }
            var start = 0
            needle.withUnsafeBytes { needleBytes in
                while start <= haystack.count - needle.count {
                    guard let hit = memmem(base + start, haystack.count - start, needleBytes.baseAddress, needle.count) else { break }
                    let offset = base.distance(to: UnsafeRawPointer(hit))
                    result.append(offset)
                    if result.count >= limit { break }
                    start = offset + 1
                }
            }
        }
        if inLowered { lowered!.withUnsafeBytes(search) } else { data.withUnsafeBytes(search) }
        return result
    }

    private func isWordBoundary(_ offset: Int, length: Int, wide: Bool) -> Bool {
        func isAlnum(_ index: Int) -> Bool {
            guard index >= 0 && index < data.count else { return false }
            let b = data[data.startIndex + index]
            return (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
        }
        let step = wide ? 2 : 1
        return !isAlnum(offset - step) && !isAlnum(offset + length)
    }
}

/// One-pass prefilter over all rules: every pattern with at least four known bytes in a row is found by
/// a single sweep through the file, instead of one search per pattern.
final class PatternIndex: @unchecked Sendable {
    struct Needle {
        let key: String
        let bytes: [UInt8]
        /// Subtract from the hit position to get the pattern's start.
        let startAdjust: Int
    }

    let needles: [Needle]
    let keys: Set<String>
    private let table: [UInt32: [Int]]
    private var bits = [UInt64](repeating: 0, count: 1 << 14)  // 2^20-bit filter

    init(rules: [YaraRuleSet.Rule]) {
        var needles: [Needle] = []
        var keys = Set<String>()
        for rule in rules {
            for (id, pattern) in rule.strings {
                let key = rule.name + "\u{0}" + id
                var candidates: [Needle] = []
                switch pattern.body {
                case .text(let bytes) where !pattern.nocase && pattern.xor == nil && !pattern.base64 && !pattern.base64wide && bytes.count >= 4:
                    if pattern.ascii || !pattern.wide { candidates.append(Needle(key: key, bytes: bytes, startAdjust: 0)) }
                    if pattern.wide { candidates.append(Needle(key: key, bytes: MatchContext.widen(bytes), startAdjust: 0)) }
                case .hex:
                    if let atom = pattern.atom, atom.bytes.count >= 4 {
                        candidates.append(Needle(key: key, bytes: atom.bytes, startAdjust: atom.offset))
                    }
                default:
                    break
                }
                if !candidates.isEmpty {
                    needles += candidates
                    keys.insert(key)
                }
            }
        }
        var table: [UInt32: [Int]] = [:]
        for (index, needle) in needles.enumerated() {
            let prefix = needle.bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            table[prefix, default: []].append(index)
        }
        self.needles = needles
        self.keys = keys
        self.table = table
        for prefix in table.keys {
            let slot = Self.slot(prefix)
            bits[slot >> 6] |= 1 << UInt64(slot & 63)
        }
    }

    @inline(__always) private static func slot(_ value: UInt32) -> Int { Int((value &* 2_654_435_761) >> 12) }

    /// Positions (pattern starts) of every needle in `data`.
    func scan(_ data: Data) -> [String: [Int]] {
        var hits: [String: [Int]] = [:]
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count >= 4 else { return }
            let count = raw.count
            for position in 0...(count - 4) {
                let value = (base + position).loadUnaligned(as: UInt32.self)
                let slot = Self.slot(value)
                guard bits[slot >> 6] & (1 << UInt64(slot & 63)) != 0, let candidates = table[value] else { continue }
                for index in candidates {
                    let needle = needles[index]
                    guard needle.bytes.count <= count - position else { continue }
                    let equal = needle.bytes.withUnsafeBytes { memcmp(base + position, $0.baseAddress, needle.bytes.count) == 0 }
                    if equal, hits[needle.key, default: []].count < MatchContext.maxMatches {
                        hits[needle.key, default: []].append(position - needle.startAdjust)
                    }
                }
            }
        }
        return hits.mapValues { Array(Set($0)).sorted() }
    }
}

enum HexMatcher {
    /// Longest run of fully known bytes within the fixed-length start of the pattern, and its offset.
    static func atom(_ tokens: [HexToken]) -> (bytes: [UInt8], offset: Int)? {
        var best: (bytes: [UInt8], offset: Int)?
        var run: [UInt8] = [], runStart = 0, position = 0
        func close() {
            if run.count > (best?.bytes.count ?? 0) { best = (run, runStart) }
            run = []
        }
        for token in tokens {
            switch token {
            case .byte(let value, let mask) where mask == 0xFF:
                if run.isEmpty { runStart = position }
                run.append(value)
                position += 1
            case .byte:
                close()
                position += 1
            case .jump(let low, let high) where high == low:
                close()
                position += low
            case .alternatives(let options):
                close()
                let lengths = Set(options.map(fixedLength))
                guard lengths.count == 1, let length = lengths.first, let fixed = length else {
                    return best.flatMap { $0.bytes.count >= 2 ? $0 : nil } ?? best
                }
                position += fixed
            default:
                close()
                return best
            }
        }
        close()
        return best
    }

    private static func fixedLength(_ tokens: [HexToken]) -> Int? {
        var total = 0
        for token in tokens {
            switch token {
            case .byte: total += 1
            case .jump(let low, let high) where high == low: total += low
            case .alternatives(let options):
                let lengths = Set(options.map(fixedLength))
                guard lengths.count == 1, let length = lengths.first, let fixed = length else { return nil }
                total += fixed
            default: return nil
            }
        }
        return total
    }

    static func find(_ tokens: [HexToken], atom: (bytes: [UInt8], offset: Int)?, in data: Data, limit: Int) -> [Int] {
        data.withUnsafeBytes { raw -> [Int] in
            let bytes = raw.bindMemory(to: UInt8.self)
            var result: [Int] = []
            if let atom, atom.bytes.count >= 2, let base = raw.baseAddress {
                // Find the known bytes with memmem, then check the whole pattern around each hit.
                var position = 0
                atom.bytes.withUnsafeBytes { needle in
                    while position <= bytes.count - atom.bytes.count {
                        guard let hit = memmem(base + position, bytes.count - position, needle.baseAddress, atom.bytes.count) else { break }
                        let found = base.distance(to: UnsafeRawPointer(hit))
                        let start = found - atom.offset
                        if start >= 0, match(tokens[...], bytes, start) != nil {
                            result.append(start)
                            if result.count >= limit { break }
                        }
                        position = found + 1
                    }
                }
                return result
            }
            // Anchor on the first fully specified byte to skip impossible starts quickly.
            if case .byte(let first, let mask) = tokens.first, mask == 0xFF {
                var position = 0
                while position < bytes.count, let base = raw.baseAddress {
                    guard let hit = memchr(base + position, Int32(first), bytes.count - position) else { break }
                    let start = base.distance(to: UnsafeRawPointer(hit))
                    if match(tokens[...], bytes, start) != nil {
                        result.append(start)
                        if result.count >= limit { break }
                    }
                    position = start + 1
                }
            } else {
                for start in 0..<bytes.count {
                    if match(tokens[...], bytes, start) != nil {
                        result.append(start)
                        if result.count >= limit { break }
                    }
                }
            }
            return result
        }
    }

    /// End offset if `tokens` match at `position`.
    static func match(_ tokens: ArraySlice<HexToken>, _ bytes: UnsafeBufferPointer<UInt8>, _ position: Int) -> Int? {
        guard let token = tokens.first else { return position }
        let rest = tokens.dropFirst()
        switch token {
        case .byte(let value, let mask):
            guard position < bytes.count, bytes[position] & mask == value & mask else { return nil }
            return match(rest, bytes, position + 1)
        case .alternatives(let options):
            for option in options {
                if let end = match(option[...], bytes, position), let full = match(rest, bytes, end) { return full }
            }
            return nil
        case .jump(let low, let high):
            let maximum = min(high ?? 65_536, bytes.count - position)
            guard low <= maximum else { return nil }
            for skip in low...maximum {
                if let end = match(rest, bytes, position + skip) { return end }
            }
            return nil
        }
    }
}

enum Base64Patterns {
    /// The three base64 encodings of `bytes` at different alignments, keeping only the characters that
    /// don't depend on neighbouring data (as YARA does).
    static func variants(of bytes: [UInt8]) -> [[UInt8]] {
        (0..<3).compactMap { shift -> [UInt8]? in
            let padded = [UInt8](repeating: 0, count: shift) + bytes
            let encoded = Array(Data(padded).base64EncodedString().utf8).filter { $0 != UInt8(ascii: "=") }
            // Leading characters mix in the unknown bytes before the string; a trailing partial group
            // mixes in the unknown byte after it.
            let leading = [0, 2, 3][shift]
            let end = encoded.count - (padded.count % 3 == 0 ? 0 : 1)
            return leading < end ? Array(encoded[leading..<end]) : nil
        }
    }
}
