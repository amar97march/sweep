import SwiftUI
import SweepCore
import SweepMonitor

/// Live vitals and the health score with what to do next.
@MainActor
@Observable
public final class AssistantModel {
    public private(set) var snapshot: SystemSnapshot?
    public private(set) var report: HealthReport?
    /// Recent samples for the sparklines, oldest first.
    public private(set) var cpuHistory: [Double] = []
    public private(set) var memoryHistory: [Double] = []
    public private(set) var networkHistory: [Double] = []
    /// The charge limit set in System Settings → Battery, on Macs with a battery.
    public private(set) var chargeLimit: ChargeLimit.State?
    /// What the drives report about their own health.
    public private(set) var drives: [DriveHealth] = []
    public private(set) var driveWrites: DriveWriteLog
    @ObservationIgnored private var drivesRead: Date?
    @ObservationIgnored private let monitor = SystemMonitor()
    @ObservationIgnored weak var state: AppState?
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// Who is showing live readings (the Assistant screen, the menu bar panel). Sampling runs only while
    /// someone is, so closing the menu bar panel doesn't leave it running in the background.
    @ObservationIgnored private var viewers = Set<String>()

    public init() {
        driveWrites = Storage.load(DriveWriteLog.self, "drive-writes") ?? DriveWriteLog()
    }

    var isSampling: Bool { timer != nil }

    /// Reads drive health at most every ten minutes (it's quick, and only changes slowly). Records the total written
    /// once a day, and sends a notification when a drive gets worse.
    func refreshDrivesIfDue(now: Date = Date()) async {
        guard now.timeIntervalSince(drivesRead ?? .distantPast) >= 600 else { return }
        drivesRead = now
        let found = await Task.detached(priority: .utility) { DriveHealthReader.read() }.value
        drives = found
        for drive in found {
            driveWrites.record(drive, at: now)
            let key = "drive.status." + drive.id
            let previous = (Preferences.object(forKey: key) as? String).flatMap(DriveHealth.Status.init(rawValue:)) ?? .good
            if drive.status > previous, let problem = drive.problems.first {
                Notifier.post(title: drive.status == .failing ? "Back up your Mac now" : "Your drive needs attention",
                              body: "\(drive.name): \(problem.text)", identifier: key)
            }
            Preferences.set(drive.status.rawValue, forKey: key)
        }
        Storage.save(driveWrites, "drive-writes")
        if let snapshot { report = HealthScore.evaluate(inputs(snapshot)) }
    }

    func previewDrives(_ drives: [DriveHealth]) {
        self.drives = drives
        drivesRead = Date()
    }

    public func start(for viewer: String = "assistant", interval: Duration = .seconds(2)) {
        viewers.insert(viewer)
        Task { await refreshDrivesIfDue() }
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleInBackground()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop(for viewer: String = "assistant") {
        viewers.remove(viewer)
        guard viewers.isEmpty else { return }
        timer?.cancel()
        timer = nil
    }

    /// Takes a reading off the main thread (IOKit, volume capacity and the charge-limit file can be slow).
    private func sampleInBackground() async {
        let monitor = monitor
        let (snapshot, limit) = await Task.detached(priority: .utility) {
            let snapshot = monitor.sample()
            return (snapshot, snapshot.battery == nil ? nil : ChargeLimit.current())
        }.value
        guard !Task.isCancelled else { return }
        apply(snapshot, chargeLimit: limit)
    }

    public func refresh() {
        let snapshot = monitor.sample()
        apply(snapshot, chargeLimit: snapshot.battery == nil ? nil : ChargeLimit.current())
    }

    private func apply(_ snapshot: SystemSnapshot, chargeLimit: ChargeLimit.State?) {
        self.snapshot = snapshot
        func push(_ value: Double, into history: inout [Double]) {
            history.append(value)
            if history.count > 40 { history.removeFirst(history.count - 40) }
        }
        if let cpu = snapshot.cpuUsage { push(cpu, into: &cpuHistory) }
        push(snapshot.memory.usedFraction, into: &memoryHistory)
        if let network = snapshot.network {
            // Log scale so a burst doesn't flatten everything else; 100 MB/s fills the chart.
            let rate = network.bytesInPerSecond + network.bytesOutPerSecond
            push(min(1, log10(max(rate, 1)) / 8), into: &networkHistory)
        }
        report = HealthScore.evaluate(inputs(snapshot))
        self.chargeLimit = chargeLimit
    }

    func inputs(_ snapshot: SystemSnapshot) -> HealthInputs {
        func found(_ kind: ModuleKind, category: String? = nil) -> (count: Int, bytes: UInt64)? {
            guard let model = state?.catalog(for: kind), [.results, .review, .done].contains(model.phase) else { return nil }
            let categories = model.categories.filter { category == nil || $0.id == category }
            return (categories.reduce(0) { $0 + $1.itemCount }, categories.reduce(0) { $0 + $1.size })
        }
        return HealthInputs(snapshot: snapshot, junkBytes: found(.cleanup)?.bytes,
                            threats: found(.protection, category: "threats")?.count,
                            updates: found(.applications, category: "updates")?.count,
                            daysSinceCleanup: ScanHistory.daysSince(.cleanup),
                            daysSinceProtectionScan: ScanHistory.daysSince(.protection),
                            hasFullDiskAccess: state?.hasFullDiskAccess ?? PrivacyAccess.hasFullDiskAccess,
                            drives: drives,
                            securityProblems: state?.security.problems.filter { $0.status == .problem }.map(\.title) ?? [],
                            intelOnlyApps: found(.applications, category: "intelApps")?.count)
    }
}

/// When each module last finished a scan (kept between launches).
enum ScanHistory {
    static func record(_ kind: ModuleKind) {
        Preferences.set(Date(), forKey: "lastScan." + kind.rawValue)
    }

    static func daysSince(_ kind: ModuleKind) -> Double? {
        (Preferences.object(forKey: "lastScan." + kind.rawValue) as? Date).map { Date().timeIntervalSince($0) / 86_400 }
    }
}

struct AssistantView: View {
    var model: AssistantModel
    var state: AppState
    private let theme = ModuleKind.assistant.theme

    var body: some View {
        ZStack {
            LiveBackground(colors: theme.colors)
            ScrollView {
                VStack(spacing: 26) {
                    if let report = model.report, let snapshot = model.snapshot {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .center, spacing: 36) {
                                score(report)
                                VitalsGrid(snapshot: snapshot, model: model)
                            }
                            VStack(spacing: 22) {
                                score(report, size: 200)
                                VitalsGrid(snapshot: snapshot, model: model)
                            }
                        }
                        .padding(.top, 20)
                        if let battery = snapshot.battery, let limit = model.chargeLimit {
                            BatteryCareCard(battery: battery, limit: limit)
                        }
                        let usage = state.activity.energy.usage(since: Date().addingTimeInterval(-86_400), onBattery: snapshot.battery != nil)
                        if !usage.isEmpty {
                            BatteryUseCard(usage: usage) {
                                state.activity.tab = .battery
                                state.selection = .activity
                            }
                        }
                        ForEach(model.drives) { drive in
                            DriveHealthCard(drive: drive, writtenPerDay: model.driveWrites.writtenPerDay(drive))
                            if drive.isInternal { DriveSpeedRow(model: state.security) }
                        }
                        if !state.security.checks.isEmpty { SecurityChecklistCard(model: state.security) }
                        RecommendationList(recommendations: report.recommendations) { module in
                            if let module, let kind = ModuleKind(rawValue: module) { state.selection = kind }
                        }
                    } else {
                        ProgressRing(theme: theme, fraction: nil, size: 120).padding(.top, 120)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 44)
                .padding(.bottom, 32)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
        .onAppear {
            model.start()
            Task { await state.security.refreshIfDue() }
        }
        .onDisappear { model.stop() }
    }

    private func score(_ report: HealthReport, size: CGFloat = 230) -> some View {
        VStack(spacing: 14) {
            ScoreRing(score: report.score, level: report.level, theme: theme, size: size)
            Text(headline(report.level))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(width: 240)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headline(_ level: HealthReport.Level) -> String {
        switch level {
        case .excellent: "Your Mac is in excellent shape."
        case .good: "Your Mac is doing well. A few things could be better."
        case .fair: "A little care will help your Mac."
        case .attention: "Your Mac needs some attention."
        case .critical: "Your Mac needs care now."
        }
    }
}

extension HealthReport.Level {
    /// Two-stop colour for the score: green when healthy through amber to red.
    var colors: [Color] {
        switch self {
        case .excellent: [Color(hex: 0x14E3A1), Color(hex: 0x9BF56B)]
        case .good: [Color(hex: 0x33E0FF), Color(hex: 0x14E3A1)]
        case .fair: [Color(hex: 0xFFB830), Color(hex: 0xFFE66B)]
        case .attention: [Color(hex: 0xFF5E3A), Color(hex: 0xFFB830)]
        case .critical: [Color(hex: 0xFF3D5A), Color(hex: 0xFF8A5C)]
        }
    }
}

struct ScoreRing: View {
    let score: Int
    let level: HealthReport.Level
    let theme: ModuleTheme
    var size: CGFloat = 230
    @State private var shown = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let colors = level.colors
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [colors[0].opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: size * 0.75))
                    .frame(width: size * 1.3, height: size * 1.3)
                    .blur(radius: 12)
                    .allowsHitTesting(false)
                    .scaleEffect(1 + 0.03 * sin(t * 1.4))
                // Tick marks
                ForEach(0..<60, id: \.self) { tick in
                    Capsule()
                        .fill(.white.opacity(Double(tick) / 60 < shown ? 0.5 : 0.12))
                        .frame(width: 2, height: tick.isMultiple(of: 5) ? 9 : 5)
                        .offset(y: -size / 2 - 14)
                        .rotationEffect(.degrees(Double(tick) * 6))
                }
                Circle().stroke(.white.opacity(0.08), lineWidth: 18)
                    .frame(width: size, height: size)
                Circle()
                    .trim(from: 0, to: shown)
                    .stroke(AngularGradient(colors: [colors[0].opacity(0.5), colors[0], colors[1]], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(360 * max(shown, 0.01))),
                            style: StrokeStyle(lineWidth: 18, lineCap: .round))
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: colors[0].opacity(0.8), radius: 14)
                // Spark riding the end of the arc
                Circle()
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .shadow(color: colors[1], radius: 8)
                    .offset(y: -size / 2)
                    .rotationEffect(.degrees(360 * shown))
                    .opacity(shown > 0.02 ? 1 : 0)
                VStack(spacing: 0) {
                    Text("\(score)")
                        .font(.system(size: size * 0.3, weight: .heavy, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [.white, colors[1].mix(with: .white, by: 0.4)], startPoint: .top, endPoint: .bottom))
                        .contentTransition(.numericText(value: Double(score)))
                    Text(level.rawValue.uppercased())
                        .font(.system(size: 13, weight: .heavy)).tracking(2)
                        .foregroundStyle(colors[1])
                }
            }
            .frame(width: size, height: size)
        }
        .frame(width: size + 40, height: size + 40)
        .fixedSize()
        .onAppear { withAnimation(.easeOut(duration: 1.4)) { shown = Double(score) / 100 } }
        .onChange(of: score) { _, new in withAnimation(.smooth) { shown = Double(new) / 100 } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mac health \(score) out of 100, \(level.rawValue)")
    }
}

struct VitalsGrid: View {
    let snapshot: SystemSnapshot
    var model: AssistantModel?

    var body: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                Vital(symbol: "cpu", title: "CPU", value: snapshot.cpuUsage.map { "\(Int($0 * 100))%" } ?? "…",
                      fraction: snapshot.cpuUsage ?? 0, colors: [Color(hex: 0x33E0FF), Color(hex: 0x6C5CFF)],
                      history: model?.cpuHistory ?? [])
                Vital(symbol: "memorychip", title: "Memory",
                      value: "\(ByteFormat.string(snapshot.memory.used)) of \(ByteFormat.string(snapshot.memory.total))",
                      fraction: snapshot.memory.usedFraction, colors: [Color(hex: 0xE25CFF), Color(hex: 0xFF7AB8)],
                      note: snapshot.memory.pressureLevel == 1 ? nil : "Pressure \(snapshot.memory.pressureLevel == 4 ? "high" : "elevated")",
                      history: model?.memoryHistory ?? [])
            }
            GridRow {
                Vital(symbol: "internaldrive.fill", title: "Disk", value: "\(ByteFormat.string(snapshot.disk.available)) free",
                      fraction: 1 - snapshot.disk.freeFraction, colors: [Color(hex: 0x14E3A1), Color(hex: 0x12A8D6)],
                      note: "of \(ByteFormat.string(snapshot.disk.total))")
                if let battery = snapshot.battery {
                    Vital(symbol: battery.isCharging ? "battery.100.bolt" : "battery.75", title: "Battery",
                          value: "\(Int(battery.charge * 100))%" + (battery.health.map { " · health \(Int(($0 * 100).rounded()))%" } ?? ""),
                          fraction: battery.charge, colors: [Color(hex: 0x9BF56B), Color(hex: 0x14E3A1)],
                          note: battery.cycleCount.map { "\($0) cycles" })
                } else {
                    Vital(symbol: "clock.fill", title: "Uptime", value: Self.duration(snapshot.uptime), fraction: nil,
                          colors: [Color(hex: 0xFFB830), Color(hex: 0xFF8A2A)])
                }
            }
            GridRow {
                Vital(symbol: "arrow.up.arrow.down", title: "Network",
                      value: snapshot.network.map { "↓ \(Self.rate($0.bytesInPerSecond))  ↑ \(Self.rate($0.bytesOutPerSecond))" } ?? "…",
                      fraction: nil, colors: [Color(hex: 0x5AC8FF), Color(hex: 0x4A6BFF)],
                      history: model?.networkHistory ?? [])
                if snapshot.battery != nil {
                    Vital(symbol: "clock.fill", title: "Uptime", value: Self.duration(snapshot.uptime), fraction: nil,
                          colors: [Color(hex: 0xFFB830), Color(hex: 0xFF8A2A)])
                } else {
                    Vital(symbol: "thermometer.medium", title: "Temperature", value: Self.thermal(snapshot.thermalState), fraction: nil,
                          colors: [Color(hex: 0xFF8A2A), Color(hex: 0xFF4D7A)])
                }
            }
        }
    }

    static func rate(_ bytes: Double) -> String { ByteFormat.string(UInt64(max(bytes, 0))) + "/s" }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds > 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "–"
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Very hot"
        @unknown default: "Unknown"
        }
    }
}

struct Vital: View {
    let symbol: String
    let title: String
    let value: String
    let fraction: Double?
    var colors: [Color] = [.white, .white]
    var note: String?
    var history: [Double] = []
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .shadow(color: colors[0].opacity(0.6), radius: 5)
                Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.4).foregroundStyle(Palette.textTertiary)
                Spacer()
                if let note {
                    Text(note).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.textTertiary).lineLimit(1)
                }
            }
            Text(value)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            if history.count > 1 {
                Sparkline(values: history, color: colors[0]).frame(height: 26)
            } else if let fraction {
                MeterBar(fraction: fraction, colors: fraction > 0.88 ? [Color(hex: 0xFFB830), Color(hex: 0xFF5E3A)] : colors)
                    .padding(.vertical, 10)
            } else {
                Spacer().frame(height: 26)
            }
        }
        .padding(16)
        .frame(minWidth: 220, idealWidth: 268, maxWidth: 300, minHeight: 120, maxHeight: 120, alignment: .topLeading)
        .glassCard(cornerRadius: 18, highlighted: hovering)
        .scaleEffect(hovering ? 1.02 : 1)
        .onHover { over in withAnimation(.spring(duration: 0.3)) { hovering = over } }
        .animation(.smooth, value: value)
    }
}

struct RecommendationList: View {
    let recommendations: [Recommendation]
    let open: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(recommendations.isEmpty ? "Nothing to do — your Mac is in great shape." : "Recommended for you")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                if !recommendations.isEmpty {
                    Text("\(recommendations.count)")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(ModuleKind.assistant.theme.buttonGradient))
                }
            }
            ForEach(Array(recommendations.enumerated()), id: \.element.id) { index, item in
                RecommendationRow(item: item, index: index, open: open)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.45), value: recommendations)
    }
}

struct RecommendationRow: View {
    let item: Recommendation
    let index: Int
    let open: (String?) -> Void
    @State private var hovering = false
    @State private var appeared = false

    var body: some View {
        let kind = item.module.flatMap(ModuleKind.init(rawValue:))
        let colors = Self.colors(item.severity)
        HStack(spacing: 14) {
            Image(systemName: Self.icon(item.severity))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
                .shadow(color: colors[0].opacity(0.6), radius: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(item.detail).font(.system(size: 13)).foregroundStyle(Palette.textSecondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if let kind {
                Button { open(item.module) } label: {
                    HStack(spacing: 7) {
                        GradientIcon(symbol: kind.theme.symbol, theme: kind.theme, size: 22)
                        Text("Open \(kind.theme.title)").font(.system(size: 13, weight: .semibold))
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).opacity(0.7)
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, 6).padding(.trailing, 14).padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(hovering ? 0.16 : 0.09)))
                    .overlay(Capsule().strokeBorder((kind.theme.colors[0].opacity(0.55)).edge, lineWidth: 1))
                    .fixedSize()
                }
                .buttonStyle(PressScale())
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 18, highlighted: hovering)
        .offset(y: appeared ? 0 : 24)
        .opacity(appeared ? 1 : 0)
        .onHover { over in withAnimation(.easeOut(duration: 0.15)) { hovering = over } }
        .onAppear { withAnimation(.spring(duration: 0.55).delay(0.15 + Double(index) * 0.06)) { appeared = true } }
    }

    static func icon(_ severity: Recommendation.Severity) -> String {
        switch severity {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .tip: "lightbulb.fill"
        }
    }

    static func colors(_ severity: Recommendation.Severity) -> [Color] {
        switch severity {
        case .critical: [Color(hex: 0xFF3D5A), Color(hex: 0xFF8A5C)]
        case .warning: [Color(hex: 0xFF8A2A), Color(hex: 0xFFD04A)]
        case .tip: [Color(hex: 0x8A5CFF), Color(hex: 0x4FD1FF)]
        }
    }
}

/// Compact dashboard for the menu bar, in the app's dark style whatever the system appearance.
public struct MenuBarDashboard: View {
    var state: AppState
    @Environment(\.openWindow) private var openWindow

    public init(state: AppState) { self.state = state }

    public var body: some View {
        let model = state.assistant
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                GradientIcon(symbol: "sparkles", theme: ModuleKind.checkup.theme, size: 24, glowing: true)
                Text("Sweep").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Spacer()
                if let report = model.report {
                    HStack(spacing: 6) {
                        Circle().fill(report.level.colors[0]).frame(width: 7, height: 7)
                            .shadow(color: report.level.colors[0], radius: 3)
                        Text("Health \(report.score)").font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit().foregroundStyle(.white)
                        Text(report.level.rawValue).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.textSecondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.08)))
                    .overlay(Capsule().strokeBorder((report.level.colors[0].opacity(0.5)).edge, lineWidth: 1))
                }
            }
            if let snapshot = model.snapshot {
                VStack(spacing: 12) {
                    MenuRow(symbol: "cpu", title: "CPU", value: snapshot.cpuUsage.map { "\(Int($0 * 100))%" } ?? "…",
                            fraction: snapshot.cpuUsage, colors: [Color(hex: 0x33E0FF), Color(hex: 0x6C5CFF)])
                    MenuRow(symbol: "memorychip", title: "Memory", value: ByteFormat.string(snapshot.memory.used),
                            fraction: snapshot.memory.usedFraction, colors: [Color(hex: 0xE25CFF), Color(hex: 0xFF7AB8)])
                    MenuRow(symbol: "internaldrive.fill", title: "Disk", value: "\(ByteFormat.string(snapshot.disk.available)) free",
                            fraction: 1 - snapshot.disk.freeFraction, colors: [Color(hex: 0x14E3A1), Color(hex: 0x12A8D6)])
                    if let battery = snapshot.battery {
                        let limit = model.chargeLimit.flatMap { if case .limited(let value) = $0 { value } else { nil } }
                        MenuRow(symbol: battery.isCharging ? "battery.100.bolt" : "battery.75", title: "Battery",
                                value: "\(Int(battery.charge * 100))%" + (limit.map { " · limit \($0)%" } ?? ""),
                                fraction: battery.charge, colors: [Color(hex: 0x9BF56B), Color(hex: 0x14E3A1)])
                    }
                    if let network = snapshot.network {
                        MenuRow(symbol: "arrow.up.arrow.down", title: "Network",
                                value: "↓\(VitalsGrid.rate(network.bytesInPerSecond)) ↑\(VitalsGrid.rate(network.bytesOutPerSecond))",
                                fraction: nil, colors: [Color(hex: 0x5AC8FF), Color(hex: 0x4A6BFF)])
                    }
                }
            }
            if !state.activity.inUseNow.isEmpty || state.activity.cameraOn {
                let apps = state.activity.inUseByApp
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: 0xFF5E3A)).frame(width: 8, height: 8).shadow(color: Color(hex: 0xFF5E3A), radius: 4)
                    Text(apps.isEmpty ? "A camera is on"
                         : apps.prefix(2).map { "\(AppLookup.name(for: $0.bundleID)) is using the \(ActivityModel.phrase($0.sensors))" }
                            .joined(separator: "; "))
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: 0xFF5E3A, opacity: 0.15)))
            }
            if !(state.alerts.runaways.isEmpty && state.alerts.memoryHogs.isEmpty && state.alerts.thermalLog.current == nil
                 && state.alerts.pendingLeftovers.isEmpty && state.alerts.accessories.isEmpty) {
                AlertsMenuSection(alerts: state.alerts) {
                    state.reviewTrashedLeftovers()
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            KeepAwakeSection(model: state.keepAwake)
                .padding(12)
                .glassCard(cornerRadius: 14)
            if state.updater.hasChecked, !state.updater.outstanding.isEmpty {
                let count = state.updater.outstanding.count
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.app.fill")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ModuleKind.updater.theme.gradient))
                    Text("\(count) app \(count == 1 ? "update" : "updates") available").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    Spacer()
                    MenuButton(title: "View") {
                        state.selection = .updater
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
            if let first = model.report?.recommendations.first {
                let colors = RecommendationRow.colors(first.severity)
                HStack(spacing: 10) {
                    Image(systemName: RecommendationRow.icon(first.severity))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
                        .shadow(color: colors[0].opacity(0.6), radius: 5)
                    Text(first.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .glassCard(cornerRadius: 12)
            }
            HStack {
                MenuButton(title: "Open Sweep", prominent: true) {
                    // The main window is a single Window scene: this shows it, restoring it if minimised or closed.
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                MenuButton(title: "Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(LinearGradient(colors: Palette.base, startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .onAppear {
            model.start(for: "menuBar")
            state.activity.refreshOnAppear()
            if !Preferences.isThrowaway { Task { await state.alerts.refreshAccessories(notify: false) } }
        }
        .onDisappear { model.stop(for: "menuBar") }
    }
}

struct MenuRow: View {
    let symbol: String
    let title: String
    let value: String
    let fraction: Double?
    let colors: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                Spacer()
                Text(value).font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(Palette.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            if let fraction {
                MeterBar(fraction: fraction, colors: fraction > 0.88 ? [Color(hex: 0xFFB830), Color(hex: 0xFF5E3A)] : colors, height: 4)
                    .padding(.leading, 28)
            }
        }
    }
}

/// Compact capsule button for the menu bar panel; `prominent` fills it with the Checkup gradient.
struct MenuButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(prominent ? AnyShapeStyle(ModuleKind.checkup.theme.buttonGradient)
                                                     : AnyShapeStyle(Color.white.opacity(hovering ? 0.16 : 0.09))))
                .overlay(Capsule().strokeBorder(prominent ? AnyShapeStyle((Color.white.opacity(0.4)).edge) : AnyShapeStyle(Palette.stroke),
                                                lineWidth: 1))
                .brightness(prominent && hovering ? 0.06 : 0)
        }
        .buttonStyle(PressScale())
        .focusEffectDisabled()
        .onHover { over in withAnimation(.easeOut(duration: 0.15)) { hovering = over } }
    }
}

/// Battery health and the charge limit macOS applies, with the way to change it.
struct BatteryCareCard: View {
    let battery: SystemSnapshot.Battery
    let limit: ChargeLimit.State
    private let colors = [Color(hex: 0x9BF56B), Color(hex: 0x14E3A1)]

    private var percent: Int { Int((battery.charge * 100).rounded()) }
    private var limitValue: Int? { if case .limited(let value) = limit { value } else { nil } }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 22) {
                BatteryGauge(charge: battery.charge, limit: limitValue, charging: battery.isCharging, colors: colors)
                details
                Spacer(minLength: 12)
                control(alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 18) {
                    BatteryGauge(charge: battery.charge, limit: limitValue, charging: battery.isCharging, colors: colors)
                    details
                }
                control(alignment: .leading)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 22)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("BATTERY CARE").font(.system(size: 11, weight: .bold)).tracking(1.4).foregroundStyle(Palette.textSecondary)
            Text(headline).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text(explanation).font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440, alignment: .leading)
            HStack(spacing: 8) {
                if let health = battery.health { chip("Health \(Int((health * 100).rounded()))%", symbol: "heart.fill") }
                if let cycles = battery.cycleCount {
                    chip(battery.designCycleCount.map { "\(cycles) of \($0.formatted()) cycles" } ?? "\(cycles) cycles",
                         symbol: "arrow.triangle.2.circlepath")
                }
            }
            .padding(.top, 2)
        }
        .layoutPriority(1)
    }

    private func control(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 8) {
            Text("CHARGE LIMIT").font(.system(size: 11, weight: .bold)).tracking(1.4).foregroundStyle(Palette.textSecondary)
            Text(limitValue.map { "\($0)%" } ?? (limit == .off ? "Off" : "Not available"))
                .font(.system(size: limitValue == nil ? 20 : 30, weight: .heavy, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [.white, colors[0]], startPoint: .top, endPoint: .bottom))
            MenuButton(title: buttonTitle, prominent: limit == .off) { NSWorkspace.shared.open(ChargeLimit.settingsURL) }
        }
        .fixedSize()
    }

    private func chip(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(Palette.stroke, lineWidth: 1))
            .fixedSize()
    }

    private var headline: String {
        switch (limitValue, battery.isPluggedIn, battery.isCharging) {
        case (let limit?, true, false) where percent >= limit - 2: "Holding at \(percent)%"
        case (let limit?, true, true): "Charging to \(limit)%"
        case (nil, true, true): "Charging to 100%"
        case (_, true, false): "Plugged in · \(percent)%"
        default: "On battery · \(percent)%"
        }
    }

    private var explanation: String {
        switch limit {
        case .limited(let value):
            "macOS stops charging at your \(value)% limit. Keeping the battery below full while it's plugged in slows wear."
        case .off:
            "If your Mac is plugged in most of the time, a charge limit of 80% slows battery wear. Set it in Battery settings."
        case .unavailable:
            "Charge limits arrive with macOS 26.4. Until then, Optimized Battery Charging learns your routine to reduce wear."
        }
    }

    private var buttonTitle: String {
        switch limit {
        case .limited: "Change in Settings"
        case .off: "Set a Limit…"
        case .unavailable: "Battery Settings…"
        }
    }
}

/// Ring showing the charge, with a tick where charging stops.
struct BatteryGauge: View {
    let charge: Double
    let limit: Int?
    let charging: Bool
    let colors: [Color]
    var size: CGFloat = 92

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.08), lineWidth: 9)
            Circle()
                .trim(from: 0, to: min(max(charge, 0.01), 1))
                .stroke(AngularGradient(colors: [colors[1], colors[0]], center: .center), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: colors[0].opacity(0.6), radius: 8)
            if let limit {
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: 15)
                    .offset(y: -size / 2)
                    .rotationEffect(.degrees(Double(limit) / 100 * 360))
                    .shadow(color: .black.opacity(0.4), radius: 2)
            }
            VStack(spacing: 0) {
                if charging { Image(systemName: "bolt.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(colors[0]) }
                Text("\(Int((charge * 100).rounded()))%").font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(Int((charge * 100).rounded())) percent" + (limit.map { ", charging stops at \($0) percent" } ?? ""))
    }
}
