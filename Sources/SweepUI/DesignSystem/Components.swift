import SwiftUI
import SweepCore

// MARK: - Backgrounds

/// Dark indigo base lit by the module's colours: a slowly drifting mesh gradient, a soft top glow and a faint
/// twinkling starfield. Static when the user prefers reduced motion.
public struct LiveBackground: View {
    let colors: [Color]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(colors: [Color]) { self.colors = colors }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                LinearGradient(colors: Palette.base, startPoint: .top, endPoint: .bottom)
                mesh(t)
                // A glow pooling at the top, like light spilling into the window.
                RadialGradient(colors: [colors[0].opacity(0.45), .clear], center: UnitPoint(x: 0.5 + 0.08 * sin(t * 0.15), y: -0.1),
                               startRadius: 10, endRadius: 620)
                    .blendMode(.screen)
                Starfield(time: t)
                // Darken the bottom so content reads well.
                LinearGradient(colors: [.clear, Color.black.opacity(0.35)], startPoint: .center, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private func mesh(_ t: Double) -> some View {
        if #available(macOS 15.0, *) {
            let dark = Palette.base[1]
            let wave = { (phase: Double, amount: Double) -> Float in Float(amount * sin(t * 0.18 + phase)) }
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5 + wave(0, 0.08), 0], [1, 0],
                    [0, 0.5 + wave(1, 0.1)], [0.5 + wave(2, 0.12), 0.45 + wave(3, 0.1)], [1, 0.5 + wave(4, 0.1)],
                    [0, 1], [0.5 + wave(5, 0.1), 1], [1, 1],
                ],
                colors: [
                    colors[1].opacity(0.55), dark, colors[0].opacity(0.5),
                    dark, colors[0].opacity(0.32), colors[2].opacity(0.22),
                    colors[2].opacity(0.25), dark, colors[1].opacity(0.4),
                ])
            .blendMode(.screen)
        } else {
            Canvas { context, size in
                context.addFilter(.blur(radius: min(size.width, size.height) * 0.14))
                for index in 0..<4 {
                    let phase = Double(index) * 1.9
                    let x = size.width * (0.5 + 0.4 * sin(t * 0.07 + phase))
                    let y = size.height * (0.5 + 0.35 * cos(t * 0.05 + phase))
                    let r = min(size.width, size.height) * 0.3
                    context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                                 with: .color(colors[index % colors.count].opacity(0.35)))
                }
            }
            .blendMode(.screen)
        }
    }
}

struct Starfield: View {
    let time: Double

    var body: some View {
        Canvas { context, size in
            var generator = SeededRandom(seed: 42)
            for _ in 0..<90 {
                let x = generator.next() * size.width, y = generator.next() * size.height * 0.85
                let phase = generator.next() * 6.28, speed = 0.4 + generator.next()
                let radius = 0.5 + generator.next() * 1.1
                let alpha = 0.15 + 0.35 * (0.5 + 0.5 * sin(time * speed + phase))
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                             with: .color(.white.opacity(alpha)))
            }
        }
        .allowsHitTesting(false)
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }
}

// MARK: - Hero

/// The module's emblem: a lit glass sphere with a rotating light ring, orbiting sparks and a breathing halo.
struct HeroBadge: View {
    let theme: ModuleTheme
    var size: CGFloat = 170
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let breathe = 1 + 0.035 * sin(t * 1.6)
            ZStack {
                // Halo
                Circle()
                    .fill(RadialGradient(colors: [theme.colors[0].opacity(0.75), theme.colors[1].opacity(0.25), .clear],
                                         center: .center, startRadius: 0, endRadius: size * 0.95))
                    .frame(width: size * 2, height: size * 2)
                    .blur(radius: 18)
                    .scaleEffect(breathe)
                // Rotating light ring
                Circle()
                    .stroke(AngularGradient(colors: [theme.colors[2], .clear, theme.colors[0], .clear, theme.colors[2]],
                                            center: .center),
                            lineWidth: 2.5)
                    .frame(width: size * 1.32, height: size * 1.32)
                    .rotationEffect(.radians(t * 0.6))
                    .blur(radius: 0.6)
                Circle()
                    .stroke(theme.colors[1].opacity(0.25), lineWidth: 1)
                    .frame(width: size * 1.55, height: size * 1.55)
                // Sphere
                Circle()
                    .fill(RadialGradient(colors: [theme.colors[2].mix(with: .white, by: 0.25), theme.colors[0], theme.colors[1].mix(with: .black, by: 0.35)],
                                         center: UnitPoint(x: 0.32, y: 0.26), startRadius: 0, endRadius: size * 0.78))
                    .frame(width: size, height: size)
                    .shadow(color: theme.colors[0].opacity(0.8), radius: 30)
                    .overlay(
                        Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.0)],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                    )
                    .overlay(
                        // Specular highlight
                        Ellipse()
                            .fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                            .frame(width: size * 0.62, height: size * 0.34)
                            .offset(y: -size * 0.24)
                            .blur(radius: 2)
                    )
                    .scaleEffect(1 + 0.015 * sin(t * 1.6))
                Image(systemName: theme.symbol)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                // Orbiting sparks
                ForEach(0..<5, id: \.self) { index in
                    let angle = t * (0.5 + Double(index) * 0.13) + Double(index) * 1.25
                    let radius = size * (0.74 + 0.07 * Double(index % 3))
                    Circle()
                        .fill(index.isMultiple(of: 2) ? theme.colors[2] : .white)
                        .frame(width: 5 - CGFloat(index % 3), height: 5 - CGFloat(index % 3))
                        .shadow(color: theme.colors[2], radius: 4)
                        .offset(x: cos(angle) * radius, y: sin(angle) * radius * 0.92)
                        .opacity(0.55 + 0.45 * sin(t * 2 + Double(index)))
                }
            }
            .frame(width: size * 1.7, height: size * 1.7)
        }
    }
}

/// Small rounded-square icon with the module gradient and a soft glow.
struct GradientIcon: View {
    let symbol: String
    let theme: ModuleTheme
    var size: CGFloat = 30
    var glowing = false
    /// The symbol bounces each time this changes.
    var bounce = 0

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .symbolEffect(.bounce, value: bounce)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(theme.gradient)
                    .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .strokeBorder((Color.white.opacity(0.35)).edge, lineWidth: 0.8))
            )
            .shadow(color: theme.glow.opacity(glowing ? 0.8 : 0.35), radius: glowing ? 10 : 4)
    }
}

// MARK: - Progress

/// Glowing ring: rotating comet while the amount of work is unknown, filling arc with a leading spark otherwise.
struct ProgressRing: View {
    let theme: ModuleTheme
    /// `nil` = indeterminate.
    let fraction: Double?
    var size: CGFloat = 190
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let progress = fraction.map { max(0.02, min($0, 1)) }
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [theme.colors[0].opacity(0.35), .clear], center: .center,
                                         startRadius: 0, endRadius: size * 0.7))
                    .frame(width: size * 1.4, height: size * 1.4)
                    .blur(radius: 10)
                    .allowsHitTesting(false)
                Circle().stroke(.white.opacity(0.08), lineWidth: 14)
                    .frame(width: size - 14, height: size - 14)
                Circle()
                    .trim(from: 0, to: progress ?? 0.32)
                    .stroke(AngularGradient(colors: [theme.colors[1].opacity(0.1), theme.colors[0], theme.colors[2]], center: .center),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .frame(width: size - 14, height: size - 14)
                    .rotationEffect(.radians(progress == nil ? t * 3.2 : -.pi / 2))
                    .shadow(color: theme.colors[0].opacity(0.9), radius: 12)
                    .animation(.smooth, value: progress)
                VStack(spacing: 2) {
                    if let progress {
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: size * 0.2, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.textGradient)
                            .contentTransition(.numericText())
                    } else {
                        Image(systemName: theme.symbol)
                            .font(.system(size: size * 0.26, weight: .semibold))
                            .foregroundStyle(theme.textGradient)
                            .scaleEffect(1 + 0.05 * sin(t * 3))
                    }
                }
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Buttons

/// Big primary action: glowing gradient capsule with a light sweep.
struct PrimaryButton: View {
    let title: String
    let theme: ModuleTheme
    var disabled = false
    /// Return presses it. Off for buttons that remove or change things, so typing in a field and pressing
    /// Return can never start a removal.
    var isDefaultAction = true
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 2.5, y: 1)
                .padding(.horizontal, 38)
                .padding(.vertical, 14)
                .background(Capsule().fill(theme.buttonGradient))
                .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .top, endPoint: .center)))
                .overlay { if !reduceMotion && !disabled { LightSweep() } }
                .mask(Capsule())
                .overlay(Capsule().strokeBorder((Color.white.opacity(0.45)).edge, lineWidth: 1))
                .compositingGroup()
                .shadow(color: theme.glow.opacity(hovering ? 0.95 : 0.6), radius: hovering ? 26 : 16, y: 6)
                .scaleEffect(hovering ? 1.04 : 1)
        }
        .buttonStyle(PressScale())
        .focusEffectDisabled()
        .opacity(disabled ? 0.4 : 1)
        .disabled(disabled)
        .keyboardShortcut(isDefaultAction ? .defaultAction : nil)
        .onHover { over in withAnimation(.spring(duration: 0.3)) { hovering = over } }
    }
}

/// A band of light that glides across its container every few seconds.
struct LightSweep: View {
    var period = 3.2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            GeometryReader { proxy in
                LinearGradient(colors: [.white.opacity(0), .white.opacity(0.4), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: proxy.size.width * 0.35, height: proxy.size.height)
                    .offset(x: proxy.size.width * (phase * 1.8 - 0.45))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Secondary action: frosted glass capsule.
struct GlassButton: View {
    let title: String
    var symbol: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Capsule().fill(LinearGradient(colors: [.white.opacity(hovering ? 0.2 : 0.13), .white.opacity(hovering ? 0.1 : 0.05)],
                                                      startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().strokeBorder(Palette.stroke, lineWidth: 1))
        }
        .buttonStyle(PressScale())
        .focusEffectDisabled()
        .onHover { over in withAnimation(.easeOut(duration: 0.15)) { hovering = over } }
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

// MARK: - Cards and text

extension View {
    /// Frosted dark glass with a light edge and depth shadow.
    func glassCard(cornerRadius: CGFloat = 22, highlighted: Bool = false, glow: Color? = nil) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: highlighted ? [.white.opacity(0.15), .white.opacity(0.07)] : [.white.opacity(0.10), .white.opacity(0.035)],
                                     startPoint: .top, endPoint: .bottom)))
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Palette.base[1].opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1))
            .shadow(color: (glow ?? .black).opacity(glow == nil ? 0.35 : 0.55), radius: highlighted ? 24 : 16, y: 8)
    }
}

/// A byte count in large gradient type. It counts up from zero when it first appears and rolls to new values.
struct AnimatedSize: View {
    let bytes: UInt64
    var font: Font = .system(size: 64, weight: .heavy, design: .rounded)
    var theme: ModuleTheme?
    @State private var shown = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ByteCounter(value: shown)
            .font(font)
            .monospacedDigit()
            .foregroundStyle(theme?.textGradient ?? LinearGradient(colors: [.white, .white.opacity(0.8)], startPoint: .top, endPoint: .bottom))
            .shadow(color: (theme?.glow ?? .white).opacity(0.35), radius: 18)
            .onAppear {
                if reduceMotion { shown = Double(bytes) } else { withAnimation(.easeOut(duration: 1.1)) { shown = Double(bytes) } }
            }
            .onChange(of: bytes) { _, new in withAnimation(.smooth(duration: 0.5)) { shown = Double(new) } }
            .accessibilityLabel(Text(ByteFormat.string(bytes)))
    }
}

/// Summary card on a results screen: lifts and glows on hover.
struct ResultTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let theme: ModuleTheme
    var width: CGFloat = 210
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                GradientIcon(symbol: symbol, theme: theme, size: 44, glowing: hovering)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.3))
            }
            Spacer(minLength: 6)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
            Text(value).font(.system(size: 28, weight: .heavy, design: .rounded)).monospacedDigit()
                .foregroundStyle(theme.textGradient).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: width, height: 218, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(RadialGradient(colors: [theme.colors[0].opacity(hovering ? 0.35 : 0.16), .clear],
                                     center: .topLeading, startRadius: 0, endRadius: 230))
        }
        .glassCard(highlighted: hovering, glow: hovering ? theme.glow : nil)
        .hoverTilt()
        .scaleEffect(hovering ? 1.03 : 1)
        .offset(y: hovering ? -4 : 0)
        .onHover { over in withAnimation(.spring(duration: 0.3)) { hovering = over } }
    }
}

extension ItemIcon {
    /// The app's own icon when it's there, otherwise a symbol (Finder's blank-document icon would look broken).
    static func app(_ path: String?, fallback: String = "app.dashed") -> ItemIcon {
        guard let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return .symbol(fallback) }
        return .file(path)
    }
}

/// Finder icon for a file or app, cached.
struct FileIcon: View {
    let icon: ItemIcon
    var size: CGFloat = 20

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.62, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(.white.opacity(0.1)))
        case .file(let path):
            Image(nsImage: IconCache.icon(for: path))
                .resizable()
                .frame(width: size, height: size)
        }
    }
}

@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }
}

// MARK: - Selection

public enum SelectionState: Sendable {
    case none, some, all
}

/// Rounded checkbox that fills with the module gradient.
struct GradientCheckbox: View {
    let state: SelectionState
    var theme: ModuleTheme = ModuleKind.checkup.theme
    var size: CGFloat = 18
    /// What VoiceOver says it selects.
    var label = "Select"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(state == .none ? AnyShapeStyle(.white.opacity(0.06)) : AnyShapeStyle(theme.gradient))
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(Color.white.opacity(state == .none ? 0.35 : 0.5).edge, lineWidth: 1.2)
                if state != .none {
                    Image(systemName: state == .all ? "checkmark" : "minus")
                        .font(.system(size: size * 0.62, weight: .heavy))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: size, height: size)
            .shadow(color: state == .none ? .clear : theme.glow.opacity(0.6), radius: 5)
            .animation(.spring(duration: 0.25), value: state)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(state == .all ? "selected" : state == .some ? "partly selected" : "not selected"))
    }
}

extension View {
    /// A row that acts when clicked, reachable from the keyboard too (Tab to it, then Space or Return) and
    /// announced as a button by VoiceOver.
    func rowAction(_ name: String, perform action: @escaping () -> Void) -> some View {
        self.onTapGesture(perform: action)
            .focusable(interactions: .activate)
            .onKeyPress(keys: [.space, .return]) { _ in
                action()
                return .handled
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text(name), action)
    }
}

/// Kept for call sites that show category and group selection.
struct TriStateCheckbox: View {
    let state: SelectionState
    var theme: ModuleTheme = ModuleKind.checkup.theme
    let action: () -> Void

    var body: some View { GradientCheckbox(state: state, theme: theme, action: action) }
}

// MARK: - Meters and switches

/// Thin gradient bar with a glowing leading edge.
struct MeterBar: View {
    let fraction: Double
    var colors: [Color]
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let value = CGFloat(min(max(fraction, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, proxy.size.width * value))
                    .shadow(color: (colors.last ?? .white).opacity(0.7), radius: 5)
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.6), value: fraction)
    }
}

/// Smooth filled line of recent samples (0…1).
struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            func point(_ index: Int) -> CGPoint {
                CGPoint(x: CGFloat(index) * step, y: size.height * (1 - CGFloat(min(max(values[index], 0), 1))) * 0.9 + size.height * 0.05)
            }
            var line = Path()
            line.move(to: point(0))
            for index in 1..<values.count {
                let previous = point(index - 1), current = point(index)
                let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
                line.addQuadCurve(to: mid, control: previous)
            }
            line.addLine(to: point(values.count - 1))
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.addFilter(.shadow(color: color.opacity(0.8), radius: 4))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Switch whose track fills with the module gradient.
struct GlowSwitchStyle: ToggleStyle {
    let theme: ModuleTheme

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? AnyShapeStyle(theme.buttonGradient) : AnyShapeStyle(.white.opacity(0.12)))
                    .overlay(Capsule().strokeBorder((Color.white.opacity(configuration.isOn ? 0.4 : 0.18)).edge, lineWidth: 1))
                    .shadow(color: configuration.isOn ? theme.glow.opacity(0.6) : .clear, radius: 6)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .padding(2.5)
            }
            .frame(width: 38, height: 22)
            .animation(.spring(duration: 0.3, bounce: 0.3), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        // VoiceOver hears a real switch with its label, though the label isn't drawn.
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// Wide glowing pill for Checkup's Run: a gradient capsule with a gloss, a light that sweeps across it, a soft halo
/// that breathes while it's ready, and an arrow chip that slides forward on hover.
struct RunButton: View {
    let title: String
    let theme: ModuleTheme
    var disabled = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || disabled)) { timeline in
                let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let breathe = 0.5 + 0.5 * sin(t * 2.2)
                HStack(spacing: 16) {
                    Text(title)
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .padding(.leading, 34)
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(theme.colors[1].mix(with: .black, by: 0.2))
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(.white))
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        .offset(x: hovering ? 5 : 0)
                        .padding(.trailing, 9)
                }
                .frame(width: 290, height: 60)
                .background(Capsule().fill(theme.buttonGradient))
                .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.32), .clear], startPoint: .top, endPoint: .center)))
                .overlay { if !reduceMotion && !disabled { LightSweep(period: 2.6) } }
                .mask(Capsule())
                .overlay(Capsule().strokeBorder((Color.white.opacity(0.5)).edge, lineWidth: 1))
                .background {
                    // The halo: a second capsule that swells and fades, like the button is breathing.
                    Capsule()
                        .strokeBorder(theme.colors[2].opacity(disabled ? 0 : 0.5 * (1 - breathe)), lineWidth: 2)
                        .padding(-6 - 8 * breathe)
                }
                .compositingGroup()
                .shadow(color: theme.glow.opacity(hovering ? 0.95 : 0.6 + 0.15 * breathe), radius: hovering ? 30 : 18, y: 8)
                .scaleEffect(hovering ? 1.03 : 1)
                .padding(16)
            }
        }
        .buttonStyle(PressScale())
        .focusEffectDisabled()
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { over in withAnimation(.spring(duration: 0.3, bounce: 0.35)) { hovering = over } }
        .accessibilityLabel(Text(title))
    }
}

/// Moving highlight laid over a view while it's busy.
struct Shimmer: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if active && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, .white.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.6)
                            .rotationEffect(.degrees(18))
                            .offset(x: proxy.size.width * (phase * 2.2 - 0.8))
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func shimmering(_ active: Bool) -> some View { modifier(Shimmer(active: active)) }
}
