// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sweep",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SweepCore", targets: ["SweepCore"]),
        .library(name: "SweepScanners", targets: ["SweepScanners"]),
        .library(name: "SweepMonitor", targets: ["SweepMonitor"]),
        .library(name: "SweepLens", targets: ["SweepLens"]),
        .library(name: "SweepUI", targets: ["SweepUI"]),
        .executable(name: "sweep", targets: ["sweep"]),
        .executable(name: "SweepApp", targets: ["SweepApp"]),
    ],
    targets: [
        // File-system engine, removal, shared result model. No UI.
        .target(name: "SweepCore"),
        // What each module looks for: junk, clutter, apps, maintenance, privacy, cloud. No UI.
        .target(name: "SweepScanners", dependencies: ["SweepCore", "SweepNative"]),
        // C helpers for system interfaces Swift can't call directly (the NVMe health log).
        .target(name: "SweepNative", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        // CPU, memory, disk, battery, network, drive health, energy and camera/microphone readings.
        .target(name: "SweepMonitor", dependencies: ["SweepNative"],
                linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreAudio"), .linkedFramework("CoreMediaIO")]),
        // Disk Map: bubble layout, view model and views.
        .target(name: "SweepLens", dependencies: ["SweepCore"]),
        // Design system and every module's screens.
        .target(name: "SweepUI", dependencies: ["SweepCore", "SweepScanners", "SweepMonitor", "SweepLens"]),
        .executableTarget(name: "sweep", dependencies: ["SweepCore", "SweepScanners", "SweepLens"]),
        .executableTarget(name: "SweepApp", dependencies: ["SweepUI"]),
        .testTarget(name: "SweepCoreTests", dependencies: ["SweepCore"]),
        .testTarget(name: "SweepScannersTests", dependencies: ["SweepScanners"]),
        .testTarget(name: "SweepMonitorTests", dependencies: ["SweepMonitor", "SweepNative"]),
        .testTarget(name: "SweepLensTests", dependencies: ["SweepLens"]),
        .testTarget(name: "SweepUITests", dependencies: ["SweepUI"]),
        .testTarget(name: "SweepCommandTests", dependencies: ["sweep"]),
    ]
)
