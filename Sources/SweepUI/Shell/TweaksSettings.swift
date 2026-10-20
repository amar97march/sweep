import SwiftUI
import SweepCore
import SweepScanners

/// Hidden macOS settings, read and written with `defaults`. Every change can be undone with "Restore Default".
@MainActor
@Observable
public final class TweaksModel {
    public struct Engine: Sendable {
        public var choice: @Sendable (Tweak) -> Int
        public var set: @Sendable (Tweak, Int) -> Bool
        public var relaunch: @Sendable (String) -> Void

        public static let live: Engine = {
            let store = TweakStore()
            return Engine(choice: { store.choice(of: $0) }, set: { store.set($0, choice: $1) }, relaunch: { store.relaunch($0) })
        }()

        /// Shows macOS's defaults and changes nothing: for tests and screenshot runs.
        public static let inert = Engine(choice: { tweak in tweak.choices.firstIndex { $0.value == nil } ?? 0 },
                                         set: { _, _ in false }, relaunch: { _ in })
    }

    public private(set) var choices: [String: Int] = [:]
    /// Apps to relaunch before changes show.
    public private(set) var needsRelaunch: Set<String> = []
    public private(set) var failure: String?
    @ObservationIgnored let engine: Engine

    public init(engine: Engine? = nil) {
        self.engine = engine ?? (Preferences.isThrowaway ? .inert : .live)
    }

    func load() async {
        let engine = engine
        choices = await Task.detached(priority: .userInitiated) {
            Dictionary(uniqueKeysWithValues: Tweak.all.map { ($0.id, engine.choice($0)) })
        }.value
    }

    public func choice(_ tweak: Tweak) -> Int {
        choices[tweak.id] ?? tweak.choices.firstIndex { $0.value == nil } ?? 0
    }

    public func set(_ tweak: Tweak, choice: Int) {
        let engine = engine
        guard engine.set(tweak, choice) else {
            failure = "Couldn't change \"\(tweak.title)\"."
            return
        }
        failure = nil
        choices[tweak.id] = choice
        if let process = tweak.relaunch { needsRelaunch.insert(process) }
    }

    /// Puts every tweak back to macOS's own default.
    public func restoreAll() {
        for tweak in Tweak.all where tweak.choices[choice(tweak)].value != nil {
            set(tweak, choice: tweak.choices.firstIndex { $0.value == nil } ?? 0)
        }
    }

    public func relaunch() {
        for process in needsRelaunch.sorted() { engine.relaunch(process) }
        needsRelaunch = []
    }
}

struct TweaksSettings: View {
    var model: TweaksModel

    var body: some View {
        Form {
            Section {
                Text("Options macOS has but doesn't show in System Settings. Each is an ordinary preference: switching it off restores macOS's default exactly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Tweak.Group.allCases, id: \.self) { group in
                Section(group.rawValue) {
                    ForEach(Tweak.all.filter { $0.group == group }) { tweak in row(tweak) }
                }
            }
            Section {
                HStack {
                    if let failure = model.failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xFFB830))
                    } else if !model.needsRelaunch.isEmpty {
                        Text("\(model.needsRelaunch.sorted().map { $0 == "SystemUIServer" ? "the menu bar" : $0 }.joined(separator: " and ")) "
                             + "must restart to show the change.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !model.needsRelaunch.isEmpty { Button("Restart Now", action: model.relaunch) }
                    Button("Restore All Defaults", action: model.restoreAll)
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
    }

    @ViewBuilder private func row(_ tweak: Tweak) -> some View {
        if tweak.isSwitch {
            Toggle(isOn: Binding(get: { model.choice(tweak) == 0 }, set: { model.set(tweak, choice: $0 ? 0 : 1) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tweak.title)
                    Text(tweak.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Picker(selection: Binding(get: { model.choice(tweak) }, set: { model.set(tweak, choice: $0) })) {
                ForEach(Array(tweak.choices.enumerated()), id: \.offset) { index, choice in Text(choice.title).tag(index) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tweak.title)
                    Text(tweak.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
