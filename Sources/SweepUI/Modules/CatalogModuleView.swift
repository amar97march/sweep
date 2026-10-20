import SwiftUI
import SweepCore

/// Full flow for a list-style module, over its live background.
public struct CatalogModuleView<Intro: View>: View {
    @Bindable var model: CatalogModuleModel
    let introExtra: Intro

    public init(model: CatalogModuleModel, @ViewBuilder introExtra: () -> Intro = { EmptyView() }) {
        self.model = model
        self.introExtra = introExtra()
    }

    public var body: some View {
        ZStack {
            LiveBackground(colors: model.theme.colors)
            Group {
                switch model.phase {
                case .intro:
                    IntroScreen(theme: model.theme, buttonTitle: "Scan", action: model.scan) { introExtra }
                case .scanning:
                    WorkScreen(theme: model.theme, title: "Scanning…", update: model.progress,
                               stopTitle: "Stop", stop: model.stop)
                case .results:
                    CatalogResultsScreen(model: model)
                case .review:
                    CatalogReviewScreen(model: model)
                case .working:
                    WorkScreen(theme: model.theme, title: model.engine.workingMessage, update: model.progress,
                               stopTitle: nil, stop: {})
                case .done:
                    DoneScreen(theme: model.theme, title: model.engine.doneTitle, records: model.records,
                               measuresSize: model.engine.measuresSize,
                               again: model.startOver, review: model.categories.isEmpty ? nil : { model.review() })
                case .failed(let message):
                    FailedScreen(theme: model.theme, message: message, retry: model.scan)
                }
            }
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97)).combined(with: .offset(y: 14)),
                                    removal: .opacity.combined(with: .scale(scale: 1.02))))
            .id(phaseKey)
        }
        .animation(.spring(duration: 0.55, bounce: 0.15), value: phaseKey)
    }

    private var phaseKey: String {
        switch model.phase {
        case .failed: "failed"
        default: "\(model.phase)"
        }
    }
}

/// Big centred title in the module's gradient, with a soft glow.
struct HeroTitle: View {
    let text: String
    let theme: ModuleTheme
    var size: CGFloat = 46
    @State private var streak = 0.0
    @State private var streaking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let title = Text(text).font(.system(size: size, weight: .heavy, design: .rounded))
        title
            .foregroundStyle(theme.textGradient)
            .overlay {
                // Sweep's signature light passes over the letters once as the title appears.
                if streaking { StreakBand(progress: streak, tint: true).mask(title.multilineTextAlignment(.center)) }
            }
            .shadow(color: theme.glow.opacity(0.4), radius: 18)
            .multilineTextAlignment(.center)
            .onAppear {
                guard !reduceMotion else { return }
                streaking = true
                withAnimation(.easeInOut(duration: 1.0).delay(0.35)) { streak = 1 } completion: { streaking = false }
            }
    }
}

struct IntroScreen<Extra: View>: View {
    let theme: ModuleTheme
    let buttonTitle: String
    let action: () -> Void
    @ViewBuilder let extra: Extra
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            HeroBadge(theme: theme)
                .scaleEffect(appeared ? 1 : 0.85)
                .opacity(appeared ? 1 : 0)
            VStack(spacing: 10) {
                HeroTitle(text: theme.title, theme: theme)
                Text(theme.tagline)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            .offset(y: appeared ? 0 : 14)
            .opacity(appeared ? 1 : 0)
            extra
                .opacity(appeared ? 1 : 0)
            PrimaryButton(title: buttonTitle, theme: theme, action: action)
                .padding(.top, 12)
                .scaleEffect(appeared ? 1 : 0.9)
                .opacity(appeared ? 1 : 0)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(.spring(duration: 0.8, bounce: 0.25)) { appeared = true } }
    }
}

struct WorkScreen: View {
    let theme: ModuleTheme
    let title: String
    let update: ProgressSink.Update
    let stopTitle: String?
    let stop: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            ProgressRing(theme: theme, fraction: update.fraction)
            VStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(update.message.isEmpty ? " " : update.message)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.white.opacity(0.05)))
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.2), value: update.message)
            }
            if let stopTitle {
                GlassButton(title: stopTitle, symbol: "stop.fill", action: stop)
            }
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CatalogResultsScreen: View {
    @Bindable var model: CatalogModuleModel
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            if model.selectableCount == 0 {
                HeroBadge(theme: model.theme, size: 120)
                HeroTitle(text: "All clear", theme: model.theme, size: 40)
                Text(model.categories.isEmpty ? "Nothing needs attention here." : "Nothing Sweep can free here. Apps manage the rest.")
                    .font(.system(size: 16)).foregroundStyle(Palette.textSecondary)
                HStack(spacing: 12) {
                    if !model.categories.isEmpty {
                        GlassButton(title: "See Details", symbol: "list.bullet.rectangle") { model.review() }
                    }
                    GlassButton(title: "Scan Again", symbol: "arrow.clockwise", action: model.scan)
                }
            } else {
                VStack(spacing: 6) {
                    Text("FOUND")
                        .font(.system(size: 12, weight: .bold)).tracking(2.5)
                        .foregroundStyle(Palette.textTertiary)
                    if model.engine.measuresSize {
                        AnimatedSize(bytes: model.totalSize, theme: model.theme)
                    } else {
                        Text(model.amount(bytes: 0, count: model.selectableCount))
                            .font(.system(size: 64, weight: .heavy, design: .rounded))
                            .foregroundStyle(model.theme.textGradient)
                            .shadow(color: model.theme.glow.opacity(0.35), radius: 18)
                            .contentTransition(.numericText())
                    }
                    Text("\(model.selected.isEmpty ? "Nothing" : model.amount(bytes: model.selectedSize, count: model.selected.count)) selected")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                        .contentTransition(.numericText())
                        .animation(.smooth, value: model.selected.count)
                }
                .scaleEffect(appeared ? 1 : 0.9)
                .opacity(appeared ? 1 : 0)
                GeometryReader { proxy in
                    let count = CGFloat(max(model.categories.count, 1))
                    let tileWidth = min(210, max(150, (proxy.size.width - 56 - 16 * (count - 1)) / count))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(Array(model.categories.enumerated()), id: \.element.id) { index, category in
                                Button { model.review(category: category.id) } label: {
                                    ResultTile(title: category.title,
                                               value: model.engine.measuresSize && category.size > 0 ? ByteFormat.string(category.size) : "\(category.itemCount)",
                                               detail: "\(category.itemCount.formatted()) \(category.itemCount == 1 ? "item" : "items") · \(category.summary)",
                                               symbol: category.symbol, theme: model.theme, width: tileWidth)
                                }
                                .buttonStyle(.plain)
                                .focusEffectDisabled()
                                .offset(y: appeared ? 0 : 40)
                                .opacity(appeared ? 1 : 0)
                                .animation(.spring(duration: 0.6, bounce: 0.25).delay(0.08 + Double(index) * 0.07), value: appeared)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                        .frame(minWidth: proxy.size.width)
                    }
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03),
                                                 .init(color: .black, location: 0.97), .init(color: .clear, location: 1)],
                                         startPoint: .leading, endPoint: .trailing))
                }
                .frame(height: 266)
                HStack(spacing: 14) {
                    GlassButton(title: "Review Details", symbol: "list.bullet.rectangle") { model.review() }
                    PrimaryButton(title: model.selected.isEmpty ? model.actionVerb
                                    : "\(model.actionVerb) \(model.amount(bytes: model.selectedSize, count: model.selected.count))",
                                  theme: model.theme, disabled: model.selected.isEmpty, isDefaultAction: false, action: model.run)
                }
                Button("Start Over", action: model.startOver)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(.spring(duration: 0.6)) { appeared = true } }
    }
}

/// Glowing sphere that draws a checkmark and throws off a ring of sparks.
struct SuccessBurst: View {
    let theme: ModuleTheme
    var size: CGFloat = 140
    @State private var drawn = false
    @State private var burst = false

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [theme.colors[0].opacity(0.6), .clear], center: .center, startRadius: 0, endRadius: size))
                .frame(width: size * 2, height: size * 2)
                .blur(radius: 10)
                .scaleEffect(burst ? 1 : 0.6)
            Circle()
                .stroke(theme.colors[2].opacity(burst ? 0 : 0.8), lineWidth: 2)
                .frame(width: size, height: size)
                .scaleEffect(burst ? 2.1 : 1)
            ForEach(0..<16, id: \.self) { index in
                let angle = Double(index) / 16 * 2 * .pi
                Capsule()
                    .fill(index.isMultiple(of: 2) ? theme.colors[2] : .white)
                    .frame(width: 10, height: 3)
                    .shadow(color: theme.glow, radius: 4)
                    .rotationEffect(.radians(angle))
                    .offset(x: cos(angle) * (burst ? size * 0.95 : size * 0.4), y: sin(angle) * (burst ? size * 0.95 : size * 0.4))
                    .opacity(burst ? 0 : 1)
            }
            Circle()
                .fill(RadialGradient(colors: [theme.colors[2].mix(with: .white, by: 0.2), theme.colors[0], theme.colors[1].mix(with: .black, by: 0.3)],
                                     center: UnitPoint(x: 0.32, y: 0.26), startRadius: 0, endRadius: size * 0.8))
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder((Color.white.opacity(0.45)).edge, lineWidth: 1.5))
                .overlay(
                    Ellipse()
                        .fill(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom))
                        .frame(width: size * 0.6, height: size * 0.32)
                        .offset(y: -size * 0.24)
                        .blur(radius: 2)
                )
                .shadow(color: theme.glow.opacity(0.8), radius: 30)
                .scaleEffect(drawn ? 1 : 0.7)
            CheckmarkShape()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: size * 0.08, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.44, height: size * 0.33)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        }
        .frame(width: size * 1.8, height: size * 1.8)
        .onAppear {
            withAnimation(.spring(duration: 0.6, bounce: 0.45).delay(0.1)) { drawn = true }
            withAnimation(.easeOut(duration: 1.1).delay(0.35)) { burst = true }
        }
    }
}

struct DoneScreen: View {
    let theme: ModuleTheme
    let title: String
    let records: [ActionRecord]
    var measuresSize = true
    let again: () -> Void
    let review: (() -> Void)?
    @State private var showingLog = false
    @State private var appeared = false

    private var succeeded: [ActionRecord] { records.filter(\.succeeded) }
    private var bytes: UInt64 { succeeded.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            SuccessBurst(theme: theme)
            VStack(spacing: 10) {
                HeroTitle(text: title, theme: theme, size: 40)
                if measuresSize && bytes > 0 {
                    HStack(spacing: 8) {
                        Text(ByteFormat.string(bytes))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.textGradient)
                        Text("cleaned up").font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.textSecondary)
                    }
                } else if !measuresSize && !succeeded.isEmpty {
                    Text("\(succeeded.count) \(succeeded.count == 1 ? "task" : "tasks") done")
                        .font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.textSecondary)
                }
                let failures = records.count - succeeded.count
                if failures > 0 {
                    Label("\(failures) \(failures == 1 ? "item" : "items") could not be handled", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xFFB830))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(Color(hex: 0xFFB830, opacity: 0.12)))
                }
            }
            .offset(y: appeared ? 0 : 16)
            .opacity(appeared ? 1 : 0)
            HStack(spacing: 12) {
                GlassButton(title: "View Log", symbol: "doc.text.magnifyingglass") { showingLog = true }
                    .disabled(records.isEmpty)
                if let review { GlassButton(title: "Review Remaining", symbol: "list.bullet", action: review) }
                PrimaryButton(title: "Done", theme: theme, action: again)
            }
            .padding(.top, 8)
            .opacity(appeared ? 1 : 0)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(.spring(duration: 0.7).delay(0.3)) { appeared = true } }
        .sheet(isPresented: $showingLog) { ActionLogSheet(records: records, theme: theme) }
    }
}

struct FailedScreen: View {
    let theme: ModuleTheme
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 54))
                .foregroundStyle(LinearGradient(colors: [Color(hex: 0xFFE66B), Color(hex: 0xFF8A2A)], startPoint: .top, endPoint: .bottom))
                .shadow(color: Color(hex: 0xFFB830).opacity(0.5), radius: 16)
            Text("Something went wrong").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text(message).foregroundStyle(Palette.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            GlassButton(title: "Try Again", symbol: "arrow.clockwise", action: retry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ActionLogSheet: View {
    let records: [ActionRecord]
    let theme: ModuleTheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Log").font(.system(size: 22, weight: .bold, design: .rounded))
                Spacer()
                Text("\(records.filter(\.succeeded).count) of \(records.count) done")
                    .font(.callout).foregroundStyle(Palette.textSecondary)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(records) { record in
                        HStack(spacing: 10) {
                            let symbol = symbol(record)
                            Image(systemName: symbol.name)
                                .font(.system(size: 16))
                                .foregroundStyle(symbol.color)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.title).lineLimit(1)
                                Text(record.detail).font(.caption).foregroundStyle(Palette.textSecondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if record.bytes > 0 {
                                    Text(ByteFormat.string(record.bytes)).monospacedDigit().foregroundStyle(Palette.textSecondary)
                                }
                                Text(outcomeText(record)).font(.caption)
                                    .foregroundStyle(record.succeeded ? Palette.textSecondary : Color(hex: 0xFFB830))
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.05)))
                    }
                }
            }
            HStack {
                GlassButton(title: "Copy to Clipboard", symbol: "doc.on.doc") {
                    let text = records.map { "\($0.title)\t\(outcomeText($0))\t\($0.detail)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Spacer()
                PrimaryButton(title: "Close", theme: theme) { dismiss() }
            }
        }
        .padding(22)
        .frame(width: 640, height: 480)
        .background(LinearGradient(colors: Palette.base, startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
    }

    private func symbol(_ record: ActionRecord) -> (name: String, color: Color) {
        switch record.outcome {
        case .done: ("checkmark.circle.fill", Color(hex: 0x14E3A1))
        case .skipped: ("minus.circle.fill", Color(hex: 0xFFB830))
        case .failed: ("xmark.octagon.fill", Color(hex: 0xFF3D5A))
        }
    }

    private func outcomeText(_ record: ActionRecord) -> String {
        switch record.outcome {
        case .done(let text): text
        case .skipped(let reason): "Skipped: \(reason)"
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}

struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
