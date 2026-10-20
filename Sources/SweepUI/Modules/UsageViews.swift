import Charts
import SwiftUI
import SweepCore
import SweepMonitor

// MARK: - Heat

/// When the Mac slowed itself down because of heat, and which app was busiest then.
struct HeatPanel: View {
    var alerts: AlertsModel
    let theme: ModuleTheme

    var body: some View {
        let week = alerts.thermalLog.summary(since: Date().addingTimeInterval(-7 * 86_400))
        ActivityPanel(title: "Heat") {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                stat(alerts.thermalLevel.title, "right now", color: alerts.thermalLevel.isThrottling ? Color(hex: 0xFFB830) : nil)
                stat("\(week.count)", week.count == 1 ? "slowdown this week" : "slowdowns this week")
                if week.count > 0 {
                    stat(SensorActivityView.duration(week.total), "slowed down in all")
                }
                Spacer()
            }
            let recent = alerts.thermalLog.episodes.suffix(6).reversed()
            if recent.isEmpty {
                Text("Your Mac hasn't had to slow down to cool off since Sweep started watching. It notes every time it does, with the busiest app at that moment.")
                    .font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(recent)) { episode in
                        HStack(spacing: 10) {
                            Image(systemName: episode.peak == .critical ? "thermometer.high" : "thermometer.medium")
                                .foregroundStyle(episode.peak == .critical ? Color(hex: 0xFF5E3A) : Color(hex: 0xFFB830))
                                .frame(width: 16)
                            Text(episode.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                                .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                                .foregroundStyle(Palette.textSecondary)
                                .frame(width: 110, alignment: .leading)
                            Text(episode.end == nil ? "Slowed down now" : "Slowed down for \(SensorActivityView.duration(episode.duration(now: Date())))")
                                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                            if let app = episode.busiestApp {
                                Text("· busiest: \(app)").font(.system(size: 12)).foregroundStyle(Palette.textTertiary).lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(theme.textGradient)).lineLimit(1)
            Text(label).font(.system(size: 11.5)).foregroundStyle(Palette.textSecondary)
        }
    }
}

// MARK: - Usage

/// How long each app was in front while you were using the Mac.
struct UsageActivityView: View {
    @Bindable var model: ActivityModel
    let theme: ModuleTheme

    var body: some View {
        let usage = model.appUsage
        let total = usage.reduce(0) { $0 + $1.seconds }
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Period", selection: $model.usageRange) {
                    Text("Today").tag(ActivityModel.EnergyRange.day)
                    Text("7 Days").tag(ActivityModel.EnergyRange.week)
                    Text("30 Days").tag(ActivityModel.EnergyRange.month)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            ActivityPanel(title: model.usageRange == .day ? "Today" : "Time on your Mac") {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    stat(SensorActivityView.duration(total), model.usageRange == .day ? "in use today" : "in use")
                    if model.usageRange != .day, total > 0 {
                        let days = Double(max(1, model.usage.perDay(since: Date().addingTimeInterval(-model.usageRange.seconds))
                            .filter { $0.seconds > 0 }.count))
                        stat(SensorActivityView.duration(total / days), "a day on average")
                    }
                    if let top = usage.first { stat(top.app.name, "used most") }
                    Spacer()
                }
                chart
            }
            ActivityPanel(title: "By app") {
                if usage.isEmpty {
                    Text("Nothing recorded yet. Time counts while an app is in front and you're using the Mac.")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.textSecondary)
                } else {
                    let largest = usage.first?.seconds ?? 1
                    VStack(spacing: 10) {
                        ForEach(usage.prefix(15)) { entry in
                            HStack(spacing: 12) {
                                FileIcon(icon: .app(entry.app.path), size: 26)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(entry.app.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                                        Spacer()
                                        Text(SensorActivityView.duration(entry.seconds))
                                            .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                                        Text("\(Int((entry.share * 100).rounded()))%")
                                            .font(.system(size: 11.5, weight: .medium, design: .rounded)).monospacedDigit()
                                            .foregroundStyle(Palette.textTertiary)
                                            .frame(width: 40, alignment: .trailing)
                                    }
                                    MeterBar(fraction: entry.seconds / largest, colors: [theme.colors[0], theme.colors[2]], height: 5)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ToggleRow(title: "Record app usage",
                          detail: "Counts the app in front while you're using the Mac; after five idle minutes, asleep or locked, nothing counts. Kept on this Mac for 90 days.",
                          isOn: $model.recordsUsage, theme: theme)
                if !model.usage.days.isEmpty {
                    HStack {
                        Spacer()
                        Button("Clear History", role: .destructive, action: model.clearUsageHistory)
                            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0xFF8A8A))
                    }
                }
            }
            .padding(18)
            .glassCard(cornerRadius: 20)
        }
    }

    @ViewBuilder private var chart: some View {
        if model.usageRange == .day {
            let hours = model.usage.perHour(of: Date())
            if hours.contains(where: { $0.seconds > 0 }) {
                Chart(hours, id: \.hour) { entry in
                    BarMark(x: .value("Hour", entry.hour), y: .value("Minutes", entry.seconds / 60))
                        .foregroundStyle(LinearGradient(colors: [theme.colors[2], theme.colors[0]], startPoint: .top, endPoint: .bottom))
                        .cornerRadius(2)
                }
                .chartXScale(domain: 0...23)
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                        AxisValueLabel {
                            let hour = value.as(Int.self) ?? 0
                            Text(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!.formatted(.dateTime.hour()))
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(values: [0, 30, 60]) { value in
                        AxisGridLine().foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)m").foregroundStyle(Palette.textTertiary) }
                    }
                }
                .frame(height: 120)
            }
        } else {
            let days = model.usage.perDay(since: Date().addingTimeInterval(-model.usageRange.seconds + 86_400))
            if days.contains(where: { $0.seconds > 0 }) {
                Chart(days, id: \.day) { entry in
                    BarMark(x: .value("Day", entry.day, unit: .day), y: .value("Hours", entry.seconds / 3_600))
                        .foregroundStyle(LinearGradient(colors: [theme.colors[2], theme.colors[0]], startPoint: .top, endPoint: .bottom))
                        .cornerRadius(2)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 7)) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(model.usageRange == .week ? date.formatted(.dateTime.weekday(.abbreviated)) : date.formatted(.dateTime.day().month(.abbreviated)))
                                    .foregroundStyle(Palette.textTertiary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel { Text("\(value.as(Double.self).map { Int($0.rounded()) } ?? 0)h").foregroundStyle(Palette.textTertiary) }
                    }
                }
                .frame(height: 120)
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(theme.textGradient).monospacedDigit().lineLimit(1)
            Text(label).font(.system(size: 11.5)).foregroundStyle(Palette.textSecondary)
        }
    }
}
