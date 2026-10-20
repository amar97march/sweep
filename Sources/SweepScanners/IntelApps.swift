import Foundation
import SweepCore

/// The processor types a program's code is built for, read from its Mach-O header.
public enum MachO {
    public enum Architecture: Hashable, Sendable {
        case arm64, x86_64, other(Int32)
    }

    static let cpuARM64: Int32 = 0x0100_000C
    static let cpuX86_64: Int32 = 0x0100_0007

    /// The architectures in `path`, or nil when it isn't a Mach-O program (a script, a damaged file).
    public static func architectures(of path: String) -> Set<Architecture>? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4096), header.count >= 8 else { return nil }
        return architectures(inHeader: header)
    }

    static func architectures(inHeader data: Data) -> Set<Architecture>? {
        func big(_ offset: Int) -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            return data[data.startIndex + offset..<data.startIndex + offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func little(_ offset: Int) -> UInt32? { big(offset).map(\.byteSwapped) }
        func architecture(_ type: UInt32) -> Architecture {
            switch Int32(bitPattern: type) {
            case cpuARM64: .arm64
            case cpuX86_64: .x86_64
            default: .other(Int32(bitPattern: type))
            }
        }
        guard let magic = big(0) else { return nil }
        switch magic {
        case 0xCAFE_BABE, 0xCAFE_BABF:  // universal: big-endian table of slices
            // Java class files share this magic; they have a version (45+) where universal files have a small count.
            guard let count = big(4), count > 0, count < 20 else { return nil }
            let entrySize = magic == 0xCAFE_BABF ? 32 : 20
            var found = Set<Architecture>()
            for index in 0..<Int(count) {
                guard let type = big(8 + index * entrySize) else { break }
                found.insert(architecture(type))
            }
            return found.isEmpty ? nil : found
        case 0xCFFA_EDFE, 0xCEFA_EDFE:  // a single slice, little-endian
            return little(4).map { [architecture($0)] }
        default:
            return nil
        }
    }

    /// Apps that run only on Intel processors (through Rosetta on Apple silicon).
    public static func isIntelOnly(_ app: InstalledApp) -> Bool {
        guard let executable = app.executable else { return false }
        guard let architectures = architectures(of: app.path + "/Contents/MacOS/" + executable) else { return false }
        return !architectures.contains(.arm64) && architectures.contains(.x86_64)
    }
}

extension ApplicationsScanner {
    /// Apps that need Rosetta, which macOS keeps only through macOS 27.
    func intelOnlyApps(_ apps: [InstalledApp]) -> ScanCategory? {
        let intel = apps.filter(MachO.isIntelOnly)
        guard !intel.isEmpty else { return nil }
        let items = intel.map { app in
            ScanItem(id: "intel:" + app.path, title: app.name,
                     subtitle: ["Intel only", app.shortVersion.map { "version \($0)" },
                                app.lastUsed.map { "last opened " + $0.formatted(date: .abbreviated, time: .omitted) }]
                        .compactMap { $0 }.joined(separator: " · "),
                     size: Measure.size(app.path), date: app.lastUsed, isSelectedByDefault: false,
                     action: .remove(paths: [app.path], mode: .moveToTrash))
        }
        return ScanCategory(
            id: "intelApps", title: "Intel-only Apps",
            summary: "These run through Rosetta, which macOS includes only up to macOS 27. Look for an Apple silicon version, or remove the ones you don't need.",
            symbol: "cpu", groups: [ScanGroup(id: "intel", title: "Need Rosetta", subtitle: "\(intel.count) \(intel.count == 1 ? "app" : "apps")",
                                              icon: .symbol("cpu"), items: items)])
    }
}
