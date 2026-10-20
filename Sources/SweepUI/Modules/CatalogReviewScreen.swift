import SwiftUI
import SweepCore

/// Three glass columns: categories → groups → items, with selection everywhere and the action in the footer.
struct CatalogReviewScreen: View {
    @Bindable var model: CatalogModuleModel
    @Namespace private var selection
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 14) {
            header
            GeometryReader { proxy in
                let widths = Self.columnWidths(for: proxy.size.width)
                HStack(alignment: .top, spacing: 14) {
                    categoryColumn
                        .frame(width: widths.categories)
                        .glassCard(cornerRadius: 20)
                        .offset(x: appeared ? 0 : -30)
                    groupColumn
                        .frame(width: widths.groups)
                        .glassCard(cornerRadius: 20)
                        .offset(x: appeared ? 0 : -15)
                    itemColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .glassCard(cornerRadius: 20)
                }
            }
            .opacity(appeared ? 1 : 0)
            footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 18)
        .onAppear { withAnimation(.spring(duration: 0.55, bounce: 0.2)) { appeared = true } }
    }

    /// Category and group column widths; the item column takes the rest and keeps at least about 40%.
    static func columnWidths(for total: CGFloat) -> (categories: CGFloat, groups: CGFloat) {
        let usable = total - 28
        let categories = min(max(usable * 0.28, 196), 260)
        let groups = min(max(usable * 0.35, 246), 340)
        return (categories, groups)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button { model.showResults() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(0.08)))
                    .overlay(Circle().strokeBorder(Palette.stroke, lineWidth: 1))
            }
            .buttonStyle(PressScale())
            .help("Back to summary")
            .accessibilityLabel("Back to summary")
            GradientIcon(symbol: model.theme.symbol, theme: model.theme, size: 30, glowing: true)
            Text(model.theme.title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            Menu {
                Button("Smart Select") { withAnimation(.snappy) { model.smartSelect() } }
                Button("Select All") { withAnimation(.snappy) { model.selectAll() } }
                Button("Deselect All") { withAnimation(.snappy) { model.deselectAll() } }
            } label: {
                ChipLabel(title: "Select", symbol: "checklist")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            Menu {
                Picker("Sort by", selection: $model.sortOrder) {
                    ForEach(CatalogModuleModel.SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                ChipLabel(title: model.sortOrder.rawValue, symbol: "arrow.up.arrow.down")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            SearchField(text: $model.searchText, tint: model.theme.accent)
        }
    }

    // MARK: Columns

    private var categoryColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnTitle(text: "Categories")
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.categories) { category in
                        let focused = model.currentCategory?.id == category.id
                        HStack(spacing: 10) {
                            GradientCheckbox(state: model.state(of: category), theme: model.theme, label: "Select all in \(category.title)") {
                                withAnimation(.snappy) { model.toggle(category.groups.flatMap(\.items)) }
                            }
                            .opacity(model.canSelect(category.groups.flatMap(\.items)) ? 1 : 0)
                            .disabled(!model.canSelect(category.groups.flatMap(\.items)))
                            GradientIcon(symbol: category.symbol, theme: model.theme, size: 30, glowing: focused)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                Text(model.amount(bytes: category.size, count: category.itemCount))
                                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background { SelectionBackground(active: focused, theme: model.theme, id: "category", namespace: selection) }
                        .contentShape(Rectangle())
                        .rowAction("Show \(category.title)") {
                            withAnimation(.spring(duration: 0.35)) {
                                model.focusedCategory = category.id
                                model.focusedGroup = nil
                            }
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    private var groupColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let category = model.currentCategory {
                ColumnTitle(text: category.title)
                Text(category.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(category.groups) { group in
                            let focused = model.currentGroup?.id == group.id
                            HStack(spacing: 10) {
                                GradientCheckbox(state: model.state(of: group), theme: model.theme, label: "Select all in \(group.title)") {
                                    withAnimation(.snappy) { model.toggle(group.items) }
                                }
                                .opacity(model.canSelect(group.items) ? 1 : 0)
                                .disabled(!model.canSelect(group.items))
                                FileIcon(icon: group.icon, size: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                    // Sizes sit on the right; plain counts join the caption so names keep their room.
                                    let showsSize = model.engine.measuresSize && group.size > 0
                                    let caption = showsSize ? group.subtitle
                                        : [model.amount(bytes: group.size, count: group.items.count), group.subtitle].compactMap { $0 }.joined(separator: " · ")
                                    if let caption {
                                        Text(caption).font(.system(size: 11)).foregroundStyle(Palette.textTertiary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 4)
                                if model.engine.measuresSize && group.size > 0 {
                                    Text(ByteFormat.string(group.size))
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(focused ? .white : Palette.textSecondary)
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background { SelectionBackground(active: focused, theme: model.theme, id: "group", namespace: selection) }
                            .contentShape(Rectangle())
                            .rowAction("Show \(group.title)") { withAnimation(.spring(duration: 0.35)) { model.focusedGroup = group.id } }
                        }
                    }
                    .padding(8)
                }
                .id(category.id)
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.spring(duration: 0.35), value: model.currentCategory?.id)
    }

    private var itemColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let group = model.currentGroup {
                let items = model.visibleItems(of: group)
                HStack(spacing: 10) {
                    FileIcon(icon: group.icon, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                        Text("\(items.count) \(items.count == 1 ? "item" : "items")")
                            .font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    GradientCheckbox(state: model.state(of: group), theme: model.theme, size: 20, label: "Select everything in \(group.title)") {
                        withAnimation(.snappy) { model.toggle(group.items) }
                    }
                    .help("Select or deselect everything in this group")
                    .opacity(model.canSelect(group.items) ? 1 : 0)
                    .disabled(!model.canSelect(group.items))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
                if items.isEmpty {
                    EmptyColumn(symbol: "magnifyingglass", text: "No results for “\(model.searchText)”")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(items) { item in
                                ItemRow(item: item, theme: model.theme, showsSize: model.engine.measuresSize,
                                        selectable: model.isSelectable(item),
                                        isSelected: model.selected.contains(item.id)) {
                                    withAnimation(.snappy) { model.toggle(item: item) }
                                }
                            }
                        }
                        .padding(8)
                    }
                    .id(group.id)
                    .transition(.opacity)
                }
            } else {
                EmptyColumn(symbol: "tray", text: "Nothing here")
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.currentGroup?.id)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(model.selected.count) of \(model.selectableCount) selected")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                if model.engine.measuresSize {
                    Text("Found \(ByteFormat.string(model.totalSize)) in total")
                        .font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer()
            if model.engine.measuresSize {
                AnimatedSize(bytes: model.selectedSize, font: .system(size: 30, weight: .heavy, design: .rounded), theme: model.theme)
            }
            PrimaryButton(title: model.actionVerb, theme: model.theme,
                          disabled: model.selected.isEmpty, isDefaultAction: false, action: model.run)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .glassCard(cornerRadius: 22, glow: model.selected.isEmpty ? nil : model.theme.glow.opacity(0.5))
        .animation(.smooth, value: model.selected.count)
    }
}

// MARK: - Pieces

/// Highlight behind the focused row, gliding between rows.
struct SelectionBackground: View {
    let active: Bool
    let theme: ModuleTheme
    let id: String
    let namespace: Namespace.ID

    var body: some View {
        if active {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [theme.colors[0].opacity(0.38), theme.colors[1].opacity(0.22)],
                                     startPoint: .leading, endPoint: .trailing))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [theme.colors[2].opacity(0.7), .white.opacity(0.08)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                .shadow(color: theme.glow.opacity(0.35), radius: 10)
                .matchedGeometryEffect(id: id, in: namespace)
        }
    }
}

struct ColumnTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold)).tracking(1.6)
            .foregroundStyle(Palette.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }
}

struct EmptyColumn: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(Palette.textTertiary)
            Text(text).font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Frosted capsule used for menu labels in headers.
struct ChipLabel: View {
    let title: String
    let symbol: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            Text(title).font(.system(size: 13, weight: .semibold))
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.6)
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(Capsule().fill(.white.opacity(hovering ? 0.14 : 0.08)))
        .overlay(Capsule().strokeBorder(Palette.stroke, lineWidth: 1))
        .onHover { over in withAnimation(.easeOut(duration: 0.15)) { hovering = over } }
    }
}

struct SearchField: View {
    @Binding var text: String
    var tint: Color = .white
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(focused ? tint : Palette.textTertiary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 130, idealWidth: 210, maxWidth: 210)
        .background(Capsule().fill(.white.opacity(focused ? 0.12 : 0.07)))
        .overlay(Capsule().strokeBorder((focused ? AnyShapeStyle(tint.opacity(0.8).edge) : AnyShapeStyle(Palette.stroke)), lineWidth: 1))
        .shadow(color: focused ? tint.opacity(0.4) : .clear, radius: 8)
        .animation(.easeOut(duration: 0.2), value: focused)
        .animation(.easeOut(duration: 0.15), value: text.isEmpty)
    }
}

struct ItemRow: View {
    let item: ScanItem
    var theme: ModuleTheme = ModuleKind.checkup.theme
    var showsSize = true
    let selectable: Bool
    let isSelected: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            if selectable {
                GradientCheckbox(state: isSelected ? .all : .none, theme: theme, label: item.title, action: toggle)
            } else {
                Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Palette.textTertiary).frame(width: 18)
                    .help("This item can't be selected")
            }
            if let path = item.action.paths.first, path.hasPrefix("/") {
                FileIcon(icon: .file(path), size: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(selectable ? 1 : 0.6))
                    .lineLimit(1).truncationMode(.middle)
                if let detail = detailLine {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Palette.textTertiary).lineLimit(1).truncationMode(.middle)
                }
                if let note = item.note {
                    Text(note).font(.system(size: 11, weight: .medium)).foregroundStyle(Color(hex: 0xFFB830))
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if showsSize && item.size > 0 {
                Text(ByteFormat.string(item.size))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? .white : Palette.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isSelected ? theme.colors[0].opacity(0.12) : .white.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .rowAction(isSelected ? "Deselect \(item.title)" : "Select \(item.title)") { if selectable { toggle() } }
        .onHover { over in withAnimation(.easeOut(duration: 0.12)) { hovering = over } }
        .contextMenu {
            if let path = item.action.paths.first ?? item.subtitle, path.hasPrefix("/") {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                Button("Quick Look") { QuickLook.show(path) }
            }
        }
    }

    /// Subtitle and date on one line, e.g. "~/Movies · 22 Jun 2026".
    private var detailLine: String? {
        let date = item.date?.formatted(.dateTime.year().month(.abbreviated).day())
        let parts = [item.subtitle, date].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum QuickLook {
    @MainActor static func show(_ path: String) {
        // `qlmanage -p` gives a Quick Look preview without hosting a QLPreviewPanel.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
