import Foundation
import SweepCore

/// Local AI models from Ollama, LM Studio, Hugging Face and a few other tools. Models can be downloaded
/// again, so they are listed for review, but none is preselected: big models take a long time to fetch.
/// Removed models go to the Trash.
public struct AIModelScanner: Sendable {
    public let finder: ToolFinder

    public init(finder: ToolFinder) {
        self.finder = finder
    }

    public var environment: ScanEnvironment { finder.environment }

    public func scan(progress: (String) -> Void = { _ in }) -> ScanCategory? {
        progress("Looking for AI models")
        var ollama = ollamaModels()
        var lmStudio = lmStudioModels()
        markDuplicates(&ollama, &lmStudio)
        let groups = [ollama.group, lmStudio.group, huggingFace(), otherTools()].compactMap { $0 }
            .filter { !$0.items.isEmpty }
            .sorted { $0.size > $1.size }
        guard !groups.isEmpty else { return nil }
        return ScanCategory(id: "aiModels", title: "AI Models",
                            summary: "Models downloaded by local AI apps. They can be downloaded again, but large ones take a while. Removed models go to the Trash.",
                            symbol: "brain", groups: groups)
    }

    // MARK: Ollama

    /// One model in an Ollama models folder.
    struct OllamaModel {
        let name: String
        let manifest: String
        /// The weights layer, for spotting the same model in another app.
        let weights: String?
        /// Blobs used by no other model; removing the model frees these.
        var exclusiveBlobs: [String]
        var bytes: UInt64
    }

    /// A tool's models, before duplicates are marked.
    struct Found {
        var group: ScanGroup?
        /// Item id → the model file that identifies it.
        var weights: [String: String] = [:]
    }

    func ollamaModels() -> Found {
        let root = finder.ollamaModels.path
        let models = Self.ollamaManifests(in: root)
        guard !models.isEmpty || FileManager.default.fileExists(atPath: root + "/blobs") else { return Found() }
        var items: [ScanItem] = []
        var weights: [String: String] = [:]
        for model in models where model.bytes > 0 {
            items.append(ScanItem(id: model.manifest, title: model.name, subtitle: "Ollama model", size: model.bytes,
                                  date: Measure.modificationDate(model.manifest), isSelectedByDefault: false,
                                  action: .remove(paths: [model.manifest] + model.exclusiveBlobs, mode: .moveToTrash)))
            weights[model.manifest] = model.weights
        }
        // Blobs no model refers to: leftovers of removed models and abandoned downloads.
        let unused = Self.unusedOllamaBlobs(in: root, now: environment.now)
        if !unused.isEmpty {
            let bytes = unused.reduce(0) { $0 + Measure.allocated($1) }
            if bytes > 0 {
                items.append(ScanItem(id: root + "/blobs#unused", title: "Unused model files",
                                      subtitle: "\(unused.count) files no installed model uses", size: bytes,
                                      isSelectedByDefault: true, action: .remove(paths: unused, mode: .moveToTrash)))
            }
        }
        let group = ScanGroup(id: "ai:ollama", title: "Ollama", subtitle: abbreviated(root),
                              icon: finder.ollamaApp.map(ItemIcon.file) ?? .symbol("brain"),
                              items: items.sorted { $0.size > $1.size })
        return Found(group: group, weights: weights)
    }

    /// Reads every manifest under `root/manifests` and works out which blobs only it uses.
    static func ollamaManifests(in root: String) -> [OllamaModel] {
        struct Manifest: Decodable {
            struct Layer: Decodable {
                let mediaType: String?
                let digest: String
            }
            let config: Layer?
            let layers: [Layer]
        }
        let manifests = root + "/manifests"
        var found: [(name: String, path: String, digests: [String], weights: String?)] = []
        func walk(_ folder: String, _ components: [String]) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = folder + "/" + name
                if AppCatalog.isDirectory(path) {
                    if components.count < 4 { walk(path, components + [name]) }
                } else if components.count == 3, let data = FileManager.default.contents(atPath: path),
                          let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
                    let digests = ([manifest.config].compactMap { $0 } + manifest.layers).map(\.digest)
                    let weights = manifest.layers.first { $0.mediaType == "application/vnd.ollama.image.model" }?.digest
                    found.append((displayName(components + [name]), path, digests,
                                  weights.map { root + "/blobs/" + blobName($0) }))
                }
            }
        }
        walk(manifests, [])

        var users: [String: Int] = [:]
        for model in found { for digest in Set(model.digests) { users[digest, default: 0] += 1 } }
        return found.map { model in
            let exclusive = Set(model.digests).filter { users[$0] == 1 }.map { root + "/blobs/" + blobName($0) }
                .filter { FileManager.default.fileExists(atPath: $0) }.sorted()
            let bytes = exclusive.reduce(Measure.allocated(model.path)) { $0 + Measure.allocated($1) }
            return OllamaModel(name: model.name, manifest: model.path, weights: model.weights,
                               exclusiveBlobs: exclusive, bytes: exclusive.isEmpty ? 0 : bytes)
        }
    }

    /// "registry.ollama.ai/library/llama3.1/8b" → "llama3.1:8b"; other namespaces and registries stay visible.
    static func displayName(_ components: [String]) -> String {
        guard components.count == 4 else { return components.joined(separator: "/") }
        let (registry, namespace, model, tag) = (components[0], components[1], components[2], components[3])
        if registry == "registry.ollama.ai" {
            return namespace == "library" ? "\(model):\(tag)" : "\(namespace)/\(model):\(tag)"
        }
        return "\(registry)/\(namespace)/\(model):\(tag)"
    }

    /// "sha256:abc" → "sha256-abc", the blob's file name.
    static func blobName(_ digest: String) -> String { digest.replacingOccurrences(of: ":", with: "-") }

    /// Blobs no manifest refers to. Partial downloads count only once they're a day old, so a download in
    /// progress is left alone.
    static func unusedOllamaBlobs(in root: String, now: Date) -> [String] {
        let blobs = root + "/blobs"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: blobs) else { return [] }
        let manifests = Self.allReferencedDigests(in: root)
        return names.sorted().compactMap { name -> String? in
            guard name.hasPrefix("sha256-") else { return nil }
            let path = blobs + "/" + name
            let digest = String(name.prefix(7 + 64))
            if name.contains("-partial") {
                let age = now.timeIntervalSince(Measure.modificationDate(path) ?? now)
                return age > 86_400 ? path : nil
            }
            return manifests.contains(digest) ? nil : path
        }
    }

    /// Every blob file name referenced by any manifest, including ones whose other blobs are missing.
    static func allReferencedDigests(in root: String) -> Set<String> {
        var digests = Set<String>()
        let enumerator = FileManager.default.enumerator(atPath: root + "/manifests")
        while let relative = enumerator?.nextObject() as? String {
            let path = root + "/manifests/" + relative
            guard !AppCatalog.isDirectory(path), let data = FileManager.default.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8) else { continue }
            var searchRange = text.startIndex..<text.endIndex
            while let match = text.range(of: #"sha256:[0-9a-f]{64}"#, options: .regularExpression, range: searchRange) {
                digests.insert(blobName(String(text[match])))
                searchRange = match.upperBound..<text.endIndex
            }
        }
        return digests
    }

    // MARK: LM Studio

    func lmStudioModels() -> Found {
        var items: [ScanItem] = []
        var weights: [String: String] = [:]
        var roots: [String] = []
        for location in finder.lmStudioModels where FileManager.default.fileExists(atPath: location.path) {
            roots.append(location.path)
            // models/<publisher>/<model>/files…
            for publisher in Self.subfolders(location.path) {
                let publisherName = (publisher as NSString).lastPathComponent
                for model in Self.contents(publisher) {
                    let bytes = Measure.size(model)
                    guard bytes > 0 else { continue }
                    let name = (model as NSString).lastPathComponent
                    let files = AppCatalog.isDirectory(model) ? Self.contents(model) : [model]
                    items.append(ScanItem(id: model, title: name,
                                          subtitle: "\(publisherName) · \(Self.format(of: files, name: name))",
                                          size: bytes, date: Measure.modificationDate(model), isSelectedByDefault: false,
                                          action: .remove(paths: [model], mode: .moveToTrash)))
                    if let largest = files.filter({ $0.hasSuffix(".gguf") }).max(by: { Measure.allocated($0) < Measure.allocated($1) }) {
                        weights[model] = largest
                    }
                }
            }
        }
        guard !items.isEmpty else { return Found() }
        let group = ScanGroup(id: "ai:lmstudio", title: "LM Studio", subtitle: roots.map(abbreviated).joined(separator: ", "),
                              icon: finder.lmStudioApp.map(ItemIcon.file) ?? .symbol("brain"),
                              items: items.sorted { $0.size > $1.size })
        return Found(group: group, weights: weights)
    }

    static func format(of files: [String], name: String) -> String {
        if files.contains(where: { $0.hasSuffix(".gguf") }) { return "GGUF" }
        if files.contains(where: { $0.hasSuffix(".safetensors") }) {
            return name.localizedCaseInsensitiveContains("mlx") ? "MLX" : "Safetensors"
        }
        return "Model"
    }

    // MARK: Hugging Face

    func huggingFace() -> ScanGroup? {
        let hub = finder.huggingFaceHub.path
        var items: [ScanItem] = []
        for repo in Self.subfolders(hub) {
            let folder = (repo as NSString).lastPathComponent
            guard let kind = ["models--": "Model", "datasets--": "Dataset", "spaces--": "Space"]
                .first(where: { folder.hasPrefix($0.key) }) else { continue }
            let bytes = Measure.size(repo)
            guard bytes > 0 else { continue }
            let name = folder.dropFirst(kind.key.count).replacingOccurrences(of: "--", with: "/")
            items.append(ScanItem(id: repo, title: name, subtitle: "Hugging Face \(kind.value.lowercased())", size: bytes,
                                  date: Measure.modificationDate(repo + "/refs") ?? Measure.modificationDate(repo),
                                  isSelectedByDefault: false, action: .remove(paths: [repo], mode: .moveToTrash)))
        }
        // The Xet chunk cache only speeds up downloads.
        let xet = (hub as NSString).deletingLastPathComponent + "/xet"
        let xetBytes = Measure.size(xet)
        if xetBytes > 0 {
            items.append(ScanItem(id: xet, title: "Download cache", subtitle: "Speeds up repeat downloads; safe to remove",
                                  size: xetBytes, isSelectedByDefault: true, action: .remove(paths: [xet], mode: .moveToTrash)))
        }
        guard !items.isEmpty else { return nil }
        return ScanGroup(id: "ai:huggingface", title: "Hugging Face", subtitle: abbreviated(hub), icon: .symbol("cube.fill"),
                         items: items.sorted { $0.size > $1.size })
    }

    // MARK: Other tools

    func otherTools() -> ScanGroup? {
        let places: [(String, String)] = [
            ("Library/Application Support/nomic.ai/GPT4All", "GPT4All"),
            (".cache/torch/hub/checkpoints", "PyTorch Hub"),
            (".cache/whisper", "Whisper"),
        ]
        var items: [ScanItem] = []
        for (relative, tool) in places {
            for file in Self.contents(environment.user(relative))
            where [".gguf", ".bin", ".pt", ".pth", ".safetensors"].contains(where: file.hasSuffix) {
                let bytes = Measure.size(file)
                guard bytes > 50_000_000 else { continue }
                items.append(ScanItem(id: file, title: (file as NSString).lastPathComponent, subtitle: "\(tool) model",
                                      size: bytes, date: Measure.modificationDate(file), isSelectedByDefault: false,
                                      action: .remove(paths: [file], mode: .moveToTrash)))
            }
        }
        guard !items.isEmpty else { return nil }
        return ScanGroup(id: "ai:other", title: "Other AI Tools", subtitle: "GPT4All, PyTorch Hub and Whisper",
                         icon: .symbol("cpu"), items: items.sorted { $0.size > $1.size })
    }

    // MARK: Duplicates

    /// The same model file kept by both Ollama and LM Studio. Compared by size, then by sampled hash.
    func markDuplicates(_ ollama: inout Found, _ lmStudio: inout Found) {
        guard var ollamaGroup = ollama.group, var lmGroup = lmStudio.group else { return }
        var bySize: [UInt64: [(id: String, file: String)]] = [:]
        for (id, file) in ollama.weights { bySize[Self.logicalSize(file), default: []].append((id, file)) }
        var notes: [String: String] = [:]
        for (lmID, lmFile) in lmStudio.weights {
            let size = Self.logicalSize(lmFile)
            guard size > 0, let candidates = bySize[size] else { continue }
            let sample = DuplicateFinder.sampledHash(lmFile, size: size)
            for candidate in candidates where sample != nil && DuplicateFinder.sampledHash(candidate.file, size: size) == sample {
                let ollamaName = ollamaGroup.items.first { $0.id == candidate.id }?.title ?? "a model"
                let lmName = lmGroup.items.first { $0.id == lmID }?.title ?? "a model"
                notes[lmID] = "Same model file as Ollama's \(ollamaName)"
                notes[candidate.id] = "Same model file as LM Studio's \(lmName)"
            }
        }
        guard !notes.isEmpty else { return }
        func annotate(_ group: inout ScanGroup) {
            group.items = group.items.map { item in
                guard let note = notes[item.id] else { return item }
                return ScanItem(id: item.id, title: item.title, subtitle: note, size: item.size, date: item.date,
                                isSelectedByDefault: item.isSelectedByDefault, action: item.action)
            }
        }
        annotate(&ollamaGroup)
        annotate(&lmGroup)
        ollama.group = ollamaGroup
        lmStudio.group = lmGroup
    }

    // MARK: Helpers

    /// "/Users/me/.ollama/models" → "~/.ollama/models".
    func abbreviated(_ path: String) -> String {
        path.hasPrefix(environment.home + "/") ? "~" + path.dropFirst(environment.home.count) : path
    }

    static func logicalSize(_ path: String) -> UInt64 {
        var info = stat()
        guard stat(path, &info) == 0 else { return 0 }
        return UInt64(info.st_size)
    }

    static func subfolders(_ folder: String) -> [String] {
        contents(folder).filter(AppCatalog.isDirectory)
    }

    static func contents(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
            .filter { !$0.hasPrefix(".") }
            .map { folder + "/" + $0 }
    }
}
