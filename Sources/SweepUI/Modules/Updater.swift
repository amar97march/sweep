import AppKit
import SwiftUI
import SweepCore
import SweepScanners

extension AppUpdate: Identifiable {
    public var id: String { bundleID + "|" + appPath }
}

/// Every app update in one list, with Update All, release notes, and apps or versions to skip.
@MainActor
@Observable
public final class UpdaterModel {
    public enum Phase: Equatable { case intro, checking, ready }

    public enum RowState: Equatable {
        case waiting, updating
        case done(String)
        case failed(String)
    }

    /// What Updater needs from the system, replaced in tests and screenshots.
    public struct Engine: Sendable {
        public var check: @Sendable () async -> [AppUpdate]
        public var install: @Sendable (AppUpdate) async -> ActionRecord.Outcome
        public var isRunning: @MainActor (AppUpdate) -> Bool
        public var relaunch: @MainActor (AppUpdate) -> Void
        public var openAppStoreUpdates: @MainActor () -> Void

        public static let live = Engine(check: {
            let running = await RunningApps.bundleIDs()
            return await UpdateChecker().check(AppCatalog.installed(in: .live(runningBundleIDs: running)))
        }, install: { update in
            var performer = ApplicationsPerformer()
            performer.quitApp = { path in await RunningApps.quit(path) }
            performer.openURL = { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } }
            // Homebrew replaces the app in place; quit it first so it isn't swapped out from under itself.
            if case .homebrew = update.source, !update.appPath.isEmpty, !(await RunningApps.quit(update.appPath)) {
                return .skipped("Quit \(update.appName) first")
            }
            return await performer.install(update).outcome
        }, isRunning: { update in
            NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == update.appPath }
        }, relaunch: { update in
            guard !update.appPath.isEmpty else { return }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: update.appPath), configuration: .init())
        }, openAppStoreUpdates: {
            _ = NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
        })

        /// Does nothing: for tests and screenshot runs.
        public static let inert = Engine(check: { [] }, install: { _ in .skipped("Preview") }, isRunning: { _ in false },
                                         relaunch: { _ in }, openAppStoreUpdates: {})
    }

    public private(set) var phase = Phase.intro
    /// Everything the last check found, ignored ones included.
    public private(set) var found: [AppUpdate] = []
    public private(set) var states: [String: RowState] = [:]
    public private(set) var lastChecked: Date?
    public private(set) var isUpdating = false
    public var ignoreList: UpdateIgnoreList {
        didSet { if ignoreList != oldValue { Preferences.set(try? JSONEncoder().encode(ignoreList), forKey: keyPrefix + "ignoreList") } }
    }
    /// Check once a day in the background and send a notification about new updates.
    public var checksDaily: Bool {
        didSet {
            Preferences.set(checksDaily, forKey: keyPrefix + "checksDaily")
            if checksDaily { Notifier.requestPermission() }
        }
    }
    @ObservationIgnored private var notified: Set<String>
    @ObservationIgnored let engine: Engine
    /// Where settings are saved; tests use their own.
    @ObservationIgnored private let keyPrefix: String

    /// `engine` defaults to the real one, or an inert one in tests and screenshot runs.
    public init(engine: Engine? = nil, keyPrefix: String = "updater.") {
        self.engine = engine ?? (Preferences.isThrowaway ? .inert : .live)
        self.keyPrefix = keyPrefix
        ignoreList = Self.savedIgnoreList(keyPrefix: keyPrefix)
        checksDaily = Preferences.object(forKey: keyPrefix + "checksDaily") as? Bool ?? true
        lastChecked = Preferences.object(forKey: keyPrefix + "lastChecked") as? Date
        notified = Set(Preferences.object(forKey: keyPrefix + "notified") as? [String] ?? [])
    }

    /// The ignore list Updater saved; Applications and Checkup hide the same updates.
    nonisolated static func savedIgnoreList(keyPrefix: String = "updater.") -> UpdateIgnoreList {
        (Preferences.object(forKey: keyPrefix + "ignoreList") as? Data).flatMap { try? JSONDecoder().decode(UpdateIgnoreList.self, from: $0) }
            ?? UpdateIgnoreList()
    }

    /// Updates to show, without the ignored ones.
    public var updates: [AppUpdate] { ignoreList.filter(found) }
    public var ignored: [AppUpdate] { found.filter(ignoreList.hides) }
    /// Updates not installed yet (or that failed and can be tried again).
    public var outstanding: [AppUpdate] {
        updates.filter { update in
            switch states[update.id] {
            case nil, .failed: true
            case .waiting, .updating, .done: false
            }
        }
    }
    public var hasChecked: Bool { lastChecked != nil && phase == .ready }

    // MARK: Checking

    public func check() {
        guard phase != .checking, !isUpdating else { return }
        phase = .checking
        Task {
            let found = await engine.check()
            show(found, checkedAt: Date())
        }
    }

    /// Shows the result of a check (also used by screenshots).
    func show(_ updates: [AppUpdate], checkedAt date: Date) {
        found = updates
        states = [:]
        lastChecked = date
        Preferences.set(date, forKey: keyPrefix + "lastChecked")
        phase = .ready
    }

    /// The daily background check: tells the user about updates they haven't heard about yet.
    func checkInBackgroundIfDue(now: Date) async {
        guard checksDaily, phase != .checking, !isUpdating,
              now.timeIntervalSince(lastChecked ?? .distantPast) >= 86_400 else { return }
        let found = await engine.check()
        show(found, checkedAt: now)
        let fresh = updates.filter { !notified.contains($0.bundleID + "@" + $0.newVersion) }
        guard !fresh.isEmpty else { return }
        notified.formUnion(fresh.map { $0.bundleID + "@" + $0.newVersion })
        Preferences.set(Array(notified), forKey: keyPrefix + "notified")
        let names = fresh.prefix(3).map(\.appName).joined(separator: ", ") + (fresh.count > 3 ? " and \(fresh.count - 3) more" : "")
        Notifier.post(title: "\(fresh.count) app \(fresh.count == 1 ? "update" : "updates") available", body: names + ". Open Sweep to update.")
    }

    // MARK: Updating

    /// Apps among `updates` that are open now and will be quit while they update.
    public func runningApps(in updates: [AppUpdate]) -> [AppUpdate] {
        updates.filter { update in
            if case .appStore = update.source { return false }
            return engine.isRunning(update)
        }
    }

    public func update(_ update: AppUpdate) { install([update]) }

    /// Installs every outstanding update, one at a time. App Store updates open the App Store's Updates page once.
    public func updateAll() { install(outstanding) }

    private func install(_ list: [AppUpdate]) {
        guard !isUpdating, !list.isEmpty else { return }
        isUpdating = true
        for update in list { states[update.id] = .waiting }
        Task {
            let appStore = list.filter { if case .appStore = $0.source { true } else { false } }
            if appStore.count > 1 {
                engine.openAppStoreUpdates()
                for update in appStore { states[update.id] = .done("Opened in the App Store") }
            }
            for update in list where !(appStore.count > 1 && appStore.contains(update)) {
                states[update.id] = .updating
                let wasRunning = runningApps(in: [update]).isEmpty == false
                let outcome = await engine.install(update)
                switch outcome {
                case .done(let message):
                    states[update.id] = .done(message)
                    if wasRunning, update.sourceIsInstalledHere { engine.relaunch(update) }
                case .skipped(let message), .failed(let message):
                    states[update.id] = .failed(message)
                }
            }
            isUpdating = false
        }
    }

    // MARK: Ignoring

    public func skipVersion(_ update: AppUpdate) { ignoreList.skippedVersions[update.bundleID] = update.newVersion }
    public func ignoreApp(_ update: AppUpdate) { ignoreList.apps.insert(update.bundleID) }

    public func stopIgnoring(_ update: AppUpdate) {
        ignoreList.apps.remove(update.bundleID)
        ignoreList.skippedVersions[update.bundleID] = nil
    }

    // MARK: Previews

    func preview(_ updates: [AppUpdate], states: [String: RowState] = [:], updating: Bool = false) {
        show(updates, checkedAt: Date().addingTimeInterval(-240))
        self.states = states
        isUpdating = updating
    }

    func previewChecking() { phase = .checking }
}

extension AppUpdate {
    /// Updates Sweep installs itself (and can reopen afterwards), as opposed to App Store ones it hands over.
    var sourceIsInstalledHere: Bool {
        if case .appStore = source { return false }
        return true
    }
}

// MARK: - Views

struct UpdaterView: View {
    @Bindable var model: UpdaterModel
    private let theme = ModuleKind.updater.theme

    var body: some View {
        ZStack {
            LiveBackground(colors: theme.colors)
            Group {
                switch model.phase {
                case .intro:
                    IntroScreen(theme: theme, buttonTitle: "Check for Updates", action: model.check) {
                        Text("Sweep checks each app's own update feed, the App Store and Homebrew. Nothing is installed until you choose.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.textTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)
                    }
                case .checking:
                    WorkScreen(theme: theme, title: "Checking for updates…",
                               update: .init(message: "Asking developers, the App Store and Homebrew"), stopTitle: nil, stop: {})
                case .ready:
                    UpdateListScreen(model: model, theme: theme)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .id(model.phase)
        }
        .animation(.spring(duration: 0.5, bounce: 0.15), value: model.phase)
    }
}

struct UpdateListScreen: View {
    @Bindable var model: UpdaterModel
    let theme: ModuleTheme
    @State private var confirmQuitting: [AppUpdate]?
    @State private var showsIgnored = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if model.updates.isEmpty {
                    upToDate
                } else {
                    VStack(spacing: 10) {
                        ForEach(model.updates) { update in
                            UpdateRow(update: update, state: model.states[update.id], theme: theme, busy: model.isUpdating,
                                      update: { start([update]) }, skip: { model.skipVersion(update) },
                                      ignore: { model.ignoreApp(update) })
                        }
                    }
                }
                if !model.ignored.isEmpty { ignoredSection }
            }
            .padding(.horizontal, 36)
            .padding(.top, 40)
            .padding(.bottom, 32)
            .frame(maxWidth: 940)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .confirmationDialog(quitTitle, isPresented: Binding(get: { confirmQuitting != nil }, set: { if !$0 { confirmQuitting = nil } }),
                            presenting: confirmQuitting) { list in
            Button(list.count == 1 ? "Quit and Update" : "Quit and Update All") { install(list) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Apps are reopened when their update is done. Save your work in them first.")
        }
    }

    private var quitTitle: String {
        let running = confirmQuitting.map { model.runningApps(in: $0) } ?? []
        let names = running.prefix(3).map(\.appName).joined(separator: ", ") + (running.count > 3 ? " and \(running.count - 3) more" : "")
        return "\(names) \(running.count == 1 ? "is" : "are") open and will be quit while updating."
    }

    /// Asks first when an update would quit an open app.
    private func start(_ list: [AppUpdate]) {
        if model.runningApps(in: list).isEmpty { install(list) } else { confirmQuitting = list }
    }

    private func install(_ list: [AppUpdate]) {
        if list.count == 1, let update = list.first { model.update(update) } else { model.updateAll() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            GradientIcon(symbol: theme.symbol, theme: theme, size: 46, glowing: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.textGradient)
                    .shadow(color: theme.glow.opacity(0.35), radius: 12)
                Text(subtitle).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 12)
            GlassButton(title: "Check Again", symbol: "arrow.clockwise", action: model.check)
                .disabled(model.isUpdating)
                .opacity(model.isUpdating ? 0.5 : 1)
            if !model.updates.isEmpty {
                PrimaryButton(title: model.isUpdating ? "Updating…" : "Update All", theme: theme,
                              disabled: model.isUpdating || model.outstanding.isEmpty, isDefaultAction: false) {
                    start(model.outstanding)
                }
                .fixedSize()
            }
        }
        .padding(.bottom, 4)
    }

    private var title: String {
        let count = model.outstanding.count
        if model.updates.isEmpty { return "Everything's up to date" }
        if model.isUpdating { return "Updating apps…" }
        if count == 0 { return "All updated" }
        return "\(count) \(count == 1 ? "update" : "updates") available"
    }

    private var subtitle: String {
        var parts: [String] = []
        if model.isUpdating {
            let finished = model.states.values.filter { if case .done = $0 { true } else if case .failed = $0 { true } else { false } }.count
            return "\(finished) of \(model.states.count) done · apps you had open reopen when they're updated"
        }
        if let date = model.lastChecked { parts.append("Checked " + date.formatted(.relative(presentation: .named))) }
        parts.append(model.checksDaily ? "checks daily" : "automatic checks off")
        return parts.joined(separator: " · ")
    }

    private var upToDate: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 26))
                .foregroundStyle(LinearGradient(colors: [Color(hex: 0x9BF56B), Color(hex: 0x14E3A1)], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 3) {
                Text("No updates for your apps right now").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text("Apps that update only inside themselves, or have no public update feed, aren't listed.")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            dailyToggle
        }
        .padding(18)
        .glassCard(cornerRadius: 18)
    }

    private var dailyToggle: some View {
        HStack(spacing: 8) {
            Text("Check daily").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.textSecondary)
            Toggle("Check for updates every day", isOn: $model.checksDaily)
                .toggleStyle(GlowSwitchStyle(theme: theme))
                .labelsHidden()
        }
        .fixedSize()
    }

    private var ignoredSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    withAnimation(.spring(duration: 0.35)) { showsIgnored.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(showsIgnored ? 90 : 0))
                        Text("Ignored (\(model.ignored.count))")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                }
                .buttonStyle(.plain)
                Spacer()
                if !model.updates.isEmpty { dailyToggle }
            }
            if showsIgnored {
                ForEach(model.ignored) { update in
                    HStack(spacing: 12) {
                        FileIcon(icon: .app(update.appPath), size: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(update.appName).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                            Text(model.ignoreList.apps.contains(update.bundleID) ? "All updates ignored" : "Version \(update.newVersion) skipped")
                                .font(.system(size: 11.5)).foregroundStyle(Palette.textTertiary)
                        }
                        Spacer()
                        Button("Stop Ignoring") { model.stopIgnoring(update) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.colors[2])
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassCard(cornerRadius: 14)
                }
            } else if model.updates.isEmpty {
                EmptyView()
            }
        }
        .padding(.top, 6)
    }
}

struct UpdateRow: View {
    let update: AppUpdate
    let state: UpdaterModel.RowState?
    let theme: ModuleTheme
    let busy: Bool
    let update_: () -> Void
    let skip: () -> Void
    let ignore: () -> Void
    @State private var showsNotes = false

    init(update: AppUpdate, state: UpdaterModel.RowState?, theme: ModuleTheme, busy: Bool,
         update action: @escaping () -> Void, skip: @escaping () -> Void, ignore: @escaping () -> Void) {
        self.update = update
        self.state = state
        self.theme = theme
        self.busy = busy
        self.update_ = action
        self.skip = skip
        self.ignore = ignore
    }

    private var notes: String? {
        update.releaseNotes.map(ReleaseNotes.plainText).flatMap { $0.isEmpty ? nil : $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                FileIcon(icon: .app(update.appPath, fallback: "shippingbox.fill"), size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(update.appName).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        SourceChip(title: update.sourceName, theme: theme)
                    }
                    HStack(spacing: 6) {
                        Text(update.installedVersion).foregroundStyle(Palette.textTertiary)
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.textTertiary)
                        Text(update.newVersion).foregroundStyle(theme.colors[2])
                        if notes != nil || update.releaseNotesURL != nil {
                            Button {
                                withAnimation(.spring(duration: 0.35)) { showsNotes.toggle() }
                            } label: {
                                Text(showsNotes ? "Hide notes" : "What's new").underline()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.leading, 6)
                        }
                    }
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                }
                Spacer(minLength: 8)
                trailing
            }
            if showsNotes {
                VStack(alignment: .leading, spacing: 8) {
                    if let notes {
                        ScrollView {
                            Text(notes)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(0.82))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 180)
                    }
                    if let link = update.releaseNotesURL {
                        Link(destination: link) {
                            Label("Full release notes", systemImage: "arrow.up.forward.square")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.colors[2])
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.18)))
                .padding(.leading, 52)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassCard(cornerRadius: 18)
    }

    @ViewBuilder private var trailing: some View {
        switch state {
        case .updating?:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Updating…").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.textSecondary)
            }
        case .waiting?:
            Text("Waiting").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.textTertiary)
        case .done(let message)?:
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color(hex: 0x9BF56B))
                .lineLimit(1)
        case .failed(let message)?:
            HStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(hex: 0xFFB830))
                    .lineLimit(2)
                    .frame(maxWidth: 220, alignment: .trailing)
                    .help(message)
                updateButton(title: "Retry")
            }
        case nil:
            HStack(spacing: 8) {
                updateButton(title: buttonTitle)
                Menu {
                    Button("Skip This Version", action: skip)
                    Button("Ignore \(update.appName)", action: ignore)
                    if !update.appPath.isEmpty {
                        Divider()
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: update.appPath)])
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More options for \(update.appName)")
            }
        }
    }

    private var buttonTitle: String {
        if case .appStore = update.source { return "Open App Store" }
        return "Update"
    }

    private func updateButton(title: String) -> some View {
        Button(action: update_) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Capsule().fill(theme.buttonGradient))
                .overlay(Capsule().strokeBorder((Color.white.opacity(0.35)).edge, lineWidth: 1))
                .shadow(color: theme.glow.opacity(0.45), radius: 8)
        }
        .buttonStyle(PressScale())
        .focusEffectDisabled()
        .disabled(busy)
        .opacity(busy ? 0.45 : 1)
        .fixedSize()
    }
}

struct SourceChip: View {
    let title: String
    let theme: ModuleTheme

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(.white.opacity(0.1)))
            .overlay(Capsule().strokeBorder((theme.colors[0].opacity(0.55)).edge, lineWidth: 1))
            .fixedSize()
    }
}
