import SweepCore

let usage = """
    usage: sweep lens <path> [--top N] [--depth N] [--json] [--logical] [--private-size]
                             [--threads N] [--cross-mounts] [--no-dedupe]
           sweep render <path> --out <file.png> [--width N] [--height N]
                             [--threads N] [--cross-mounts] [--no-dedupe]
           sweep --help

    lens    Scan <path> and print where the space goes (allocated bytes, hard links counted once).
              --top N         entries listed per folder (default 15)
              --depth N       folder levels to list (default 1)
              --json          print JSON instead of text
              --logical       size and sort by file length instead of space on disk
              --private-size  also show what deleting each entry would free (APFS clones share the rest)
    render  Scan <path> and save the Disk Map bubble view as a PNG.
              --out <file>    where to write the PNG
              --width N, --height N   size in points, 200 to 4000 (default 1200 × 800)

    Both    --threads N       scanner threads, 1 to 64
            --cross-mounts    also scan other volumes mounted below <path>
            --no-dedupe       count every hard link instead of each file once
            --                ends the options, for a path that starts with "-"
    """

enum Subcommand: String, CaseIterable {
    case lens, render
}

/// A mistake on the command line; printed with the usage, exit status 64.
struct UsageError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

struct Arguments: Equatable {
    var command: Subcommand
    var path = ""
    var top = 15
    var depth = 1
    var json = false
    var logical = false
    var privateSize = false
    var output: String?
    var width = 1200
    var height = 800
    var threads: Int?
    var crossMounts = false
    var deduplicate = true

    init(command: Subcommand) {
        self.command = command
    }

    var options: ScanOptions {
        var options = ScanOptions()
        if let threads { options.threadCount = threads }
        options.crossMountPoints = crossMounts
        options.deduplicateHardLinks = deduplicate
        options.measurePrivateSize = privateSize
        return options
    }

    /// What a command line asks for.
    enum Parsed: Equatable {
        case help
        case run(Arguments)
    }

    static func parse(_ raw: [String]) throws -> Parsed {
        let options = raw.prefix { $0 != "--" }
        if raw.first == "help" || options.contains("-h") || options.contains("--help") { return .help }
        var remaining = raw[...]
        guard let name = remaining.popFirst() else { throw UsageError("missing command") }
        guard let command = Subcommand(rawValue: name) else { throw UsageError("unknown command “\(name)”") }
        var arguments = Arguments(command: command)
        var optionsEnded = false
        while let argument = remaining.popFirst() {
            if !optionsEnded, argument == "--" {
                optionsEnded = true
            } else if !optionsEnded, argument.hasPrefix("-"), argument != "-" {
                try arguments.apply(argument) {
                    guard let value = remaining.popFirst() else { throw UsageError("\(argument) needs a value") }
                    return value
                }
            } else {
                guard arguments.path.isEmpty else {
                    throw UsageError("one path at a time (got “\(arguments.path)” and “\(argument)”)")
                }
                arguments.path = argument
            }
        }
        if arguments.path.isEmpty { throw UsageError("\(command.rawValue) needs a folder to scan") }
        if command == .render, arguments.output == nil { throw UsageError("render needs --out <file.png>") }
        return .run(arguments)
    }

    private mutating func apply(_ flag: String, value: () throws -> String) throws {
        func only(_ allowed: Subcommand) throws {
            guard command == allowed else {
                throw UsageError("\(flag) only works with “sweep \(allowed.rawValue)”")
            }
        }
        func number(_ range: ClosedRange<Int>) throws -> Int {
            let text = try value()
            guard let parsed = Int(text), range.contains(parsed) else {
                throw UsageError("\(flag) takes a whole number from \(range.lowerBound) to \(range.upperBound), not “\(text)”")
            }
            return parsed
        }
        switch flag {
        case "--top": try only(.lens); top = try number(1...100_000)
        case "--depth": try only(.lens); depth = try number(1...255)
        case "--json": try only(.lens); json = true
        case "--logical": try only(.lens); logical = true
        case "--private-size": try only(.lens); privateSize = true
        case "--out": try only(.render); output = try value()
        case "--width": try only(.render); width = try number(200...4000)
        case "--height": try only(.render); height = try number(200...4000)
        case "--threads": threads = try number(1...64)
        case "--cross-mounts": crossMounts = true
        case "--no-dedupe": deduplicate = false
        default: throw UsageError("unknown option \(flag)")
        }
    }
}
