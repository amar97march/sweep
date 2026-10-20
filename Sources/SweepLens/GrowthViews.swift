import SwiftUI
import SweepCore

/// "What Grew": the places that explain how this folder changed since an earlier scan.
struct GrowthPanel: View {
    @Bindable var model: LensModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.horizontal, 12)
            let growth = model.growth
            if growth.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 30)).foregroundStyle(LensStyle.success)
                    Text("Nothing grew much").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text("No folder or file grew by more than 100 MB since that scan.")
                        .font(.system(size: 12)).foregroundStyle(LensStyle.textSecondary).multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        let largest = Double(growth.map(\.delta).max() ?? 1)
                        ForEach(growth) { item in
                            GrowthRow(growth: item, root: model.result.root.path, fraction: Double(item.delta) / largest) {
                                withAnimation(.spring(duration: 0.45)) {
                                    model.reveal(item.path)
                                    model.showsGrowth = false
                                }
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("What Grew").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Spacer()
                if model.baselineDates.count > 1 {
                    Menu {
                        ForEach(model.baselineDates, id: \.self) { date in
                            Button(date.formatted(date: .abbreviated, time: .shortened)) { model.useBaseline(from: date) }
                        }
                    } label: {
                        Text("Compare with…").font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .tint(LensStyle.accent[0])
                }
            }
            if let baseline = model.baseline {
                Text("Since \(baseline.date.formatted(date: .abbreviated, time: .shortened)) · \(baseline.date.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(LensStyle.textSecondary)
            }
            if let change = model.totalChange {
                HStack(spacing: 6) {
                    ChangeChip(change: .changed(change), prominent: true)
                    Text(change >= 0 ? "more used in this scan" : "less used in this scan")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(LensStyle.textSecondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

struct GrowthRow: View {
    let growth: Growth
    let root: String
    let fraction: Double
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(nsImage: LensIcons.icon(for: growth.path)).resizable().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(growth.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        ChangeChip(change: growth.before == nil ? .new : .changed(growth.delta))
                    }
                    Text(location).font(.system(size: 11)).foregroundStyle(LensStyle.textSecondary)
                        .lineLimit(1).truncationMode(.head)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.07))
                            Capsule().fill(LinearGradient(colors: [LensStyle.warning, LensStyle.danger[0]], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(3, proxy.size.width * min(max(fraction, 0), 1)))
                        }
                    }
                    .frame(height: 3)
                    Text(sizes).font(.system(size: 10.5, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(LensStyle.textSecondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hovering ? 0.06 : 0.02)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { over in withAnimation(.easeOut(duration: 0.12)) { hovering = over } }
        .help("Show in Disk Map")
    }

    /// The folder it's in, relative to the scanned root.
    private var location: String {
        let parent = (growth.path as NSString).deletingLastPathComponent
        if parent == root { return "In the scanned folder" }
        let prefix = root == "/" ? "/" : root + "/"
        return parent.hasPrefix(prefix) ? String(parent.dropFirst(prefix.count)) : parent
    }

    private var sizes: String {
        let now = ByteFormat.string(growth.now)
        guard let before = growth.before else { return "Now \(now) · new, or under 20 MB before" }
        return "Now \(now) · was \(ByteFormat.string(before))"
    }
}

/// "+1.2 GB" in amber for growth, "−800 MB" in green for space freed, or "New".
struct ChangeChip: View {
    let change: LensModel.ItemChange
    var prominent = false

    var body: some View {
        let (text, color) = Self.describe(change)
        Text(text)
            .font(.system(size: prominent ? 12 : 10.5, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .fixedSize()
    }

    static func describe(_ change: LensModel.ItemChange) -> (String, Color) {
        switch change {
        case .new: return ("New", LensStyle.accent[0])
        case .changed(let delta):
            let amount = ByteFormat.string(UInt64(abs(delta)))
            return delta >= 0 ? ("+" + amount, LensStyle.warning) : ("−" + amount, LensStyle.success)
        }
    }
}
