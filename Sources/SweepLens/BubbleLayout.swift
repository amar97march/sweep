import Foundation
import SweepCore

public struct Bubble: Identifiable, Sendable {
    public let id: String
    public let item: LensItem
    public let center: CGPoint
    public let radius: Double
    /// 0 for entries of the current folder, 1 for the preview of a folder's own contents.
    public let depth: Int
    /// Index of the top-level bubble this one belongs to, for coloring.
    public let group: Int

    public func contains(_ point: CGPoint) -> Bool {
        let dx = point.x - center.x, dy = point.y - center.y
        return dx * dx + dy * dy <= radius * radius
    }
}

public enum BubbleLayout {
    /// Lays out `items` as packed circles whose areas are proportional to their sizes, centered in `size`.
    /// Large folders also get a preview of their biggest contents drawn inside them.
    public static func layout(
        items: [LensItem], in size: CGSize, padding: Double = 8, previewLimit: Int = 24,
        minimumPreviewRadius: Double = 48
    ) -> [Bubble] {
        let visible = items.filter { $0.size > 0 }
        guard !visible.isEmpty, size.width > 2 * padding, size.height > 2 * padding else { return [] }

        let packed = CirclePacker.pack(visible.map { Double($0.size).squareRoot() })
        guard packed.radius > 0 else { return [] }
        let scale = (min(size.width, size.height) / 2 - padding) / packed.radius
        let origin = CGPoint(x: size.width / 2, y: size.height / 2)
        let gap = 0.97  // leave a hairline between neighbours

        var bubbles: [Bubble] = []
        for (group, (item, circle)) in zip(visible, packed.circles).enumerated() {
            let center = CGPoint(x: origin.x + circle.x * scale, y: origin.y + circle.y * scale)
            let radius = circle.r * scale * gap
            bubbles.append(Bubble(id: item.id, item: item, center: center, radius: radius, depth: 0, group: group))

            guard radius >= minimumPreviewRadius, item.kind == .directory, let directory = item.directory,
                  directory.allocatedSize > 0 else { continue }
            let inner = LensItem.items(of: previewTarget(directory), limit: previewLimit, minimumFraction: 0.01)
                .filter { $0.size > 0 }
            guard inner.count > 1 else { continue }
            let preview = CirclePacker.pack(inner.map { Double($0.size).squareRoot() })
            guard preview.radius > 0 else { continue }
            let innerScale = radius * 0.86 / preview.radius
            for (child, childCircle) in zip(inner, preview.circles) {
                bubbles.append(Bubble(
                    id: item.id + "\u{0}" + child.id,
                    item: child,
                    center: CGPoint(x: center.x + childCircle.x * innerScale, y: center.y + childCircle.y * innerScale),
                    radius: childCircle.r * innerScale * gap,
                    depth: 1,
                    group: group
                ))
            }
        }
        return bubbles
    }

    /// Skips folders that only wrap one other folder (an app bundle's `Contents`, for example) so the
    /// preview shows something useful.
    static func previewTarget(_ directory: DirectoryNode) -> DirectoryNode {
        var target = directory
        while target.children.count == 1, let only = target.children.first, only.status == .scanned,
              only.allocatedSize >= target.allocatedSize - target.allocatedSize / 50 {
            target = only
        }
        return target
    }

    /// The top-level bubble under `point`.
    public static func hit(_ bubbles: [Bubble], at point: CGPoint) -> Bubble? {
        bubbles.first { $0.depth == 0 && $0.contains(point) }
    }
}
