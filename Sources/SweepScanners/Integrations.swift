import Foundation
import SQLite3
import SweepCore

/// Folders and programs the user pointed Sweep at, overriding what it finds by itself.
public struct ToolLocations: Sendable, Equatable, Codable {
    public var ollamaModels: String?
    public var lmStudioModels: String?
    public var huggingFaceCache: String?
    public var dockerCLI: String?

    public init(ollamaModels: String? = nil, lmStudioModels: String? = nil, huggingFaceCache: String? = nil,
                dockerCLI: String? = nil) {
        self.ollamaModels = ollamaModels
        self.lmStudioModels = lmStudioModels
        self.huggingFaceCache = huggingFaceCache
        self.dockerCLI = dockerCLI
    }
}

/// A folder or program, and where Sweep learned about it.
public struct ToolLocation: Sendable, Equatable {
    public enum Origin: String, Sendable {
        case sweep = "Set in Sweep"
        case environment = "From an environment variable"
        case toolSettings = "From the app's own settings"
        case standard = "Standard location"
    }

    public let path: String
    public let origin: Origin
}

/// Finds the AI and container tools Sweep cleans up after, following each tool's own settings.
public struct ToolFinder: Sendable {
    public let environment: ScanEnvironment
    public let overrides: ToolLocations

    public init(environment: ScanEnvironment, overrides: ToolLocations = ToolLocations()) {
        self.environment = environment
        self.overrides = overrides
    }

    // MARK: Ollama

    /// Sweep's setting, then `OLLAMA_MODELS`, then the folder chosen in the Ollama app, then `~/.ollama/models`.
    public var ollamaModels: ToolLocation {
        if let path = overrides.ollamaModels, !path.isEmpty { return ToolLocation(path: path, origin: .sweep) }
        if let path = environment.variables["OLLAMA_MODELS"], !path.isEmpty {
            return ToolLocation(path: expand(path), origin: .environment)
        }
        if let path = Self.ollamaAppModelsFolder(home: environment.home), !path.isEmpty {
            return ToolLocation(path: expand(path), origin: .toolSettings)
        }
        return ToolLocation(path: environment.user(".ollama/models"), origin: .standard)
    }

    public var ollamaApp: String? { app(named: "Ollama.app") }

    public var ollamaCLI: String? {
        executable([environment.system("/usr/local/bin/ollama"), environment.system("/opt/homebrew/bin/ollama")]
                   + [ollamaApp.map { $0 + "/Contents/Resources/ollama" }].compactMap { $0 })
    }

    /// The models folder picked in the Ollama app (stored in its settings database).
    static func ollamaAppModelsFolder(home: String) -> String? {
        let path = home + "/Library/Application Support/Ollama/db.sqlite"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT models FROM settings LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    // MARK: LM Studio

    /// Sweep's setting, then the downloads folder in LM Studio's settings, then `~/.lmstudio/models`.
    /// Older LM Studio versions kept models in `~/.cache/lm-studio/models`, which is added when present.
    public var lmStudioModels: [ToolLocation] {
        var locations: [ToolLocation] = []
        if let path = overrides.lmStudioModels, !path.isEmpty {
            locations.append(ToolLocation(path: path, origin: .sweep))
        } else if let path = Self.lmStudioDownloadsFolder(home: environment.home) {
            locations.append(ToolLocation(path: expand(path), origin: .toolSettings))
        } else {
            locations.append(ToolLocation(path: environment.user(".lmstudio/models"), origin: .standard))
        }
        let legacy = environment.user(".cache/lm-studio/models")
        if !locations.contains(where: { $0.path == legacy }), FileManager.default.fileExists(atPath: legacy) {
            locations.append(ToolLocation(path: legacy, origin: .standard))
        }
        return locations
    }

    public var lmStudioApp: String? { app(named: "LM Studio.app") }

    static func lmStudioDownloadsFolder(home: String) -> String? {
        guard let data = FileManager.default.contents(atPath: home + "/.lmstudio/settings.json"),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return settings["downloadsFolder"] as? String
    }

    // MARK: Hugging Face

    /// Sweep's setting, then `HF_HUB_CACHE`, then `HF_HOME/hub`, then `~/.cache/huggingface/hub`.
    public var huggingFaceHub: ToolLocation {
        if let path = overrides.huggingFaceCache, !path.isEmpty { return ToolLocation(path: path, origin: .sweep) }
        if let path = environment.variables["HF_HUB_CACHE"] ?? environment.variables["HUGGINGFACE_HUB_CACHE"], !path.isEmpty {
            return ToolLocation(path: expand(path), origin: .environment)
        }
        if let home = environment.variables["HF_HOME"], !home.isEmpty {
            return ToolLocation(path: expand(home) + "/hub", origin: .environment)
        }
        return ToolLocation(path: environment.user(".cache/huggingface/hub"), origin: .standard)
    }

    // MARK: Docker

    public var dockerApp: String? { app(named: "Docker.app") ?? app(named: "OrbStack.app") }

    /// Sweep's setting, then the usual places Docker Desktop, OrbStack, Colima and Homebrew install it.
    public var dockerCLI: ToolLocation? {
        if let path = overrides.dockerCLI, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return ToolLocation(path: path, origin: .sweep)
        }
        let candidates = [
            environment.system("/usr/local/bin/docker"), environment.system("/opt/homebrew/bin/docker"),
            environment.user(".docker/bin/docker"),
            environment.system("/Applications/Docker.app/Contents/Resources/bin/docker"),
            environment.user(".orbstack/bin/docker"),
            environment.system("/Applications/OrbStack.app/Contents/MacOS/xbin/docker"),
        ]
        return executable(candidates).map { ToolLocation(path: $0, origin: .standard) }
    }

    /// Docker Desktop's virtual disk. Its logical size is huge; only the allocated bytes count.
    public var dockerDiskImage: String? {
        let path = environment.user("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // MARK: Helpers

    private func app(named name: String) -> String? {
        environment.applicationFolders.map { $0 + "/" + name }.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func executable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func expand(_ path: String) -> String {
        path.hasPrefix("~") ? environment.home + path.dropFirst() : path
    }
}
