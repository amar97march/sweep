import Foundation

/// Runs a program and reads its output and its errors at the same time. Reading one pipe to the end before
/// the other (or waiting for the program first) stalls a program that fills the other pipe's 64 KB buffer.
public enum Subprocess {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
        public let errors: String
        /// Stopped because it ran longer than the timeout.
        public let timedOut: Bool
    }

    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval? = nil) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        let collected = Locked((output: Data(), errors: Data()))
        let readers = DispatchGroup()
        for (pipe, isOutput) in [(output, true), (errors, false)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                collected.withLock { if isOutput { $0.output = data } else { $0.errors = data } }
                readers.leave()
            }
        }
        var timedOut = false
        if let timeout {
            if finished.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                process.terminate()
                finished.wait()
            }
        } else {
            finished.wait()
        }
        readers.wait()
        let data = collected.withLock { $0 }
        return Result(status: process.terminationStatus, output: String(decoding: data.output, as: UTF8.self),
                      errors: String(decoding: data.errors, as: UTF8.self), timedOut: timedOut)
    }
}
