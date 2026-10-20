import AppKit
import Foundation
import SwiftUI
import SweepCore
import SweepLens
import UniformTypeIdentifiers

/// Scans a folder and writes the Disk Map chart to a PNG (handy for checking layouts without the app).
func runRender(_ arguments: Arguments, console: Console) throws {
    guard let output = arguments.output else { throw UsageError("render needs --out <file.png>") }
    let result = try scan(arguments, console: console, showProgress: true)

    let written = try MainActor.assumeIsolated {
        let model = LensModel(result: result)
        let chart = VStack(spacing: 0) {
            Text("\(result.root.path) — \(ByteFormat.string(result.root.allocatedSize))")
                .font(.title3.weight(.semibold))
                .padding(10)
            BubbleChart(model: model, animated: false)
        }
        .frame(width: CGFloat(arguments.width), height: CGFloat(arguments.height))
        .background(Color.white)
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: chart)
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw RenderError.drawingFailed }
        let url = URL(fileURLWithPath: output)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw RenderError.unwritable(url.path) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.unwritable(url.path) }
        return "wrote \(url.path) (\(image.width)×\(image.height))"
    }
    console.line(written)
}

enum RenderError: LocalizedError {
    case drawingFailed
    case unwritable(String)

    var errorDescription: String? {
        switch self {
        case .drawingFailed: "Couldn't draw the chart."
        case .unwritable(let path): "Couldn't write a PNG to “\(path)”."
        }
    }
}
