import SwiftUI
import SweepCore
import SweepScanners

/// "System Data, explained": what macOS counts as System Data on this Mac, why it's there, and where to act.
struct SystemDataView: View {
    let report: SystemDataReport
    let theme: ModuleTheme
    let back: () -> Void
    let open: (SystemDataReport.Part.Destination) -> Void
    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    GlassButton(title: "Disk Map", symbol: "chevron.left", action: back)
                    Spacer()
                    Text("Measured \(report.measuredAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.textSecondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HeroTitle(text: "System Data, explained", theme: theme, size: 36)
                    Text("macOS files these under System Data in Storage settings. Here's what they are on this Mac, and what you can do about each.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                summary
                    .offset(y: appeared ? 0 : 16)
                    .opacity(appeared ? 1 : 0)
                VStack(spacing: 12) {
                    ForEach(Array(report.parts.enumerated()), id: \.element.id) { index, part in
                        SystemDataRow(part: part, share: Double(part.bytes) / Double(max(report.total, 1)),
                                      color: Self.color(part.id), open: open)
                            .offset(y: appeared ? 0 : 24)
                            .opacity(appeared ? 1 : 0)
                            .animation(.spring(duration: 0.55, bounce: 0.2).delay(0.1 + Double(index) * 0.05), value: appeared)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    if !report.hasFullDiskAccess { FullDiskAccessNote() }
                    Text("Sizes are measured on this Mac just now. The figure in Storage settings can differ: it also counts system files no app can read.")
                        .font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 40)
            .padding(.bottom, 32)
            .frame(maxWidth: 940)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .onAppear { withAnimation(.spring(duration: 0.6)) { appeared = true } }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(ByteFormat.string(report.total))
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.textGradient)
                    .shadow(color: theme.glow.opacity(0.35), radius: 14)
                Text("in \(report.parts.count) places")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.textSecondary)
                Spacer()
                let reclaimable = report.parts.filter { $0.handling != .automatic }.reduce(UInt64(0)) { $0 + $1.bytes }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ByteFormat.string(reclaimable))
                        .font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text("you can do something about").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.textSecondary)
                }
                .monospacedDigit()
            }
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(report.parts) { part in
                        let width = proxy.size.width * Double(part.bytes) / Double(max(report.total, 1))
                        Rectangle()
                            .fill(LinearGradient(colors: [Self.color(part.id), Self.color(part.id).opacity(0.7)], startPoint: .top, endPoint: .bottom))
                            .frame(width: max(width - 2, 2))
                            .help("\(part.title): \(ByteFormat.string(part.bytes))")
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)
            .shadow(color: theme.glow.opacity(0.25), radius: 8)
        }
        .padding(20)
        .glassCard(cornerRadius: 22)
    }

    static func color(_ id: String) -> Color {
        switch id {
        case "purgeable": Color(hex: 0x5AC8FF)
        case "virtualMemory": Color(hex: 0x8A5CFF)
        case "caches": Color(hex: 0x14E3A1)
        case "logs": Color(hex: 0x9BF56B)
        case "aiModels": Color(hex: 0xE25CFF)
        case "docker": Color(hex: 0x3D8BFF)
        case "developer": Color(hex: 0xFF8A2A)
        case "deviceFiles": Color(hex: 0xFFB830)
        case "appData": Color(hex: 0x2FE0D3)
        default: Color(hex: 0xFF5E7E)
        }
    }
}

struct SystemDataRow: View {
    let part: SystemDataReport.Part
    let share: Double
    let color: Color
    let open: (SystemDataReport.Part.Destination) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: part.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [color, color.mix(with: .black, by: 0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder((Color.white.opacity(0.3)).edge, lineWidth: 0.8))
                .shadow(color: color.opacity(0.45), radius: 8)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(part.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    HandlingBadge(handling: part.handling)
                }
                Text(part.detail)
                    .font(.system(size: 12.5)).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(ByteFormat.string(part.bytes))
                        .font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text(share < 0.01 ? "under 1%" : "\(Int((share * 100).rounded()))% of System Data")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.textSecondary)
                }
                .monospacedDigit()
                if let title = actionTitle {
                    Button { open(part.destination) } label: {
                        HStack(spacing: 5) {
                            Text(title)
                            Image(systemName: "arrow.right").font(.system(size: 9.5, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(color.opacity(hovering ? 0.42 : 0.26)))
                        .overlay(Capsule().strokeBorder((color.opacity(0.6)).edge, lineWidth: 1))
                        .fixedSize()
                    }
                    .buttonStyle(PressScale())
                    .focusEffectDisabled()
                    .onHover { over in withAnimation(.easeOut(duration: 0.15)) { hovering = over } }
                }
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 18)
    }

    private var actionTitle: String? {
        switch part.destination {
        case .cleanup: "Review in Junk Files"
        case .diskMap: "Open in Disk Map"
        case .performance: "Thin Snapshots"
        case .openApp(let path): "Open \(((path as NSString).lastPathComponent as NSString).deletingPathExtension)"
        case .none: nil
        }
    }
}

/// Who looks after a part of System Data, as a small coloured label.
struct HandlingBadge: View {
    let handling: SystemDataReport.Part.Handling

    var body: some View {
        let (text, color): (String, Color) = switch handling {
        case .automatic: ("Managed by macOS", Color(hex: 0x5AC8FF))
        case .safe: ("Safe to clean", Color(hex: 0x14E3A1))
        case .review: ("Review first", Color(hex: 0xFFB830))
        }
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2.5)
            .background(Capsule().fill(color.opacity(0.14)))
            .fixedSize()
    }
}
