import Foundation

// Front-chain circle packing (Wang et al., "Visualization of large hierarchical data by circle packing",
// CHI 2006) and the smallest circle enclosing a set of circles (Welzl's algorithm). Adapted from
// d3-hierarchy's pack/siblings.js and pack/enclose.js, Copyright 2010-2021 Mike Bostock, ISC License
// (see THIRD_PARTY_NOTICES.md).

public struct Circle: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var r: Double

    public init(x: Double, y: Double, r: Double) {
        self.x = x
        self.y = y
        self.r = r
    }
}

public enum CirclePacker {
    /// Packs circles with the given radii tightly around the origin.
    /// - Returns: The placed circles (same order as `radii`) and the radius of the circle enclosing them,
    ///   which is centered on the origin.
    public static func pack(_ radii: [Double]) -> (circles: [Circle], radius: Double) {
        var circles = radii.map { Circle(x: 0, y: 0, r: $0) }
        let count = circles.count
        if count == 0 { return ([], 0) }
        if count == 1 { return (circles, circles[0].r) }

        circles[0].x = -circles[1].r
        circles[1].x = circles[0].r
        if count == 2 { return (circles, circles[0].r + circles[1].r) }

        place(circles[1], circles[0], &circles[2])

        // The front chain is a circular doubly linked list of indices into `circles`.
        var next = [Int](repeating: 0, count: count)
        var previous = [Int](repeating: 0, count: count)
        var a = 0, b = 1
        next[0] = 1; previous[2] = 1
        next[1] = 2; previous[0] = 2
        next[2] = 0; previous[1] = 0

        var index = 3
        placing: while index < count {
            place(circles[a], circles[b], &circles[index])

            // Look along the front chain, in both directions, for the nearest circle the new one overlaps.
            var j = next[b], k = previous[a]
            var distanceAhead = circles[b].r, distanceBehind = circles[a].r
            repeat {
                if distanceAhead <= distanceBehind {
                    if intersects(circles[j], circles[index]) {
                        b = j
                        next[a] = b; previous[b] = a
                        continue placing  // retry this circle against the shortened chain
                    }
                    distanceAhead += circles[j].r
                    j = next[j]
                } else {
                    if intersects(circles[k], circles[index]) {
                        a = k
                        next[a] = b; previous[b] = a
                        continue placing
                    }
                    distanceBehind += circles[k].r
                    k = previous[k]
                }
            } while j != next[k]

            // No overlap: insert the new circle between a and b.
            previous[index] = a; next[index] = b
            next[a] = index; previous[b] = index
            b = index

            // Continue from the chain pair closest to the centroid.
            var best = score(circles, a, next[a])
            var node = next[index]
            while node != index {
                let candidate = score(circles, node, next[node])
                if candidate < best {
                    a = node
                    best = candidate
                }
                node = next[node]
            }
            b = next[a]
            index += 1
        }

        var chain = [circles[b]]
        var node = next[b]
        while node != b {
            chain.append(circles[node])
            node = next[node]
        }
        let enclosing = enclose(chain)
        for i in circles.indices {
            circles[i].x -= enclosing.x
            circles[i].y -= enclosing.y
        }
        return (circles, enclosing.r)
    }

    /// Smallest circle containing all `circles`.
    public static func enclose(_ circles: [Circle]) -> Circle {
        var shuffled = circles
        var generator = SplitMix64(seed: 0x5EED)
        shuffled.shuffle(using: &generator)  // a fixed seed keeps layouts stable between redraws

        var basis: [Circle] = []
        var enclosing: Circle?
        var i = 0
        while i < shuffled.count {
            let circle = shuffled[i]
            if let current = enclosing, enclosesWeak(current, circle) {
                i += 1
            } else {
                basis = extendBasis(basis, circle)
                enclosing = encloseBasis(basis)
                i = 0
            }
        }
        return enclosing ?? Circle(x: 0, y: 0, r: 0)
    }

    // MARK: - Geometry

    /// Places `c` tangent to both `a` and `b`.
    private static func place(_ b: Circle, _ a: Circle, _ c: inout Circle) {
        let dx = b.x - a.x, dy = b.y - a.y
        let d2 = dx * dx + dy * dy
        guard d2 > 0 else {
            c.x = a.x + c.r
            c.y = a.y
            return
        }
        let a2 = (a.r + c.r) * (a.r + c.r)
        let b2 = (b.r + c.r) * (b.r + c.r)
        if a2 > b2 {
            let x = (d2 + b2 - a2) / (2 * d2)
            let y = (max(0, b2 / d2 - x * x)).squareRoot()
            c.x = b.x - x * dx - y * dy
            c.y = b.y - x * dy + y * dx
        } else {
            let x = (d2 + a2 - b2) / (2 * d2)
            let y = (max(0, a2 / d2 - x * x)).squareRoot()
            c.x = a.x + x * dx - y * dy
            c.y = a.y + x * dy + y * dx
        }
    }

    private static func intersects(_ a: Circle, _ b: Circle) -> Bool {
        let dr = a.r + b.r - 1e-6
        let dx = b.x - a.x, dy = b.y - a.y
        return dr > 0 && dr * dr > dx * dx + dy * dy
    }

    /// Squared distance from the origin to the weighted midpoint of a chain pair.
    private static func score(_ circles: [Circle], _ i: Int, _ j: Int) -> Double {
        let a = circles[i], b = circles[j]
        let sum = a.r + b.r
        let dx = (a.x * b.r + b.x * a.r) / sum
        let dy = (a.y * b.r + b.y * a.r) / sum
        return dx * dx + dy * dy
    }

    private static func extendBasis(_ basis: [Circle], _ p: Circle) -> [Circle] {
        if enclosesWeakAll(p, basis) { return [p] }
        for i in basis.indices {
            if enclosesNot(p, basis[i]), enclosesWeakAll(encloseBasis2(basis[i], p), basis) {
                return [basis[i], p]
            }
        }
        for i in basis.indices.dropLast() {
            for j in (i + 1)..<basis.count {
                if enclosesNot(encloseBasis2(basis[i], basis[j]), p),
                   enclosesNot(encloseBasis2(basis[i], p), basis[j]),
                   enclosesNot(encloseBasis2(basis[j], p), basis[i]),
                   enclosesWeakAll(encloseBasis3(basis[i], basis[j], p), basis) {
                    return [basis[i], basis[j], p]
                }
            }
        }
        // Only reachable through floating-point trouble; a slightly loose circle is acceptable.
        return basis + [p]
    }

    private static func enclosesNot(_ a: Circle, _ b: Circle) -> Bool {
        let dr = a.r - b.r, dx = b.x - a.x, dy = b.y - a.y
        return dr < 0 || dr * dr < dx * dx + dy * dy
    }

    private static func enclosesWeak(_ a: Circle, _ b: Circle) -> Bool {
        let dr = a.r - b.r + max(a.r, b.r, 1) * 1e-9
        let dx = b.x - a.x, dy = b.y - a.y
        return dr > 0 && dr * dr > dx * dx + dy * dy
    }

    private static func enclosesWeakAll(_ a: Circle, _ basis: [Circle]) -> Bool {
        basis.allSatisfy { enclosesWeak(a, $0) }
    }

    private static func encloseBasis(_ basis: [Circle]) -> Circle {
        switch basis.count {
        case 1: return basis[0]
        case 2: return encloseBasis2(basis[0], basis[1])
        case 3: return encloseBasis3(basis[0], basis[1], basis[2])
        default:
            // Fallback for the degenerate path in extendBasis.
            let first = basis.dropFirst().reduce(basis[0]) { encloseBasis2($0, $1) }
            return Circle(x: first.x, y: first.y, r: basis.map { hypot($0.x - first.x, $0.y - first.y) + $0.r }.max() ?? first.r)
        }
    }

    private static func encloseBasis2(_ a: Circle, _ b: Circle) -> Circle {
        let x21 = b.x - a.x, y21 = b.y - a.y, r21 = b.r - a.r
        let length = (x21 * x21 + y21 * y21).squareRoot()
        guard length > 0 else { return a.r >= b.r ? a : b }
        return Circle(
            x: (a.x + b.x + x21 / length * r21) / 2,
            y: (a.y + b.y + y21 / length * r21) / 2,
            r: (length + a.r + b.r) / 2
        )
    }

    private static func encloseBasis3(_ a: Circle, _ b: Circle, _ c: Circle) -> Circle {
        let x1 = a.x, y1 = a.y, r1 = a.r
        let a2 = x1 - b.x, a3 = x1 - c.x
        let b2 = y1 - b.y, b3 = y1 - c.y
        let c2 = b.r - r1, c3 = c.r - r1
        let d1 = x1 * x1 + y1 * y1 - r1 * r1
        let d2 = d1 - b.x * b.x - b.y * b.y + b.r * b.r
        let d3 = d1 - c.x * c.x - c.y * c.y + c.r * c.r
        let ab = a3 * b2 - a2 * b3
        let xa = (b2 * d3 - b3 * d2) / (ab * 2) - x1
        let xb = (b3 * c2 - b2 * c3) / ab
        let ya = (a3 * d2 - a2 * d3) / (ab * 2) - y1
        let yb = (a2 * c3 - a3 * c2) / ab
        let qa = xb * xb + yb * yb - 1
        let qb = 2 * (r1 + xa * xb + ya * yb)
        let qc = xa * xa + ya * ya - r1 * r1
        let r = -(abs(qa) > 1e-6 ? (qb + (qb * qb - 4 * qa * qc).squareRoot()) / (2 * qa) : qc / qb)
        return Circle(x: x1 + xa + xb * r, y: y1 + ya + yb * r, r: r)
    }
}

/// Small deterministic generator for stable layouts.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
