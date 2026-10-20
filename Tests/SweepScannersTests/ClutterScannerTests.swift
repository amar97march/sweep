import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SweepCore
@testable import SweepScanners

@Suite struct ClutterScannerTests {
    private func options(_ configure: (inout ClutterScanner.Options) -> Void = { _ in }) -> ClutterScanner.Options {
        var options = ClutterScanner.Options()
        configure(&options)
        return options
    }

    @Test func findsExactDuplicatesAndKeepsTheOriginal() throws {
        let mac = try FakeMac()
        let data = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try mac.file("Documents/report.pdf", contents: data)
        try mac.file("Documents/report copy.pdf", contents: data)
        try mac.file("Downloads/report.pdf", contents: data)
        try mac.file("Documents/other.pdf", bytes: 300_000)  // same size, different bytes

        let category = try #require(ClutterScanner(environment: mac.environment()).scan().category("duplicates"))
        let group = try #require(category.groups.first)
        #expect(category.groups.count == 1)
        #expect(group.items.count == 3)
        let kept = group.items.filter { !$0.isSelectedByDefault }.map(\.id)
        #expect(kept == [mac.home + "/Documents/report.pdf"])
        #expect(group.items.allSatisfy { $0.action.paths.count == 1 })
        if case .remove(_, let mode) = group.items[0].action { #expect(mode == .moveToTrash) }
    }

    @Test func largeFilesDifferingOutsideTheSamplesAreNotDuplicates() throws {
        let mac = try FakeMac()
        var first = Data((0..<6_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        var second = first
        second[1_200_000] ^= 0xFF  // between the 1 MiB samples at 0 and 1.5 MB
        try mac.file("Movies/a.mov", contents: first)
        try mac.file("Movies/b.mov", contents: second)
        first[0] = first[0]  // keep `first` mutable for symmetry

        let a = mac.home + "/Movies/a.mov", b = mac.home + "/Movies/b.mov"
        #expect(DuplicateFinder.sampledHash(a, size: 6_000_000) == DuplicateFinder.sampledHash(b, size: 6_000_000))
        #expect(ClutterScanner(environment: mac.environment()).scan().category("duplicates") == nil)
    }

    @Test func filesInsideDocumentPackagesAreLeftAlone() throws {
        let mac = try FakeMac()
        let data = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try mac.file("Documents/Papers/source.pdf", contents: data)
        // The same PDF imported into a Scrivener project and kept in a virtual machine bundle.
        try mac.file("Documents/Novel.scriv/Files/Data/research.pdf", contents: data)
        try mac.file("Documents/VMs/Ubuntu.utm/Data/disk.pdf", contents: data)
        let category = ClutterScanner(environment: mac.environment()).scan().category("duplicates")
        #expect(category == nil)
        #expect(ClutterScanner(environment: mac.environment()).scan().allItems
            .allSatisfy { !$0.action.paths.contains { $0.contains(".scriv/") || $0.contains(".utm/") } })
    }

    @Test func comparingPhotosStopsWhenAsked() {
        let hashes = (0..<50).map { ImageHash(bits: UInt64($0), width: 10, height: 10) }
        #expect(ImageHash.clusters(hashes, threshold: 64, isCancelled: { true }).isEmpty)
        #expect(!ImageHash.clusters(hashes, threshold: 64).isEmpty)
    }

    @Test func hardLinksAreNotDuplicates() throws {
        let mac = try FakeMac()
        let original = try mac.file("Documents/a.bin", bytes: 200_000)
        #expect(link(original, mac.home + "/Documents/b.bin") == 0)
        #expect(ClutterScanner(environment: mac.environment()).scan().category("duplicates") == nil)
    }

    @Test func skipsDependencyFoldersAndPackages() throws {
        let mac = try FakeMac()
        let data = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
        try mac.file("Documents/project/node_modules/lib/a.js", contents: data)
        try mac.file("Documents/project/node_modules/lib2/a.js", contents: data)
        try mac.file("Documents/Thing.app/Contents/Resources/x.bin", contents: data)
        try mac.file("Documents/x.bin", contents: data)
        #expect(ClutterScanner(environment: mac.environment()).scan().category("duplicates") == nil)
    }

    @Test func findsSimilarImagesButSelectsNothing() throws {
        let mac = try FakeMac()
        try writeImage(mac.home + "/Pictures/beach.png", size: 800, pattern: .gradient)
        try writeImage(mac.home + "/Pictures/beach-small.png", size: 300, pattern: .gradient)
        try writeImage(mac.home + "/Pictures/checks.png", size: 800, pattern: .checkerboard)

        let category = try #require(ClutterScanner(environment: mac.environment(),
                                                   options: options { $0.minimumDuplicateSize = 0 }).scan().category("similar"))
        let group = try #require(category.groups.first)
        #expect(category.groups.count == 1)
        #expect(Set(group.items.map { ($0.id as NSString).lastPathComponent }) == ["beach.png", "beach-small.png"])
        #expect(group.items.allSatisfy { !$0.isSelectedByDefault })
        #expect(group.title == "beach.png")  // the larger image is the "best" one
    }

    @Test func largeFilesAreBandedAndNotSelected() throws {
        let mac = try FakeMac()
        try mac.file("Movies/big.mov", bytes: 120_000)
        try mac.file("Documents/small.txt", bytes: 1_000)
        let category = try #require(ClutterScanner(environment: mac.environment(),
                                                   options: options { $0.largeFileSize = 100_000 }).scan().category("large"))
        let items = category.groups.flatMap(\.items)
        #expect(items.map(\.title) == ["big.mov"])
        #expect(!items[0].isSelectedByDefault)
    }

    @Test func oldDownloadsByKind() throws {
        let mac = try FakeMac()
        let installer = try mac.file("Downloads/Tool.dmg", bytes: 30_000)
        let archive = try mac.file("Downloads/photos.zip", bytes: 30_000)
        try mac.file("Downloads/fresh.pdf", bytes: 30_000)
        let old = Date().addingTimeInterval(-90 * 86_400)
        for path in [installer, archive] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
        }
        // "Date added" can't be back-dated in a test, so look 100 days into the future instead.
        var environment = mac.environment()
        environment.now = Date().addingTimeInterval(100 * 86_400)
        let category = try #require(ClutterScanner(environment: environment, roots: []).oldDownloads())
        let titles = Dictionary(uniqueKeysWithValues: category.groups.map { ($0.title, $0.items.map(\.title)) })
        #expect(titles["Installers"] == ["Tool.dmg"])
        #expect(titles["Archives"] == ["photos.zip"])
        #expect(titles["Other downloads"] == ["fresh.pdf"])
    }

    @Test func hashDistance() {
        #expect(ImageHash.distance(0, 0) == 0)
        #expect(ImageHash.distance(0b1011, 0b0001) == 2)
        let hashes = [ImageHash(bits: 0, width: 1, height: 1), ImageHash(bits: 0b11, width: 1, height: 1),
                      ImageHash(bits: .max, width: 1, height: 1)]
        #expect(ImageHash.clusters(hashes, threshold: 3) == [[0, 1]])
    }

    enum Pattern { case gradient, checkerboard }

    private func writeImage(_ path: String, size: Int, pattern: Pattern) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        switch pattern {
        case .gradient:
            for x in 0..<size {
                let value = CGFloat(x) / CGFloat(size)
                context.setFillColor(red: value, green: 0.4, blue: 1 - value, alpha: 1)
                context.fill(CGRect(x: x, y: 0, width: 1, height: size / 2))
                context.setFillColor(red: 1 - value, green: value, blue: 0.2, alpha: 1)
                context.fill(CGRect(x: x, y: size / 2, width: 1, height: size / 2))
            }
        case .checkerboard:
            let cell = size / 8
            for row in 0..<8 {
                for column in 0..<8 {
                    context.setFillColor(gray: (row + column).isMultiple(of: 2) ? 1 : 0, alpha: 1)
                    context.fill(CGRect(x: column * cell, y: row * cell, width: cell, height: cell))
                }
            }
        }
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                                       UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
