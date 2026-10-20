import Foundation
import SweepCore

/// Space Docker can free inside its virtual disk, measured and freed with Docker's own commands.
/// Volumes hold data and are never touched.
public struct DockerScanner: Sendable {
    public typealias Run = @Sendable (String, [String]) -> (status: Int32, output: String)

    public enum Engine: Sendable, Equatable {
        case notInstalled
        /// The `docker` command exists but the engine isn't answering (Docker Desktop not started).
        case notRunning(cli: String)
        case running(cli: String)
    }

    public let finder: ToolFinder
    public let run: Run

    public init(finder: ToolFinder, run: @escaping Run = { Shell.run($0, $1, timeout: 20) }) {
        self.finder = finder
        self.run = run
    }

    /// The engine's state and, when it's running, what can be freed.
    public func scan(progress: (String) -> Void = { _ in }) -> (engine: Engine, category: ScanCategory?) {
        guard let cli = finder.dockerCLI?.path else { return (.notInstalled, nil) }
        progress("Asking Docker what it can free")
        let result = run(cli, ["system", "df", "--format", "{{json .}}"])
        guard result.status == 0, let usage = Self.parseSystemDF(result.output) else { return (.notRunning(cli: cli), nil) }

        let entries: [(type: String, id: String, title: String, subtitle: String, arguments: [String])] = [
            ("Build Cache", "buildcache", "Build cache", "Layers saved from earlier builds; Docker rebuilds them when needed",
             ["builder", "prune", "--force"]),
            ("Images", "images", "Unused images", "Images no container uses; Docker downloads them again when needed",
             ["image", "prune", "--all", "--force"]),
            ("Containers", "containers", "Stopped containers", "Removes stopped containers and changes made inside them",
             ["container", "prune", "--force"]),
        ]
        let items = entries.compactMap { entry -> ScanItem? in
            guard let bytes = usage[entry.type], bytes > 0 else { return nil }
            return ScanItem(id: "docker:" + entry.id, title: entry.title, subtitle: entry.subtitle, size: bytes,
                            isSelectedByDefault: false, action: .custom(kind: "docker", payload: [cli] + entry.arguments))
        }
        guard !items.isEmpty else { return (.running(cli: cli), nil) }
        var subtitle = "Docker"
        if let disk = finder.dockerDiskImage {
            subtitle = "Docker Desktop · its disk image uses \(ByteFormat.string(Measure.allocated(disk))) on this Mac"
        }
        let group = ScanGroup(id: "docker", title: "Docker", subtitle: subtitle,
                              icon: finder.dockerApp.map(ItemIcon.file) ?? .symbol("shippingbox.fill"), items: items)
        let category = ScanCategory(id: "docker", title: "Docker",
                                    summary: "Space Docker can free inside its virtual disk. Volumes, which hold your data, are never touched. Docker returns the space to macOS after cleaning.",
                                    symbol: "shippingbox.fill", groups: [group])
        return (.running(cli: cli), category)
    }

    /// Reclaimable bytes per type from `docker system df --format '{{json .}}'` (one JSON object per line).
    static func parseSystemDF(_ output: String) -> [String: UInt64]? {
        var usage: [String: UInt64] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["Type"] as? String else { continue }
            let reclaimable = (object["Reclaimable"] as? String) ?? "0B"
            usage[type] = parseSize(String(reclaimable.split(separator: " ").first ?? "0B")) ?? 0
        }
        return usage.isEmpty ? nil : usage
    }

    /// Docker's sizes: "1.234GB", "512MB", "12.5kB", "0B" (powers of 1000).
    static func parseSize(_ text: String) -> UInt64? {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (suffix, multiplier) in units where text.hasSuffix(suffix) {
            guard let value = Double(text.dropLast(suffix.count)) else { return nil }
            return UInt64((value * multiplier).rounded())
        }
        return nil
    }
}

/// Runs the prune commands the Docker scanner offered.
public struct DockerPerformer: Sendable {
    /// The only commands this performer will run.
    static let allowed: [[String]] = [
        ["builder", "prune", "--force"], ["image", "prune", "--all", "--force"], ["container", "prune", "--force"],
    ]

    public var run: DockerScanner.Run

    public init(run: @escaping DockerScanner.Run = { Shell.run($0, $1, timeout: 600) }) {
        self.run = run
    }

    public static func handles(_ item: ScanItem) -> Bool {
        if case .custom("docker", _) = item.action { return true }
        return false
    }

    public func perform(_ items: [ScanItem], progress: (Int, Int) -> Void = { _, _ in }) -> [ActionRecord] {
        items.enumerated().map { index, item in
            defer { progress(index + 1, items.count) }
            guard case .custom("docker", let payload) = item.action, let cli = payload.first,
                  (cli as NSString).lastPathComponent == "docker", Self.allowed.contains(Array(payload.dropFirst())) else {
                return ActionRecord(itemID: item.id, title: item.title, detail: item.subtitle ?? "", bytes: 0,
                                    outcome: .skipped("Not a Docker clean-up command"))
            }
            let result = run(cli, Array(payload.dropFirst()))
            guard result.status == 0 else {
                let message = result.status == -2 ? "Docker didn't finish in time"
                    : result.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? "Docker reported an error"
                return ActionRecord(itemID: item.id, title: item.title, detail: item.subtitle ?? "", bytes: 0, outcome: .failed(message))
            }
            let freed = Self.reclaimed(result.output) ?? item.size
            return ActionRecord(itemID: item.id, title: item.title, detail: item.subtitle ?? "", bytes: freed,
                                outcome: .done("Cleaned by Docker"))
        }
    }

    /// "Total reclaimed space: 1.2GB" → bytes.
    static func reclaimed(_ output: String) -> UInt64? {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.contains("reclaimed space") }),
              let value = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) else { return nil }
        return DockerScanner.parseSize(value)
    }
}
