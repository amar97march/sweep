import SwiftUI
import SweepCore
import SweepMonitor

/// What a drive reports about its own wear and errors.
struct DriveHealthCard: View {
    let drive: DriveHealth
    /// Recent average, once Sweep has readings a day or more apart.
    let writtenPerDay: UInt64?

    private var colors: [Color] {
        switch drive.status {
        case .good: [Color(hex: 0x9BF56B), Color(hex: 0x14E3A1)]
        case .watch: [Color(hex: 0xFFE66B), Color(hex: 0xFFB830)]
        case .failing: [Color(hex: 0xFF8A5C), Color(hex: 0xFF3D5C)]
        }
    }

    private var headline: String {
        switch drive.status {
        case .good: "Healthy"
        case .watch: "Keep an eye on it"
        case .failing: "Back up now"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            ZStack {
                Circle().stroke(.white.opacity(0.1), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: CGFloat(drive.lifeLeft) / 100)
                    .stroke(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: colors[1].opacity(0.6), radius: 6)
                VStack(spacing: 0) {
                    Text("\(drive.lifeLeft)%").font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(.white).monospacedDigit()
                    Text("life left").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(width: 96, height: 96)
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "internaldrive.fill").foregroundStyle(.white.opacity(0.85))
                    Text(drive.isInternal ? "Startup drive" : "External drive").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text(drive.name + (drive.capacity.map { " · " + ByteFormat.string($0) } ?? ""))
                        .font(.system(size: 12)).foregroundStyle(Palette.textTertiary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(headline)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black.opacity(0.75))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)))
                }
                if let problem = drive.problems.first {
                    Text(problem.text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(colors[0])
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("The drive reports no errors, and \(drive.percentageUsed)% of its rated write endurance is used.")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { stats }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 8) { stats }
                }
            }
        }
        .padding(20)
        .glassCard(cornerRadius: 22)
    }

    @ViewBuilder private var stats: some View {
        stat(ByteFormat.string(drive.bytesWritten), writtenPerDay.map { "written · ~\(ByteFormat.string($0))/day lately" } ?? "written in total")
        stat(ByteFormat.string(drive.bytesRead), "read in total")
        stat("\(drive.powerOnHours.formatted()) h", "powered on")
        if let temperature = drive.temperatureCelsius { stat("\(temperature)°C", "temperature") }
        stat("\(drive.unsafeShutdowns.formatted())", "unexpected power-offs")
        stat("\(drive.mediaErrors.formatted())", drive.mediaErrors == 1 ? "data error" : "data errors")
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white).monospacedDigit().lineLimit(1)
            Text(label).font(.system(size: 10.5)).foregroundStyle(Palette.textTertiary).lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// The apps that used the most battery in the last day, with a way into Activity.
struct BatteryUseCard: View {
    let usage: [EnergyHistory.Usage]
    let open: () -> Void
    private let theme = ModuleKind.activity.theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "battery.75percent").foregroundStyle(theme.colors[2])
                Text("Battery use · last 24 hours").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Button("See All", action: open)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.colors[2])
            }
            HStack(spacing: 16) {
                ForEach(usage.prefix(3)) { entry in
                    HStack(spacing: 10) {
                        FileIcon(icon: .app(entry.app.path, fallback: entry.app.key == "system" ? "applelogo" : "app.dashed"), size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.app.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                            Text("\(Int((entry.share * 100).rounded()))% of energy").font(.system(size: 11.5)).foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(18)
        .glassCard(cornerRadius: 20)
    }
}
