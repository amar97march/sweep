import CryptoKit
import Foundation
import ImageIO
import SweepCore

/// Finds clutter in the user's own folders: exact duplicates, look-alike photos, big files not opened
/// in a long time, and old downloads. Everything found here goes to the Trash, never straight to deletion.
public struct ClutterScanner: Sendable {
    public struct Options: Sendable {
        /// Files smaller than this are ignored for duplicates and similar images.
        public var minimumDuplicateSize: UInt64 = 100 * 1024
        /// "Large" starts here (decimal, as Finder shows sizes).
        public var largeFileSize: UInt64 = 50_000_000
        /// Not opened for this long counts as "old".
        public var oldAge: TimeInterval = 365 * 86_400
        /// Downloads older than this are listed.
        public var downloadAge: TimeInterval = 30 * 86_400
        /// Maximum Hamming distance between perceptual hashes for "similar".
        public var similarityThreshold = 10
        public init() {}
    }

    public let environment: ScanEnvironment
    public let options: Options
    /// Folders searched; defaults to the user's document folders.
    public let roots: [String]

    public init(environment: ScanEnvironment, options: Options = Options(), roots: [String]? = nil) {
        self.environment = environment
        self.options = options
        self.roots = roots ?? ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"]
            .map(environment.user)
    }

    public func scan(progress: (String) -> Void = { _ in }, isCancelled: () -> Bool = { false }) -> [ScanCategory] {
        progress("Listing your files")
        let files = FileWalker.files(under: roots, isCancelled: isCancelled)
        guard !isCancelled() else { return [] }
        var categories: [ScanCategory] = []
        progress("Comparing \(files.count.formatted()) files for duplicates")
        if let category = duplicates(in: files) { categories.append(category) }
        guard !isCancelled() else { return categories }
        progress("Looking for similar photos")
        if let category = similarImages(in: files, isCancelled: isCancelled) { categories.append(category) }
        progress("Looking for large and old files")
        if let category = largeAndOld(in: files) { categories.append(category) }
        progress("Checking Downloads")
        if let category = oldDownloads() { categories.append(category) }
        return categories
    }

    // MARK: Duplicates

    func duplicates(in files: [WalkedFile]) -> ScanCategory? {
        let candidates = files.filter { $0.size >= options.minimumDuplicateSize }
        let sets = DuplicateFinder.groups(candidates)
        let groups = sets.map { set -> ScanGroup in
            let keeper = DuplicateFinder.keeper(of: set, downloads: environment.user("Downloads"))
            let items = set.map { file in
                ScanItem(id: file.path, title: (file.path as NSString).lastPathComponent,
                         subtitle: (file.path as NSString).deletingLastPathComponent, size: file.size,
                         date: file.modified, isSelectedByDefault: file.path != keeper.path,
                         action: .remove(paths: [file.path], mode: .moveToTrash),
                         note: nil)
            }
            let name = (keeper.path as NSString).lastPathComponent
            return ScanGroup(id: "dup:" + keeper.path, title: name,
                             subtitle: "\(set.count) copies · \(ByteFormat.string(keeper.size)) each",
                             icon: .file(keeper.path), items: items)
        }
        guard !groups.isEmpty else { return nil }
        return ScanCategory(id: "duplicates", title: "Duplicates",
                            summary: "Identical copies of the same file. One copy of each is kept unless you choose otherwise.",
                            symbol: "doc.on.doc.fill", groups: groups.sorted { $0.size > $1.size })
    }

    // MARK: Similar images

    func similarImages(in files: [WalkedFile], isCancelled: () -> Bool = { false }) -> ScanCategory? {
        let images = files.filter { $0.size >= options.minimumDuplicateSize && ImageHash.isImage($0.path) }
        var hashed: [(WalkedFile, ImageHash)] = []
        for file in images {
            if isCancelled() { return nil }
            if let hash = ImageHash.compute(file.path) { hashed.append((file, hash)) }
        }
        let clusters = ImageHash.clusters(hashed.map(\.1), threshold: options.similarityThreshold, isCancelled: isCancelled)
        let groups = clusters.compactMap { indices -> ScanGroup? in
            let members = indices.map { hashed[$0] }
            // Keep the one with the most pixels (ties: the largest file).
            guard let best = members.max(by: { ($0.1.pixels, $0.0.size) < ($1.1.pixels, $1.0.size) }) else { return nil }
            let items = members.map { file, hash in
                ScanItem(id: file.path, title: (file.path as NSString).lastPathComponent,
                         subtitle: "\(hash.width)×\(hash.height) · \((file.path as NSString).deletingLastPathComponent)",
                         size: file.size, date: file.modified,
                         // Look-alikes may differ in ways that matter, so nothing is preselected.
                         isSelectedByDefault: false,
                         action: .remove(paths: [file.path], mode: .moveToTrash),
                         note: nil)
            }
            return ScanGroup(id: "similar:" + best.0.path, title: (best.0.path as NSString).lastPathComponent,
                             subtitle: "\(members.count) similar photos · best: \(best.1.width)×\(best.1.height)",
                             icon: .file(best.0.path), items: items)
        }
        guard !groups.isEmpty else { return nil }
        return ScanCategory(id: "similar", title: "Similar Images",
                            summary: "Photos that look nearly the same, like bursts and resized copies. Review before removing.",
                            symbol: "photo.stack.fill", groups: groups.sorted { $0.size > $1.size })
    }

    // MARK: Large and old

    func largeAndOld(in files: [WalkedFile]) -> ScanCategory? {
        let large = files.filter { $0.size >= options.largeFileSize }
        let bands: [(String, String, ClosedRange<UInt64>)] = [
            ("huge", "1 GB and larger", 1_000_000_000...UInt64.max),
            ("medium", "500 MB – 1 GB", 500_000_000...999_999_999),
            ("small", "50 – 500 MB", options.largeFileSize...499_999_999),
        ]
        let cutoff = environment.now.addingTimeInterval(-options.oldAge)
        var groups: [ScanGroup] = []
        for (id, title, range) in bands {
            let items = large.filter { range.contains($0.size) }.map { file -> ScanItem in
                let opened = file.accessed ?? file.modified
                let old = (opened ?? .distantPast) < cutoff
                return ScanItem(id: file.path, title: (file.path as NSString).lastPathComponent,
                                subtitle: (old ? "Not opened for over a year · " : "") + (file.path as NSString).deletingLastPathComponent,
                                size: file.size, date: opened, isSelectedByDefault: false,
                                action: .remove(paths: [file.path], mode: .moveToTrash))
            }
            if !items.isEmpty {
                groups.append(ScanGroup(id: "large:" + id, title: title, subtitle: "\(items.count) files",
                                        icon: .symbol("externaldrive.fill"), items: items))
            }
        }
        guard !groups.isEmpty else { return nil }
        return ScanCategory(id: "large", title: "Large & Old Files",
                            summary: "Big files in your folders, with when you last opened them. Nothing is selected for you.",
                            symbol: "shippingbox.fill", groups: groups)
    }

    // MARK: Downloads

    func oldDownloads() -> ScanCategory? {
        let folder = environment.user("Downloads")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }
        let cutoff = environment.now.addingTimeInterval(-options.downloadAge)
        var installers: [ScanItem] = [], archives: [ScanItem] = [], other: [ScanItem] = []
        for name in names.sorted() {
            let path = folder + "/" + name
            let added = Self.addedDate(path) ?? Measure.modificationDate(path) ?? .distantFuture
            guard added < cutoff else { continue }
            let item = ScanItem(id: "download:" + path, title: name, subtitle: path, size: Measure.size(path),
                                date: added, isSelectedByDefault: false,
                                action: .remove(paths: [path], mode: .moveToTrash))
            switch (name as NSString).pathExtension.lowercased() {
            case "dmg", "pkg", "mpkg", "iso": installers.append(item)
            case "zip", "rar", "7z", "tar", "gz", "tgz", "xip": archives.append(item)
            default: other.append(item)
            }
        }
        let groups = [("Installers", "Disk images and packages, usually not needed after installing", installers),
                      ("Archives", "Compressed files you may already have opened", archives),
                      ("Other downloads", "Downloaded more than a month ago", other)]
            .filter { !$0.2.isEmpty }
            .map { ScanGroup(id: "downloads:" + $0.0, title: $0.0, subtitle: $0.1, icon: .symbol("arrow.down.circle.fill"),
                             items: $0.2.sorted { $0.size > $1.size }) }
        guard !groups.isEmpty else { return nil }
        return ScanCategory(id: "downloads", title: "Old Downloads",
                            summary: "Things in Downloads you got more than a month ago.",
                            symbol: "arrow.down.circle.fill", groups: groups)
    }

    static func addedDate(_ path: String) -> Date? {
        try? URL(fileURLWithPath: path).resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate
    }
}

/// A regular file found while walking the user's folders.
public struct WalkedFile: Sendable, Hashable {
    public let path: String
    public let size: UInt64
    public let device: Int32
    public let inode: UInt64
    public let modified: Date?
    public let accessed: Date?
}

enum FileWalker {
    /// Folder names never searched for clutter (build output, dependencies, app data).
    static let skippedFolders: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", "bower_components", "Pods", "DerivedData", ".build", "build",
        "Library", ".Trash", "venv", ".venv", "__pycache__", ".gradle", ".npm", ".cache", "target",
    ]
    /// Package extensions treated as single files and not searched inside, including ones whose app may not be
    /// installed (so macOS can't say they're packages). A file inside a package belongs to it: taking a
    /// "duplicate" out of a Scrivener project or a virtual machine breaks it.
    static let packages: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "tvlibrary", "bundle", "framework", "plugin", "kext", "xcodeproj",
        "xcworkspace", "playground", "sparsebundle", "fcpbundle", "logicx", "band", "pages", "numbers", "key",
        "lproj", "xcassets", "rtfd", "imovielibrary", "photolibrary", "aplibrary",
        "scriv", "dtbase2", "dtsparse", "vmwarevm", "pvm", "utm", "lrlibrary", "lrdata", "cocatalog", "cosessiondb",
        "xcarchive", "mpkg", "download", "workflow", "appex", "dsym", "docarchive", "mlmodelc", "mlpackage",
        "graffle", "omnioutliner", "ulysses", "logicx", "garageband", "fcpxbundle", "motn", "prproj", "aep",
    ]

    /// A folder macOS (or the list above) treats as one document.
    static func isPackage(_ path: String, name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if packages.contains(ext) { return true }
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    /// Every regular file under `roots` (hard links listed once), not following symlinks.
    static func files(under roots: [String], isCancelled: () -> Bool) -> [WalkedFile] {
        var result: [WalkedFile] = []
        var seen = Set<String>()
        let reader = BulkDirectoryReader()
        var queue = roots
        var visitedInodes = Set<[UInt64]>()
        while let folder = queue.popLast() {
            if isCancelled() { break }
            reader.read(folder) { entry in
                if entry.name.hasPrefix(".") && entry.name != ".." { return }
                let path = folder + "/" + entry.name
                switch entry.kind {
                case .directory:
                    guard !skippedFolders.contains(entry.name), !isPackage(path, name: entry.name) else { return }
                    if visitedInodes.insert([UInt64(bitPattern: Int64(entry.deviceID)), entry.fileID]).inserted {
                        queue.append(path)
                    }
                case .file:
                    guard !entry.isDataless, entry.allocatedSize > 0 || entry.logicalSize == 0 else { return }
                    let key = "\(entry.deviceID):\(entry.fileID)"
                    guard seen.insert(key).inserted else { return }
                    result.append(WalkedFile(path: path, size: entry.logicalSize, device: entry.deviceID,
                                             inode: entry.fileID, modified: nil, accessed: nil))
                default:
                    break
                }
            }
        }
        // Dates for the files that may need them (large ones and duplicate candidates), via one stat each.
        return result.map { file in
            var info = stat()
            guard lstat(file.path, &info) == 0 else { return file }
            return WalkedFile(path: file.path, size: file.size, device: file.device, inode: file.inode,
                              modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
                              accessed: Date(timeIntervalSince1970: TimeInterval(info.st_atimespec.tv_sec)))
        }
    }
}

/// Exact-duplicate detection: same size → same sampled hash → same full hash.
public enum DuplicateFinder {
    static let sampleSize = 1 << 20  // 1 MiB
    static let sampleCount = 4

    /// Sets of identical files (two or more each), largest first.
    public static func groups(_ files: [WalkedFile]) -> [[WalkedFile]] {
        let bySize = Dictionary(grouping: files, by: \.size).values.filter { $0.count > 1 }
        var result: [[WalkedFile]] = []
        for sameSize in bySize {
            let bySample = Dictionary(grouping: sameSize) { sampledHash($0.path, size: $0.size) ?? "" }
            for (sample, candidates) in bySample where !sample.isEmpty && candidates.count > 1 {
                // Small files were hashed whole already. Large ones are confirmed with a full hash so that
                // files that differ outside the samples are never reported as duplicates.
                if candidates[0].size <= UInt64(sampleSize * sampleCount) {
                    result.append(candidates)
                } else {
                    let byFull = Dictionary(grouping: candidates) { fullHash($0.path) ?? "" }
                    result += byFull.filter { !$0.key.isEmpty && $0.value.count > 1 }.map(\.value)
                }
            }
        }
        return result.map { $0.sorted { $0.path < $1.path } }.sorted { $0[0].size > $1[0].size }
    }

    /// Which copy to keep: not in Downloads, no "copy" / "(2)" in the name, shortest path, oldest.
    public static func keeper(of set: [WalkedFile], downloads: String) -> WalkedFile {
        set.min { score($0, downloads) < score($1, downloads) }!
    }

    private static func score(_ file: WalkedFile, _ downloads: String) -> (Int, Int, Int, Double, String) {
        let name = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        let isCopy = name.hasSuffix(" copy") || name.hasPrefix("copy of ") || name.hasSuffix("-copy")
            || name.range(of: #" \(\d+\)$| \d+$"#, options: .regularExpression) != nil
        return (file.path.hasPrefix(downloads + "/") ? 1 : 0, isCopy ? 1 : 0,
                file.path.split(separator: "/").count, file.modified?.timeIntervalSince1970 ?? 0, file.path)
    }

    /// SHA-256 of the whole file if it's up to 4 MiB, otherwise of four 1 MiB samples plus the size.
    static func sampledHash(_ path: String, size: UInt64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        let limit = UInt64(sampleSize * sampleCount)
        if size <= limit {
            guard let data = try? handle.readToEnd() else { return nil }
            hasher.update(data: data)
        } else {
            let stride = size / UInt64(sampleCount)
            for index in 0..<UInt64(sampleCount) {
                do {
                    try handle.seek(toOffset: index * stride)
                    guard let data = try handle.read(upToCount: sampleSize) else { return nil }
                    hasher.update(data: data)
                } catch {
                    return nil
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fullHash(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let data = try? handle.read(upToCount: 4 << 20) else { return nil }
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 64-bit DCT perceptual hash: robust to resizing, recompression and small edits.
public struct ImageHash: Sendable, Hashable {
    public let bits: UInt64
    public let width: Int
    public let height: Int
    public var pixels: Int { width * height }

    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]

    public static func isImage(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    public static func compute(_ path: String) -> ImageHash? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        guard let bits = hash(thumbnail) else { return nil }
        return ImageHash(bits: bits, width: width, height: height)
    }

    /// Grayscale 32×32 → 2-D DCT → low 8×8 frequencies → one bit per coefficient above the median.
    static func hash(_ image: CGImage) -> UInt64? {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var coefficients: [Double] = []
        coefficients.reserveCapacity(64)
        for u in 0..<8 {
            for v in 0..<8 {
                var sum = 0.0
                for x in 0..<side {
                    let cx = cos(Double(2 * x + 1) * Double(u) * .pi / Double(2 * side))
                    for y in 0..<side {
                        sum += Double(pixels[y * side + x]) * cx * cos(Double(2 * y + 1) * Double(v) * .pi / Double(2 * side))
                    }
                }
                coefficients.append(sum)
            }
        }
        // Skip the DC term (overall brightness) when picking the median.
        let median = coefficients.dropFirst().sorted()[31]
        var bits: UInt64 = 0
        for (index, value) in coefficients.enumerated() where value > median {
            bits |= 1 << UInt64(index)
        }
        return bits
    }

    public static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// Groups of indices whose hashes are within `threshold` of each other (single linkage).
    static func clusters(_ hashes: [ImageHash], threshold: Int, isCancelled: () -> Bool = { false }) -> [[Int]] {
        var parent = Array(hashes.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in hashes.indices {
            // Comparing every pair takes a while for big photo folders, so Stop is checked as it goes.
            if isCancelled() { return [] }
            for j in hashes.indices where j > i && distance(hashes[i].bits, hashes[j].bits) <= threshold {
                parent[root(i)] = root(j)
            }
        }
        return Dictionary(grouping: hashes.indices, by: root).values.filter { $0.count > 1 }.map { $0.sorted() }
    }
}
