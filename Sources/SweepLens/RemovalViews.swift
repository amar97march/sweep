import AppKit
import SwiftUI
import SweepCore

/// Bottom bar of Disk Map: what's marked, and the way into review.
struct RemovalBar: View {
    var model: LensModel

    var body: some View {
        HStack(spacing: 14) {
            if model.marked.isEmpty {
                Image(systemName: "hand.tap.fill").foregroundStyle(LensStyle.accent[0])
                Text("Tick items, or right-click a bubble, to mark them for removal.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LensStyle.textSecondary)
            } else {
                Image(systemName: "checkmark.square.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(LinearGradient(colors: LensStyle.danger, startPoint: .top, endPoint: .bottom))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(model.marked.count) marked")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text(ByteFormat.string(model.markedSize))
                        .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(LensStyle.textSecondary)
                        .contentTransition(.numericText())
                }
                .monospacedDigit()
                LensCapsuleButton(title: "Clear", symbol: "xmark") { withAnimation(.snappy) { model.clearMarks() } }
            }
            Spacer()
            LensCapsuleButton(title: "Review and Remove", symbol: "trash.fill", prominent: true, destructive: true,
                              disabled: model.marked.isEmpty) { model.reviewMarkedItems() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .lensGlass(cornerRadius: 22)
        .animation(.spring(duration: 0.35), value: model.marked.count)
    }
}

/// Sheet that walks through review → removing → results.
public struct RemovalSheet: View {
    @Bindable private var session: RemovalSession
    private let model: LensModel
    @State private var confirmingPermanentDeletion = false

    public init(session: RemovalSession, model: LensModel) {
        self.session = session
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch session.phase {
            case .review:
                review
            case .removing(let done, let total):
                removing(done: done, total: total)
            case .finished(let records):
                RemovalResults(records: records, mode: session.mode) { model.removal = nil }
            }
        }
        .padding(22)
        .frame(width: 660, height: 520)
        .background(LinearGradient(colors: [SweepBrand.base[0], SweepBrand.base[1]], startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review Items Before Removal").font(.system(size: 22, weight: .bold, design: .rounded))
                Text(session.deletesPermanently
                     ? "These items will be deleted immediately."
                     : "These items will be moved to the Trash. You can put them back until you empty it.")
                    .foregroundStyle(LensStyle.textSecondary)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(session.items) { item in
                        ReviewRow(item: item, warning: session.warnings[item.id])
                    }
                }
                .padding(6)
            }
            .lensGlass(cornerRadius: 14)

            Toggle("Delete immediately instead of moving to the Trash (can't be undone)",
                   isOn: $session.deletesPermanently)
                .toggleStyle(DangerCheckboxStyle())

            HStack {
                let count = session.removableItems.count
                Text("\(count) \(count == 1 ? "item" : "items") · \(ByteFormat.string(session.removableSize))")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                if session.warnings.count > 0 {
                    Text("· \(session.warnings.count) will be skipped").foregroundStyle(LensStyle.warning)
                }
                Spacer()
                LensCapsuleButton(title: "Cancel") { model.removal = nil }
                    .keyboardShortcut(.cancelAction)
                LensCapsuleButton(title: session.deletesPermanently ? "Delete Permanently" : "Move to Trash",
                                  symbol: "trash.fill", prominent: true, destructive: true,
                                  disabled: session.removableItems.isEmpty) {
                    if session.deletesPermanently {
                        confirmingPermanentDeletion = true
                    } else {
                        session.start(updating: model)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .confirmationDialog("Delete \(session.removableItems.count) items permanently?",
                            isPresented: $confirmingPermanentDeletion) {
            Button("Delete Permanently", role: .destructive) { session.start(updating: model) }
        } message: {
            Text("\(ByteFormat.string(session.removableSize)) will be deleted. This can't be undone.")
        }
    }

    private func removing(done: Int, total: Int) -> some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                SwiftUI.Circle().stroke(.white.opacity(0.08), lineWidth: 10)
                SwiftUI.Circle()
                    .trim(from: 0, to: Double(done) / Double(max(total, 1)))
                    .stroke(LensStyle.accentGradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: LensStyle.accent[1].opacity(0.8), radius: 10)
                    .animation(.smooth, value: done)
                Text("\(Int(Double(done) / Double(max(total, 1)) * 100))%")
                    .font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            .frame(width: 130, height: 130)
            Text(session.deletesPermanently ? "Deleting \(done) of \(total)…" : "Moving to Trash \(done) of \(total)…")
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct ReviewRow: View {
    let item: LensItem
    let warning: String?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let path = item.path {
                    Image(nsImage: LensIcons.icon(for: path)).resizable()
                } else {
                    Image(systemName: item.kind == .directory ? "folder.fill" : "doc.fill").foregroundStyle(LensStyle.accent[0])
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                Text(item.path ?? "").font(.system(size: 11)).foregroundStyle(LensStyle.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(LensStyle.warning)
                }
            }
            Spacer(minLength: 8)
            Text(ByteFormat.string(item.size))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(LensStyle.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.04)))
        .opacity(warning == nil ? 1 : 0.6)
    }
}

/// What happened to each item, with links to the log file and the Trash.
public struct RemovalResults: View {
    let records: [RemovalRecord]
    let mode: RemovalMode
    let done: () -> Void

    public init(records: [RemovalRecord], mode: RemovalMode, done: @escaping () -> Void) {
        self.records = records
        self.mode = mode
        self.done = done
    }

    private var succeeded: [RemovalRecord] { records.filter(\.succeeded) }
    private var removedBytes: UInt64 { succeeded.reduce(0) { $0 + $1.bytes } }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: succeeded.count == records.count ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white, succeeded.count == records.count ? LensStyle.success : LensStyle.warning)
                    .shadow(color: (succeeded.count == records.count ? LensStyle.success : LensStyle.warning).opacity(0.7), radius: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(detail).foregroundStyle(LensStyle.textSecondary)
                }
            }

            Text("REMOVAL LOG").font(.system(size: 11, weight: .bold)).tracking(1.6).foregroundStyle(LensStyle.textTertiary)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(records) { record in
                        LogRow(record: record)
                    }
                }
                .padding(6)
            }
            .lensGlass(cornerRadius: 14)

            HStack {
                LensCapsuleButton(title: "Show Log File", symbol: "doc.text") { Finder.reveal(RemovalLog.defaultURL.path) }
                if mode == .moveToTrash && !succeeded.isEmpty {
                    LensCapsuleButton(title: "Open Trash", symbol: "trash") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
                    }
                }
                Spacer()
                LensCapsuleButton(title: "Done", prominent: true, action: done).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var headline: String {
        if succeeded.isEmpty { return "Nothing was removed" }
        let items = succeeded.count == 1 ? "1 item" : "\(succeeded.count) items"
        return mode == .moveToTrash ? "Moved \(items) to the Trash" : "Deleted \(items)"
    }

    private var detail: String {
        var parts: [String] = []
        if !succeeded.isEmpty {
            parts.append(mode == .moveToTrash
                ? "\(ByteFormat.string(removedBytes)) will be freed when you empty the Trash."
                : "\(ByteFormat.string(removedBytes)) freed.")
        }
        let failed = records.count - succeeded.count
        if failed > 0 { parts.append("\(failed) could not be removed.") }
        return parts.joined(separator: " ")
    }
}

struct LogRow: View {
    let record: RemovalRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol.name).foregroundStyle(symbol.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text((record.path as NSString).lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(record.path).font(.system(size: 11)).foregroundStyle(LensStyle.textSecondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormat.string(record.bytes)).font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(LensStyle.textSecondary)
                Text(outcome).font(.system(size: 11)).foregroundStyle(record.succeeded ? LensStyle.textSecondary : LensStyle.warning)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.04)))
    }

    private var symbol: (name: String, color: Color) {
        switch record.outcome {
        case .trashed, .deleted: ("checkmark.circle.fill", LensStyle.success)
        case .skipped: ("minus.circle.fill", LensStyle.warning)
        case .failed: ("xmark.octagon.fill", LensStyle.danger[0])
        }
    }

    private var outcome: String {
        switch record.outcome {
        case .trashed: "In Trash"
        case .deleted: "Deleted"
        case .skipped(let reason): "Skipped: \(reason)"
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}
