import Foundation

/// Thin wrapper around `Process` for shelling out to CLIs (`tart`, `tar`, the
/// actions-runner `run.sh`). Synchronous `run` for quick commands; `launch`
/// for long-lived processes (a runner agent) whose exit we observe via a
/// termination handler.
public enum Shell {
  public struct Result: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var ok: Bool { status == 0 }
  }

  public enum ShellError: Error, CustomStringConvertible {
    case nonZeroExit(command: String, status: Int32, stderr: String)
    public var description: String {
      switch self {
      case let .nonZeroExit(command, status, stderr):
        return "`\(command)` exited \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
      }
    }
  }

  /// Run a command to completion and capture its output.
  @discardableResult
  public static func run(
    _ executable: String,
    _ arguments: [String],
    currentDirectory: URL? = nil,
    environment: [String: String]? = nil
  ) throws -> Result {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let currentDirectory { process.currentDirectoryURL = currentDirectory }
    if let environment { process.environment = environment }

    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err

    try process.run()
    // Drain before waiting so a large output can't deadlock the pipe buffer.
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return Result(
      status: process.terminationStatus,
      stdout: String(data: outData, encoding: .utf8) ?? "",
      stderr: String(data: errData, encoding: .utf8) ?? ""
    )
  }

  /// Like `run`, but throws if the command exits non-zero.
  @discardableResult
  public static func runChecked(
    _ executable: String,
    _ arguments: [String],
    currentDirectory: URL? = nil,
    environment: [String: String]? = nil
  ) throws -> Result {
    let result = try run(executable, arguments, currentDirectory: currentDirectory, environment: environment)
    guard result.ok else {
      throw ShellError.nonZeroExit(
        command: ([executable] + arguments).joined(separator: " "),
        status: result.status,
        stderr: result.stderr
      )
    }
    return result
  }

  /// Resolve an executable on the user's PATH (and common Homebrew dirs, which
  /// a GUI app launched from Finder won't have on its inherited PATH).
  public static func which(_ name: String) -> String? {
    let candidates =
      ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].map { "\($0)/\(name)" }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
}
