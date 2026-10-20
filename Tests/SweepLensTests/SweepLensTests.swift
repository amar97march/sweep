import Foundation
import Testing
@testable import SweepCore
@testable import SweepLens

@Suite struct CirclePackingTests {
    @Test(arguments: [1, 2, 3, 7, 40, 250])
    func circlesNeverOverlapAndStayInsideTheEnclosingCircle(count: Int) {
        var generator = SplitMix64(seed: UInt64(count))
        let radii = (0..<count).map { _ in Double.random(in: 1...100, using: &generator) }
        let (circles, radius) = CirclePacker.pack(radii)

        #expect(circles.count == count)
        #expect(zip(circles, radii).allSatisfy { $0.r == $1 })
        for i in circles.indices {
            #expect(hypot(circles[i].x, circles[i].y) + circles[i].r <= radius * (1 + 1e-6) + 1e-6)
            for j in circles.indices where j > i {
                let distance = hypot(circles[i].x - circles[j].x, circles[i].y - circles[j].y)
                #expect(distance >= circles[i].r + circles[j].r - 1e-6)
            }
        }
        // The packing should be reasonably tight: at least 45% of the enclosing area is used.
        if count > 2 {
            let used = radii.reduce(0) { $0 + $1 * $1 }
            #expect(used / (radius * radius) > 0.45)
        }
    }

    @Test func emptyInputGivesNothing() {
        let (circles, radius) = CirclePacker.pack([])
        #expect(circles.isEmpty)
        #expect(radius == 0)
    }

    @Test func layoutIsDeterministic() {
        let radii = (1...30).map(Double.init)
        #expect(CirclePacker.pack(radii).circles == CirclePacker.pack(radii).circles)
    }
}

@MainActor
@Suite struct LensModelTests {
    /// root/ big/ (a.bin 400 KB, b.bin 100 KB), small/ (c.bin 10 KB), top.bin 50 KB
    private func scanFixture() throws -> (ScanResult, String) {
        let root = URL(fileURLWithPath: try TestSandbox.newFolder("lens"))
        let files = ["big/a.bin": 400_000, "big/b.bin": 100_000, "small/c.bin": 10_000, "top.bin": 50_000]
        for (path, size) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var generator = SystemRandomNumberGenerator()
            try Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &generator) }).write(to: url)
        }
        var options = ScanOptions()
        options.mountPointsOverride = ["/"]
        return (try DiskTreeScanner(options: options).scan(root.path), root.path)
    }

    @Test func itemsAreSortedAndSmallOnesFolded() throws {
        let (result, path) = try scanFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let all = LensItem.items(of: result.root, limit: .max, minimumFraction: 0)
        #expect(all.map(\.name) == ["big", "top.bin", "small"])
        #expect(all.map(\.size) == all.map(\.size).sorted(by: >))

        let folded = LensItem.items(of: result.root, limit: 1, minimumFraction: 0)
        #expect(folded.map(\.name) == ["big", "2 smaller items"])
        #expect(folded.reduce(0) { $0 + $1.size } == result.root.allocatedSize)
    }

    @Test func navigationKeepsHistory() throws {
        let (result, path) = try scanFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let model = LensModel(result: result)
        let big = try #require(model.items.first { $0.name == "big" })

        model.open(big)
        #expect(model.current.name == "big")
        #expect(model.breadcrumb.count == 2)
        #expect(model.canGoBack && !model.canGoForward)

        model.goBack()
        #expect(model.current === result.root)
        #expect(model.canGoForward)
        model.goForward()
        #expect(model.current.name == "big")
        model.goUp()
        #expect(model.current === result.root)
    }

    @Test func bubblesFitTheCanvas() throws {
        let (result, path) = try scanFixture()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let model = LensModel(result: result)
        let size = CGSize(width: 600, height: 400)
        let bubbles = model.bubbles(in: size)

        #expect(bubbles.filter { $0.depth == 0 }.count == 3)
        for bubble in bubbles {
            #expect(bubble.center.x - bubble.radius >= -0.5 && bubble.center.x + bubble.radius <= size.width + 0.5)
            #expect(bubble.center.y - bubble.radius >= -0.5 && bubble.center.y + bubble.radius <= size.height + 0.5)
        }
        let largest = try #require(bubbles.first { $0.item.name == "big" })
        #expect(BubbleLayout.hit(bubbles, at: largest.center)?.item.name == "big")
        #expect(BubbleLayout.hit(bubbles, at: CGPoint(x: 1, y: 1)) == nil)
    }
}

/// Every test file lives under `<package>/.build/test-fixtures`, never elsewhere on the Mac.
enum TestSandbox {
    static let root: String = {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let folder = package.appendingPathComponent(".build/test-fixtures")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let resolved = realpath(folder.path, nil)!
        defer { free(resolved) }
        return String(cString: resolved)
    }()

    static func remove(_ path: String) {
        func unlock(_ folder: String) {
            chmod(folder, 0o755)
            chflags(folder, 0)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                let child = folder + "/" + name
                var info = stat()
                guard lstat(child, &info) == 0 else { continue }
                chflags(child, 0)
                if info.st_mode & S_IFMT == S_IFDIR { unlock(child) }
            }
        }
        unlock(path)
        try? FileManager.default.removeItem(atPath: path)
    }

    static func newFolder(_ prefix: String) throws -> String {
        let path = root + "/" + prefix + "-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}
