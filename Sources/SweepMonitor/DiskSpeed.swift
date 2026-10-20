import Darwin
import Foundation

/// Sequential write and read speed of a drive, measured with a temporary file that bypasses the file cache.
public enum DiskSpeed {
    public struct Result: Sendable, Equatable, Codable {
        /// Bytes per second.
        public let write: Double
        public let read: Double
        public let date: Date

        public init(write: Double, read: Double, date: Date) {
            self.write = write
            self.read = read
            self.date = date
        }
    }

    public enum Failure: Error, Equatable {
        case notEnoughSpace
        case failed(String)
        case cancelled
    }

    /// Writes `bytes` to a new file in `folder`, reads it back, and removes it. The file never outlives the test.
    public static func measure(in folder: String, bytes: Int = 1 << 30, chunk: Int = 8 << 20,
                               isCancelled: @Sendable () -> Bool = { false }) throws -> Result {
        if let free = (try? URL(fileURLWithPath: folder).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage, free < Int64(bytes) * 3 {
            throw Failure.notEnoughSpace
        }
        let path = folder + "/.sweep-speed-test-\(UUID().uuidString)"
        defer { unlink(path) }
        var buffer = [UInt8](repeating: 0, count: chunk)
        for index in stride(from: 0, to: chunk, by: 8) {  // incompressible, so APFS can't cheat
            var value = UInt64.random(in: 0...UInt64.max)
            withUnsafeBytes(of: &value) { raw in
                for byte in 0..<min(8, chunk - index) { buffer[index + byte] = raw[byte] }
            }
        }

        let output = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard output >= 0 else { throw Failure.failed(String(cString: strerror(errno))) }
        _ = fcntl(output, F_NOCACHE, 1)
        let writeStart = DispatchTime.now()
        var written = 0
        while written < bytes {
            if isCancelled() { close(output); throw Failure.cancelled }
            let count = buffer.withUnsafeBytes { write(output, $0.baseAddress, min(chunk, bytes - written)) }
            guard count > 0 else { close(output); throw Failure.failed(String(cString: strerror(errno))) }
            written += count
        }
        _ = fcntl(output, F_FULLFSYNC)
        let writeSeconds = seconds(since: writeStart)
        close(output)

        let input = open(path, O_RDONLY)
        guard input >= 0 else { throw Failure.failed(String(cString: strerror(errno))) }
        defer { close(input) }
        _ = fcntl(input, F_NOCACHE, 1)
        let readStart = DispatchTime.now()
        var read = 0
        while read < bytes {
            if isCancelled() { throw Failure.cancelled }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, chunk) }
            guard count > 0 else { break }
            read += count
        }
        let readSeconds = seconds(since: readStart)
        return Result(write: Double(written) / max(writeSeconds, 0.000_001), read: Double(read) / max(readSeconds, 0.000_001),
                      date: Date())
    }

    private static func seconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }
}
