import AppKit
import SwiftUI
import SweepCore
import SweepLens
import SweepScanners

/// Disk Map inside the main window: pick a disk or folder, measure it, explore it, and see what grew
/// since the last scan. Also explains what macOS counts as System Data.
@MainActor
@Observable
public final class DiskMapModel {
    public enum Phase {
        case intro
        case scanning(path: String, progress: ScanProgress)
        case exploring(LensModel)
        case measuringSystemData(String)
        case systemData(SystemDataReport)
        case failed(String)
    }

    public private(set) var phase = Phase.intro
    /// Earlier scans, for "What Grew".
    public let history: SizeHistory
    @ObservationIgnored private var scanner: DiskTreeScanner?
    @ObservationIgnored private var systemDataRun: UUID?
    /// The last folder scanned, so "Try Again" after a failure scans it again.
    @ObservationIgnored private(set) var lastScanURL: URL?

    public init(history: SizeHistory = DiskMapModel.defaultHistory) {
        self.history = history
    }

    /// Snapshots live in Application Support; tests and screenshots keep them in memory.
    public static var defaultHistory: SizeHistory {
        guard !Preferences.isThrowaway,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return SizeHistory(folder: nil) }
        return SizeHistory(folder: support.appendingPathComponent("Sweep/Disk Map History"))
    }

    public func scan(_ url: URL) {
        scanner?.cancel()
        systemDataRun = nil
        lastScanURL = url
        let scanner = DiskTreeScanner()
        self.scanner = scanner
        let path = url.path
        let history = history
        phase = .scanning(path: path, progress: ScanProgress())
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try scanner.scan(path) { progress in
                    Task { @MainActor in self?.progressed(progress, scanner: scanner) }
                }
                // Compare with the previous scan of the same place, then remember this one. Saving keeps
                // `keep` snapshots including the new one, so only the newest `keep - 1` earlier ones stay pickable.
                let root = result.root.path
                let previous = history.latestReadable(for: root)
                let dates = Array((previous?.dates ?? []).prefix(history.keep - 1))
                let baseline = previous?.snapshot
                history.save(SizeSnapshot(of: result.root, date: Date()))
                await self?.finished(result, baseline: baseline, dates: dates, scanner: scanner)
            } catch ScanError.cancelled {
                await self?.reset(scanner: scanner)
            } catch {
                await self?.failed(Self.message(for: error), scanner: scanner)
            }
        }
    }

    public func stop() { scanner?.cancel() }

    /// Scans the folder that failed again; with nothing to retry, goes back to the start.
    public func retry() {
        if let url = lastScanURL { scan(url) } else { startOver() }
    }

    public func startOver() {
        scanner?.cancel()
        scanner = nil
        systemDataRun = nil
        phase = .intro
    }

    /// Shows an existing result (previews).
    public func show(_ result: ScanResult, baseline: SizeSnapshot? = nil) {
        phase = .exploring(LensModel(result: result, baseline: baseline))
    }

    /// When `path` was last scanned, if ever.
    public func lastScan(of path: String) -> Date? { history.dates(for: path).first }

    // MARK: System Data

    public func explainSystemData(locations: ToolLocations) {
        scanner?.cancel()
        let run = UUID()
        systemDataRun = run
        phase = .measuringSystemData("Getting started…")
        Task.detached(priority: .userInitiated) { [weak self] in
            let finder = ToolFinder(environment: .live(), overrides: locations)
            let report = SystemDataScanner(finder: finder).scan { message in
                Task { @MainActor in self?.systemDataProgressed(message, run: run) }
            }
            await self?.systemDataFinished(report, run: run)
        }
    }

    /// Shows an existing report (previews).
    public func show(_ report: SystemDataReport) { phase = .systemData(report) }

    private func systemDataProgressed(_ message: String, run: UUID) {
        guard run == systemDataRun, case .measuringSystemData = phase else { return }
        phase = .measuringSystemData(message)
    }

    private func systemDataFinished(_ report: SystemDataReport, run: UUID) {
        guard run == systemDataRun else { return }
        phase = .systemData(report)
    }

    // MARK: Scan results

    private func progressed(_ progress: ScanProgress, scanner: DiskTreeScanner) {
        guard scanner === self.scanner, case .scanning(let path, _) = phase else { return }
        phase = .scanning(path: path, progress: progress)
    }

    private func finished(_ result: ScanResult, baseline: SizeSnapshot?, dates: [Date], scanner: DiskTreeScanner) {
        guard scanner === self.scanner else { return }
        let lens = LensModel(result: result, baseline: baseline)
        lens.baselineDates = dates
        let history = history
        let root = result.root.path
        lens.loadBaseline = { date in history.snapshot(for: root, at: date) }
        phase = .exploring(lens)
    }

    private func reset(scanner: DiskTreeScanner) {
        guard scanner === self.scanner else { return }
        phase = .intro
    }

    private func failed(_ message: String, scanner: DiskTreeScanner) {
        guard scanner === self.scanner else { return }
        phase = .failed(message)
    }

    /// What the failure screen says: a sentence, plus what to do when privacy protection was the cause.
    nonisolated static func message(for error: any Error) -> String {
        guard let error = error as? ScanError else { return error.localizedDescription }
        let text = error.localizedDescription
        return error.needsFullDiskAccess
            ? text + " Give Sweep Full Disk Access in System Settings → Privacy & Security, then try again." : text
    }
}

struct DiskMapView: View {
    var model: DiskMapModel
    var state: AppState
    private let theme = ModuleKind.diskMap.theme

    var body: some View {
        ZStack {
            LiveBackground(colors: theme.colors)
            Group {
                switch model.phase {
                case .exploring(let lens):
                    LensView(model: lens, newScan: model.startOver)
                case .intro:
                    IntroScreen(theme: theme, buttonTitle: "Scan Macintosh HD", action: {
                        model.scan(URL(fileURLWithPath: "/"))
                    }) {
                        VStack(spacing: 16) {
                            DiskCard(theme: theme, lastScan: model.lastScan(of: "/")) {
                                model.explainSystemData(locations: state.settings.toolLocations)
                            }
                            HStack(spacing: 12) {
                                GlassButton(title: "Home Folder", symbol: "house.fill") {
                                    model.scan(FileManager.default.homeDirectoryForCurrentUser)
                                }
                                GlassButton(title: "Choose Folder…", symbol: "folder.fill") { chooseFolder() }
                            }
                        }
                        .padding(.top, 4)
                    }
                case .scanning(let path, let progress):
                    WorkScreen(theme: theme, title: "Measuring \((path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent)…",
                               update: .init(message: "\(progress.files.formatted()) files · \(ByteFormat.string(progress.allocatedBytes)) · \(progress.currentPath)"),
                               stopTitle: "Stop", stop: model.stop)
                case .measuringSystemData(let message):
                    WorkScreen(theme: theme, title: "Looking into System Data…", update: .init(message: message),
                               stopTitle: "Cancel", stop: model.startOver)
                case .systemData(let report):
                    SystemDataView(report: report, theme: theme, back: model.startOver) { destination in
                        state.open(destination)
                    }
                case .failed(let message):
                    FailedScreen(theme: theme, message: message, retry: model.retry)
                }
            }
            .id(phaseKey)
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)), removal: .opacity))
        }
        .animation(.spring(duration: 0.55), value: phaseKey)
    }

    private var phaseKey: Int {
        switch model.phase {
        case .intro: 0
        case .scanning: 1
        case .exploring: 2
        case .measuringSystemData: 3
        case .systemData: 4
        case .failed: 5
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url { model.scan(url) }
    }
}

/// Startup disk at a glance: used and free space on a gradient bar, when it was last scanned, and the way
/// into "System Data, explained".
struct DiskCard: View {
    let theme: ModuleTheme
    var lastScan: Date?
    var explainSystemData: () -> Void
    @State private var usage: (total: UInt64, free: UInt64)?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.gradient))
                    .shadow(color: theme.glow.opacity(0.5), radius: 8)
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Macintosh HD").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        Spacer()
                        if let usage {
                            Text("\(ByteFormat.string(usage.free)) free of \(ByteFormat.string(usage.total))")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.textSecondary)
                        }
                    }
                    MeterBar(fraction: usage.map { 1 - Double($0.free) / Double(max($0.total, 1)) } ?? 0,
                             colors: [theme.colors[0], theme.colors[1], theme.colors[2]], height: 8)
                }
            }
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.colors[0])
                Text(lastScan.map { "Scanned \($0.formatted(.relative(presentation: .named))) · scan again to see what grew" }
                     ?? "Scan once to start tracking what grows")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(action: explainSystemData) {
                    HStack(spacing: 4) {
                        Text("What's in System Data?")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(hovering ? .white : theme.colors[0].mix(with: .white, by: 0.25))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(theme.colors[0].opacity(hovering ? 0.28 : 0.16)))
                    .fixedSize()
                }
                .buttonStyle(PressScale())
                .focusEffectDisabled()
                .onHover { over in withAnimation(.easeOut(duration: 0.15)) { hovering = over } }
            }
        }
        .padding(16)
        .frame(width: 500)
        .glassCard(cornerRadius: 18)
        .task {
            let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            if let total = values?.volumeTotalCapacity, let free = values?.volumeAvailableCapacityForImportantUsage {
                withAnimation(.smooth(duration: 1)) { usage = (UInt64(total), UInt64(max(free, 0))) }
            }
        }
    }
}
