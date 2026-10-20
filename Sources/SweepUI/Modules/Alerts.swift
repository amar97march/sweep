import AppKit
import SwiftUI
import SweepCore
import SweepMonitor
import SweepScanners

/// Things worth a nudge as they happen: an app stuck at full CPU, an accessory about to run flat, and files left
/// behind by an app just moved to the Trash. Runs while Sweep is open; never in tests or screenshot runs.
@MainActor
@Observable
public final class AlertsModel {
    public struct Runaway: Identifiable, Equatable {
        public let app: EnergyApp
        public let usage: Double
        public let since: Date
        public var id: String { app.key }
    }

    public struct MemoryHog: Identifiable, Equatable {
        public let app: EnergyApp
        public let bytes: UInt64
        /// How much it grew over the last ten minutes, when it keeps growing.
        public let growth: UInt64
        public var id: String { app.key }
    }

    /// The system, replaced in tests and screenshot runs.
    public struct Engine: Sendable {
        public var readCPU: @Sendable () -> [ProcessCPU]
        public var readAccessories: @Sendable () -> [Accessory]
        /// The Trash to watch, or nil.
        public var trashFolder: String?
        public var trashedApps: @Sendable (String) -> [InstalledApp]
        public var leftovers: @Sendable (InstalledApp) -> ScanCategory?
        public var quit: @MainActor (EnergyApp) -> Void
        public var thermalLevel: @Sendable () -> ThermalLevel = { .nominal }
        public var memoryPressure: @Sendable () -> MemoryPressure = { .normal }
        public var totalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory

        public static let live = Engine(
            readCPU: { CPUReader.read() },
            readAccessories: { AccessoryReader.read() },
            trashFolder: NSHomeDirectory() + "/.Trash",
            trashedApps: { TrashedApps.apps(inTrash: $0) },
            leftovers: { TrashedApps.leftovers(of: $0, environment: .live()) },
            quit: { app in
                NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == app.key || $0.bundleURL?.path == app.path }
                    .forEach { $0.terminate() }
            },
            thermalLevel: { ThermalLevel(ProcessInfo.processInfo.thermalState) },
            memoryPressure: { MemoryPressure.current() })

        public static let inert = Engine(readCPU: { [] }, readAccessories: { [] }, trashFolder: nil, trashedApps: { _ in [] },
                                         leftovers: { _ in nil }, quit: { _ in })
    }

    // Settings
    public var watchesRunawayApps: Bool { didSet { save("watchesRunawayApps", watchesRunawayApps) } }
    /// Share of one core (0.8 = 80%).
    public var runawayThreshold: Double { didSet { save("runawayThreshold", runawayThreshold) } }
    public var runawayMinutes: Int { didSet { save("runawayMinutes", runawayMinutes) } }
    public var warnsAboutAccessories: Bool { didSet { save("warnsAboutAccessories", warnsAboutAccessories) } }
    public var accessoryThreshold: Int { didSet { save("accessoryThreshold", accessoryThreshold) } }
    public var offersLeftovers: Bool { didSet { save("offersLeftovers", offersLeftovers) } }
    public var warnsAboutHeat: Bool { didSet { save("warnsAboutHeat", warnsAboutHeat) } }
    public var warnsAboutMemory: Bool { didSet { save("warnsAboutMemory", warnsAboutMemory) } }

    // What's happening now
    public private(set) var runaways: [Runaway] = []
    public private(set) var memoryHogs: [MemoryHog] = []
    public private(set) var thermalLevel = ThermalLevel.nominal
    /// When the Mac slowed itself down because of heat.
    public private(set) var thermalLog: ThermalLog
    public private(set) var accessories: [Accessory] = []
    /// Files of apps just moved to the Trash, waiting to be reviewed.
    public private(set) var pendingLeftovers: [ScanCategory] = []
    public private(set) var canWatchTrash = false

    @ObservationIgnored let engine: Engine
    @ObservationIgnored private let prefix: String
    @ObservationIgnored private var detector = RunawayDetector()
    @ObservationIgnored private var memoryDetector = MemoryHogDetector()
    @ObservationIgnored private var thermalObserver: NSObjectProtocol?
    @ObservationIgnored private var accessoryAlerts = AccessoryAlerts()
    @ObservationIgnored private var lastAccessoryCheck: Date?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var trashWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var trashSeen = Set<String>()
    @ObservationIgnored private var pendingTrashCheck: Task<Void, Never>?

    /// `engine` defaults to the real one, or an inert one in tests and screenshot runs.
    public init(engine: Engine? = nil, keyPrefix: String = "alerts.") {
        self.engine = engine ?? (Preferences.isThrowaway ? .inert : .live)
        prefix = keyPrefix
        func load<T>(_ key: String, _ fallback: T) -> T { Preferences.object(forKey: keyPrefix + key) as? T ?? fallback }
        watchesRunawayApps = load("watchesRunawayApps", true)
        runawayThreshold = load("runawayThreshold", 0.8)
        runawayMinutes = load("runawayMinutes", 5)
        warnsAboutAccessories = load("warnsAboutAccessories", true)
        accessoryThreshold = load("accessoryThreshold", 20)
        offersLeftovers = load("offersLeftovers", true)
        warnsAboutHeat = load("warnsAboutHeat", true)
        warnsAboutMemory = load("warnsAboutMemory", true)
        thermalLog = Storage.load(ThermalLog.self, keyPrefix + "thermal") ?? ThermalLog()
    }

    private func save(_ key: String, _ value: Any) {
        Preferences.set(value, forKey: prefix + key)
        Notifier.requestPermission()
    }

    // MARK: Running

    public func start() {
        guard timer == nil, !Preferences.isThrowaway else { return }
        watchTrash()
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHeat(at: Date()) }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick(now: Date())
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func tick(now: Date) async {
        if watchesRunawayApps || warnsAboutMemory || warnsAboutHeat { await checkCPU(at: now) }
        checkHeat(at: now)
        if now.timeIntervalSince(lastAccessoryCheck ?? .distantPast) >= 290 { await refreshAccessories(notify: true, at: now) }
    }

    // MARK: Runaway apps

    func checkCPU(at date: Date) async {
        let engine = engine
        let (readings, pressure) = await Task.detached(priority: .utility) { (engine.readCPU(), engine.memoryPressure()) }.value
        let ownApp: Set<String> = [Bundle.main.bundleIdentifier ?? "org.sweep.Sweep"]
        let hogs = memoryDetector.add(readings, pressure: pressure, totalMemory: engine.totalMemory, ignoring: ownApp)
        memoryHogs.removeAll { !memoryDetector.flagged.contains($0.app.key) }
        if warnsAboutMemory {
            for hog in hogs {
                memoryHogs.append(MemoryHog(app: hog.app, bytes: hog.bytes, growth: hog.growth))
                Notifier.post(title: "\(hog.app.name) is using \(ByteFormat.string(hog.bytes)) of memory",
                              body: hog.growth > 0
                                  ? "It grew by \(ByteFormat.string(hog.growth)) in a few minutes, which usually means it's leaking memory. Quitting and reopening it gives the memory back."
                                  : "Your Mac is short of memory, so everything slows down. Quit it if you don't need it right now.",
                              identifier: "memory." + hog.app.key)
            }
        }
        let found = detector.add(readings, at: date, threshold: runawayThreshold, readings: runawayMinutes, ignoring: ownApp)
        guard watchesRunawayApps else { return }
        let flagged = detector.flagged
        runaways.removeAll { !flagged.contains($0.app.key) }
        for entry in found {
            runaways.append(Runaway(app: entry.app, usage: entry.usage,
                                    since: date.addingTimeInterval(-Double(runawayMinutes) * 60)))
            Notifier.post(title: "\(entry.app.name) has kept the processor busy for \(runawayMinutes) minutes",
                          body: "It's using \(Int((entry.usage * 100).rounded()))% CPU, which drains the battery and heats the Mac. If it isn't doing something for you, quit it from Sweep's menu.",
                          identifier: "runaway." + entry.app.key)
        }
    }

    public func quit(_ runaway: Runaway) {
        engine.quit(runaway.app)
        runaways.removeAll { $0.id == runaway.id }
    }

    public func dismiss(_ runaway: Runaway) { runaways.removeAll { $0.id == runaway.id } }

    public func quit(_ hog: MemoryHog) {
        engine.quit(hog.app)
        memoryHogs.removeAll { $0.id == hog.id }
    }

    // MARK: Heat

    /// Records the thermal level, and tells the user when the Mac starts slowing itself down.
    func checkHeat(at date: Date) {
        let level = engine.thermalLevel()
        thermalLevel = level
        let busiest = detector.busiest.flatMap { $0.app == .system ? nil : $0.app.name }
        let before = thermalLog
        let started = thermalLog.record(level, at: date, busiestApp: busiest)
        if thermalLog != before { Storage.save(thermalLog, prefix + "thermal") }
        guard started, warnsAboutHeat else { return }
        Notifier.post(title: "Your Mac is slowing down to cool off",
                      body: "It's running hot" + (busiest.map { ", and \($0) is using the most processor time" } ?? "")
                          + ". Quit apps you don't need, and keep the vents clear.",
                      identifier: "thermal")
    }

    public func clearThermalLog() {
        thermalLog.clear()
        Storage.save(thermalLog, prefix + "thermal")
    }

    // MARK: Accessories

    public func refreshAccessories(notify: Bool, at date: Date = Date()) async {
        lastAccessoryCheck = date
        let engine = engine
        accessories = await Task.detached(priority: .utility) { engine.readAccessories() }.value
        let low = accessoryAlerts.check(accessories, threshold: accessoryThreshold)
        guard notify, warnsAboutAccessories else { return }
        for accessory in low {
            Notifier.post(title: "\(accessory.name) battery is low",
                          body: "\(accessory.lowest ?? 0)% left. Charge it soon.", identifier: "accessory." + accessory.id)
        }
    }

    // MARK: Leftovers of trashed apps

    /// Watches the Trash folder (it can only be read with Full Disk Access).
    private func watchTrash() {
        guard let folder = engine.trashFolder else { return }
        trashSeen = Set(engine.trashedApps(folder).map(\.path))
        let descriptor = open(folder, O_EVTONLY)
        guard descriptor >= 0 else { return }
        canWatchTrash = true
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.trashChanged() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        trashWatcher = source
    }

    private func trashChanged() {
        pendingTrashCheck?.cancel()
        pendingTrashCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))  // let Finder finish moving it
            guard !Task.isCancelled else { return }
            await self?.checkTrash()
        }
    }

    func checkTrash() async {
        guard offersLeftovers, let folder = engine.trashFolder else { return }
        let engine = engine
        let seen = trashSeen
        let found = await Task.detached(priority: .utility) { () -> ([String], [ScanCategory]) in
            let apps = engine.trashedApps(folder)
            let fresh = apps.filter { !seen.contains($0.path) }
            return (apps.map(\.path), fresh.compactMap(engine.leftovers))
        }.value
        trashSeen = Set(found.0)
        for category in found.1 where !pendingLeftovers.contains(where: { $0.id == category.id && $0.title == category.title }) {
            pendingLeftovers.append(category)
            let name = category.groups.first?.title ?? "An app"
            Notifier.post(title: "\(name) is in the Trash, but \(ByteFormat.string(category.size)) of its files aren't",
                          body: "Settings, caches and support files stay behind when you drag an app to the Trash. Open Sweep to remove them too.",
                          identifier: "leftovers." + category.title)
        }
    }

    /// Hands the waiting leftovers over to be reviewed.
    public func takeLeftovers() -> [ScanCategory] {
        defer { pendingLeftovers = [] }
        return pendingLeftovers
    }

    // MARK: Previews

    func preview(runaways: [Runaway], accessories: [Accessory], leftovers: [ScanCategory]) {
        self.runaways = runaways
        self.accessories = accessories
        pendingLeftovers = leftovers
    }

    func preview(memoryHogs: [MemoryHog], thermalLevel: ThermalLevel, thermalLog: ThermalLog) {
        self.memoryHogs = memoryHogs
        self.thermalLevel = thermalLevel
        self.thermalLog = thermalLog
    }
}

// MARK: - Menu bar

/// Accessory batteries, busy apps and waiting leftovers, for the menu bar panel.
struct AlertsMenuSection: View {
    var alerts: AlertsModel
    let reviewLeftovers: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let hot = alerts.thermalLog.current {
                HStack(spacing: 8) {
                    Image(systemName: "thermometer.high").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(LinearGradient(colors: [Color(hex: 0xFFB830), Color(hex: 0xFF5E3A)], startPoint: .top, endPoint: .bottom)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Running hot: slowed down").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        Text("For \(max(1, Int(hot.duration(now: Date()) / 60))) min" + (hot.busiestApp.map { " · busiest: \($0)" } ?? ""))
                            .font(.system(size: 11)).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                    Spacer()
                }
            }
            ForEach(alerts.memoryHogs) { hog in
                HStack(spacing: 8) {
                    Image(systemName: "memorychip.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(LinearGradient(colors: [Color(hex: 0xE25CFF), Color(hex: 0xFF5E7E)], startPoint: .top, endPoint: .bottom)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hog.app.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                        Text("\(ByteFormat.string(hog.bytes)) of memory" + (hog.growth > 0 ? ", growing" : ""))
                            .font(.system(size: 11)).foregroundStyle(Palette.textSecondary).lineLimit(1)
                    }
                    Spacer()
                    if hog.app.path != nil { MenuButton(title: "Quit") { alerts.quit(hog) } }
                }
            }
            ForEach(alerts.runaways) { runaway in
                HStack(spacing: 8) {
                    Image(systemName: "flame.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(LinearGradient(colors: [Color(hex: 0xFF8A5C), Color(hex: 0xFF3D5C)], startPoint: .top, endPoint: .bottom)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(runaway.app.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                        Text("\(Int((runaway.usage * 100).rounded()))% CPU for \(Int(Date().timeIntervalSince(runaway.since) / 60)) min")
                            .font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    if runaway.app.path != nil { MenuButton(title: "Quit") { alerts.quit(runaway) } }
                }
            }
            ForEach(alerts.pendingLeftovers, id: \.title) { category in
                HStack(spacing: 8) {
                    FileIcon(icon: category.groups.first?.icon ?? .symbol("trash"), size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(category.groups.first?.title ?? "An app").font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                        Text("\(ByteFormat.string(category.size)) left behind").font(.system(size: 11)).foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    MenuButton(title: "Review", action: reviewLeftovers)
                }
            }
            if !alerts.accessories.isEmpty {
                HStack(spacing: 14) {
                    ForEach(alerts.accessories) { accessory in
                        let level = accessory.lowest ?? 0
                        HStack(spacing: 5) {
                            Image(systemName: accessory.symbol).font(.system(size: 12))
                            Text("\(level)%").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                        }
                        .foregroundStyle(level <= alerts.accessoryThreshold ? Color(hex: 0xFFB830) : .white.opacity(0.85))
                        .help(accessory.name + ": " + accessory.levels.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)%" }.joined(separator: ", "))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(accessory.name), \(level) percent")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    var isEmpty: Bool {
        alerts.runaways.isEmpty && alerts.memoryHogs.isEmpty && alerts.thermalLog.current == nil && alerts.pendingLeftovers.isEmpty
            && alerts.accessories.isEmpty
    }
}

// MARK: - Settings

/// Every notification Sweep can send, in one place.
struct AlertsSettings: View {
    @Bindable var alerts: AlertsModel
    @Bindable var activity: ActivityModel
    @Bindable var updater: UpdaterModel

    var body: some View {
        Form {
            Section("Busy apps") {
                Toggle("Tell me when an app keeps the processor busy", isOn: $alerts.watchesRunawayApps)
                Picker("Busier than", selection: $alerts.runawayThreshold) {
                    Text("50% of a core").tag(0.5)
                    Text("80% of a core").tag(0.8)
                    Text("A whole core").tag(1.0)
                    Text("Two cores").tag(2.0)
                }
                .disabled(!alerts.watchesRunawayApps)
                Picker("For at least", selection: $alerts.runawayMinutes) {
                    Text("2 minutes").tag(2)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("30 minutes").tag(30)
                }
                .disabled(!alerts.watchesRunawayApps)
                Text("A stuck app drains the battery and heats your Mac. Sweep shows it in the menu bar with a Quit button.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Tell me when an app hogs memory while the Mac is short of it", isOn: $alerts.warnsAboutMemory)
                Text("An app taking a quarter of your memory, or one that keeps growing (a leak), slows everything else down.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Heat") {
                Toggle("Tell me when the Mac slows itself down because it's hot", isOn: $alerts.warnsAboutHeat)
                Text("macOS lowers processor speed to cool off. Sweep names the busiest app at the time and keeps a history in Activity → Power.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Accessories") {
                Toggle("Warn when AirPods, a mouse or a keyboard runs low", isOn: $alerts.warnsAboutAccessories)
                Picker("At", selection: $alerts.accessoryThreshold) {
                    Text("10%").tag(10)
                    Text("20%").tag(20)
                    Text("30%").tag(30)
                }
                .disabled(!alerts.warnsAboutAccessories)
            }
            Section("Deleted apps") {
                Toggle("Offer to remove the files an app leaves behind when you trash it", isOn: $alerts.offersLeftovers)
                Text(alerts.canWatchTrash || Preferences.isThrowaway ? "Settings, caches and support files are found right after you drag an app to the Trash. Nothing is removed until you review them."
                     : "Needs Full Disk Access, which lets Sweep see the Trash.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy and updates") {
                Toggle("When an app starts using the camera, microphone or screen recording", isOn: $activity.notifiesSensorUse)
                Toggle("When a new background item is added", isOn: $activity.notifiesBackgroundChanges)
                Toggle("When app updates are available (checked daily)", isOn: $updater.checksDaily)
                Text("Drive health problems are always reported.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
