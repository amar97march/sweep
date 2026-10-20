import AppKit
import CoreGraphics
import Foundation
import Observation
import SweepCore
import SweepMonitor
import SweepScanners

/// Things Sweep watches over time: camera, microphone and screen recording use, background items coming and
/// going, and which apps use the battery. Runs while Sweep is open (in the menu bar after the window closes).
@MainActor
@Observable
public final class ActivityModel {
    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case sensors, background, battery, network, usage, privacy

        public var id: String { rawValue }

        var title: String {
            switch self {
            case .sensors: "Camera & Mic"
            case .background: "Background"
            case .battery: "Power"
            case .network: "Network"
            case .usage: "Usage"
            case .privacy: "Privacy"
            }
        }

        var symbol: String {
            switch self {
            case .sensors: "video.fill"
            case .background: "gearshape.2.fill"
            case .battery: "battery.75percent"
            case .network: "arrow.up.arrow.down"
            case .usage: "hourglass"
            case .privacy: "hand.raised.fill"
            }
        }
    }

    public enum EnergyRange: String, CaseIterable, Identifiable, Sendable {
        case day, week, month

        public var id: String { rawValue }
        var title: String { switch self { case .day: "24 Hours"; case .week: "7 Days"; case .month: "30 Days" } }
        var seconds: TimeInterval { switch self { case .day: 86_400; case .week: 7 * 86_400; case .month: 30 * 86_400 } }
    }

    /// Everything Activity reads from or does to the system, replaced in tests and screenshot runs.
    public struct Engine: Sendable {
        public var readSensorLog: @Sendable (Date?) -> [SensorLog.Change]?
        public var liveSensors: @Sendable () -> (microphone: Set<String>, cameraOn: Bool)
        public var listBackgroundItems: @Sendable () -> [BackgroundItem]
        public var launchdState: @Sendable (_ systemLabels: [String]) -> LaunchdState
        public var signer: @Sendable (String) -> Signer
        public var switchItem: @Sendable (WatchedItem, Bool) -> BackgroundItemSwitch.Outcome
        public var readEnergy: @Sendable () -> [ProcessEnergy]
        public var battery: @Sendable () -> (charge: Double?, onBattery: Bool, hasBattery: Bool)
        public var bootTime: @Sendable () -> Date?
        /// Each process's traffic, with the app it counts toward.
        public var readTraffic: @Sendable () -> (traffic: [ProcessTraffic], apps: [pid_t: EnergyApp]) = { ([], [:]) }
        public var isOnExpensiveNetwork: @Sendable () -> Bool = { false }
        /// Battery capacity relative to design, and cycles, when the Mac has a battery.
        public var batteryHealth: @Sendable () -> (health: Double, cycles: Int?)? = { nil }
        public var permissions: @Sendable () -> [TCCPermissions.Entry] = { [] }
        public var keyboardWatchers: @Sendable () -> [KeyboardWatcher] = { [] }
        /// The app in front now, and seconds since the last keyboard or mouse input.
        public var frontmostApp: @MainActor () -> EnergyApp? = { nil }
        public var idleSeconds: @Sendable () -> TimeInterval = { 0 }

        public static let live = Engine(
            readSensorLog: { SensorLog.read(since: $0) },
            liveSensors: { (SensorLive.microphoneUsers(), SensorLive.cameraIsOn()) },
            listBackgroundItems: { BackgroundItems.list(environment: .live(), run: Shell.quick) },
            launchdState: { LaunchdState.read(userID: getuid(), systemLabels: $0) },
            signer: { Signer.check($0) },
            switchItem: { BackgroundItemSwitch().set($0, on: $1) },
            readEnergy: { EnergyReader.read() },
            battery: {
                guard let battery = SystemMonitor.battery() else { return (nil, false, false) }
                return (battery.charge, !battery.isPluggedIn, true)
            },
            bootTime: { BootTime.current },
            readTraffic: {
                let traffic = NetworkReader.read()
                var cache: [String: EnergyApp] = [:]
                var apps: [pid_t: EnergyApp] = [:]
                for reading in traffic { apps[reading.pid] = EnergyReader.app(forPID: reading.pid, cache: &cache) }
                return (traffic, apps)
            },
            isOnExpensiveNetwork: { NetworkReader.isOnExpensiveNetwork() },
            batteryHealth: {
                guard let battery = SystemMonitor.battery(), let health = battery.health else { return nil }
                return (health, battery.cycleCount)
            },
            permissions: { TCCPermissions.allowed(home: NSHomeDirectory(), systemRoot: "") },
            keyboardWatchers: { KeyboardWatchers.read() },
            frontmostApp: { NSWorkspace.shared.frontmostApplication.map(ActivityModel.usageApp) },
            idleSeconds: {
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            })

        /// Reads and changes nothing: for tests and screenshot runs.
        public static let inert = Engine(
            readSensorLog: { _ in nil }, liveSensors: { ([], false) }, listBackgroundItems: { [] },
            launchdState: { _ in LaunchdState() }, signer: { _ in .unsigned }, switchItem: { _, _ in .failed("Preview") },
            readEnergy: { [] }, battery: { (nil, false, false) }, bootTime: { nil })
    }

    public var tab = Tab.sensors

    // Camera, microphone, screen recording
    public private(set) var sensors: SensorHistory
    public private(set) var liveMicrophone: Set<String> = []
    public private(set) var cameraOn = false
    public var sensorFilter: Sensor?
    public var notifiesSensorUse: Bool {
        didSet {
            Preferences.set(notifiesSensorUse, forKey: "activity.\(prefix)notifiesSensorUse")
            if notifiesSensorUse { Notifier.requestPermission() }
        }
    }

    // Background items
    public private(set) var backgroundItems: [WatchedItem] = []
    public private(set) var backgroundChanges: [BackgroundChange]
    public private(set) var signers: [String: Signer] = [:]
    public private(set) var launchd = LaunchdState()
    /// Items added since the user last marked the list as reviewed.
    public private(set) var unreviewed: Set<String>
    public private(set) var switching: Set<String> = []
    public private(set) var switchMessage: String?
    public private(set) var lastBackgroundCheck: Date?
    public var notifiesBackgroundChanges: Bool {
        didSet {
            Preferences.set(notifiesBackgroundChanges, forKey: "activity.\(prefix)notifiesBackgroundChanges")
            if notifiesBackgroundChanges { Notifier.requestPermission() }
        }
    }

    // Energy
    public private(set) var energy: EnergyHistory
    public private(set) var hasBattery = true
    public var energyRange = EnergyRange.day
    public var energyOnBatteryOnly = true
    public private(set) var batteryHealth: BatteryHealthLog

    // Network
    public private(set) var network: NetworkHistory
    public private(set) var onExpensiveNetwork = false
    public var networkRange = EnergyRange.day

    // App usage
    public private(set) var usage: AppUsageHistory
    public var usageRange = EnergyRange.day
    public var recordsUsage: Bool {
        didSet {
            Preferences.set(recordsUsage, forKey: "activity.\(prefix)recordsUsage")
            if !recordsUsage { usagePaused(at: Date()) }
        }
    }
    /// Use stops counting after this long without keyboard or mouse input.
    static let idleLimit: TimeInterval = 5 * 60

    // Privacy
    public private(set) var permissions: [TCCPermissions.Entry] = []
    public private(set) var keyboardWatchers: [KeyboardWatcher] = []
    public private(set) var privacyChecked: Date?

    @ObservationIgnored let engine: Engine
    /// Put in front of every file and preference name, so tests don't share saved state.
    @ObservationIgnored private let prefix: String
    @ObservationIgnored private var ledger = EnergyLedger()
    @ObservationIgnored private var trafficLedger = TrafficLedger()
    @ObservationIgnored private var recorder = UsageRecorder()
    @ObservationIgnored private var usageObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var usageSaved = Date.distantPast
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var watchers: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var pendingBackgroundCheck: Task<Void, Never>?
    @ObservationIgnored private var lastSensorImport: Date?
    @ObservationIgnored private var lastEnergySample: Date?
    @ObservationIgnored private var knownItems: [WatchedItem]?

    /// `engine` defaults to the real one, or an inert one in tests and screenshot runs.
    public init(engine: Engine? = nil, storagePrefix: String = "") {
        self.engine = engine ?? (Preferences.isThrowaway ? .inert : .live)
        prefix = storagePrefix
        sensors = Storage.load(SensorHistory.self, prefix + "sensors") ?? SensorHistory()
        energy = Storage.load(EnergyHistory.self, prefix + "energy") ?? EnergyHistory()
        network = Storage.load(NetworkHistory.self, prefix + "network") ?? NetworkHistory()
        batteryHealth = Storage.load(BatteryHealthLog.self, prefix + "battery-health") ?? BatteryHealthLog()
        usage = Storage.load(AppUsageHistory.self, prefix + "usage") ?? AppUsageHistory()
        recordsUsage = Preferences.object(forKey: "activity.\(storagePrefix)recordsUsage") as? Bool ?? true
        knownItems = Storage.load([WatchedItem].self, prefix + "background-items")
        backgroundItems = knownItems ?? []
        backgroundChanges = Storage.load([BackgroundChange].self, prefix + "background-changes") ?? []
        unreviewed = Set(Preferences.object(forKey: "activity.\(prefix)unreviewed") as? [String] ?? [])
        notifiesSensorUse = Preferences.object(forKey: "activity.\(prefix)notifiesSensorUse") as? Bool ?? false
        notifiesBackgroundChanges = Preferences.object(forKey: "activity.\(prefix)notifiesBackgroundChanges") as? Bool ?? true
    }

    // MARK: Running in the background

    /// Starts watching: every minute for new camera and microphone use, every five minutes for energy, and
    /// whenever the background item database or a LaunchAgents folder changes. Never in tests or screenshot runs.
    public func start() {
        guard timer == nil, !Preferences.isThrowaway else { return }
        watchFolders()
        watchUsage()
        timer = Task { [weak self] in
            await self?.refreshBackground(notify: true)
            while !Task.isCancelled {
                await self?.tick(now: Date())
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func tick(now: Date) async {
        usageTick(now: now)
        if now.timeIntervalSince(lastSensorImport ?? .distantPast) >= 55 { await importSensorUse(notify: true) }
        if now.timeIntervalSince(lastEnergySample ?? .distantPast) >= 295 { await sampleEnergy(at: now) }
        if now.timeIntervalSince(lastBackgroundCheck ?? .distantPast) >= 30 * 60 { await refreshBackground(notify: true) }
    }

    /// Background items change through the system's item database and the LaunchAgents/LaunchDaemons folders.
    private func watchFolders() {
        let home = NSHomeDirectory()
        let folders = ["/private/var/db/com.apple.backgroundtaskmanagement", home + "/Library/LaunchAgents",
                       "/Library/LaunchAgents", "/Library/LaunchDaemons"]
        for folder in folders {
            let descriptor = open(folder, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
                                                                   queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleBackgroundCheck() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watchers.append(source)
        }
    }

    /// Waits a few seconds for an installer to finish writing, then looks once.
    private func scheduleBackgroundCheck() {
        pendingBackgroundCheck?.cancel()
        pendingBackgroundCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await self?.refreshBackground(notify: true)
        }
    }

    /// Called when the Activity screen or the menu bar panel opens.
    public func refreshOnAppear() {
        guard !Preferences.isThrowaway else { return }
        Task {
            await importSensorUse(notify: false)
            await refreshLive()
            if tab == .background { await refreshBackground(notify: false) }
            if tab == .privacy { await refreshPrivacy() }
            if tab == .network { onExpensiveNetwork = await Task.detached { [engine] in engine.isOnExpensiveNetwork() }.value }
        }
    }

    // MARK: App usage

    /// How an app counts for usage: by bundle, named as the Dock shows it.
    nonisolated static func usageApp(_ app: NSRunningApplication) -> EnergyApp {
        EnergyApp(key: app.bundleIdentifier ?? app.bundleURL?.path ?? "app-\(app.processIdentifier)",
                  name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "App",
                  path: app.bundleURL?.path)
    }

    /// Switching apps, sleep, the screen locking and waking: the moments use starts and stops.
    private func watchUsage() {
        let workspace = NSWorkspace.shared.notificationCenter
        usageObservers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication).map(ActivityModel.usageApp)
            MainActor.assumeIsolated { self?.appActivated(app, at: Date()) }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            usageObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.usagePaused(at: Date()) }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            usageObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.usageTick(now: Date()) }
            })
        }
        usageObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.usagePaused(at: Date()) }
        })
        appActivated(engine.frontmostApp(), at: Date())
    }

    func appActivated(_ app: EnergyApp?, at date: Date) {
        guard recordsUsage else { return }
        save(recorder.activate(app, at: date), at: date)
    }

    func usagePaused(at date: Date) {
        save(recorder.stop(at: date), at: date, force: true)
    }

    /// Every minute: stop counting when nobody has touched the Mac for a while, start again when they're back,
    /// and save what's been counted so far.
    func usageTick(now: Date) {
        guard recordsUsage else { return }
        let idle = engine.idleSeconds()
        if idle >= Self.idleLimit {
            save(recorder.stop(at: now.addingTimeInterval(-idle)), at: now)
        } else if recorder.current == nil {
            save(recorder.activate(engine.frontmostApp(), at: now), at: now)
        } else {
            save(recorder.checkpoint(at: now), at: now)
        }
    }

    private func save(_ interval: (app: EnergyApp, start: Date, end: Date)?, at date: Date, force: Bool = false) {
        if let interval { usage.add(interval.app, from: interval.start, to: interval.end) }
        // A write every few minutes is plenty; quitting or sleeping saves at once.
        if force || date.timeIntervalSince(usageSaved) >= 300 {
            usageSaved = date
            Storage.save(usage, prefix + "usage")
        }
    }

    public var appUsage: [AppUsageHistory.Usage] {
        usage.usage(since: usageRange == .day ? Calendar.current.startOfDay(for: Date()) : Date().addingTimeInterval(-usageRange.seconds))
    }

    public func clearUsageHistory() {
        usage.clear()
        Storage.save(usage, prefix + "usage")
    }

    // MARK: Camera, microphone, screen recording

    func importSensorUse(notify: Bool) async {
        let started = Date()
        lastSensorImport = started
        let engine = engine
        // From the last change seen, or from the last read (a little before, in case the log was still being written):
        // with no camera use yet, this keeps each read to the last minute instead of the whole week.
        let checked = (Preferences.object(forKey: "activity.\(prefix)sensorsReadAt") as? Date)?.addingTimeInterval(-120)
        let since = [sensors.readThrough, checked].compactMap { $0 }.max()
        let (read, boot) = await Task.detached(priority: .utility) { (engine.readSensorLog(since), engine.bootTime()) }.value
        guard let changes = read else { return }
        Preferences.set(started, forKey: "activity.\(prefix)sensorsReadAt")
        let before = Set(sensors.sessions.map(\.id))
        var updated = sensors
        updated.apply(changes, bootTime: boot)
        guard updated != sensors else { return }
        sensors = updated
        Storage.save(sensors, prefix + "sensors")
        guard notify, notifiesSensorUse else { return }
        // Only uses that began in the last few minutes: an import after a long gap shouldn't replay old ones.
        for session in sensors.sessions where !before.contains(session.id) && Date().timeIntervalSince(session.start) < 300 {
            Notifier.post(title: "\(AppLookup.name(for: session.bundleID)) is using the \(session.sensor.title.lowercased())",
                          body: "Started at \(session.start.formatted(date: .omitted, time: .shortened)). See every use in Sweep → Activity.",
                          identifier: "sensor." + session.id)
        }
    }

    func refreshLive() async {
        let engine = engine
        let live = await Task.detached(priority: .userInitiated) { engine.liveSensors() }.value
        liveMicrophone = live.microphone
        cameraOn = live.cameraOn
    }

    /// Apps using a sensor right now: the indicator log's open sessions, plus microphone users seen directly.
    public var inUseNow: [SensorUse] {
        var uses = Set(sensors.inUse.map(\.use))
        for bundleID in liveMicrophone { uses.insert(SensorUse(sensor: .microphone, bundleID: bundleID)) }
        return uses.sorted { ($0.sensor.rawValue, $0.bundleID) < ($1.sensor.rawValue, $1.bundleID) }
    }

    /// Each app using something now, with what it's using.
    public var inUseByApp: [(bundleID: String, sensors: [Sensor])] {
        let uses = inUseNow
        var order: [String] = []
        var sensors: [String: [Sensor]] = [:]
        for use in uses {
            if sensors[use.bundleID] == nil { order.append(use.bundleID) }
            sensors[use.bundleID, default: []].append(use.sensor)
        }
        return order.map { ($0, Sensor.allCases.filter(sensors[$0]!.contains)) }
    }

    /// "camera", "camera and microphone", "camera, microphone and screen recording".
    nonisolated static func phrase(_ sensors: [Sensor]) -> String {
        let names = sensors.map { $0.title.lowercased() }
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    public func clearSensorHistory() {
        sensors.clear()
        Storage.save(sensors, prefix + "sensors")
    }

    // MARK: Background items

    func refreshBackground(notify: Bool) async {
        lastBackgroundCheck = Date()
        let engine = engine
        let items = await Task.detached(priority: .utility) { engine.listBackgroundItems() }.value
        // Listing can fail (sfltool missing); an empty answer must not count as "everything was removed".
        guard !items.isEmpty || knownItems == nil else { return }
        let comparison = BackgroundWatch.compare(known: knownItems, current: items, now: Date())
        knownItems = comparison.current
        backgroundItems = comparison.current
        Storage.save(comparison.current, prefix + "background-items")
        if !comparison.added.isEmpty || !comparison.removed.isEmpty {
            let now = Date()
            let changes = comparison.added.map { BackgroundChange(kind: .added, item: $0, date: now) }
                + comparison.removed.map { BackgroundChange(kind: .removed, item: $0, date: now) }
            backgroundChanges = Array((changes + backgroundChanges).prefix(50))
            Storage.save(backgroundChanges, prefix + "background-changes")
            unreviewed.formUnion(comparison.added.map(\.id))
            unreviewed.formIntersection(Set(comparison.current.map(\.id)))
            Preferences.set(Array(unreviewed), forKey: "activity.\(prefix)unreviewed")
            if notify && notifiesBackgroundChanges {
                for item in comparison.added.prefix(3) {
                    Notifier.post(title: "New background item: \(item.name)",
                                  body: "\(item.developer ?? "An unknown developer") added a \(item.kind.title.lowercased()) that runs without being opened. Review it in Sweep → Activity.",
                                  identifier: "background." + item.id)
                }
            }
        }
        await refreshDetails()
    }

    /// Signatures (once per program) and launchd state, off the main thread.
    func refreshDetails() async {
        let engine = engine
        let items = backgroundItems
        let known = signers
        let systemLabels = items.filter(\.isSystemWide).compactMap(\.label)
        let (found, state) = await Task.detached(priority: .utility) { () -> ([String: Signer], LaunchdState) in
            var found = known
            for item in items { if let path = item.signedPath, found[path] == nil { found[path] = engine.signer(path) } }
            return (found, engine.launchdState(systemLabels))
        }.value
        signers = found
        launchd = state
    }

    public func signer(for item: WatchedItem) -> Signer? { item.signedPath.flatMap { signers[$0] } }

    /// On, off, or not known (login items are switched in System Settings).
    public func isOn(_ item: WatchedItem) -> Bool {
        guard let label = item.label else { return item.enabled }
        return item.enabled && !launchd.disabled.contains(label)
    }

    public func isRunning(_ item: WatchedItem) -> Bool { item.label.map(launchd.running.contains) ?? false }

    public func markReviewed() {
        unreviewed = []
        Preferences.set([String](), forKey: "activity.\(prefix)unreviewed")
    }

    public func setItem(_ item: WatchedItem, on: Bool) {
        guard !switching.contains(item.id) else { return }
        guard item.isSwitchable else {
            _ = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
            return
        }
        switching.insert(item.id)
        switchMessage = nil
        let engine = engine
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { engine.switchItem(item, on) }.value
            switching.remove(item.id)
            switch outcome {
            case .done:
                unreviewed.remove(item.id)
                Preferences.set(Array(unreviewed), forKey: "activity.\(prefix)unreviewed")
            case .cancelled: break
            case .needsSystemSettings:
                _ = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
            case .failed(let message):
                switchMessage = "Couldn't turn \(on ? "on" : "off") \(item.name): \(message)"
            }
            await refreshDetails()
        }
    }

    // MARK: Energy

    func sampleEnergy(at date: Date) async {
        lastEnergySample = date
        let engine = engine
        let (readings, battery, traffic, expensive, health) = await Task.detached(priority: .utility) {
            (engine.readEnergy(), engine.battery(), engine.readTraffic(), engine.isOnExpensiveNetwork(), engine.batteryHealth())
        }.value
        let used = ledger.add(readings, at: date)
        hasBattery = battery.hasBattery
        energy.record(used, charge: battery.charge, onBattery: battery.onBattery, at: date)
        Storage.save(energy, prefix + "energy")

        let bytes = trafficLedger.add(traffic.traffic) { pid in traffic.apps[pid] ?? .system }
        onExpensiveNetwork = expensive
        network.record(bytes, expensive: expensive, at: date)
        Storage.save(network, prefix + "network")

        if let health {
            let before = batteryHealth.entries.count
            batteryHealth.record(health: health.health, cycles: health.cycles, at: date)
            if batteryHealth.entries.count != before { Storage.save(batteryHealth, prefix + "battery-health") }
        }
    }

    public var networkUsage: [NetworkHistory.Usage] {
        network.usage(since: Date().addingTimeInterval(-networkRange.seconds))
    }

    public func clearNetworkHistory() {
        network.clear()
        Storage.save(network, prefix + "network")
    }

    // MARK: Privacy

    /// Who can use what (from the permission databases) and who's reading keystrokes right now.
    func refreshPrivacy() async {
        let engine = engine
        let known = signers
        let (permissions, watchers, found) = await Task.detached(priority: .userInitiated) { () -> ([TCCPermissions.Entry], [KeyboardWatcher], [String: Signer]) in
            let watchers = engine.keyboardWatchers()
            var found = known
            for watcher in watchers where !watcher.isPartOfMacOS {
                let path = watcher.app.path ?? watcher.executable
                if found[path] == nil, !path.isEmpty { found[path] = engine.signer(path) }
            }
            return (engine.permissions(), watchers, found)
        }.value
        self.permissions = permissions
        keyboardWatchers = watchers
        signers = found
        privacyChecked = Date()
    }

    /// Permissions grouped by what they allow, most sensitive first.
    public var permissionsByService: [(service: String, clients: [String])] {
        let order = ["kTCCServiceSystemPolicyAllFiles", "kTCCServiceAccessibility", "kTCCServiceScreenCapture", "kTCCServiceListenEvent",
                     "kTCCServiceCamera", "kTCCServiceMicrophone", "kTCCServiceSystemPolicyAppBundles", "kTCCServiceAppleEvents"]
        let grouped = Dictionary(grouping: permissions, by: \.service).mapValues { $0.map(\.client).sorted() }
        return grouped.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
            .map { ($0, grouped[$0]!) }
    }

    public func clearEnergyHistory() {
        energy.clear()
        Storage.save(energy, prefix + "energy")
    }

    public var energyUsage: [EnergyHistory.Usage] {
        energy.usage(since: Date().addingTimeInterval(-energyRange.seconds), onBattery: energyOnBatteryOnly && hasBattery)
    }

    // MARK: Previews

    func preview(usage: AppUsageHistory) { self.usage = usage }

    func preview(network: NetworkHistory, onHotspot: Bool, batteryHealth: BatteryHealthLog, permissions: [TCCPermissions.Entry],
                 keyboardWatchers: [KeyboardWatcher], signers: [String: Signer]) {
        self.signers.merge(signers) { _, new in new }
        self.network = network
        onExpensiveNetwork = onHotspot
        self.batteryHealth = batteryHealth
        self.permissions = permissions
        self.keyboardWatchers = keyboardWatchers
        privacyChecked = Date()
    }

    func preview(sensors: SensorHistory, cameraOn: Bool = false, background: [WatchedItem], changes: [BackgroundChange],
                 unreviewed: Set<String>, signers: [String: Signer], launchd: LaunchdState, energy: EnergyHistory) {
        self.sensors = sensors
        self.cameraOn = cameraOn
        backgroundItems = background
        backgroundChanges = changes
        self.unreviewed = unreviewed
        self.signers.merge(signers) { _, new in new }
        self.launchd = launchd
        self.energy = energy
        hasBattery = true
        lastBackgroundCheck = Date().addingTimeInterval(-600)
    }
}

/// App names and icons for bundle IDs, looked up once.
@MainActor
enum AppLookup {
    private static var paths: [String: String?] = [:]
    /// Names for screenshots, where the demo apps may not be installed.
    static var previewNames: [String: String] = [:]

    static func path(for bundleID: String) -> String? {
        if let cached = paths[bundleID] { return cached }
        let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
        paths[bundleID] = path
        return path
    }

    static func name(for bundleID: String) -> String {
        if let name = previewNames[bundleID] { return name }
        if let path = path(for: bundleID) { return FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "") }
        // "com.example.Some-App" → "Some App"
        return bundleID.split(separator: ".").last.map { $0.replacingOccurrences(of: "-", with: " ") } ?? bundleID
    }

    static func icon(for bundleID: String) -> ItemIcon {
        path(for: bundleID).map(ItemIcon.file) ?? .symbol("app.dashed")
    }
}
