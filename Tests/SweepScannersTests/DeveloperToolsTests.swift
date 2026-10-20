import Foundation
import SQLite3
import Testing
@testable import SweepCore
@testable import SweepScanners

/// AI model, Docker and tool-location scanning, all against fake home folders.
@Suite struct DeveloperToolsTests {
    private static let digestA = "sha256:" + String(repeating: "a", count: 64)
    private static let digestB = "sha256:" + String(repeating: "b", count: 64)
    private static let shared = "sha256:" + String(repeating: "c", count: 64)
    private static let orphan = "sha256-" + String(repeating: "d", count: 64)

    private func manifest(weights: String, config: String) -> Data {
        let json: [String: Any] = [
            "schemaVersion": 2,
            "config": ["mediaType": "application/vnd.docker.container.image.v1+json", "digest": config, "size": 10],
            "layers": [["mediaType": "application/vnd.ollama.image.model", "digest": weights, "size": 100]],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func ollamaFixture(_ mac: FakeMac, root: String = ".ollama/models") throws {
        let manifests = root + "/manifests/registry.ollama.ai"
        try mac.file(manifests + "/library/llama3.1/8b", contents: manifest(weights: Self.digestA, config: Self.shared))
        try mac.file(manifests + "/someone/coder/latest", contents: manifest(weights: Self.digestB, config: Self.shared))
        try mac.file(root + "/blobs/" + AIModelScanner.blobName(Self.digestA), bytes: 300_000)
        try mac.file(root + "/blobs/" + AIModelScanner.blobName(Self.digestB), bytes: 200_000)
        try mac.file(root + "/blobs/" + AIModelScanner.blobName(Self.shared), bytes: 4_000)
        try mac.file(root + "/blobs/" + Self.orphan, bytes: 50_000)
    }

    @Test func ollamaModelsFreeOnlyTheirOwnBlobs() throws {
        let mac = try FakeMac()
        try ollamaFixture(mac)
        // A fresh partial download is left alone; an abandoned one counts as unused.
        try mac.file(".ollama/models/blobs/sha256-" + String(repeating: "e", count: 64) + "-partial", bytes: 10_000)
        let stale = try mac.file(".ollama/models/blobs/sha256-" + String(repeating: "f", count: 64) + "-partial-0", bytes: 10_000)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: stale)

        let category = try #require(AIModelScanner(finder: ToolFinder(environment: mac.environment())).scan())
        let ollama = try #require(category.groups.first { $0.title == "Ollama" })
        let llama = try #require(ollama.items.first { $0.title == "llama3.1:8b" })
        let coder = try #require(ollama.items.first { $0.title == "someone/coder:latest" })
        #expect(!llama.isSelectedByDefault && !coder.isSelectedByDefault)
        // The config blob both models use stays until neither needs it.
        #expect(!llama.action.paths.contains { $0.hasSuffix(AIModelScanner.blobName(Self.shared)) })
        #expect(llama.action.paths.contains { $0.hasSuffix(AIModelScanner.blobName(Self.digestA)) })
        #expect(llama.action.paths.first?.hasSuffix("/library/llama3.1/8b") == true)
        if case .remove(_, let mode) = llama.action { #expect(mode == .moveToTrash) }

        let unused = try #require(ollama.items.first { $0.title == "Unused model files" })
        #expect(unused.isSelectedByDefault)
        #expect(unused.action.paths.contains { $0.hasSuffix(Self.orphan) })
        #expect(unused.action.paths.contains(stale))
        #expect(!unused.action.paths.contains { $0.hasSuffix("-partial") })
    }

    @Test func modelNamesFollowOllamaConventions() {
        #expect(AIModelScanner.displayName(["registry.ollama.ai", "library", "gemma3", "1b"]) == "gemma3:1b")
        #expect(AIModelScanner.displayName(["registry.ollama.ai", "acme", "coder", "latest"]) == "acme/coder:latest")
        #expect(AIModelScanner.displayName(["hf.co", "org", "repo", "Q4"]) == "hf.co/org/repo:Q4")
    }

    @Test func lmStudioFollowsItsDownloadsFolderSetting() throws {
        let mac = try FakeMac()
        let custom = mac.root + "/External/Models"
        try mac.file(".lmstudio/settings.json",
                     contents: try JSONSerialization.data(withJSONObject: ["downloadsFolder": custom]))
        try mac.file(custom + "/acme/Tiny-7B-GGUF/tiny-7b.Q4_K_M.gguf", bytes: 120_000)
        try mac.file(custom + "/acme/Small-mlx-4bit/model.safetensors", bytes: 80_000)

        let finder = ToolFinder(environment: mac.environment())
        #expect(finder.lmStudioModels.first == ToolLocation(path: custom, origin: .toolSettings))
        let group = try #require(AIModelScanner(finder: finder).scan()?.groups.first { $0.title == "LM Studio" })
        #expect(group.items.map(\.title).sorted() == ["Small-mlx-4bit", "Tiny-7B-GGUF"])
        #expect(group.items.first { $0.title == "Tiny-7B-GGUF" }?.subtitle == "acme · GGUF")
        #expect(group.items.first { $0.title == "Small-mlx-4bit" }?.subtitle == "acme · MLX")
    }

    @Test func huggingFaceFollowsHFHome() throws {
        let mac = try FakeMac()
        let hfHome = mac.root + "/hf"
        try mac.file(hfHome + "/hub/models--acme--bert-tiny/blobs/abc", bytes: 90_000)
        try mac.file(hfHome + "/hub/datasets--acme--reviews/blobs/def", bytes: 40_000)
        try mac.file(hfHome + "/hub/version.txt", bytes: 10)
        try mac.file(hfHome + "/xet/chunk-cache/x", bytes: 30_000)
        var environment = mac.environment()
        environment.variables = ["HF_HOME": hfHome]

        let group = try #require(AIModelScanner(finder: ToolFinder(environment: environment)).scan()?
            .groups.first { $0.title == "Hugging Face" })
        #expect(Set(group.items.map(\.title)) == ["acme/bert-tiny", "acme/reviews", "Download cache"])
        #expect(group.items.first { $0.title == "acme/reviews" }?.subtitle == "Hugging Face dataset")
        #expect(group.items.first { $0.title == "Download cache" }?.isSelectedByDefault == true)
        #expect(group.items.first { $0.title == "acme/bert-tiny" }?.isSelectedByDefault == false)
    }

    @Test func sameModelInOllamaAndLMStudioIsPointedOut() throws {
        let mac = try FakeMac()
        try ollamaFixture(mac)
        let weights = try Data(contentsOf: URL(fileURLWithPath: mac.home + "/.ollama/models/blobs/" + AIModelScanner.blobName(Self.digestA)))
        try mac.file(".lmstudio/models/acme/Llama-8B-GGUF/llama-8b.gguf", contents: weights)

        let category = try #require(AIModelScanner(finder: ToolFinder(environment: mac.environment())).scan())
        let lm = try #require(category.groups.first { $0.title == "LM Studio" }?.items.first)
        let llama = try #require(category.groups.first { $0.title == "Ollama" }?.items.first { $0.title == "llama3.1:8b" })
        #expect(lm.subtitle == "Same model file as Ollama's llama3.1:8b")
        #expect(llama.subtitle == "Same model file as LM Studio's Llama-8B-GGUF")
    }

    @Test func ollamaLocationPrecedence() throws {
        let mac = try FakeMac()
        // The Ollama app's own setting.
        try FileManager.default.createDirectory(atPath: mac.home + "/Library/Application Support/Ollama", withIntermediateDirectories: true)
        let database = mac.home + "/Library/Application Support/Ollama/db.sqlite"
        var handle: OpaquePointer?
        #expect(sqlite3_open(database, &handle) == SQLITE_OK)
        sqlite3_exec(handle, "CREATE TABLE settings (id INTEGER, models TEXT); INSERT INTO settings VALUES (1, '/Volumes/AI/ollama');", nil, nil, nil)
        sqlite3_close(handle)

        var environment = mac.environment()
        #expect(ToolFinder(environment: environment).ollamaModels == ToolLocation(path: "/Volumes/AI/ollama", origin: .toolSettings))
        environment.variables = ["OLLAMA_MODELS": "~/models"]
        #expect(ToolFinder(environment: environment).ollamaModels == ToolLocation(path: mac.home + "/models", origin: .environment))
        let custom = ToolFinder(environment: environment, overrides: ToolLocations(ollamaModels: "/Users/Shared/ollama"))
        #expect(custom.ollamaModels == ToolLocation(path: "/Users/Shared/ollama", origin: .sweep))
        #expect(ToolFinder(environment: FakeMacWithoutTools(mac).environment).ollamaModels.origin == .standard)
    }

    // MARK: Docker

    private static let systemDF = """
        {"Active":"2","Reclaimable":"1.234GB (45%)","Size":"2.7GB","TotalCount":"5","Type":"Images"}
        {"Active":"1","Reclaimable":"12.5kB (10%)","Size":"125kB","TotalCount":"3","Type":"Containers"}
        {"Active":"1","Reclaimable":"800MB (50%)","Size":"1.6GB","TotalCount":"2","Type":"Local Volumes"}
        {"Active":"0","Reclaimable":"512MB","Size":"512MB","TotalCount":"14","Type":"Build Cache"}
        """

    @Test func dockerSizesAndUsage() throws {
        #expect(DockerScanner.parseSize("1.234GB") == 1_234_000_000)
        #expect(DockerScanner.parseSize("12.5kB") == 12_500)
        #expect(DockerScanner.parseSize("0B") == 0)
        #expect(DockerScanner.parseSize("nonsense") == nil)
        let usage = try #require(DockerScanner.parseSystemDF(Self.systemDF))
        #expect(usage["Images"] == 1_234_000_000)
        #expect(usage["Build Cache"] == 512_000_000)
        #expect(DockerScanner.parseSystemDF("Cannot connect to the Docker daemon") == nil)
    }

    @Test func dockerOffersPrunesButNeverVolumes() throws {
        let mac = try FakeMac()
        let cli = try mac.file(".docker/bin/docker", bytes: 100)
        chmod(cli, 0o755)
        let finder = ToolFinder(environment: mac.environment())
        let scanner = DockerScanner(finder: finder) { executable, arguments in
            #expect(executable == cli)
            #expect(arguments.prefix(2) == ["system", "df"])
            return (0, Self.systemDF)
        }
        let result = scanner.scan()
        #expect(result.engine == .running(cli: cli))
        let items = try #require(result.category?.groups.first?.items)
        #expect(items.map(\.title) == ["Build cache", "Unused images", "Stopped containers"])
        #expect(items.allSatisfy { !$0.isSelectedByDefault })
        #expect(!items.contains { item in
            if case .custom(_, let payload) = item.action { return payload.contains("volume") }
            return false
        })

        let stopped = DockerScanner(finder: finder) { _, _ in (1, "Cannot connect to the Docker daemon") }.scan()
        #expect(stopped.engine == .notRunning(cli: cli))
        #expect(stopped.category == nil)
        #expect(DockerScanner(finder: ToolFinder(environment: FakeMacWithoutTools(mac).environment)).scan().engine == .notInstalled)
    }

    @Test func dockerPerformerRunsOnlyKnownPrunes() {
        let ran = Locked<[[String]]>([])
        let performer = DockerPerformer { executable, arguments in
            ran.withLock { $0.append([executable] + arguments) }
            return (0, "Deleted build cache objects:\nabc\n\nTotal reclaimed space: 1.5GB")
        }
        let allowed = ScanItem(id: "docker:buildcache", title: "Build cache", size: 10, isSelectedByDefault: false,
                               action: .custom(kind: "docker", payload: ["/usr/local/bin/docker", "builder", "prune", "--force"]))
        let volumes = ScanItem(id: "docker:volumes", title: "Volumes", size: 10, isSelectedByDefault: false,
                               action: .custom(kind: "docker", payload: ["/usr/local/bin/docker", "volume", "prune", "--force"]))
        let other = ScanItem(id: "x", title: "Not docker", size: 10, isSelectedByDefault: false,
                             action: .custom(kind: "docker", payload: ["/bin/rm", "builder", "prune", "--force"]))
        let records = performer.perform([allowed, volumes, other])
        #expect(ran.withLock { $0 } == [["/usr/local/bin/docker", "builder", "prune", "--force"]])
        #expect(records[0].outcome == .done("Cleaned by Docker") && records[0].bytes == 1_500_000_000)
        #expect(!records[1].succeeded && !records[2].succeeded)
    }

    // MARK: Device files

    @Test func downloadedDeviceSoftwareUpdatesAreListed() throws {
        let mac = try FakeMac()
        try mac.file("Library/iTunes/iPhone Software Updates/iPhone17,1_26.0_Restore.ipsw", bytes: 70_000)
        let category = try #require(CleanupScanner(environment: mac.environment()).scan().category("deviceBackups"))
        let item = try #require(category.groups.first { $0.id == "firmware" }?.items.first)
        #expect(item.title == "iPhone17,1_26.0_Restore.ipsw")
        #expect(item.isSelectedByDefault)
    }
}

/// The same fake Mac with no applications folder, so no tool apps or settings are found.
private struct FakeMacWithoutTools {
    let environment: ScanEnvironment

    init(_ mac: FakeMac) {
        let empty = mac.root + "/empty-home"
        try? FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        environment = ScanEnvironment(home: empty, systemRoot: mac.root + "/empty-system", applicationFolders: [])
    }
}
