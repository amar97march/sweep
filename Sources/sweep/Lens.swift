import Foundation
import SweepCore

/// Where the command writes, so tests can capture it.
struct Console {
    var write: (String) -> Void
    var writeError: (String) -> Void
    /// Draw a progress line on standard error while scanning.
    var showsProgress: Bool

    static var standard: Console {
        Console(write: { print($0, terminator: "") },
                writeError: { FileHandle.standardError.write(Data($0.utf8)) },
                showsProgress: isatty(STDERR_FILENO) != 0)
    }

    func line(_ text: String = "") { write(text + "\n") }
    func errorLine(_ text: String) { writeError(text + "\n") }
}

enum CLI {
    /// Runs a command line and returns the exit status: 0, 1 when the scan or render failed, 64 for a usage mistake.
    static func run(_ raw: [String], console: Console) -> Int32 {
        do {
            guard case .run(let arguments) = try Arguments.parse(raw) else {
                console.line(usage)
                return 0
            }
            switch arguments.command {
            case .lens: try runLens(arguments, console: console)
            case .render: try runRender(arguments, console: console)
            }
            return 0
        } catch let error as UsageError {
            console.errorLine(raw.isEmpty ? usage : "sweep: \(error.message)\nRun “sweep --help” to see the options.")
            return 64
        } catch let error as ScanError {
            console.errorLine("sweep: \(error.localizedDescription)")
            if error.needsFullDiskAccess {
                console.errorLine("Give your terminal app Full Disk Access in System Settings → Privacy & Security.")
            }
            return 1
        } catch {
            console.errorLine("sweep: \(error.localizedDescription)")
            return 1
        }
    }
}

func scan(_ arguments: Arguments, console: Console, showProgress: Bool) throws -> ScanResult {
    let scanner = DiskTreeScanner(options: arguments.options)
    let draw = showProgress && console.showsProgress
    defer { if draw { FileHandle.standardError.write(Data("\u{1B}[2K\r".utf8)) } }
    return try scanner.scan(arguments.path, progressInterval: 0.2) { progress in
        guard draw else { return }
        let line = "\u{1B}[2K\r\(progress.files) files, \(ByteFormat.string(progress.allocatedBytes))  \(progress.currentPath.suffix(70))"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// The folders and files `sweep lens` lists, sized and sorted the way the arguments ask.
struct LensReport {
    struct Entry {
        let name: String
        let path: String
        let kind: EntryKind
        /// "scanned", or why the numbers may be incomplete.
        let status: String
        /// The system's reason, for folders that couldn't be read completely.
        let problem: String?
        let allocatedBytes: UInt64
        let logicalBytes: UInt64
        /// What deleting it would free; only with `--private-size`.
        let privateBytes: UInt64?
        let folder: DirectoryNode?
    }

    let result: ScanResult
    let arguments: Arguments
    /// Private bytes of every folder, added up from its files; nil unless `--private-size`.
    let folderPrivateSizes: [ObjectIdentifier: UInt64]?

    init(result: ScanResult, arguments: Arguments) {
        self.result = result
        self.arguments = arguments
        folderPrivateSizes = arguments.privateSize ? Self.privateSizes(below: result.root) : nil
    }

    var root: DirectoryNode { result.root }

    func size(_ entry: Entry) -> UInt64 { arguments.logical ? entry.logicalBytes : entry.allocatedBytes }
    func size(_ folder: DirectoryNode) -> UInt64 { arguments.logical ? folder.logicalSize : folder.allocatedSize }
    func privateSize(_ folder: DirectoryNode) -> UInt64? { folderPrivateSizes?[folder.id] }

    /// Everything directly inside `folder`, largest first.
    func entries(in folder: DirectoryNode) -> [Entry] {
        var entries = folder.children.map { child in
            Entry(name: child.name, path: child.path, kind: .directory, status: Self.status(of: child.status),
                  problem: Self.problem(of: child.status), allocatedBytes: child.allocatedSize,
                  logicalBytes: child.logicalSize, privateBytes: privateSize(child), folder: child)
        }
        entries += folder.files.map { file in
            Entry(name: file.name, path: Self.join(folder.path, file.name), kind: file.kind, status: Self.status(of: file),
                  problem: nil, allocatedBytes: file.allocatedSize, logicalBytes: file.logicalSize,
                  privateBytes: arguments.privateSize ? Self.privateSize(of: file) : nil, folder: nil)
        }
        return entries.sorted { size($0) != size($1) ? size($0) > size($1) : $0.name < $1.name }
    }

    static func status(of status: DirectoryStatus) -> String {
        switch status {
        case .pending: "pending"
        case .scanned: "scanned"
        case .partial: "partial"
        case .inaccessible: "noAccess"
        case .skippedMountPoint: "otherVolume"
        case .skippedExcluded: "excluded"
        }
    }

    static func status(of file: FileItem) -> String {
        if file.flags.contains(.entryError) { return "error" }
        if file.flags.contains(.dataless) { return "cloudPlaceholder" }
        if file.flags.contains(.hardLinkDuplicate) { return "hardLinkDuplicate" }
        return "scanned"
    }

    static func problem(of status: DirectoryStatus) -> String? {
        switch status {
        case .partial(let code), .inaccessible(let code): String(cString: strerror(code))
        default: nil
        }
    }

    /// A hard link already counted elsewhere frees nothing; without a measurement, assume nothing is shared.
    static func privateSize(of file: FileItem) -> UInt64 {
        file.flags.contains(.hardLinkDuplicate) ? 0 : file.privateSize ?? file.allocatedSize
    }

    static func privateSizes(below root: DirectoryNode) -> [ObjectIdentifier: UInt64] {
        var totals: [ObjectIdentifier: UInt64] = [:]
        var stack: [(DirectoryNode, Bool)] = [(root, false)]
        while let (node, childrenDone) = stack.popLast() {
            if !childrenDone {
                stack.append((node, true))
                for child in node.children { stack.append((child, false)) }
                continue
            }
            totals[node.id] = node.files.reduce(0) { $0 + privateSize(of: $1) }
                + node.children.reduce(0) { $0 + (totals[$1.id] ?? 0) }
        }
        return totals
    }

    static func join(_ folder: String, _ name: String) -> String { folder == "/" ? "/" + name : folder + "/" + name }
}

func runLens(_ arguments: Arguments, console: Console) throws {
    let result = try scan(arguments, console: console, showProgress: !arguments.json)
    let report = LensReport(result: result, arguments: arguments)
    if arguments.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        console.line(String(decoding: try encoder.encode(LensJSON(report)), as: UTF8.self))
    } else {
        printLens(report, console: console)
    }
}

// MARK: - Text

func printLens(_ report: LensReport, console: Console) {
    let root = report.root
    let stats = report.result.statistics
    console.line(root.path)
    var totals = "  on disk \(ByteFormat.string(root.allocatedSize)), logical \(ByteFormat.string(root.logicalSize))"
    if let freed = report.privateSize(root) { totals += ", deleting it all would free \(ByteFormat.string(freed))" }
    console.line(totals)
    printTree(root, report: report, console: console)
    let perSecond = Double(stats.files + stats.directories) / max(stats.elapsedSeconds, 0.001)
    console.line("""

        \(stats.files) files, \(stats.directories) folders, \(stats.symlinks) symlinks \
        in \(String(format: "%.2f", stats.elapsedSeconds)) s (\(Int(perSecond)) entries/s, \
        \(report.arguments.options.threadCount) threads)
        """)
    var notes: [String] = []
    if stats.hardLinkDuplicates > 0 {
        notes.append("\(stats.hardLinkDuplicates) hard links counted once (\(ByteFormat.string(stats.hardLinkDuplicateBytes)) not double-counted)")
    }
    if stats.inaccessibleDirectories > 0 { notes.append("\(stats.inaccessibleDirectories) folders without access") }
    if stats.skippedMountPoints > 0 { notes.append("\(stats.skippedMountPoints) other volumes skipped") }
    if stats.datalessFiles > 0 { notes.append("\(stats.datalessFiles) cloud placeholders not downloaded") }
    if !notes.isEmpty { console.line(notes.joined(separator: "; ")) }
}

func printTree(_ folder: DirectoryNode, report: LensReport, console: Console, level: Int = 0) {
    let arguments = report.arguments
    let indent = String(repeating: "  ", count: level + 1)
    let total = max(report.size(folder), 1)
    let entries = report.entries(in: folder)
    for entry in entries.prefix(arguments.top) {
        let bytes = report.size(entry)
        let percent = Double(bytes) * 100 / Double(total)
        let sizeText = ByteFormat.string(bytes).padding(toLength: 10, withPad: " ", startingAt: 0)
        var name = entry.name
        if let folder = entry.folder { name += "/" + statusNote(folder.status) }
        if let freed = entry.privateBytes { name += "  (frees \(ByteFormat.string(freed)))" }
        console.line("\(indent)\(sizeText) \(String(format: "%5.1f%%", percent))  \(name)")
        if let child = entry.folder, level + 1 < arguments.depth {
            printTree(child, report: report, console: console, level: level + 1)
        }
    }
    if entries.count > arguments.top {
        let rest = entries.dropFirst(arguments.top).reduce(0) { $0 + report.size($1) }
        console.line("\(indent)\(ByteFormat.string(rest)) in \(entries.count - arguments.top) more items")
    }
}

func statusNote(_ status: DirectoryStatus) -> String {
    switch status {
    case .inaccessible: " [no access]"
    case .partial: " [partial]"
    case .skippedMountPoint: " [other volume]"
    case .skippedExcluded: " [excluded]"
    case .pending, .scanned: ""
    }
}

// MARK: - JSON

/// `sweep lens --json`: the same entries as the text report, nested as deep as `--depth`.
struct LensJSON: Encodable {
    struct Item: Encodable {
        let name: String
        let path: String
        let kind: String
        let isDirectory: Bool
        let status: String
        let problem: String?
        let allocatedBytes: UInt64
        let logicalBytes: UInt64
        let privateBytes: UInt64?
        /// The largest entries inside a folder, while `--depth` reaches it.
        let largest: [Item]?
        let more: Remainder?
    }

    /// Entries left out by `--top`.
    struct Remainder: Encodable {
        let items: Int
        let allocatedBytes: UInt64
        let logicalBytes: UInt64
    }

    let root: String
    /// "allocated" (space on disk) or "logical" (`--logical`).
    let sortedBy: String
    let allocatedBytes: UInt64
    let logicalBytes: UInt64
    let privateBytes: UInt64?
    let statistics: ScanStatistics
    let largest: [Item]
    let more: Remainder?

    init(_ report: LensReport) {
        let root = report.root
        let (items, more) = Self.items(in: root, report: report, level: 0)
        self.root = root.path
        sortedBy = report.arguments.logical ? "logical" : "allocated"
        allocatedBytes = root.allocatedSize
        logicalBytes = root.logicalSize
        privateBytes = report.privateSize(root)
        statistics = report.result.statistics
        largest = items
        self.more = more
    }

    static func items(in folder: DirectoryNode, report: LensReport, level: Int) -> ([Item], Remainder?) {
        let entries = report.entries(in: folder)
        let items = entries.prefix(report.arguments.top).map { entry in
            let inside = entry.folder.flatMap { level + 1 < report.arguments.depth ? items(in: $0, report: report, level: level + 1) : nil }
            return Item(name: entry.name, path: entry.path, kind: "\(entry.kind)", isDirectory: entry.kind == .directory,
                        status: entry.status, problem: entry.problem, allocatedBytes: entry.allocatedBytes,
                        logicalBytes: entry.logicalBytes, privateBytes: entry.privateBytes,
                        largest: inside?.0, more: inside?.1)
        }
        let rest = entries.dropFirst(report.arguments.top)
        let more = rest.isEmpty ? nil : Remainder(items: rest.count,
                                                   allocatedBytes: rest.reduce(0) { $0 + $1.allocatedBytes },
                                                   logicalBytes: rest.reduce(0) { $0 + $1.logicalBytes })
        return (Array(items), more)
    }
}
