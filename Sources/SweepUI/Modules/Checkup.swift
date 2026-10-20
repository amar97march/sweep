import SwiftUI
import SweepCore

/// One scan across Cleanup, Protection, Performance, Applications and Declutter, then one Run.
@MainActor
@Observable
public final class CheckupModel {
    public enum Phase { case intro, scanning, results, running, done }

    public enum CardStatus: Equatable {
        case waiting
        case working(String)
        case found(String)
        case clean
        case finished(String)
        case failed(String)
        case off
        /// The module has no scan results to show (it was stopped, or is busy with something else).
        case notScanned
    }

    public static let modules: [ModuleKind] = [.cleanup, .protection, .performance, .applications, .declutter]

    public private(set) var phase = Phase.intro
    public private(set) var status: [ModuleKind: CardStatus] = [:]
    public var enabled: Set<ModuleKind> {
        didSet { Preferences.set(enabled.map(\.rawValue), forKey: "checkupModules") }
    }
    @ObservationIgnored weak var state: AppState?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    public init() {
        let saved = (Preferences.object(forKey: "checkupModules") as? [String])?.compactMap(ModuleKind.init(rawValue:))
        // Declutter reads all your documents, so it's opt-in.
        enabled = Set(saved ?? [.cleanup, .protection, .performance, .applications])
    }

    func catalog(_ kind: ModuleKind) -> CatalogModuleModel? { state?.catalog(for: kind) }

    public func scan() {
        scanTask?.cancel()
        phase = .scanning
        for kind in Self.modules { status[kind] = enabled.contains(kind) ? .waiting : .off }
        scanTask = Task {
            for kind in Self.modules where enabled.contains(kind) {
                guard !Task.isCancelled, phase == .scanning, let model = catalog(kind) else { continue }
                // A module that is removing or updating things finishes first; scanning now would lose its results.
                while model.phase == .working && !Task.isCancelled {
                    status[kind] = .working("Waiting for \(kind.theme.title) to finish…")
                    try? await Task.sleep(for: .milliseconds(150))
                }
                guard !Task.isCancelled else { return }
                status[kind] = .working("Scanning…")
                model.scan()
                while model.phase == .scanning && !Task.isCancelled {
                    status[kind] = .working(model.progress.message.isEmpty ? "Scanning…" : model.progress.message)
                    try? await Task.sleep(for: .milliseconds(150))
                }
                guard !Task.isCancelled else { return }
                status[kind] = summary(model)
            }
            if phase == .scanning, !Task.isCancelled { phase = .results }
        }
    }

    /// Stops Checkup's scan. Modules that are scanning stop too; one that is removing things finishes.
    public func stop() {
        scanTask?.cancel()
        scanTask = nil
        for kind in Self.modules { catalog(kind)?.stop() }
        status = [:]
        phase = .intro
    }

    /// Runs every module's selected items, one module at a time.
    /// Items the last Run couldn't handle, across modules.
    public private(set) var itemsNeedingAttention = 0

    public func run() {
        phase = .running
        itemsNeedingAttention = 0
        Task {
            for kind in Self.modules where enabled.contains(kind) {
                guard let model = catalog(kind), !model.selected.isEmpty, model.phase == .results || model.phase == .review else { continue }
                status[kind] = .working(model.engine.workingMessage)
                model.run()
                while model.phase == .working {
                    try? await Task.sleep(for: .milliseconds(150))
                }
                let succeeded = model.records.filter(\.succeeded)
                let failed = model.records.count - succeeded.count
                var text = model.engine.measuresSize
                    ? "\(ByteFormat.string(succeeded.reduce(0) { $0 + $1.bytes })) done"
                    : "\(succeeded.count) done"
                if failed > 0 { text += " · \(failed) need attention" }
                itemsNeedingAttention += failed
                status[kind] = .finished(text)
            }
            phase = .done
        }
    }

    public func review(_ kind: ModuleKind) {
        guard let model = catalog(kind) else { return }
        state?.selection = kind
        model.review()
    }

    /// Screenshots only: a scan in progress, with no scanning.
    func previewScanning() {
        status = [.cleanup: .found("10.3 GB of junk"),
                  .protection: .working("Checking /Applications/Developer Tools/Instruments.app/Contents/Frameworks/InstrumentsKit.framework"),
                  .performance: .waiting, .applications: .waiting, .declutter: .off]
        phase = .scanning
    }

    /// Shows results from scans the modules already finished (scheduled runs, and screenshots).
    func showLoadedResults() {
        for kind in Self.modules {
            guard enabled.contains(kind), let model = catalog(kind) else { status[kind] = .off; continue }
            status[kind] = summary(model)
        }
        phase = .results
    }

    public func startOver() {
        phase = .intro
        status = [:]
    }

    public var hasSomethingToRun: Bool {
        Self.modules.contains { enabled.contains($0) && !(catalog($0)?.selected.isEmpty ?? true) }
    }

    func summary(_ model: CatalogModuleModel) -> CardStatus {
        switch model.phase {
        case .failed(let message): return .failed(message)
        case .results, .review:
            guard !model.selected.isEmpty else { return model.categories.isEmpty ? .clean : .found("Nothing selected") }
            let amount = model.amount(bytes: model.selectedSize, count: model.selected.count)
            switch model.kind {
            case .cleanup: return .found("\(amount) of junk")
            case .protection: return .found("\(model.selected.count) \(model.selected.count == 1 ? "threat" : "threats") to remove")
            case .performance: return .found("\(model.selected.count) tasks to run")
            case .applications: return .found(Self.applicationsSummary(model))
            default: return .found("\(amount) to remove")
            }
        case .intro, .scanning, .working, .done:
            // Only finished scan results can say "All clear".
            return .notScanned
        }
    }

    /// Updates are counted as updates; anything else selected (leftovers, an app to uninstall) as what it removes,
    /// each on its own line so the card never breaks a size in two.
    static func applicationsSummary(_ model: CatalogModuleModel) -> String {
        let updateIDs = Set(model.categories.filter { $0.id == "updates" }.flatMap(\.groups).flatMap(\.items).map(\.id))
        let selected = model.selectedItems
        let updates = selected.filter { updateIDs.contains($0.id) }.count
        let removals = selected.filter { !updateIDs.contains($0.id) }
        var parts: [String] = []
        if updates > 0 { parts.append("\(updates) \(updates == 1 ? "update" : "updates")") }
        if !removals.isEmpty {
            parts.append("\(model.amount(bytes: removals.reduce(0) { $0 + $1.size }, count: removals.count)) to remove")
        }
        return parts.joined(separator: "\n")
    }
}

struct CheckupView: View {
    @Bindable var model: CheckupModel
    private let theme = ModuleKind.checkup.theme

    var body: some View {
        ZStack {
            LiveBackground(colors: theme.colors)
            GeometryReader { proxy in
                let compact = proxy.size.height < 760
                VStack(spacing: compact ? 20 : 28) {
                    Spacer(minLength: 12)
                    header
                        .id(model.phase)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: 10)),
                                                removal: .opacity))
                    cards(width: Self.cardWidth(for: proxy.size.width - 60), compact: compact)
                    actions
                        .id("actions-\(model.phase)")
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    Spacer(minLength: 12)
                }
                .padding(30)
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .animation(.spring(duration: 0.55, bounce: 0.2), value: model.phase)
    }

    @ViewBuilder private var header: some View {
        switch model.phase {
        case .intro:
            VStack(spacing: 12) {
                HeroBadge(theme: theme, size: 120)
                HeroTitle(text: theme.title, theme: theme)
                Text("One scan for junk, threats, speed and updates.")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(Palette.textSecondary)
            }
        case .scanning:
            VStack(spacing: 16) {
                ProgressRing(theme: theme, fraction: scanFraction, size: 130)
                Text("Checking your Mac…").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
        case .results:
            VStack(spacing: 10) {
                let incomplete = model.status.values.contains(.notScanned)
                HeroTitle(text: model.hasSomethingToRun ? "Your tasks are ready" : incomplete ? "Scan incomplete" : "Nothing needs doing",
                          theme: theme, size: 40)
                Text(incomplete ? "Some modules weren't scanned. Scan again to check everything."
                     : model.hasSomethingToRun ? "Review any card, or run everything at once." : "Your Mac looks great. Check back later.")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.textSecondary)
            }
        case .running:
            VStack(spacing: 16) {
                ProgressRing(theme: theme, fraction: nil, size: 130)
                Text("Taking care of your Mac…").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
        case .done:
            VStack(spacing: 6) {
                SuccessBurst(theme: theme, size: 110)
                let failures = model.itemsNeedingAttention
                HeroTitle(text: failures == 0 ? "Well done!" : "Mostly done", theme: theme, size: 40)
                Text(failures == 0 ? "Your Mac is in great shape."
                     : "\(failures) \(failures == 1 ? "item" : "items") couldn't be handled. Open a card to see why.")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var scanFraction: Double {
        let active = CheckupModel.modules.filter(model.enabled.contains)
        let finished = active.filter { kind in
            switch model.status[kind] { case .waiting?, .working?: false; default: true }
        }
        return active.isEmpty ? 0 : Double(finished.count) / Double(active.count)
    }

    /// Five cards across, as wide as 196pt and no narrower than 128pt.
    static func cardWidth(for available: CGFloat) -> CGFloat {
        let count = CGFloat(CheckupModel.modules.count), spacing: CGFloat = 14
        return min(196, max(128, (available - spacing * (count - 1)) / count))
    }

    private func cards(width: CGFloat, compact: Bool) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(CheckupModel.modules.enumerated()), id: \.element) { index, kind in
                CheckupCard(kind: kind, status: model.status[kind], enabled: model.enabled.contains(kind),
                              editable: model.phase == .intro, index: index, width: width, height: compact ? 196 : 220) {
                    if model.enabled.contains(kind) { model.enabled.remove(kind) } else { model.enabled.insert(kind) }
                } review: {
                    model.review(kind)
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch model.phase {
        case .intro:
            PrimaryButton(title: "Scan", theme: theme, disabled: model.enabled.isEmpty, action: model.scan)
        case .scanning:
            GlassButton(title: "Stop", symbol: "stop.fill", action: model.stop)
        case .results:
            VStack(spacing: 6) {
                RunButton(title: "Run All Tasks", theme: theme, disabled: !model.hasSomethingToRun, action: model.run)
                Button("Start Over", action: model.startOver)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.textTertiary)
            }
        case .running:
            EmptyView()
        case .done:
            PrimaryButton(title: "Done", theme: theme, action: model.startOver)
        }
    }
}

struct CheckupCard: View {
    let kind: ModuleKind
    let status: CheckupModel.CardStatus?
    let enabled: Bool
    let editable: Bool
    var index = 0
    var width: CGFloat = 196
    var height: CGFloat = 220
    let toggle: () -> Void
    let review: () -> Void
    @State private var hovering = false
    @State private var appeared = false

    var body: some View {
        let theme = kind.theme
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                GradientIcon(symbol: theme.symbol, theme: theme, size: width < 160 ? 40 : 48, glowing: isWorking || hovering || isFound)
                Spacer()
                if editable {
                    Toggle("Include \(theme.title) in Checkup", isOn: Binding(get: { enabled }, set: { _ in toggle() }))
                        .toggleStyle(GlowSwitchStyle(theme: theme))
                        .labelsHidden()
                } else {
                    statusIcon
                        .transition(.scale.combined(with: .opacity))
                }
            }
            Text(theme.title).font(.system(size: width < 160 ? 14 : 16, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.85)
            Group {
                switch status {
                case .working(let message)?:
                    Text(message).foregroundStyle(Palette.textSecondary).lineLimit(2).truncationMode(.middle)
                case .found(let text)?:
                    Text(text).font(.system(size: width < 160 ? 13 : 15, weight: .bold, design: .rounded)).foregroundStyle(theme.textGradient)
                        .lineLimit(2).minimumScaleFactor(0.8)
                case .finished(let text)?:
                    Text(text).foregroundStyle(Palette.textSecondary)
                case .failed(let message)?:
                    Text(message).foregroundStyle(Color(hex: 0xFFB830)).lineLimit(2)
                case .clean?:
                    Text("All clear").foregroundStyle(Palette.textSecondary)
                case .off?:
                    Text("Not included").foregroundStyle(Palette.textTertiary)
                case .waiting?:
                    Text("Waiting…").foregroundStyle(Palette.textTertiary)
                case .notScanned?:
                    Text("Not scanned").foregroundStyle(Palette.textTertiary)
                case nil:
                    Text(enabled ? "Included" : "Not included").foregroundStyle(enabled ? Palette.textSecondary : Palette.textTertiary)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .contentTransition(.opacity)
            Spacer(minLength: 0)
            if isFound {
                Button(action: review) {
                    HStack(spacing: 4) {
                        Text("Review")
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.12)))
                    .overlay(Capsule().strokeBorder((theme.colors[2].opacity(0.5)).edge, lineWidth: 1))
                }
                .buttonStyle(PressScale())
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if isWorking {
                MeterBar(fraction: 1, colors: [theme.colors[1], theme.colors[0], theme.colors[2]], height: 3)
                    .opacity(0.8)
                    .shimmering(true)
            }
        }
        .padding(width < 160 ? 14 : 18)
        .frame(width: width, height: height, alignment: .topLeading)
        .background {
            // The card lights up in its module's colour.
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(RadialGradient(colors: [theme.colors[0].opacity(lit ? 0.32 : 0.12), .clear],
                                     center: .topLeading, startRadius: 0, endRadius: 240))
        }
        .glassCard(cornerRadius: 22, highlighted: hovering || isWorking, glow: lit ? theme.glow.opacity(0.6) : nil)
        .shimmering(isWorking)
        // A streak of light crosses the card the moment its part of the checkup finishes.
        .sweepStreak(in: RoundedRectangle(cornerRadius: 22, style: .continuous), trigger: isSettled, enabled: isSettled, onAppear: false)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .hoverTilt()
        .opacity(enabled || editable ? 1 : 0.5)
        .saturation(enabled || editable ? 1 : 0.3)
        .scaleEffect(isWorking ? 1.04 : hovering ? 1.02 : 1)
        .offset(y: appeared ? 0 : 40)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(duration: 0.4), value: isWorking)
        .animation(.spring(duration: 0.4), value: status)
        .onHover { over in withAnimation(.spring(duration: 0.3)) { hovering = over } }
        .onAppear { withAnimation(.spring(duration: 0.6, bounce: 0.25).delay(0.1 + Double(index) * 0.07)) { appeared = true } }
    }

    private var isWorking: Bool { if case .working? = status { true } else { false } }
    private var isFound: Bool { if case .found? = status { true } else { false } }
    private var lit: Bool { isWorking || isFound || hovering }
    /// The card's part of the checkup has an answer: something found, all clear, or done.
    private var isSettled: Bool {
        switch status {
        case .found?, .clean?, .finished?: true
        default: false
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch status {
        case .working?:
            ProgressView().controlSize(.small).tint(.white)
        case .found?:
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 20))
                .foregroundStyle(.white, kind.theme.colors[0])
                .shadow(color: kind.theme.glow, radius: 6)
        case .clean?, .finished?:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 20))
                .foregroundStyle(.white, Color(hex: 0x14E3A1))
                .shadow(color: Color(hex: 0x14E3A1).opacity(0.8), radius: 6)
        case .failed?:
            Image(systemName: "xmark.octagon.fill").font(.system(size: 20)).foregroundStyle(Color(hex: 0xFF3D5A))
        default:
            Image(systemName: "circle.dotted").font(.system(size: 18)).foregroundStyle(Palette.textTertiary)
        }
    }
}

extension CheckupModel.Phase: Equatable {}
