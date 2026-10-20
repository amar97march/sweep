import SwiftUI
import SweepCore
import SweepMonitor
import SweepScanners

/// The security checklist and the drive speed test, for Assistant.
@MainActor
@Observable
public final class SecurityModel {
    public private(set) var checks: [SecurityCheck] = []
    public private(set) var checked: Date?
    public private(set) var isChecking = false
    /// Last speed test of the startup drive.
    public private(set) var speed: DiskSpeed.Result?
    public private(set) var isTestingSpeed = false
    public private(set) var speedError: String?

    public struct Engine: Sendable {
        public var checks: @Sendable () -> [SecurityCheck]
        public var measureSpeed: @Sendable () throws -> DiskSpeed.Result

        public static let live = Engine(checks: { SecurityChecklist().checks() },
                                        measureSpeed: { try DiskSpeed.measure(in: NSTemporaryDirectory()) })
        public static let inert = Engine(checks: { [] }, measureSpeed: { throw DiskSpeed.Failure.cancelled })
    }

    @ObservationIgnored let engine: Engine

    public init(engine: Engine? = nil) {
        self.engine = engine ?? (Preferences.isThrowaway ? .inert : .live)
        speed = Storage.load(DiskSpeed.Result.self, "disk-speed")
    }

    /// Checks again at most every ten minutes.
    func refreshIfDue(now: Date = Date()) async {
        guard !isChecking, now.timeIntervalSince(checked ?? .distantPast) >= 600 else { return }
        isChecking = true
        let engine = engine
        checks = await Task.detached(priority: .utility) { engine.checks() }.value
        checked = now
        isChecking = false
    }

    public var problems: [SecurityCheck] { checks.filter { $0.status >= .warning }.sorted { $0.status > $1.status } }

    public func testSpeed() {
        guard !isTestingSpeed else { return }
        isTestingSpeed = true
        speedError = nil
        let engine = engine
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { Result { try engine.measureSpeed() } }.value
            switch outcome {
            case .success(let result):
                speed = result
                Storage.save(result, "disk-speed")
            case .failure(DiskSpeed.Failure.notEnoughSpace):
                speedError = "Needs about 3 GB of free space."
            case .failure(let error):
                speedError = "The test didn't finish: \(error.localizedDescription)"
            }
            isTestingSpeed = false
        }
    }

    func preview(checks: [SecurityCheck], speed: DiskSpeed.Result?) {
        self.checks = checks
        checked = Date()
        self.speed = speed
    }
}

struct SecurityChecklistCard: View {
    var model: SecurityModel
    private let theme = ModuleKind.protection.theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lock.shield.fill").foregroundStyle(theme.colors[0])
                Text("Security checklist").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                let issues = model.problems.count
                Text(issues == 0 ? "All good" : "\(issues) to look at")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black.opacity(0.75))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Capsule().fill(LinearGradient(colors: issues == 0 ? [Color(hex: 0x9BF56B), Color(hex: 0x14E3A1)]
                                                                             : [Color(hex: 0xFFE66B), Color(hex: 0xFFB830)],
                                                              startPoint: .leading, endPoint: .trailing)))
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)],
                      alignment: .leading, spacing: 12) {
                ForEach(model.checks.sorted { ($0.status > $1.status) }) { check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: Self.symbol(check.status))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Self.color(check.status))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(check.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            Text(check.detail).font(.system(size: 11.5)).foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let fix = check.fix, check.status >= .warning {
                                Button("Open Settings") { NSWorkspace.shared.open(fix) }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(theme.colors[2])
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(18)
        .glassCard(cornerRadius: 20)
    }

    static func symbol(_ status: SecurityCheck.Status) -> String {
        switch status {
        case .good: "checkmark.circle.fill"
        case .unknown: "questionmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .problem: "xmark.octagon.fill"
        }
    }

    static func color(_ status: SecurityCheck.Status) -> Color {
        switch status {
        case .good: Color(hex: 0x9BF56B)
        case .unknown: Palette.textTertiary
        case .warning: Color(hex: 0xFFB830)
        case .problem: Color(hex: 0xFF5E5E)
        }
    }
}

/// "Test Speed" for the startup drive, shown under its health.
struct DriveSpeedRow: View {
    var model: SecurityModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "speedometer").foregroundStyle(Color(hex: 0x14E3A1))
            if let speed = model.speed {
                speedLabel("Write", speed.write)
                speedLabel("Read", speed.read)
                Text("tested " + speed.date.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11)).foregroundStyle(Palette.textTertiary)
            } else {
                Text("How fast is this drive? The test writes and reads a 1 GB file, then deletes it.")
                    .font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
            }
            if let error = model.speedError {
                Text(error).font(.system(size: 11.5)).foregroundStyle(Color(hex: 0xFFB830))
            }
            Spacer()
            if model.isTestingSpeed {
                ProgressView().controlSize(.small)
                Text("Testing…").font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
            } else {
                SmallButton(title: model.speed == nil ? "Test Speed" : "Test Again", prominent: model.speed == nil, action: model.testSpeed)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassCard(cornerRadius: 16)
    }

    private func speedLabel(_ title: String, _ bytesPerSecond: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(Palette.textSecondary)
            Text("\(Int((bytesPerSecond / 1_000_000).rounded()).formatted()) MB/s")
                .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white).monospacedDigit()
        }
    }
}
