import Darwin
import Foundation
import SweepCore

/// What macOS lumps into "System Data", split into parts with a plain explanation and what to do next.
public struct SystemDataReport: Sendable {
    public struct Part: Identifiable, Sendable, Hashable {
        /// Who looks after the space.
        public enum Handling: String, Sendable {
            /// macOS frees or resizes it by itself.
            case automatic
            /// Safe to clean; apps rebuild it.
            case safe
            /// The user's own downloads or app data: worth a look before removing anything.
            case review
        }

        /// Where the user can act on it.
        public enum Destination: Sendable, Hashable {
            /// A Cleanup category, by id.
            case cleanup(String)
            /// Measure this folder in Disk Map.
            case diskMap(String)
            /// Performance's maintenance tasks.
            case performance
            /// An app that has to be running first, like Docker Desktop.
            case openApp(String)
            case none
        }

        public let id: String
        public let title: String
        public let detail: String
        public let symbol: String
        public let bytes: UInt64
        public let handling: Handling
        public let destination: Destination
    }

    public let parts: [Part]
    public let measuredAt: Date
    /// Without Full Disk Access some app data can't be measured, so totals are lower than macOS reports.
    public let hasFullDiskAccess: Bool

    public init(parts: [Part], measuredAt: Date, hasFullDiskAccess: Bool) {
        self.parts = parts
        self.measuredAt = measuredAt
        self.hasFullDiskAccess = hasFullDiskAccess
    }

    public var total: UInt64 { parts.reduce(0) { $0 + $1.bytes } }
}

/// Measures the usual contents of System Data on the startup disk. Read-only.
public struct SystemDataScanner: Sendable {
    /// Volume figures, replaceable in tests.
    public struct Volume: Sendable {
        /// Free space macOS can create on its own by deleting snapshots and caches.
        public var purgeable: UInt64
        /// Swap file bytes in use plus the sleep image.
        public var virtualMemory: UInt64
        /// Local Time Machine snapshots (not the ones macOS keeps for updates).
        public var timeMachineSnapshots: Int

        public init(purgeable: UInt64, virtualMemory: UInt64, timeMachineSnapshots: Int) {
            self.purgeable = purgeable
            self.virtualMemory = virtualMemory
            self.timeMachineSnapshots = timeMachineSnapshots
        }
    }

    public let finder: ToolFinder
    public let volume: @Sendable () -> Volume
    public let dockerIsRunning: @Sendable () -> Bool
    public var hasFullDiskAccess: @Sendable () -> Bool = { PrivacyAccess.hasFullDiskAccess }

    public init(finder: ToolFinder, volume: @escaping @Sendable () -> Volume = SystemDataScanner.liveVolume,
                dockerIsRunning: (@Sendable () -> Bool)? = nil) {
        self.finder = finder
        self.volume = volume
        self.dockerIsRunning = dockerIsRunning ?? {
            guard let cli = finder.dockerCLI?.path else { return false }
            return Shell.run(cli, ["version", "--format", "{{.Server.Version}}"], timeout: 8).status == 0
        }
    }

    var environment: ScanEnvironment { finder.environment }

    public func scan(progress: (String) -> Void = { _ in }) -> SystemDataReport {
        var parts: [SystemDataReport.Part] = []
        func add(_ id: String, _ title: String, _ detail: String, symbol: String, bytes: UInt64,
                 handling: SystemDataReport.Part.Handling, destination: SystemDataReport.Part.Destination) {
            guard bytes > 0 else { return }
            parts.append(.init(id: id, title: title, detail: detail, symbol: symbol, bytes: bytes, handling: handling,
                               destination: destination))
        }

        progress("Checking purgeable space")
        let volume = volume()
        let snapshots = volume.timeMachineSnapshots
        add("purgeable", "Purgeable space",
            (snapshots > 0 ? "\(snapshots) local Time Machine snapshot\(snapshots == 1 ? "" : "s") and caches" : "Caches and snapshots")
                + " macOS can delete by itself. It frees this space automatically when an app needs it.",
            symbol: "clock.arrow.circlepath", bytes: volume.purgeable, handling: .automatic,
            destination: snapshots > 0 ? .performance : .none)
        add("virtualMemory", "Virtual memory",
            "Swap files and the sleep image let macOS keep more apps open than fit in memory and wake quickly. They shrink after a restart.",
            symbol: "memorychip", bytes: volume.virtualMemory, handling: .automatic, destination: .none)

        progress("Measuring caches")
        add("caches", "Caches and temporary files",
            "Copies apps keep so they open and load faster. Apps rebuild them when needed.",
            symbol: "archivebox.fill", bytes: sum([environment.user("Library/Caches"), environment.system("/Library/Caches")]
                                                + (environment.systemRoot.isEmpty ? Self.userTemporaryFolders() : [])),
            handling: .safe, destination: .cleanup("userCaches"))

        progress("Measuring logs")
        add("logs", "Logs and crash reports",
            "Records of what apps and macOS did. Only useful when troubleshooting.",
            symbol: "doc.text.magnifyingglass",
            bytes: sum([environment.user("Library/Logs"), environment.system("/Library/Logs"), environment.system("/private/var/log")]),
            handling: .safe, destination: .cleanup("logs"))

        progress("Measuring AI models")
        let models = [finder.ollamaModels.path, finder.huggingFaceHub.path,
                      (finder.huggingFaceHub.path as NSString).deletingLastPathComponent + "/xet"]
            + finder.lmStudioModels.map(\.path)
        let modelBytes = models.reduce(UInt64(0)) { $0 + Measure.size($1) }
        add("aiModels", "AI models",
            "Models downloaded by Ollama, LM Studio and Hugging Face tools. Each can be several gigabytes.",
            symbol: "brain", bytes: modelBytes, handling: .review, destination: .cleanup("aiModels"))

        let docker = finder.dockerDiskImage.map(Measure.allocated) ?? 0
        if docker > 0 {
            progress("Checking Docker")
            // Docker can only say what it would free while it runs.
            let running = dockerIsRunning()
            add("docker", "Docker",
                "Docker Desktop's virtual disk: images, containers, build cache and volumes. Free space from inside Docker, never by deleting the file."
                    + (running ? "" : " Open Docker so Sweep can see what it can free."),
                symbol: "shippingbox.fill", bytes: docker, handling: .review,
                destination: running ? .cleanup("docker") : finder.dockerApp.map { .openApp($0) } ?? .none)
        }

        progress("Measuring developer files")
        add("developer", "Developer files",
            "Xcode build products, simulators and device support files. macOS sometimes lists these under Developer.",
            symbol: "hammer.fill", bytes: sum([environment.user("Library/Developer")]),
            handling: .review, destination: .cleanup("developerJunk"))

        add("deviceFiles", "iPhone and iPad files",
            "Device backups and software updates downloaded to restore them. macOS sometimes lists these under iOS Files.",
            symbol: "iphone.gen3",
            bytes: sum([environment.user("Library/Application Support/MobileSync/Backup"),
                        environment.user("Library/iTunes/iPhone Software Updates"),
                        environment.user("Library/iTunes/iPad Software Updates")]),
            handling: .review, destination: .cleanup("deviceBackups"))

        // App data and hidden folders, minus the parts above that live inside them.
        let claimed = models + [finder.dockerDiskImage].compactMap { $0 }
        progress("Measuring app data")
        let appFolders = ["Library/Application Support", "Library/Containers", "Library/Group Containers"].map(environment.user)
        add("appData", "App data",
            "Settings, databases and downloads apps keep in your Library folder. Look through the biggest ones in Disk Map.",
            symbol: "folder.fill", bytes: sum(appFolders, excluding: claimed),
            handling: .review, destination: .diskMap(environment.user("Library")))

        progress("Measuring hidden folders")
        let hidden = Self.hiddenFolders(in: environment.home)
        add("hidden", "Hidden folders in your home",
            "Folders starting with a dot, used by developer tools and command-line apps for caches and settings.",
            symbol: "eye.slash.fill", bytes: sum(hidden, excluding: claimed),
            handling: .review, destination: .diskMap(environment.home))

        return SystemDataReport(parts: parts.sorted { $0.bytes > $1.bytes }, measuredAt: environment.now,
                                hasFullDiskAccess: hasFullDiskAccess())
    }

    /// Total size of `folders`, without counting anything inside `excluding` twice.
    func sum(_ folders: [String], excluding: [String] = []) -> UInt64 {
        var total: UInt64 = 0
        for folder in Set(folders) {
            let bytes = Measure.size(folder)
            let inside = excluding.filter { $0.hasPrefix(folder + "/") }.reduce(UInt64(0)) {
                $0 + ($1.hasSuffix(".raw") ? Measure.allocated($1) : Measure.size($1))
            }
            total += bytes - min(bytes, inside)
        }
        return total
    }

    static func hiddenFolders(in home: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []).sorted()
            .filter { $0.hasPrefix(".") && ![".Trash", ".DS_Store", ".localized"].contains($0) }
            .map { home + "/" + $0 }
            .filter(AppCatalog.isDirectory)
    }

    /// The per-user cache and temporary folders under /private/var/folders.
    static func userTemporaryFolders() -> [String] {
        [_CS_DARWIN_USER_CACHE_DIR, _CS_DARWIN_USER_TEMP_DIR].compactMap { name in
            let length = confstr(name, nil, 0)
            guard length > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: length)
            confstr(name, &buffer, length)
            let path = String(cString: buffer)
            return path.hasSuffix("/") ? String(path.dropLast()) : path
        }
    }

    // MARK: Live volume figures

    public static let liveVolume: @Sendable () -> Volume = {
        Volume(purgeable: purgeableBytes(), virtualMemory: swapBytes() + Measure.allocated("/private/var/vm/sleepimage"),
               timeMachineSnapshots: timeMachineSnapshots(Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 10).output))
    }

    /// Space macOS reports as available "for important usage" beyond what's plainly free.
    static func purgeableBytes() -> UInt64 {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let important = values.volumeAvailableCapacityForImportantUsage,
              let available = values.volumeAvailableCapacity else { return 0 }
        return UInt64(max(0, important - Int64(available)))
    }

    static func swapBytes() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_total
    }

    /// Counts "com.apple.TimeMachine.…" snapshots; the ones macOS makes for updates aren't counted.
    static func timeMachineSnapshots(_ output: String) -> Int {
        output.split(whereSeparator: \.isNewline).filter { $0.contains("com.apple.TimeMachine.") }.count
    }
}
