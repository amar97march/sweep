import SwiftUI
import SweepCore
import SweepScanners

/// Settings → Automation: scheduled Checkup, auto-tidy rules, open at login and recent activity.
struct AutomationSettings: View {
    @Bindable var automation: AutomationModel
    @State private var previews: [TidyRule.Kind: [ScanItem]] = [:]
    @State private var confirming: TidyRule?
    @State private var loginMessage: String?

    var body: some View {
        Form {
            Section {
                Picker("Run Checkup", selection: $automation.schedule.frequency) {
                    Text("Never").tag(CheckupSchedule.Frequency.never)
                    Text("Every day").tag(CheckupSchedule.Frequency.daily)
                    Text("Every week").tag(CheckupSchedule.Frequency.weekly)
                    Text("Every month").tag(CheckupSchedule.Frequency.monthly)
                }
                if automation.schedule.frequency == .weekly {
                    Picker("On", selection: $automation.schedule.weekday) {
                        ForEach(1...7, id: \.self) { day in Text(Calendar.current.weekdaySymbols[day - 1]).tag(day) }
                    }
                }
                if automation.schedule.frequency == .monthly {
                    Picker("On day", selection: $automation.schedule.dayOfMonth) {
                        ForEach(1...28, id: \.self) { day in Text("\(day)").tag(day) }
                    }
                }
                if automation.schedule.frequency != .never {
                    DatePicker("At", selection: time, displayedComponents: .hourAndMinute)
                    Picker("Then", selection: $automation.schedule.action) {
                        Text("Tell me what it found").tag(CheckupSchedule.Action.notify)
                        Text("Clean junk automatically").tag(CheckupSchedule.Action.cleanJunk)
                    }
                    if let next = automation.nextRun {
                        LabeledContent("Next run") {
                            Text(next.formatted(date: .complete, time: .shortened)).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Scheduled Checkup")
            } footer: {
                Text(automation.schedule.frequency == .never
                     ? "Checkup can scan on a schedule and tell you what it found, or clean junk for you."
                     : "Scheduled runs check the modules chosen for Checkup. Cleaning junk automatically moves caches and logs in your home folder to the Trash; it never asks for your password and never empties the Trash.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach($automation.rules) { $rule in
                    TidyRuleRow(rule: $rule, preview: previews[rule.kind], busy: automation.isRunning) {
                        Task { previews[rule.kind] = await automation.preview(rule) }
                    } tidyNow: {
                        confirming = rule
                    }
                }
            } header: {
                Text("Auto-tidy")
            } footer: {
                Text("Checked once a day. Everything goes to the Trash, so you can put it back. A rule you switch on first runs tomorrow.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Background") {
                Toggle("Open Sweep at login", isOn: Binding(get: { automation.loginItemEnabled },
                                                            set: { loginMessage = automation.setOpensAtLogin($0) }))
                    .disabled(!AutomationModel.canOpenAtLogin)
                Text(loginMessage ?? "Schedules and rules run while Sweep is open, including in the menu bar after you close its window.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !automation.activity.isEmpty {
                Section("Recent activity") {
                    ForEach(automation.activity.prefix(5)) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: entry.symbol).foregroundStyle(ModuleKind.checkup.theme.accent).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(entry.date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { rule in
            Button("Move to Trash") {
                Task {
                    await automation.tidy([rule])
                    previews[rule.kind] = await automation.preview(rule)
                }
            }
        } message: { _ in
            Text("You can put them back from the Trash.")
        }
    }

    private var confirmTitle: String {
        guard let rule = confirming else { return "" }
        let count = previews[rule.kind]?.count
        return count.map { "Move \($0) \($0 == 1 ? "item" : "items") to the Trash?" } ?? "Tidy \(rule.title.lowercased()) now?"
    }

    /// The schedule's hour and minute as a date for the time picker.
    private var time: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: automation.schedule.hour, minute: automation.schedule.minute, second: 0, of: Date()) ?? Date()
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            automation.schedule.hour = parts.hour ?? 10
            automation.schedule.minute = parts.minute ?? 0
        }
    }
}

struct TidyRuleRow: View {
    @Binding var rule: TidyRule
    let preview: [ScanItem]?
    let busy: Bool
    let showPreview: () -> Void
    let tidyNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $rule.isEnabled) {
                HStack(spacing: 10) {
                    Image(systemName: rule.symbol)
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ModuleKind.declutter.theme.gradient))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.title)
                        Text(rule.explanation).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                Text("After").foregroundStyle(.secondary)
                Picker("After", selection: $rule.days) {
                    ForEach(TidyRule.dayChoices, id: \.self) { days in Text("\(days) days untouched").tag(days) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 8)
                if let preview {
                    Text(preview.isEmpty ? "Nothing to tidy now"
                         : "\(preview.count) \(preview.count == 1 ? "item" : "items") · \(ByteFormat.string(preview.reduce(0) { $0 + $1.size }))")
                        .foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                Button("Preview", action: showPreview).fixedSize()
                Button("Tidy Now…", action: tidyNow).disabled(busy || preview?.isEmpty == true).fixedSize()
            }
            .font(.caption)
            .controlSize(.small)
            .padding(.leading, 34)
        }
        .padding(.vertical, 2)
        .onChange(of: rule.days) { _, _ in if preview != nil { showPreview() } }
    }
}
