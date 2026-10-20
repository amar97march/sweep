import AppKit
import SwiftUI
import SweepMonitor

/// Keeps the Mac awake for a while, until turned off, or while an app is open.
@MainActor
@Observable
public final class KeepAwakeModel {
    public private(set) var session: KeepAwakeSession?
    /// Why the last session ended by itself, shown until the next one starts.
    public private(set) var lastEnd: KeepAwakeSession.EndReason?
    public var keepsDisplayOn: Bool {
        didSet {
            guard keepsDisplayOn != oldValue else { return }
            Preferences.set(keepsDisplayOn, forKey: "keepAwake.display")
            if let session { take(KeepAwakeSession(duration: session.duration, started: session.started, keepsDisplayOn: keepsDisplayOn)) }
        }
    }
    /// End by itself when the battery falls to `batteryFloor` percent on battery power.
    public var stopsOnLowBattery: Bool {
        didSet { Preferences.set(stopsOnLowBattery, forKey: "keepAwake.lowBattery") }
    }
    public static let batteryFloor = 20

    /// The system, replaced in tests and screenshot runs so they never hold a real power assertion.
    public struct Environment: Sendable {
        public var assertions: PowerAssertions
        public var runningBundleIDs: @MainActor () -> Set<String>
        public var battery: @Sendable () -> (percent: Int?, onBattery: Bool)

        public static let live = Environment(
            assertions: .system,
            runningBundleIDs: { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) },
            battery: {
                guard let battery = SystemMonitor.battery() else { return (nil, false) }
                return (Int((battery.charge * 100).rounded()), !battery.isPluggedIn)
            })

        public static let inert = Environment(assertions: PowerAssertions(take: { _, _ in 1 }, release: { _ in }),
                                              runningBundleIDs: { [] }, battery: { (nil, false) })
    }

    @ObservationIgnored let environment: Environment
    @ObservationIgnored private var assertionID: UInt32?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var quitObserver: NSObjectProtocol?

    /// `environment` defaults to the real system, or an inert one in tests and screenshot runs.
    public init(environment: Environment? = nil) {
        self.environment = environment ?? (Preferences.isThrowaway ? .inert : .live)
        keepsDisplayOn = Preferences.object(forKey: "keepAwake.display") as? Bool ?? true
        stopsOnLowBattery = Preferences.object(forKey: "keepAwake.lowBattery") as? Bool ?? true
        quitObserver = NotificationCenter.default.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(now: Date()) }
        }
    }

    public var isActive: Bool { session != nil }

    public func start(_ duration: KeepAwakeDuration) {
        lastEnd = nil
        take(KeepAwakeSession(duration: duration, started: Date(), keepsDisplayOn: keepsDisplayOn))
        guard session != nil else { return }
        watcher?.cancel()
        // Timers don't run while the Mac sleeps, so check often rather than sleeping until the end time.
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.check(now: Date())
            }
        }
    }

    public func stop() {
        watcher?.cancel()
        watcher = nil
        release()
        session = nil
    }

    /// Ends the session if its time is up, its app quit, or the battery is low.
    func check(now: Date) {
        guard let session else { return }
        let battery = environment.battery()
        if let reason = session.endReason(now: now, runningBundleIDs: environment.runningBundleIDs(), batteryPercent: battery.percent,
                                          onBattery: battery.onBattery, batteryFloor: stopsOnLowBattery ? Self.batteryFloor : nil) {
            stop()
            lastEnd = reason
        }
    }

    private func take(_ next: KeepAwakeSession) {
        release()
        let reason = "Keep Awake in Sweep (" + next.duration.title.lowercased() + ")"
        assertionID = environment.assertions.take(next.keepsDisplayOn, reason)
        session = assertionID == nil ? nil : next
    }

    private func release() {
        if let assertionID { environment.assertions.release(assertionID) }
        assertionID = nil
    }

    /// "Awake until 3:45 PM", "Until you turn it off", "While Xcode is open".
    public func statusText(now: Date = Date()) -> String {
        guard let session else {
            switch lastEnd {
            case .timeUp?: return "Ended: time was up"
            case .appQuit(let name)?: return "Ended when \(name) quit"
            case .batteryLow(let floor)?: return "Ended: battery fell to \(floor)%"
            case nil: return "Your Mac sleeps as usual"
            }
        }
        if let end = session.endDate {
            let minutes = max(1, Int(end.timeIntervalSince(now) / 60))
            let left = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min left" : "\(minutes) min left"
            return "Until \(end.formatted(date: .omitted, time: .shortened)) · \(left)"
        }
        if case .whileRunning(_, let name) = session.duration { return "While \(name) is open" }
        return "Until you turn it off"
    }

    /// Open apps that can be followed ("while this app is open").
    public static func followableApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }
}

/// Keep Awake controls for the menu bar panel.
struct KeepAwakeSection: View {
    @Bindable var model: KeepAwakeModel
    private let accent = [Color(hex: 0xFFB830), Color(hex: 0xFF7A45)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: model.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: accent, startPoint: .topLeading, endPoint: .bottomTrailing)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep Awake").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    Text(model.statusText()).font(.system(size: 11)).foregroundStyle(Palette.textSecondary).lineLimit(1)
                }
                Spacer()
                Toggle("Keep Awake", isOn: Binding(get: { model.isActive }, set: { $0 ? model.start(.indefinitely) : model.stop() }))
                    .toggleStyle(GlowSwitchStyle(theme: ModuleTheme(title: "", tagline: "", symbol: "", colors: accent + [Color(hex: 0xFFE66B)])))
                    .labelsHidden()
            }
            HStack(spacing: 5) {
                ForEach(KeepAwakeDuration.presets, id: \.self) { duration in
                    chip(duration)
                }
                Menu {
                    let apps = KeepAwakeModel.followableApps()
                    if apps.isEmpty { Text("No open apps") }
                    ForEach(apps, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "App") {
                            model.start(.whileRunning(bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? "the app"))
                        }
                    }
                } label: {
                    Image(systemName: "app.badge.clock").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 24)
                .background(Capsule().fill(isFollowingApp ? AnyShapeStyle(LinearGradient(colors: accent, startPoint: .leading, endPoint: .trailing))
                                                          : AnyShapeStyle(Color.white.opacity(0.09))))
                .help("Stay awake while an app is open")
                .accessibilityLabel("Stay awake while an app is open")
            }
            HStack(spacing: 14) {
                option("Display on", isOn: $model.keepsDisplayOn)
                option("Stop at \(KeepAwakeModel.batteryFloor)% battery", isOn: $model.stopsOnLowBattery)
            }
        }
    }

    private var isFollowingApp: Bool {
        if case .whileRunning? = model.session?.duration { return true }
        return false
    }

    private func chip(_ duration: KeepAwakeDuration) -> some View {
        let selected = model.session?.duration == duration
        let label: String = {
            switch duration {
            case .indefinitely: return "∞"
            case .minutes(let minutes): return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
            case .whileRunning: return ""
            }
        }()
        return Button { model.start(duration) } label: {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(selected ? 1 : 0.85))
                .frame(minWidth: 30)
                .padding(.vertical, 4)
                .background(Capsule().fill(selected ? AnyShapeStyle(LinearGradient(colors: accent, startPoint: .leading, endPoint: .trailing))
                                                    : AnyShapeStyle(Color.white.opacity(0.09))))
        }
        .buttonStyle(PressScale())
        .focusEffectDisabled()
        .help(duration.title)
        .accessibilityLabel("Keep awake: \(duration.title)")
    }

    private func option(_ title: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn.wrappedValue ? Color(hex: 0xFFB830) : Palette.textTertiary)
                Text(title).foregroundStyle(Palette.textSecondary)
            }
            .font(.system(size: 11.5, weight: .medium))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }
}
