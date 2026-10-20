import SwiftUI
import SweepCore
import SweepScanners

public struct SettingsView: View {
    var state: AppState

    public init(state: AppState) { self.state = state }

    public var body: some View {
        TabView {
            // Tall enough for every section, so nothing hides below the fold.
            GeneralSettings(settings: state.settings, checkup: state.checkup, state: state)
                .frame(height: 530)
                .background(Self.background)
                .tabItem { Label("General", systemImage: "gearshape") }
            ProtectionSettings(settings: state.settings)
                .frame(height: 460)
                .background(Self.background)
                .tabItem { Label("Security", systemImage: "shield.lefthalf.filled") }
            AutomationSettings(automation: state.automation)
                .frame(height: 600)
                .background(Self.background)
                .tabItem { Label("Automation", systemImage: "clock.arrow.2.circlepath") }
            AlertsSettings(alerts: state.alerts, activity: state.activity, updater: state.updater)
                .frame(height: 600)
                .background(Self.background)
                .tabItem { Label("Alerts", systemImage: "bell.badge.fill") }
            IntegrationsSettings(settings: state.settings)
                .frame(height: 620)
                .background(Self.background)
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension.fill") }
            TweaksSettings(model: state.tweaks)
                .frame(height: 640)
                .background(Self.background)
                .tabItem { Label("Tweaks", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 620)
        .scrollContentBackground(.hidden)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .tint(ModuleKind.checkup.theme.accent)
        .preferredColorScheme(.dark)
    }

    /// Indigo base that also runs under the toolbar.
    private static var background: some View {
        LinearGradient(colors: Palette.base, startPoint: .top, endPoint: .bottom).ignoresSafeArea()
    }
}

struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    @Bindable var checkup: CheckupModel
    var state: AppState

    var body: some View {
        Form {
            Section("Junk Files") {
                Toggle("Move cleaned items to the Trash instead of deleting them", isOn: $settings.cleanupUsesTrash)
                Text("Junk is normally deleted right away. With this on, space is freed when you empty the Trash.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Checkup includes") {
                ForEach(CheckupModel.modules) { kind in
                    Toggle(isOn: Binding(
                        get: { checkup.enabled.contains(kind) },
                        set: { on in if on { checkup.enabled.insert(kind) } else { checkup.enabled.remove(kind) } })) {
                        HStack(spacing: 10) {
                            GradientIcon(symbol: kind.theme.symbol, theme: kind.theme, size: 24)
                            Text(kind.theme.title)
                        }
                    }
                }
            }
            Section("Access") {
                LabeledContent("Full Disk Access") {
                    if state.hasFullDiskAccess {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(Color(hex: 0x14E3A1))
                    } else {
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                    }
                }
                if !state.hasFullDiskAccess {
                    Text("Already allowed it? Quit and reopen Sweep. After installing a new build, switch Sweep off and on again in that list.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ProtectionSettings: View {
    @Bindable var settings: AppSettings
    @State private var entries: [Quarantine.Entry] = []
    @State private var confirmDelete: Quarantine.Entry?

    var body: some View {
        Form {
            Section("Malware scan") {
                Picker("Scan", selection: $settings.protectionDeepScan) {
                    Text("Quick — startup items, apps, Downloads").tag(false)
                    Text("Deep — everything in your home folder").tag(true)
                }
                LabeledContent("Signatures") {
                    Text(RuleSource.xprotectPaths.contains(where: FileManager.default.isReadableFile)
                         ? "Apple XProtect rules on this Mac" : "XProtect rules not found")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Your own rules") {
                    Button("Show Folder") {
                        let folder = NSHomeDirectory() + "/Library/Application Support/Sweep/Rules"
                        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(URL(fileURLWithPath: folder))
                    }
                }
                Text("Add .yar files to that folder to scan with extra YARA rules.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Quarantine") {
                if entries.isEmpty {
                    Text("Nothing in quarantine.").foregroundStyle(.secondary)
                }
                ForEach(entries, id: \.quarantinedPath) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text((entry.originalPath as NSString).lastPathComponent)
                            Text("\(entry.threat) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") { try? Quarantine.restore(entry); reload() }
                        Button("Delete", role: .destructive) { confirmDelete = entry }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .confirmationDialog("Delete this file for good?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { entry in
            Button("Delete", role: .destructive) {
                try? FileManager.default.removeItem(atPath: (entry.quarantinedPath as NSString).deletingLastPathComponent)
                reload()
            }
        }
    }

    private func reload() {
        let folder = Quarantine.defaultFolder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).compactMap { slot in
            guard let data = FileManager.default.contents(atPath: folder + "/" + slot + "/manifest.json") else { return nil }
            return try? decoder.decode(Quarantine.Entry.self, from: data)
        }.sorted { $0.date > $1.date }
    }
}
