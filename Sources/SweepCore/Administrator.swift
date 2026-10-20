import Foundation

/// Runs a few fixed operations as root after the standard macOS administrator password prompt.
///
/// This is the interim privileged path: one prompt per batch, nothing stays installed. A launchd helper
/// registered with `SMAppService` can replace it later without changing callers.
public enum Administrator {
    public enum Failure: Error, Equatable, Sendable {
        case cancelled
        case failed(String)
    }

    /// Removes `paths` as root. Callers must have checked every path against `RemovalPolicy` first.
    public static func removeItems(_ paths: [String]) -> Result<Void, Failure> {
        guard !paths.isEmpty else { return .success(()) }
        return run(removeCommand(paths)).map { _ in () }
    }

    /// `rm` commands with every path quoted into the command itself. (A list file in the user's temporary
    /// folder could be edited by another process while the password prompt is up.) Paths are split across
    /// commands to stay well under the argument limit, and every command runs even if one fails.
    static func removeCommand(_ paths: [String], chunkLength: Int = 100_000) -> String {
        var commands: [String] = []
        var current: [String] = []
        var length = 0
        for path in paths.map(shellQuote) {
            if !current.isEmpty && length + path.count > chunkLength {
                commands.append(current.joined(separator: " "))
                current = []
                length = 0
            }
            current.append(path)
            length += path.count + 1
        }
        if !current.isEmpty { commands.append(current.joined(separator: " ")) }
        return commands.map { "/bin/rm -rf -- " + $0 }.joined(separator: "; ")
    }

    /// Runs several fixed commands as root behind one password prompt. Stops at the first failure.
    public static func runBatch(_ commands: [[String]]) -> Result<String, Failure> {
        guard !commands.isEmpty else { return .success("") }
        return run(commands.map { $0.map(shellQuote).joined(separator: " ") }.joined(separator: " && "))
    }

    /// Runs one fixed program with arguments as root.
    public static func run(_ executable: String, _ arguments: [String]) -> Result<String, Failure> {
        run(([executable] + arguments).map(shellQuote).joined(separator: " "))
    }

    private static func run(_ command: String) -> Result<String, Failure> {
        let script = "do shell script \"\(appleScriptEscape(command))\" with administrator privileges"
        // No timeout: it waits for the person to type their password.
        let result: Subprocess.Result
        do {
            result = try Subprocess.run("/usr/bin/osascript", ["-e", script])
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
        if result.status == 0 { return .success(result.output) }
        if result.errors.contains("-128") || result.errors.localizedCaseInsensitiveContains("cancel") { return .failure(.cancelled) }
        return .failure(.failed(result.errors.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
