import SwiftUI
import SweepCore
import SweepLens

// MARK: - Light streak

/// Sweep's signature: a band of light that crosses a view once, left to right, like a sweep.
struct StreakBand: View {
    /// 0 = just off the leading edge, 1 = just off the trailing edge.
    let progress: Double
    /// Over light text the band tints the letters in Sweep's colours instead of adding light, which wouldn't show.
    var tint = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1), height = proxy.size.height
            let brand = SweepBrand.signature
            let colors = tint
                ? [brand[0].opacity(0), brand[0], brand[2], brand[0], brand[0].opacity(0)]
                : [brand[2].opacity(0), brand[2].opacity(0.45), .white.opacity(0.8), brand[2].opacity(0.45), brand[2].opacity(0)]
            LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                .frame(width: max(70, width * (tint ? 0.22 : 0.3)), height: height * 2.4)
                .rotationEffect(.degrees(18))
                .position(x: -width * 0.35 + width * 1.7 * progress, y: height / 2)
                .blendMode(tint ? .normal : .plusLighter)
        }
        .allowsHitTesting(false)
    }
}

/// Plays a `StreakBand` inside `shape` when the view appears (if `onAppear`) and whenever `trigger` changes,
/// as long as `enabled`.
struct SweepStreak<S: Shape, Trigger: Equatable>: ViewModifier {
    let shape: S
    let trigger: Trigger
    var enabled = true
    var onAppear = true
    var delay = 0.0
    @State private var progress = 0.0
    @State private var playing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if playing { StreakBand(progress: progress).clipShape(shape) }
            }
            .onAppear { if onAppear { play() } }
            .onChange(of: trigger) { play() }
    }

    private func play() {
        guard enabled, !reduceMotion else { return }
        progress = 0
        playing = true
        withAnimation(.easeInOut(duration: 0.9).delay(delay)) {
            progress = 1
        } completion: {
            playing = false
        }
    }
}

extension View {
    /// Sweeps a band of light across the view inside `shape`: on appear, and again whenever `trigger` changes.
    func sweepStreak<S: Shape, T: Equatable>(in shape: S, trigger: T, enabled: Bool = true, onAppear: Bool = true,
                                             delay: Double = 0) -> some View {
        modifier(SweepStreak(shape: shape, trigger: trigger, enabled: enabled, onAppear: onAppear, delay: delay))
    }
}

// MARK: - Hover tilt

/// Tilts a card toward the pointer in 3D, with a soft glare that follows it.
struct HoverTilt: ViewModifier {
    var maxAngle = 6.0
    var cornerRadius: CGFloat = 22
    @State private var point: CGPoint?
    @State private var size = CGSize.zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let offset = point.map { CGPoint(x: ($0.x / max(size.width, 1) - 0.5) * 2, y: ($0.y / max(size.height, 1) - 0.5) * 2) } ?? .zero
        return content
            .overlay {
                if let point {
                    RadialGradient(colors: [.white.opacity(0.14), .clear],
                                   center: UnitPoint(x: point.x / max(size.width, 1), y: point.y / max(size.height, 1)),
                                   startRadius: 0, endRadius: max(size.width, size.height) * 0.7)
                        .blendMode(.plusLighter)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .allowsHitTesting(false)
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .rotation3DEffect(.degrees(reduceMotion ? 0 : maxAngle * hypot(offset.x, offset.y) / sqrt(2)),
                              axis: (x: -offset.y, y: offset.x, z: 0), perspective: 0.7)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): withAnimation(.interactiveSpring(duration: 0.25)) { point = location }
                case .ended: withAnimation(.spring(duration: 0.5, bounce: 0.3)) { point = nil }
                }
            }
    }
}

extension View {
    func hoverTilt(cornerRadius: CGFloat = 22, maxAngle: Double = 6) -> some View {
        modifier(HoverTilt(maxAngle: maxAngle, cornerRadius: cornerRadius))
    }
}

// MARK: - Counting numbers

/// A byte count that rolls through the values in between when it changes.
struct ByteCounter: View, @preconcurrency Animatable {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(ByteFormat.string(UInt64(max(value, 0).rounded())))
    }
}
