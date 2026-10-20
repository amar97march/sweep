import Charts
import SwiftUI
import SweepCore
import SweepMonitor
import SweepScanners

struct ActivityView: View {
    @Bindable var model: ActivityModel
    var alerts: AlertsModel
    private let theme = ModuleKind.activity.theme

    var body: some View {
        ZStack {
            LiveBackground(colors: theme.colors)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    tabs
                    Group {
                        switch model.tab {
                        case .sensors: SensorActivityView(model: model, theme: theme)
                        case .background: BackgroundActivityView(model: model, theme: theme)
                        case .battery: EnergyActivityView(model: model, alerts: alerts, theme: theme)
                        case .network: NetworkActivityView(model: model, theme: theme)
                        case .usage: UsageActivityView(model: model, theme: theme)
                        case .privacy: PrivacyActivityView(model: model, theme: theme)
                        }
                    }
                    .transition(.opacity)
                    .id(model.tab)
                }
                .padding(.horizontal, 36)
                .padding(.top, 40)
                .padding(.bottom, 32)
                .frame(maxWidth: 940)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
        .animation(.easeOut(duration: 0.2), value: model.tab)
        .onAppear { model.refreshOnAppear() }
        .onChange(of: model.tab) { model.refreshOnAppear() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            GradientIcon(symbol: theme.symbol, theme: theme, size: 46, glowing: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Activity")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.textGradient)
                    .shadow(color: theme.glow.opacity(0.35), radius: 12)
                Text("What happened on your Mac while Sweep was watching. Everything stays on this Mac.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
        }
    }

    private var tabs: some View {
        HStack(spacing: 5) {
            ForEach(ActivityModel.Tab.allCases) { tab in
                let selected = model.tab == tab
                Button {
                    model.tab = tab
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.symbol).font(.system(size: 11, weight: .bold))
                        Text(tab.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if tab == .background, !model.unreviewed.isEmpty {
                            Text("\(model.unreviewed.count)")
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(Capsule().fill(Color(hex: 0xFF5E7E)))
                        }
                    }
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background {
                        if selected {
                            Capsule().fill(theme.buttonGradient.opacity(0.85))
                                .overlay(Capsule().strokeBorder((Color.white.opacity(0.35)).edge, lineWidth: 1))
                                .shadow(color: theme.glow.opacity(0.45), radius: 8)
                        } else {
                            Capsule().fill(.white.opacity(0.06))
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressScale())
                .focusEffectDisabled()
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }
}

/// A small titled glass panel.
struct ActivityPanel<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Palette.textTertiary)
                Spacer()
                trailing
            }
            content
        }
        .padding(18)
        .glassCard(cornerRadius: 20)
    }
}

struct ToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool
    let theme: ModuleTheme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn).toggleStyle(GlowSwitchStyle(theme: theme)).labelsHidden()
        }
    }
}

// MARK: - Camera, microphone, screen recording

struct SensorActivityView: View {
    @Bindable var model: ActivityModel
    let theme: ModuleTheme

    private var weekAgo: Date { Date().addingTimeInterval(-7 * 86_400) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.inUseNow.isEmpty || model.cameraOn { liveBanner }
            HStack(spacing: 12) {
                ForEach(Sensor.allCases) { sensor in summaryTile(sensor) }
            }
            if model.sensors.sessions.isEmpty {
                empty
            } else {
                appsPanel
                timeline
            }
            settings
        }
    }

    private var liveBanner: some View {
        let apps = model.inUseByApp
        return HStack(spacing: 12) {
            Circle().fill(Color(hex: 0xFF5E3A)).frame(width: 10, height: 10)
                .shadow(color: Color(hex: 0xFF5E3A), radius: 6)
            Text(apps.isEmpty ? "A camera is on"
                 : apps.map { "\(AppLookup.name(for: $0.bundleID)) is using the \(ActivityModel.phrase($0.sensors))" }.joined(separator: " · "))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Text("Now").font(.system(size: 12, weight: .bold)).foregroundStyle(Color(hex: 0xFF8A5C))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: 0xFF5E3A, opacity: 0.16)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder((Color(hex: 0xFF5E3A, opacity: 0.5)).edge))
    }

    private func summaryTile(_ sensor: Sensor) -> some View {
        let recent = model.sensors.sessions.filter { $0.sensor == sensor && ($0.end ?? Date()) >= weekAgo }
        let apps = Set(recent.map(\.bundleID)).count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: sensor.symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Self.color(sensor).gradient))
                Text(sensor.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            }
            Text(recent.isEmpty ? "Not used" : "\(recent.count) \(recent.count == 1 ? "time" : "times")")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textGradient)
            Text(recent.isEmpty ? "in the last 7 days" : "by \(apps) \(apps == 1 ? "app" : "apps") in the last 7 days")
                .font(.system(size: 11.5)).foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: 18)
        .accessibilityElement(children: .combine)
    }

    private var empty: some View {
        HStack(spacing: 14) {
            Image(systemName: "eye.slash").font(.system(size: 24)).foregroundStyle(Palette.textSecondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("No camera, microphone or screen recording use yet").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text("Each time an app turns on the privacy indicator in the menu bar, it's listed here with the time and how long.")
                    .font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 18)
    }

    private var appsPanel: some View {
        let summaries = model.sensors.summary(since: Date().addingTimeInterval(-30 * 86_400))
        let apps = Dictionary(grouping: summaries, by: \.use.bundleID)
            .map { bundleID, parts in (bundleID: bundleID, parts: parts.sorted { $0.use.sensor.rawValue < $1.use.sensor.rawValue }) }
            .sorted { first, second in
                let a = (first.parts.contains(where: \.inUse) ? 1 : 0, first.parts.map(\.lastUsed).max() ?? .distantPast)
                let b = (second.parts.contains(where: \.inUse) ? 1 : 0, second.parts.map(\.lastUsed).max() ?? .distantPast)
                return a > b
            }
        return ActivityPanel(title: "Apps · last 30 days") {
            VStack(spacing: 2) {
                ForEach(apps, id: \.bundleID) { app in
                    HStack(spacing: 12) {
                        FileIcon(icon: AppLookup.icon(for: app.bundleID), size: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(AppLookup.name(for: app.bundleID)).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                            HStack(spacing: 12) {
                                ForEach(app.parts) { part in
                                    HStack(spacing: 4) {
                                        Image(systemName: part.use.sensor.symbol)
                                            .font(.system(size: 9.5, weight: .bold)).foregroundStyle(Self.color(part.use.sensor))
                                        Text("\(part.sessions)× · \(Self.duration(part.duration))")
                                    }
                                    .help("\(part.use.sensor.title): \(part.sessions) \(part.sessions == 1 ? "time" : "times"), \(Self.duration(part.duration)) in all")
                                }
                            }
                            .font(.system(size: 11.5)).foregroundStyle(Palette.textSecondary)
                        }
                        Spacer()
                        if app.parts.contains(where: \.inUse) {
                            Text("In use").font(.system(size: 11.5, weight: .bold)).foregroundStyle(Color(hex: 0xFF8A5C))
                        } else if let last = app.parts.map(\.lastUsed).max() {
                            Text(last.formatted(.relative(presentation: .named)))
                                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.textTertiary)
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var timeline: some View {
        let sessions = model.sensors.sessions.reversed().filter { model.sensorFilter == nil || $0.sensor == model.sensorFilter }
        let days = Dictionary(grouping: sessions.prefix(200)) { Calendar.current.startOfDay(for: $0.start) }
        let filter = Picker("Show", selection: $model.sensorFilter) {
            Text("All").tag(Sensor?.none)
            ForEach(Sensor.allCases) { Text($0.title).tag(Sensor?.some($0)) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        return ActivityPanel(title: "Timeline", trailing: AnyView(filter)) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(days.keys.sorted(by: >), id: \.self) { day in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.textSecondary)
                        ForEach(days[day]!) { session in
                            HStack(spacing: 10) {
                                Text(Self.timeRange(session))
                                    .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                                    .foregroundStyle(Palette.textTertiary)
                                    .frame(width: 118, alignment: .leading)
                                Image(systemName: session.sensor.symbol)
                                    .font(.system(size: 10, weight: .bold)).foregroundStyle(Self.color(session.sensor))
                                    .frame(width: 16)
                                FileIcon(icon: AppLookup.icon(for: session.bundleID), size: 18)
                                Text(AppLookup.name(for: session.bundleID)).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                                Text(session.sensor.title.lowercased()).font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                                Spacer()
                                Text(session.end == nil ? "in use" : Self.duration(session.duration(now: Date())))
                                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                                    .foregroundStyle(session.end == nil ? Color(hex: 0xFF8A5C) : Palette.textSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            ToggleRow(title: "Notify me when an app starts using them",
                      detail: "Within a minute of the camera, microphone or screen recording turning on.",
                      isOn: $model.notifiesSensorUse, theme: theme)
            HStack {
                Text("Read from the privacy indicator log macOS keeps for a few days; Sweep keeps 90 days while it runs.")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if !model.sensors.sessions.isEmpty {
                    Button("Clear History", role: .destructive, action: model.clearSensorHistory)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xFF8A8A))
                }
            }
        }
        .padding(18)
        .glassCard(cornerRadius: 20)
    }

    static func color(_ sensor: Sensor) -> Color {
        switch sensor {
        case .camera: Color(hex: 0x3DDC84)
        case .microphone: Color(hex: 0xFFB830)
        case .screen: Color(hex: 0x8A7CFF)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(max(1, Int(seconds.rounded()))) s" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }

    static func timeRange(_ session: SensorSession) -> String {
        let start = session.start.formatted(date: .omitted, time: .shortened)
        guard let end = session.end else { return start + " – now" }
        return start + " – " + end.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Background items

struct BackgroundActivityView: View {
    @Bindable var model: ActivityModel
    let theme: ModuleTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            summary
            if let message = model.switchMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color(hex: 0xFFB830))
            }
            let fresh = model.backgroundItems.filter { model.unreviewed.contains($0.id) }
            if !fresh.isEmpty {
                ActivityPanel(title: "New since you last looked",
                              trailing: AnyView(Button("Mark as Reviewed", action: model.markReviewed)
                                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.colors[2]))) {
                    VStack(spacing: 8) { ForEach(fresh) { row($0, isNew: true) } }
                }
            }
            let rest = model.backgroundItems.filter { !model.unreviewed.contains($0.id) }
                .sorted { ($0.kind.rawValue, $0.name.lowercased()) < ($1.kind.rawValue, $1.name.lowercased()) }
            if !rest.isEmpty {
                ActivityPanel(title: "Everything that starts by itself") {
                    VStack(spacing: 8) { ForEach(rest) { row($0, isNew: false) } }
                }
            }
            if !model.backgroundChanges.isEmpty { changes }
        }
    }

    private var summary: some View {
        let untrusted = model.backgroundItems.filter { item in model.signer(for: item).map { !$0.isTrusted } ?? false }.count
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(model.backgroundItems.count)")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.textGradient)
                Text("background \(model.backgroundItems.count == 1 ? "item" : "items") watched")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.textSecondary)
                Spacer()
                if untrusted > 0 {
                    Label("\(untrusted) not from a known developer", systemImage: "exclamationmark.shield.fill")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(hex: 0xFFB830))
                }
            }
            ToggleRow(title: "Tell me when something new is added",
                      detail: "Sweep checks whenever the list of login items or launch agents changes.",
                      isOn: $model.notifiesBackgroundChanges, theme: theme)
        }
        .padding(18)
        .glassCard(cornerRadius: 20)
    }

    private func row(_ item: WatchedItem, isNew: Bool) -> some View {
        BackgroundItemRow(item: item, signer: model.signer(for: item), isOn: model.isOn(item), isRunning: model.isRunning(item),
                          isNew: isNew, busy: model.switching.contains(item.id), theme: theme) { on in
            model.setItem(item, on: on)
        }
    }

    private var changes: some View {
        ActivityPanel(title: "Recent changes") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.backgroundChanges.prefix(12)) { change in
                    HStack(spacing: 10) {
                        Image(systemName: change.kind == .added ? "plus.circle.fill" : "minus.circle.fill")
                            .foregroundStyle(change.kind == .added ? Color(hex: 0x3DDC84) : Color(hex: 0xFF8A8A))
                        Text(change.item.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                        Text(change.kind == .added ? "added" : "removed").font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                        Text(change.item.developer ?? "").font(.system(size: 12)).foregroundStyle(Palette.textTertiary).lineLimit(1)
                        Spacer()
                        Text(change.date.formatted(.relative(presentation: .named)))
                            .font(.system(size: 11.5)).foregroundStyle(Palette.textTertiary)
                    }
                }
            }
        }
    }
}

struct BackgroundItemRow: View {
    let item: WatchedItem
    let signer: Signer?
    let isOn: Bool
    let isRunning: Bool
    let isNew: Bool
    let busy: Bool
    let theme: ModuleTheme
    let set: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FileIcon(icon: .app(item.bundlePath, fallback: item.kind == .daemon ? "gearshape.2.fill" : "gearshape.fill"), size: 32)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    if isNew { Chip(text: "New", color: Color(hex: 0xFF5E7E)) }
                    Chip(text: item.kind.title, color: theme.colors[0])
                    if item.isSystemWide { Chip(text: "All users", color: Color(hex: 0x8A7CFF)) }
                }
                Text(item.developer ?? "Unknown developer").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.textSecondary)
                if let signer {
                    Label(signer.summary, systemImage: signer.isTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(signer.isTrusted ? Color(hex: 0x9BF56B) : Color(hex: 0xFFB830))
                }
                if let location = item.plist ?? item.bundlePath {
                    Text(location.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11)).foregroundStyle(Palette.textTertiary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                Text(status).font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isOn ? (isRunning ? Color(hex: 0x9BF56B) : Palette.textSecondary) : Palette.textTertiary)
                HStack(spacing: 6) {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else if item.isSwitchable {
                        SmallButton(title: isOn ? "Turn Off" : "Turn On", prominent: !isOn) { set(!isOn) }
                            .help(item.isSystemWide ? "Asks for your administrator password." : "Stops it starting until you turn it back on.")
                    } else {
                        SmallButton(title: "Login Items…", prominent: false) { set(!isOn) }
                            .help("Apps' own background items are switched in System Settings → General → Login Items.")
                    }
                    if let path = item.plist ?? item.bundlePath {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        } label: {
                            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                                .frame(width: 26, height: 26).background(Circle().fill(.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .help("Show in Finder")
                        .accessibilityLabel("Show \(item.name) in Finder")
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(isNew ? 0.08 : 0.04)))
    }

    private var status: String {
        if !isOn { return "Off" }
        if item.label != nil { return isRunning ? "Running" : "On · not running" }
        return "On"
    }
}

struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(Capsule().fill(color.opacity(0.22)))
            .overlay(Capsule().strokeBorder((color.opacity(0.6)).edge, lineWidth: 1))
            .fixedSize()
    }
}

struct SmallButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(prominent ? AnyShapeStyle(ModuleKind.activity.theme.buttonGradient)
                                                     : AnyShapeStyle(Color.white.opacity(hovering ? 0.16 : 0.1))))
                .overlay(Capsule().strokeBorder(Palette.stroke, lineWidth: 1))
        }
        .buttonStyle(PressScale())
        .focusEffectDisabled()
        .fixedSize()
        .onHover { over in withAnimation(.easeOut(duration: 0.15)) { hovering = over } }
    }
}

// MARK: - Energy

struct EnergyActivityView: View {
    @Bindable var model: ActivityModel
    var alerts: AlertsModel
    let theme: ModuleTheme

    private var since: Date { Date().addingTimeInterval(-model.energyRange.seconds) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            controls
            if model.hasBattery { batteryPanel }
            appsPanel
            HeatPanel(alerts: alerts, theme: theme)
            if model.hasBattery { BatteryHealthPanel(log: model.batteryHealth, theme: theme) }
            footer
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Period", selection: $model.energyRange) {
                ForEach(ActivityModel.EnergyRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if model.hasBattery {
                Picker("Energy", selection: $model.energyOnBatteryOnly) {
                    Text("On battery").tag(true)
                    Text("All energy").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var batteryPanel: some View {
        let levels = model.energy.levels.filter { $0.date >= since }
        let drain = model.energy.drainPerHour(since: since)
        let onBattery = model.energy.batteryTime(since: since)
        return ActivityPanel(title: "Battery level") {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                stat(drain.map { "\(String(format: "%.1f", $0 * 100))%" } ?? "—", "used per hour on battery")
                stat(SensorActivityView.duration(onBattery), "on battery while recording")
                if let last = levels.last { stat("\(Int((last.charge * 100).rounded()))%", last.onBattery ? "now, on battery" : "now, plugged in") }
                Spacer()
            }
            if levels.count >= 2 {
                Chart {
                    ForEach(Array(segments(levels).enumerated()), id: \.offset) { index, segment in
                        ForEach(segment, id: \.date) { level in
                            AreaMark(x: .value("Time", level.date), y: .value("Charge", level.charge * 100), series: .value("Segment", index))
                                .foregroundStyle(LinearGradient(colors: [(level.onBattery ? theme.colors[0] : Color(hex: 0x9BF56B)).opacity(0.35), .clear],
                                                                startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("Time", level.date), y: .value("Charge", level.charge * 100), series: .value("Segment", index))
                                .foregroundStyle(level.onBattery ? theme.colors[2] : Color(hex: 0x9BF56B))
                                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        }
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) { value in
                        AxisGridLine().foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").foregroundStyle(Palette.textTertiary) }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { value in
                        AxisGridLine().foregroundStyle(.white.opacity(0.05))
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(model.energyRange == .day ? date.formatted(.dateTime.hour()) : date.formatted(.dateTime.weekday(.abbreviated).day()))
                                    .foregroundStyle(Palette.textTertiary)
                            }
                        }
                    }
                }
                .frame(height: 150)
                HStack(spacing: 14) {
                    legend(theme.colors[2], "On battery")
                    legend(Color(hex: 0x9BF56B), "Plugged in")
                }
            } else {
                Text("The chart fills in as Sweep records. Readings are taken every five minutes.")
                    .font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
            }
        }
    }

    /// Splits readings where the power source changes, so each stretch is drawn in its own colour.
    private func segments(_ levels: [EnergyHistory.Level]) -> [[EnergyHistory.Level]] {
        var result: [[EnergyHistory.Level]] = []
        for level in levels {
            if let last = result.last?.last, last.onBattery == level.onBattery, level.date.timeIntervalSince(last.date) <= 20 * 60 {
                result[result.count - 1].append(level)
            } else {
                result.append([level])
            }
        }
        return result
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(theme.textGradient).monospacedDigit()
            Text(label).font(.system(size: 11.5)).foregroundStyle(Palette.textSecondary)
        }
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 14, height: 4)
            Text(title).font(.system(size: 11)).foregroundStyle(Palette.textTertiary)
        }
    }

    private var appsPanel: some View {
        let usage = model.energyUsage
        let title = model.hasBattery && model.energyOnBatteryOnly ? "Apps that used the battery" : "Energy use by app"
        return ActivityPanel(title: title) {
            if usage.isEmpty {
                Text(model.hasBattery && model.energyOnBatteryOnly
                     ? "Nothing recorded on battery in this period yet."
                     : "Nothing recorded in this period yet. Sweep reads each app's energy use every five minutes.")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.textSecondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(usage.prefix(12)) { entry in
                        HStack(spacing: 12) {
                            FileIcon(icon: .app(entry.app.path, fallback: entry.app.key == "system" ? "applelogo" : entry.app.path == nil ? "terminal.fill" : "app.dashed"), size: 26)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(entry.app.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                    Spacer()
                                    Text("\(Int((entry.share * 100).rounded()))%")
                                        .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                                    Text(Self.energy(entry.joules))
                                        .font(.system(size: 11.5, weight: .medium, design: .rounded)).monospacedDigit()
                                        .foregroundStyle(Palette.textTertiary)
                                        .frame(width: 64, alignment: .trailing)
                                }
                                MeterBar(fraction: entry.share, colors: [theme.colors[0], theme.colors[2]], height: 5)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .top) {
            Text("Sweep adds up each app's energy use, including its helpers, every five minutes while it's running. Turn on Open at Login in Settings → Automation for a complete history.")
                .font(.system(size: 11.5)).foregroundStyle(Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if !model.energy.hours.isEmpty {
                Button("Clear History", role: .destructive, action: model.clearEnergyHistory)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xFF8A8A))
            }
        }
        .padding(.horizontal, 4)
    }

    /// Joules as watt-hours, the unit batteries are rated in.
    static func energy(_ joules: Double) -> String {
        let wattHours = joules / 3_600
        return wattHours >= 10 ? "\(Int(wattHours.rounded())) Wh" : String(format: "%.1f Wh", wattHours)
    }
}
