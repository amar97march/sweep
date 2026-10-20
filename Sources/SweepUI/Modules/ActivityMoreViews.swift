import Charts
import SwiftUI
import SweepCore
import SweepMonitor
import SweepScanners

// MARK: - Battery health

/// How the battery's capacity has changed since Sweep started recording it.
struct BatteryHealthPanel: View {
    let log: BatteryHealthLog
    let theme: ModuleTheme

    var body: some View {
        ActivityPanel(title: "Battery health over time") {
            if let last = log.entries.last {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    stat("\(Int((last.health * 100).rounded()))%", "of its original capacity")
                    if let cycles = last.cycles { stat("\(cycles)", "charge cycles") }
                    if let change = log.change(since: .distantPast) {
                        let points = change.health
                        stat((points > 0 ? "+" : "") + String(format: "%.1f", points),
                             "points in \(Int(change.days)) days" + (change.cycles.map { ", \($0) cycles" } ?? ""))
                    }
                    Spacer()
                }
                if log.entries.count >= 2 {
                    Chart(log.entries, id: \.date) { entry in
                        LineMark(x: .value("Date", entry.date), y: .value("Health", entry.health * 100))
                            .foregroundStyle(Color(hex: 0x9BF56B))
                            .interpolationMethod(.monotone)
                        AreaMark(x: .value("Date", entry.date), y: .value("Health", entry.health * 100))
                            .foregroundStyle(LinearGradient(colors: [Color(hex: 0x9BF56B, opacity: 0.25), .clear], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                    .chartYScale(domain: max(0, (log.entries.map(\.health).min() ?? 0.8) * 100 - 5)...100)
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine().foregroundStyle(.white.opacity(0.08))
                            AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").foregroundStyle(Palette.textTertiary) }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(Palette.textTertiary)
                        }
                    }
                    .frame(height: 110)
                }
                Text("Recorded once a day since \(log.entries.first!.date.formatted(date: .abbreviated, time: .omitted)). A healthy battery loses a few points a year; below 80% it may need service.")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Sweep records the battery's capacity once a day, so you can see how it ages over months.")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(theme.textGradient).monospacedDigit()
            Text(label).font(.system(size: 11.5)).foregroundStyle(Palette.textSecondary)
        }
    }
}

// MARK: - Network

struct NetworkActivityView: View {
    @Bindable var model: ActivityModel
    let theme: ModuleTheme

    private var since: Date { Date().addingTimeInterval(-model.networkRange.seconds) }

    var body: some View {
        let usage = model.networkUsage
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Period", selection: $model.networkRange) {
                    ForEach(ActivityModel.EnergyRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            if model.onExpensiveNetwork { hotspotBanner }
            ActivityPanel(title: "Data used") {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    stat(ByteFormat.string(usage.reduce(0) { $0 + $1.received }), "downloaded")
                    stat(ByteFormat.string(usage.reduce(0) { $0 + $1.sent }), "uploaded")
                    stat("\(usage.count)", usage.count == 1 ? "app" : "apps")
                    Spacer()
                }
                let hours = model.network.perHour(since: since)
                if hours.count >= 2 {
                    Chart(hours, id: \.start) { hour in
                        BarMark(x: .value("Hour", hour.start, unit: model.networkRange == .day ? .hour : .day),
                                y: .value("Bytes", Double(hour.bytes)))
                            .foregroundStyle(LinearGradient(colors: [theme.colors[2], theme.colors[0]], startPoint: .top, endPoint: .bottom))
                            .cornerRadius(2)
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { value in
                            AxisGridLine().foregroundStyle(.white.opacity(0.08))
                            AxisValueLabel {
                                let bytes = UInt64(max(0, value.as(Double.self) ?? 0))
                                Text(bytes == 0 ? "0" : ByteFormat.short(bytes)).foregroundStyle(Palette.textTertiary)
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { value in
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(model.networkRange == .day ? date.formatted(.dateTime.hour()) : date.formatted(.dateTime.weekday(.abbreviated).day()))
                                        .foregroundStyle(Palette.textTertiary)
                                }
                            }
                        }
                    }
                    .frame(height: 130)
                }
            }
            ActivityPanel(title: "By app") {
                if usage.isEmpty {
                    Text("Nothing recorded in this period yet. Sweep reads each app's network use every five minutes.")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.textSecondary)
                } else {
                    let largest = Double(usage.first?.total ?? 1)
                    VStack(spacing: 10) {
                        ForEach(usage.prefix(15)) { entry in
                            HStack(spacing: 12) {
                                FileIcon(icon: .app(entry.app.path, fallback: entry.app.key == "system" ? "applelogo" : entry.app.path == nil ? "terminal.fill" : "app.dashed"), size: 26)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 10) {
                                        Text(entry.app.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                        Spacer()
                                        Label(ByteFormat.string(entry.received), systemImage: "arrow.down")
                                        Label(ByteFormat.string(entry.sent), systemImage: "arrow.up")
                                            .frame(width: 92, alignment: .trailing)
                                    }
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(Palette.textSecondary)
                                    MeterBar(fraction: Double(entry.total) / largest, colors: [theme.colors[0], theme.colors[2]], height: 5)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            HStack(alignment: .top) {
                Text("Measured from macOS's own network statistics every five minutes while Sweep runs. Helpers count toward their app; system services are grouped as macOS.")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if !model.network.hours.isEmpty {
                    Button("Clear History", role: .destructive, action: model.clearNetworkHistory)
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0xFF8A8A))
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var hotspotBanner: some View {
        let used = model.network.usage(since: Date().addingTimeInterval(-86_400), expensiveOnly: true)
        return HStack(spacing: 12) {
            Image(systemName: "personalhotspot").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color(hex: 0xFFB830))
            VStack(alignment: .leading, spacing: 2) {
                Text("You're on a hotspot or cellular connection").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(used.isEmpty ? "Data may be limited or cost extra. Apps using it will show up here."
                     : "In the last day: " + used.prefix(3).map { "\($0.app.name) \(ByteFormat.string($0.total))" }.joined(separator: ", "))
                    .font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: 0xFFB830, opacity: 0.13)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder((Color(hex: 0xFFB830, opacity: 0.45)).edge))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(theme.textGradient).monospacedDigit()
            Text(label).font(.system(size: 11.5)).foregroundStyle(Palette.textSecondary)
        }
    }
}

// MARK: - Privacy

struct PrivacyActivityView: View {
    @Bindable var model: ActivityModel
    let theme: ModuleTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            keyboardPanel
            permissionsPanel
        }
    }

    private var keyboardPanel: some View {
        let apps = model.keyboardWatchers.filter { !$0.isPartOfMacOS }
        let system = model.keyboardWatchers.filter(\.isPartOfMacOS)
        return ActivityPanel(title: "Apps that can see what you type",
                             trailing: AnyView(settingsLink("Input Monitoring", pane: "Privacy_ListenEvent"))) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Text expanders, shortcut and accessibility tools need this. Anything you don't recognise could be a keylogger: turn it off in Input Monitoring or Accessibility settings, and remove the app.")
                    .font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if apps.isEmpty {
                    Label("No apps are reading your keystrokes right now.", systemImage: "checkmark.shield.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: 0x9BF56B))
                }
                ForEach(apps) { watcher in
                    let signer = model.signers[watcher.app.path ?? watcher.executable]
                    HStack(spacing: 12) {
                        FileIcon(icon: .app(watcher.app.path, fallback: "keyboard.fill"), size: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(watcher.app.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                Chip(text: watcher.listenOnly ? "Reads keystrokes" : "Can change keystrokes",
                                     color: watcher.listenOnly ? theme.colors[0] : Color(hex: 0xFFB830))
                                if !watcher.enabled { Chip(text: "Paused", color: .gray) }
                            }
                            if let signer {
                                Label(signer.summary, systemImage: signer.isTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(signer.isTrusted ? Color(hex: 0x9BF56B) : Color(hex: 0xFFB830))
                            }
                            Text(watcher.executable.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.system(size: 11)).foregroundStyle(Palette.textTertiary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
                }
                if !system.isEmpty {
                    let names = Set(system.map { ($0.executable as NSString).lastPathComponent }).sorted()
                    Text("Also \(system.count) \(system.count == 1 ? "part" : "parts") of macOS: \(names.prefix(4).joined(separator: ", "))\(names.count > 4 ? "…" : "").")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.textTertiary)
                }
            }
        }
    }

    private var permissionsPanel: some View {
        ActivityPanel(title: "Permissions you've given") {
            VStack(alignment: .leading, spacing: 14) {
                if model.permissions.isEmpty {
                    Text("Sweep can read Mac-wide permissions (Full Disk Access, Accessibility, Screen Recording, Input Monitoring) once it has Full Disk Access itself.")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    FullDiskAccessNote()
                }
                ForEach(model.permissionsByService, id: \.service) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: Self.symbol(group.service)).foregroundStyle(theme.colors[2]).frame(width: 18)
                            Text(TCCPermissions.label(group.service)).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                            Text("\(group.clients.count)").font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(Palette.textSecondary)
                                .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(.white.opacity(0.1)))
                            Spacer()
                            if let pane = Self.pane(group.service) { settingsLink("Change", pane: pane) }
                        }
                        Text(Self.meaning(group.service)).font(.system(size: 11.5)).foregroundStyle(Palette.textTertiary)
                        FlowChips(items: group.clients.map { ($0, AppLookup.name(for: $0), AppLookup.icon(for: $0)) })
                    }
                }
                Text("On macOS 27, camera and microphone permissions are kept where no app can read them; Camera & Mic shows which apps actually used them.")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func settingsLink(_ title: String, pane: String) -> some View {
        Button(title + "…") {
            _ = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane)!)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(theme.colors[2])
    }

    static func pane(_ service: String) -> String? {
        [
            "kTCCServiceSystemPolicyAllFiles": "Privacy_AllFiles", "kTCCServiceAccessibility": "Privacy_Accessibility",
            "kTCCServiceScreenCapture": "Privacy_ScreenCapture", "kTCCServiceListenEvent": "Privacy_ListenEvent",
            "kTCCServiceCamera": "Privacy_Camera", "kTCCServiceMicrophone": "Privacy_Microphone",
            "kTCCServiceAppleEvents": "Privacy_Automation", "kTCCServiceSystemPolicyAppBundles": "Privacy_AppBundles",
            "kTCCServiceDeveloperTool": "Privacy_DevTools",
        ][service]
    }

    static func symbol(_ service: String) -> String {
        switch service {
        case "kTCCServiceSystemPolicyAllFiles": "internaldrive.fill"
        case "kTCCServiceAccessibility": "accessibility"
        case "kTCCServiceScreenCapture": "rectangle.dashed.badge.record"
        case "kTCCServiceListenEvent": "keyboard"
        case "kTCCServiceCamera": "video.fill"
        case "kTCCServiceMicrophone": "mic.fill"
        case "kTCCServiceAppleEvents": "gearshape.2"
        default: "lock.fill"
        }
    }

    static func meaning(_ service: String) -> String {
        switch service {
        case "kTCCServiceSystemPolicyAllFiles": "Can read every file, including Mail, Messages and Safari data."
        case "kTCCServiceAccessibility": "Can control your Mac: click, type and read what's on screen in other apps."
        case "kTCCServiceScreenCapture": "Can record your screen and see other apps' windows."
        case "kTCCServiceListenEvent": "Can read your keyboard and mouse input in every app."
        case "kTCCServiceAppleEvents": "Can control other apps with scripts."
        case "kTCCServiceSystemPolicyAppBundles": "Can change or delete other apps."
        case "kTCCServiceDeveloperTool": "Can run software that macOS doesn't check."
        default: "Allowed in Privacy & Security settings."
        }
    }
}

/// App chips that wrap onto as many lines as they need.
struct FlowChips: View {
    let items: [(id: String, name: String, icon: ItemIcon)]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.id) { item in
                HStack(spacing: 5) {
                    FileIcon(icon: item.icon, size: 16)
                    Text(item.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.08)))
                .help(item.id)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
