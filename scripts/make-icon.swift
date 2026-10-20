// Draws the app icon (an original design: glass bubbles on a deep tile, crossed by a sweeping streak of light)
// at every size macOS needs and writes an .iconset folder. Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// Sweep's colours, matching `SweepBrand` in the app: tile top, tile bottom, then the signature main, secondary
/// and highlight.
let palette: [UInt32] = [0x0F3633, 0x041010, 0x1FD8B4, 0x0E9FD8, 0xA8F5C8]

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func mix(_ hex: UInt32, white amount: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255, g = CGFloat((hex >> 8) & 0xFF) / 255, b = CGFloat(hex & 0xFF) / 255
    return CGColor(srgbRed: r + (1 - r) * amount, green: g + (1 - g) * amount, blue: b + (1 - b) * amount, alpha: alpha)
}

/// An original design: glass bubbles (Disk Map) on a deep tile, crossed by a sweeping streak of light.
func drawIcon(pixels: Int) -> CGImage {
    let size = CGFloat(pixels)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: the tile is ~80% of the canvas, with a soft shadow below.
    let inset = size * 0.1
    let tile = CGRect(x: inset, y: inset * 1.15, width: size - inset * 2, height: size - inset * 2)
    let corner = tile.width * 0.225
    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)
    /// A point given in tile units from the top left.
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tile.minX + x * tile.width, y: tile.maxY - y * tile.height) }

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03, color: CGColor(gray: 0, alpha: 0.4))
    context.addPath(tilePath)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    // Deep base, lit from the top left in the signature colour.
    let base = CGGradient(colorsSpace: space, colors: [color(palette[0]), color(palette[1])] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(base, start: point(0.2, 0), end: point(0.8, 1), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let light = CGGradient(colorsSpace: space, colors: [color(palette[2], 0.45), color(palette[2], 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(light, startCenter: point(0.3, 0.25), startRadius: 0, endCenter: point(0.3, 0.25),
                               endRadius: tile.width * 0.75, options: [])

    // Glass bubbles: (x, y, radius) in tile units, with a palette colour index.
    let bubbles: [(CGFloat, CGFloat, CGFloat, Int)] = [
        (0.43, 0.47, 0.25, 2), (0.73, 0.66, 0.135, 3), (0.71, 0.29, 0.10, 4), (0.27, 0.80, 0.075, 3), (0.86, 0.43, 0.05, 2),
    ]
    for (x, y, r, index) in bubbles {
        let hex = palette[index]
        let center = point(x, y)
        let radius = r * tile.width
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.saveGState()
        context.setShadow(offset: .zero, blur: radius * 0.6, color: color(hex, 0.7))
        context.setFillColor(color(hex, 0.35))
        context.fillEllipse(in: rect)
        context.restoreGState()

        context.saveGState()
        context.addEllipse(in: rect)
        context.clip()
        let body = CGGradient(colorsSpace: space, colors: [mix(hex, white: 0.45), color(hex), mix(hex, white: 0, 0.55)] as CFArray,
                              locations: [0, 0.55, 1])!
        let lightPoint = CGPoint(x: center.x - radius * 0.35, y: center.y + radius * 0.4)
        context.drawRadialGradient(body, startCenter: lightPoint, startRadius: 0, endCenter: center, endRadius: radius * 1.05,
                                   options: [.drawsAfterEndLocation])
        // Gloss across the top.
        let gloss = CGRect(x: center.x - radius * 0.55, y: center.y + radius * 0.22, width: radius * 1.1, height: radius * 0.62)
        context.addEllipse(in: gloss)
        context.clip()
        let shine = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.6), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(shine, start: CGPoint(x: gloss.midX, y: gloss.maxY), end: CGPoint(x: gloss.midX, y: gloss.minY), options: [])
        context.restoreGState()

        context.setStrokeColor(CGColor(gray: 1, alpha: 0.55))
        context.setLineWidth(max(0.6, tile.width * 0.008))
        context.strokeEllipse(in: rect.insetBy(dx: tile.width * 0.004, dy: tile.width * 0.004))
    }

    // The sweep: a comet of light curving up across the tile, thin and faint at its tail, bright at its head.
    let start = point(0.08, 0.86), control = point(0.44, 0.97), end = point(0.88, 0.2)
    func bezier(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x, y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
    }
    /// A ribbon along the curve from `from` to 1, tapering from a hairline to its full width.
    func ribbon(from: CGFloat) -> CGPath {
        let samples = 90
        var left: [CGPoint] = [], right: [CGPoint] = []
        for index in 0...samples {
            let t = from + (1 - from) * CGFloat(index) / CGFloat(samples)
            let p = bezier(t), q = bezier(min(t + 0.001, 1)), o = bezier(max(t - 0.001, 0))
            var dx = q.x - o.x, dy = q.y - o.y
            let length = max(hypot(dx, dy), 0.0001)
            dx /= length; dy /= length
            let half = tile.width * (0.002 + 0.018 * pow(t, 1.5))
            left.append(CGPoint(x: p.x - dy * half, y: p.y + dx * half))
            right.append(CGPoint(x: p.x + dy * half, y: p.y - dx * half))
        }
        let path = CGMutablePath()
        path.addLines(between: left + right.reversed())
        path.closeSubpath()
        return path
    }
    context.saveGState()
    context.setShadow(offset: .zero, blur: tile.width * 0.05, color: color(palette[4], 0.95))
    context.addPath(ribbon(from: 0.5))
    context.setFillColor(color(palette[4], 0.5))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(ribbon(from: 0))
    context.clip()
    let trail = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0), color(palette[4], 0.7), CGColor(gray: 1, alpha: 1)] as CFArray,
                           locations: [0, 0.55, 1])!
    context.drawLinearGradient(trail, start: start, end: end, options: [])
    context.restoreGState()
    // A spark at the head.
    let head = CGRect(x: end.x - tile.width * 0.035, y: end.y - tile.width * 0.035, width: tile.width * 0.07, height: tile.width * 0.07)
    let spark = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 1), color(palette[4], 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(spark, startCenter: CGPoint(x: head.midX, y: head.midY), startRadius: 0,
                               endCenter: CGPoint(x: head.midX, y: head.midY), endRadius: head.width, options: [])

    // A fine light edge around the tile.
    context.addPath(tilePath)
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
    context.setLineWidth(max(0.5, tile.width * 0.006))
    context.strokePath()
    context.restoreGState()
    return context.makeImage()!
}

// Standard iconset contents: 16–512 pt at 1x and 2x.
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let image = NSBitmapImageRep(cgImage: drawIcon(pixels: points * scale))
        try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
print("wrote \(output.path)")
