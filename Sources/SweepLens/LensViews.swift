import AppKit
import SwiftUI
import SweepCore
import UniformTypeIdentifiers

/// Disk Map: folder list on the left, bubble chart on the right, navigation on top.
/// Transparent, so it shows whatever background the host draws behind it.
public struct LensView: View {
    @Bindable private var model: LensModel
    private let newScan: (() -> Void)?

    public init(model: LensModel, newScan: (() -> Void)? = nil) {
        self.model = model
        self.newScan = newScan
    }

    public var body: some View {
        VStack(spacing: 14) {
            LensToolbar(model: model, newScan: newScan)
            GeometryReader { proxy in
                HStack(spacing: 14) {
                    Group {
                        if model.showsGrowth && model.baseline != nil {
                            GrowthPanel(model: model).transition(.opacity.combined(with: .offset(x: -12)))
                        } else {
                            LensItemList(model: model).transition(.opacity)
                        }
                    }
                    .frame(width: min(max(proxy.size.width * 0.38, 270), 400))
                    .lensGlass(cornerRadius: 20)
                    .animation(.spring(duration: 0.4), value: model.showsGrowth)
                    BubbleChart(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            RemovalBar(model: model)
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 18)
        .sheet(item: $model.removal) { session in
            RemovalSheet(session: session, model: model)
        }
    }
}

struct LensToolbar: View {
    var model: LensModel
    var newScan: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            LensIconButton(symbol: "chevron.left", help: "Back", disabled: !model.canGoBack) { model.goBack() }
            LensIconButton(symbol: "chevron.right", help: "Forward", disabled: !model.canGoForward) { model.goForward() }
            LensIconButton(symbol: "arrow.up", help: "Enclosing folder", disabled: !model.canGoUp) { model.goUp() }
                .padding(.trailing, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.breadcrumb.enumerated()), id: \.element.id) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right").foregroundStyle(LensStyle.textTertiary)
                        }
                        let isCurrent = node === model.current
                        Button { withAnimation(.spring(duration: 0.45)) { model.navigate(to: node) } } label: {
                            HStack(spacing: 5) {
                                if index == 0 { Image(systemName: "internaldrive.fill").font(.system(size: 11)) }
                                Text(index == 0 ? node.path : node.name).lineLimit(1)
                            }
                            .font(.system(size: 13, weight: isCurrent ? .bold : .medium))
                            .foregroundStyle(isCurrent ? .white : LensStyle.textSecondary)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background {
                                if isCurrent {
                                    Capsule().fill(LinearGradient(colors: [LensStyle.accent[1].opacity(0.45), LensStyle.accent[2].opacity(0.3)],
                                                                  startPoint: .leading, endPoint: .trailing))
                                        .overlay(Capsule().strokeBorder((LensStyle.accent[0].opacity(0.55)).edge, lineWidth: 1))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }

            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(ByteFormat.string(model.current.allocatedSize))
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.white, LensStyle.accent[0]], startPoint: .top, endPoint: .bottom))
                    .contentTransition(.numericText())
                Text("\(model.current.fileCount.formatted()) files")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(LensStyle.textTertiary)
            }
            .monospacedDigit()
            .fixedSize()
            if model.baseline != nil {
                LensCapsuleButton(title: "What Grew", symbol: "chart.line.uptrend.xyaxis", prominent: model.showsGrowth) {
                    model.showsGrowth.toggle()
                }
                .fixedSize()
                .padding(.leading, 6)
                .help("Compare with your scan of \(model.baseline?.date.formatted(date: .abbreviated, time: .omitted) ?? "")")
            }
            if let newScan {
                LensCapsuleButton(title: "New Scan", symbol: "arrow.counterclockwise", action: newScan)
                    .fixedSize()
                    .padding(.leading, model.baseline == nil ? 6 : 0)
            }
        }
    }
}

struct LensItemList: View {
    @Bindable var model: LensModel

    var body: some View {
        let total = max(model.current.allocatedSize, 1)
        let groups = Dictionary(model.items.filter { $0.size > 0 }.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.current.name.isEmpty ? model.current.path : model.current.name)
                    .font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Text("\(model.items.count) items").font(.system(size: 11, weight: .medium)).foregroundStyle(LensStyle.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.items) { item in
                        LensRow(item: item, fraction: Double(item.size) / Double(total), model: model,
                                color: groups[item.id].map { BubbleChart.color(group: $0, item: item) } ?? .gray)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .id(ObjectIdentifier(model.current))
            .transition(.opacity.combined(with: .offset(x: 12)))
        }
        .animation(.spring(duration: 0.4), value: ObjectIdentifier(model.current))
    }
}

/// Context-menu actions shared by the list and the bubble chart.
struct ItemActions: View {
    let item: LensItem
    var model: LensModel

    var body: some View {
        if model.canMark(item) {
            Button(model.isMarked(item) ? "Unmark" : "Mark for Removal") { model.toggleMark(item) }
                .disabled(model.isCoveredByMarkedFolder(item))
        }
        if item.isOpenable { Button("Open in Disk Map") { model.open(item) } }
        if let path = item.path { Button("Reveal in Finder") { Finder.reveal(path) } }
    }
}

struct LensRow: View {
    let item: LensItem
    let fraction: Double
    var model: LensModel
    var color: Color = .blue
    @State private var hovering = false

    var body: some View {
        let covered = model.isCoveredByMarkedFolder(item)
        let selected = model.selection == item.id || model.hovered == item.id
        HStack(spacing: 10) {
            MarkBox(marked: model.isMarked(item) || covered, enabled: model.canMark(item) && !covered) {
                withAnimation(.snappy) { model.toggleMark(item) }
            }
            .opacity(model.canMark(item) ? 1 : 0)
            Group {
                if let path = item.path, item.statusNote == nil {
                    Image(nsImage: LensIcons.icon(for: path, isDirectory: item.kind == .directory)).resizable()
                } else {
                    Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(LensStyle.textSecondary)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        .lineLimit(1).truncationMode(.middle)
                    if let note = item.statusNote {
                        Text(note).font(.system(size: 10, weight: .semibold)).foregroundStyle(LensStyle.warning)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(LensStyle.warning.opacity(0.14)))
                    }
                    Spacer(minLength: 6)
                    if let change = model.change(for: item), Self.isWorthShowing(change) {
                        ChangeChip(change: change)
                    }
                    Text(ByteFormat.string(item.size))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(selected ? .white : LensStyle.textSecondary)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.07))
                        Capsule()
                            .fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(3, proxy.size.width * min(fraction, 1)))
                            .shadow(color: color.opacity(0.6), radius: 3)
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(selected ? color.opacity(0.18) : .white.opacity(hovering ? 0.05 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder((selected ? color.opacity(0.5) : .clear).edge, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if item.isOpenable { withAnimation(.spring(duration: 0.45)) { model.open(item) } } }
        .onTapGesture { model.selection = item.id }
        .onHover { over in
            withAnimation(.easeOut(duration: 0.12)) { hovering = over }
            model.hovered = over ? item.id : (model.hovered == item.id ? nil : model.hovered)
        }
        .contextMenu { ItemActions(item: item, model: model) }
    }

    /// Changes under 50 MB are noise.
    static func isWorthShowing(_ change: LensModel.ItemChange) -> Bool {
        if case .changed(let delta) = change { return abs(delta) >= 50_000_000 }
        return true
    }

    private var symbol: String {
        switch item.kind {
        case .directory: item.statusNote == nil ? "folder.fill" : "folder.badge.questionmark"
        case .file: "doc.fill"
        case .other: "ellipsis.circle.fill"
        }
    }
}

/// Packed-circle chart of the current folder. Double-click a bubble to open it (the map zooms in from that
/// bubble), or the background to go up.
public struct BubbleChart: View {
    @Bindable private var model: LensModel
    private let animated: Bool
    /// Where the next folder change zooms from, and which way.
    @State private var zoomAnchor = UnitPoint.center
    @State private var zoomingIn = true

    /// `animated: false` draws the finished map at once, for rendering to an image.
    public init(model: LensModel, animated: Bool = true) {
        self.model = model
        self.animated = animated
    }

    public var body: some View {
        GeometryReader { proxy in
            let bubbles = model.bubbles(in: proxy.size)
            BubbleCanvas(model: model, bubbles: bubbles, folderSize: model.current.allocatedSize, size: proxy.size, animated: animated)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, coordinateSpace: .local) { point in
                    if let bubble = BubbleLayout.hit(bubbles, at: point) {
                        guard bubble.item.isOpenable else { return }
                        zoomAnchor = UnitPoint(x: bubble.center.x / max(proxy.size.width, 1), y: bubble.center.y / max(proxy.size.height, 1))
                        zoomingIn = true
                        withAnimation(.spring(duration: 0.55, bounce: 0.15)) { model.open(bubble.item) }
                    } else if model.canGoUp {
                        zoomAnchor = .center
                        zoomingIn = false
                        withAnimation(.spring(duration: 0.55, bounce: 0.15)) { model.goUp() }
                    }
                }
                .onTapGesture(count: 1, coordinateSpace: .local) { point in
                    model.selection = BubbleLayout.hit(bubbles, at: point)?.item.id
                }
                .onContinuousHover(coordinateSpace: .local) { phase in
                    if case .active(let point) = phase {
                        let id = BubbleLayout.hit(bubbles, at: point)?.item.id
                        if model.hovered != id { model.hovered = id }
                    } else {
                        model.hovered = nil
                    }
                }
                .contextMenu {
                    if let item = model.item(withID: model.hovered ?? model.selection) {
                        ItemActions(item: item, model: model)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let item = model.item(withID: model.hovered ?? model.selection) {
                        BubbleTooltip(item: item, total: model.current.allocatedSize)
                            .padding(12)
                            .transition(.opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.96, anchor: .bottomLeading)))
                            .id(item.id)
                    }
                }
                .animation(.spring(duration: 0.3), value: model.hovered ?? model.selection)
                .overlay {
                    if bubbles.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "circle.dashed").font(.system(size: 40, weight: .light)).foregroundStyle(LensStyle.textTertiary)
                            Text("Nothing to show").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            Text("This folder is empty or could not be read.").font(.system(size: 13)).foregroundStyle(LensStyle.textSecondary)
                        }
                    }
                }
                .id(ObjectIdentifier(model.current))
                .transition(.asymmetric(
                    insertion: .scale(scale: zoomingIn ? 0.55 : 1.5, anchor: zoomAnchor).combined(with: .opacity),
                    removal: .scale(scale: zoomingIn ? 2.2 : 0.5, anchor: zoomAnchor).combined(with: .opacity)))
        }
        .animation(.spring(duration: 0.55, bounce: 0.15), value: ObjectIdentifier(model.current))
    }

    static func color(group: Int, item: LensItem, depth: Int = 0) -> Color {
        switch item.kind {
        case .other: return Color(white: 0.6)
        case .file where depth == 0: return LensStyle.color(0x9AA4C8)
        default:
            if item.statusNote != nil { return Color(white: 0.55) }
            return LensStyle.bubblePalette[group % LensStyle.bubblePalette.count]
        }
    }
}

/// Draws one folder's bubbles and animates them: they pop in largest first, drift gently, lift under the pointer
/// while the rest dim, show their share of the folder as a ring, ripple when clicked, and marked ones get moving
/// dashes. Everything holds still when the user prefers reduced motion.
struct BubbleCanvas: View {
    var model: LensModel
    let bubbles: [Bubble]
    /// Size of the folder these bubbles belong to. Kept with them, so a folder fading out during a zoom still
    /// shows its own percentages.
    let folderSize: UInt64
    let size: CGSize
    var animated = true
    @State private var start = Date()
    @State private var hoverIn: (id: String?, at: Date) = (nil, .distantPast)
    @State private var hoverOut: (id: String?, at: Date) = (nil, .distantPast)
    @State private var spotlight = Fade()
    @State private var ripple: (id: String, at: Date)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A value easing from one level to another over a fixed time.
    struct Fade {
        var from = 0.0, to = 0.0, at = Date.distantPast
        func value(_ now: Date, duration: Double = 0.28) -> Double {
            let p = min(max(now.timeIntervalSince(at) / duration, 0), 1)
            return from + (to - from) * (1 - pow(1 - p, 3))
        }
    }

    private var still: Bool { !animated || reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 40, paused: still)) { timeline in
            Canvas { context, _ in
                draw(in: &context, now: still ? .distantFuture : timeline.date)
            }
        }
        .onChange(of: model.hovered) { old, new in
            let now = Date()
            hoverOut = (old, now)
            hoverIn = (new, now)
            spotlight = Fade(from: spotlight.value(now), to: new == nil ? 0 : 1, at: now)
        }
        .onChange(of: model.selection) { _, new in
            if let new { ripple = (new, Date()) }
        }
    }

    private static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    private func draw(in context: inout GraphicsContext, now: Date) {
        guard !bubbles.isEmpty else { return }
        let elapsed = now.timeIntervalSince(start)
        let clock = still ? 0 : now.timeIntervalSinceReferenceDate
        let spot = spotlight.value(now)
        let focusIn = min(max(now.timeIntervalSince(hoverIn.at) / 0.28, 0), 1)
        let focusOut = 1 - min(max(now.timeIntervalSince(hoverOut.at) / 0.28, 0), 1)

        // Where each top-level bubble is drawn this frame: popped in, drifting and lifted.
        var placed: [Int: (center: CGPoint, scale: Double, appear: Double, focus: Double)] = [:]
        var origins: [Int: CGPoint] = [:]
        var rank = 0
        for bubble in bubbles where bubble.depth == 0 {
            origins[bubble.group] = bubble.center
            let delay = min(Double(rank) * 0.02, 0.45)
            rank += 1
            let progress = still ? 1 : min(max((elapsed - delay) / 0.5, 0), 1)
            let appear = still ? 1 : Self.easeOutBack(progress)
            let phase = Double(bubble.group) * 1.7
            let drift = still ? .zero : CGPoint(x: sin(clock * 0.55 + phase) * 1.8, y: cos(clock * 0.45 + phase * 1.3) * 1.8)
            let id = bubble.item.id
            let focus = id == hoverIn.id ? focusIn : id == hoverOut.id ? focusOut : 0
            placed[bubble.group] = (CGPoint(x: bubble.center.x + drift.x, y: bubble.center.y + drift.y),
                                    max(appear, 0) * (1 + 0.05 * focus), min(progress * 1.6, 1), focus)
        }

        // A soft pool of light under the cluster, breathing slowly.
        let cluster = bubbles.filter { $0.depth == 0 }.map { hypot($0.center.x - size.width / 2, $0.center.y - size.height / 2) + $0.radius }.max() ?? 0
        let breathe = 1 + 0.03 * sin(clock * 0.8)
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        context.fill(Path(ellipseIn: CGRect(x: middle.x - cluster * 1.15, y: middle.y - cluster * 1.15, width: cluster * 2.3, height: cluster * 2.3)),
                     with: .radialGradient(Gradient(colors: [SweepBrand.signature[0].opacity(0.16 * breathe), .clear]),
                                           center: middle, startRadius: 0, endRadius: cluster * 1.15 * breathe))
        // A dashed orbit around the map, turning very slowly.
        let orbit = cluster + 10
        context.stroke(Path(ellipseIn: CGRect(x: middle.x - orbit, y: middle.y - orbit, width: orbit * 2, height: orbit * 2)),
                       with: .color(.white.opacity(0.07)), style: StrokeStyle(lineWidth: 1, dash: [2, 7], dashPhase: clock * 4))

        for bubble in bubbles {
            guard let parent = placed[bubble.group] else { continue }
            let center: CGPoint
            let radius: Double
            if bubble.depth == 0 {
                center = parent.center
                radius = bubble.radius * parent.scale
            } else {
                let origin = origins[bubble.group] ?? bubble.center
                center = CGPoint(x: parent.center.x + (bubble.center.x - origin.x) * parent.scale,
                                 y: parent.center.y + (bubble.center.y - origin.y) * parent.scale)
                radius = bubble.radius * parent.scale
            }
            guard radius > 0.5 else { continue }
            let focused = bubble.depth == 0 && parent.focus > 0
            let selected = bubble.depth == 0 && bubble.item.id == model.selection
            let dim = focused || selected ? 1 : 1 - 0.38 * spot
            var layer = context
            layer.opacity = parent.appear * dim
            drawBubble(bubble, center: center, radius: radius, focus: parent.focus, selected: selected, clock: clock, in: &layer)
        }

        // Labels on top, faded in with their bubble.
        let previewed = Set(bubbles.filter { $0.depth == 1 }.map(\.group))
        for bubble in bubbles where bubble.depth == 0 && bubble.radius > 26 {
            guard let parent = placed[bubble.group] else { continue }
            let radius = bubble.radius * parent.scale
            let hasPreview = previewed.contains(bubble.group)
            let selected = bubble.item.id == model.selection
            var layer = context
            layer.opacity = parent.appear * (parent.focus > 0 || selected ? 1 : 1 - 0.3 * spot)
            layer.addFilter(.shadow(color: .black.opacity(0.55), radius: 3, y: 1))
            let nameSize = min(16, max(10, radius / 6))
            let name = Text(truncated(bubble.item.name, radius: radius))
                .font(.system(size: nameSize, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            let share = Double(bubble.item.size) / Double(max(folderSize, 1))
            let detail = radius > 58 ? "\(ByteFormat.string(bubble.item.size)) · \(Self.percent(share))" : ByteFormat.string(bubble.item.size)
            let size = Text(detail)
                .font(.system(size: min(13, max(9, radius / 7)), weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
            // Folders with a preview get their label near the top edge so the contents stay visible.
            var y = hasPreview ? parent.center.y - radius * 0.78 : parent.center.y - 7
            if !hasPreview && radius > 64 {
                let symbol = Text(Image(systemName: Self.symbol(bubble.item)))
                    .font(.system(size: min(22, radius / 4.5), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                layer.draw(symbol, at: CGPoint(x: parent.center.x, y: y - nameSize - 8))
                y += 4
            }
            layer.draw(name, at: CGPoint(x: parent.center.x, y: y))
            layer.draw(size, at: CGPoint(x: parent.center.x, y: y + max(13, nameSize + 1)))
        }
        for bubble in bubbles where bubble.depth == 1 && bubble.radius > 34 {
            guard let parent = placed[bubble.group], let origin = origins[bubble.group] else { continue }
            let center = CGPoint(x: parent.center.x + (bubble.center.x - origin.x) * parent.scale,
                                 y: parent.center.y + (bubble.center.y - origin.y) * parent.scale)
            var layer = context
            layer.opacity = parent.appear * (parent.focus > 0 ? 1 : 1 - 0.3 * spot)
            let name = Text(truncated(bubble.item.name, radius: bubble.radius))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
            layer.draw(name, at: center)
        }
    }

    private func drawBubble(_ bubble: Bubble, center: CGPoint, radius: Double, focus: Double, selected: Bool, clock: Double,
                            in context: inout GraphicsContext) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let shape = Path(ellipseIn: rect)
        let color = BubbleChart.color(group: bubble.group, item: bubble.item, depth: bubble.depth)
        let light = CGPoint(x: rect.minX + rect.width * 0.32, y: rect.minY + rect.height * 0.26)
        guard bubble.depth == 0 else {
            context.fill(shape, with: .radialGradient(
                Gradient(colors: [color.mix(white: 0.3).opacity(0.6), color.opacity(0.3)]),
                center: light, startRadius: 0, endRadius: radius * 1.5))
            context.stroke(shape, with: .color(.white.opacity(0.2)), lineWidth: 0.7)
            if radius > 12 { highlight(rect, strength: 0.22, in: &context) }
            return
        }
        let lift = max(focus, selected ? 0.6 : 0)
        if lift > 0 {
            // Glow behind the focused bubble.
            var glow = context
            glow.addFilter(.shadow(color: color.opacity(0.9 * lift), radius: 20))
            glow.fill(shape, with: .color(color.opacity(0.3 * lift)))
        }
        // Glass body: lit from the top left, deepening toward the rim.
        context.fill(shape, with: .radialGradient(
            Gradient(colors: [color.mix(white: 0.18).opacity(0.62 + 0.2 * lift), color.opacity(0.36 + 0.15 * lift), color.opacity(0.12)]),
            center: light, startRadius: 0, endRadius: radius * 1.65))
        // Shade along the bottom edge for depth.
        context.fill(shape, with: .radialGradient(
            Gradient(colors: [.clear, .black.opacity(0.18)]),
            center: CGPoint(x: center.x - radius * 0.2, y: center.y - radius * 0.3), startRadius: radius * 0.7, endRadius: radius * 1.35))
        if radius > 14 { highlight(rect, strength: 0.32 + 0.12 * lift, in: &context) }
        context.stroke(shape, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.55 + 0.4 * lift), color.opacity(0.45 + 0.4 * lift), .white.opacity(0.08)]),
            startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)),
            lineWidth: 1 + lift)

        if model.isMarked(bubble.item) || model.isCoveredByMarkedFolder(bubble.item) {
            context.fill(shape, with: .color(LensStyle.danger[0].opacity(0.2)))
            context.stroke(Path(ellipseIn: rect.insetBy(dx: 2, dy: 2)), with: .color(LensStyle.danger[0]),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [7, 5], dashPhase: -clock * 16))
        }

        // The bubble's share of this folder, as a ring that draws itself around it.
        let ring = max(focus, selected ? 1 : 0)
        if ring > 0 {
            let share = Double(bubble.item.size) / Double(max(folderSize, 1))
            let orbit = radius + 6
            let track = Path(ellipseIn: CGRect(x: center.x - orbit, y: center.y - orbit, width: orbit * 2, height: orbit * 2))
            context.stroke(track, with: .color(.white.opacity(0.12 * ring)), lineWidth: 3)
            var arc = Path()
            arc.addArc(center: center, radius: orbit, startAngle: .degrees(-90),
                       endAngle: .degrees(-90 + 360 * max(share, 0.01) * ring), clockwise: false)
            var glow = context
            glow.addFilter(.shadow(color: color.opacity(0.9 * ring), radius: 6))
            glow.stroke(arc, with: .color(.white.opacity(0.92 * ring)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }

        // A ripple when the bubble is clicked.
        if let ripple, ripple.id == bubble.item.id {
            let p = Date().timeIntervalSince(ripple.at) / 0.7
            if p < 1 {
                let r = radius * (1 + 0.45 * p)
                context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                               with: .color(color.mix(white: 0.4).opacity(0.7 * (1 - p))), lineWidth: 2.5 * (1 - p) + 0.5)
            }
        }
    }

    /// A glossy reflection near the top of a bubble.
    private func highlight(_ rect: CGRect, strength: Double, in context: inout GraphicsContext) {
        let gloss = CGRect(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.07,
                           width: rect.width * 0.5, height: rect.height * 0.26)
        context.fill(Path(ellipseIn: gloss), with: .linearGradient(
            Gradient(colors: [.white.opacity(strength), .white.opacity(0)]),
            startPoint: CGPoint(x: gloss.midX, y: gloss.minY), endPoint: CGPoint(x: gloss.midX, y: gloss.maxY)))
    }

    static func percent(_ share: Double) -> String {
        share < 0.01 ? "<1%" : "\(Int((share * 100).rounded()))%"
    }

    static func symbol(_ item: LensItem) -> String {
        switch item.kind {
        case .directory: (item.path ?? "").hasSuffix(".app") ? "app.fill" : "folder.fill"
        case .file: "doc.fill"
        case .other: "ellipsis.circle.fill"
        }
    }

    private func truncated(_ name: String, radius: Double) -> String {
        let limit = max(4, Int(radius / 4.5))
        return name.count <= limit ? name : String(name.prefix(limit - 1)) + "…"
    }
}

extension Color {
    /// Lighten toward white (0 = unchanged, 1 = white).
    func mix(white amount: Double) -> Color {
        let base = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let t = CGFloat(min(max(amount, 0), 1))
        return Color(.sRGB, red: Double(base.redComponent + (1 - base.redComponent) * t),
                     green: Double(base.greenComponent + (1 - base.greenComponent) * t),
                     blue: Double(base.blueComponent + (1 - base.blueComponent) * t),
                     opacity: Double(base.alphaComponent))
    }
}

struct BubbleTooltip: View {
    let item: LensItem
    let total: UInt64
    @State private var shown = 0.0

    var body: some View {
        let share = Double(item.size) / Double(max(total, 1))
        HStack(spacing: 12) {
            ZStack {
                SwiftUI.Circle().stroke(.white.opacity(0.1), lineWidth: 4)
                SwiftUI.Circle().trim(from: 0, to: shown)
                    .stroke(LensStyle.accentGradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(BubbleCanvas.percent(share)).font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: BubbleCanvas.symbol(item)).font(.system(size: 11, weight: .semibold)).foregroundStyle(LensStyle.accent[0])
                    Text(item.name).font(.system(size: 14, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                }
                Text("\(ByteFormat.string(item.size)) of this folder")
                    .font(.system(size: 12)).foregroundStyle(LensStyle.textSecondary)
                if let note = item.statusNote {
                    Text(note).font(.system(size: 12)).foregroundStyle(LensStyle.warning)
                } else if item.isOpenable {
                    Text("Double-click to open").font(.system(size: 11)).foregroundStyle(LensStyle.textTertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .lensGlass(cornerRadius: 14)
        .onAppear { withAnimation(.easeOut(duration: 0.6).delay(0.05)) { shown = max(share, 0.01) } }
    }
}

@MainActor
enum LensIcons {
    private static var cache: [String: NSImage] = [:]

    /// Finder's icon for the item; for one that's no longer on disk, the generic icon for its kind instead of a
    /// blank page.
    static func icon(for path: String, isDirectory: Bool = false) -> NSImage {
        if let icon = cache[path] { return icon }
        let icon: NSImage
        if FileManager.default.fileExists(atPath: path) {
            icon = NSWorkspace.shared.icon(forFile: path)
        } else if isDirectory, (path as NSString).pathExtension.isEmpty {
            icon = NSWorkspace.shared.icon(for: .folder)
        } else {
            icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: (path as NSString).pathExtension) ?? (isDirectory ? .folder : .data))
        }
        cache[path] = icon
        return icon
    }
}

enum Finder {
    @MainActor static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
