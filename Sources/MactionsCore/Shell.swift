import Foundation

/// Thin wrapper around `Process` for shelling out to CLIs (`tar`, `vmrun`, the
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
    case timedOut(command: String, seconds: TimeInterval)
    public var description: String {
      switch self {
      case let .nonZeroExit(command, status, stderr):
        return "`\(command)` exited \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
      case let .timedOut(command, seconds):
        return "`\(command)` did not finish within \(Int(seconds.rounded())) s and was stopped"
      }
    }
  }

  /// How long a timed-out command gets between SIGTERM and SIGKILL.
  static let terminationGrace: TimeInterval = 2
  /// How long a bounded run waits for the output pipes to close once the
  /// command itself has exited. A grandchild that inherited stdout/stderr (a
  /// daemon it started, a backgrounded job) can hold them open long after the
  /// command is gone, and a blocking read-to-EOF would then wait out the
  /// grandchild's whole lifetime.
  static let drainGrace: TimeInterval = 1

  /// Run a command to completion and capture its output.
  ///
  /// `timeout` bounds the whole run: past it the command gets SIGTERM, then
  /// SIGKILL after `terminationGrace`, and the call throws
  /// `ShellError.timedOut` instead of returning a partial result. Use it for a
  /// command whose hang would stall something that must not stall (a network
  /// check, a teardown that sleep/wake ordering waits on). `nil` keeps the
  /// unbounded behavior every existing caller was written against.
  @discardableResult
  public static func run(
    _ executable: String,
    _ arguments: [String],
    currentDirectory: URL? = nil,
    environment: [String: String]? = nil,
    timeout: TimeInterval? = nil
  ) throws -> Result {
    if let timeout {
      return try runBounded(
        executable, arguments, currentDirectory: currentDirectory, environment: environment,
        timeout: timeout)
    }
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

  /// The `timeout` path of `run`. Output is drained through readability
  /// handlers rather than a blocking read, so neither a command that never
  /// exits nor a grandchild holding a pipe open can hold the caller past
  /// `timeout + terminationGrace + drainGrace`.
  private static func runBounded(
    _ executable: String,
    _ arguments: [String],
    currentDirectory: URL?,
    environment: [String: String]?,
    timeout: TimeInterval
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
    let drain = PipeDrain()
    drain.attach(out.fileHandleForReading, stream: .out)
    drain.attach(err.fileHandleForReading, stream: .err)
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }

    do {
      try process.run()
    } catch {
      drain.detach()
      throw error
    }

    var timedOut = false
    if exited.wait(timeout: .now() + timeout) == .timedOut {
      timedOut = true
      process.terminate()
      if exited.wait(timeout: .now() + terminationGrace) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        // Bounded too: a process stuck in uninterruptible I/O ignores even
        // SIGKILL until the I/O returns, and the caller must not wait on it.
        _ = exited.wait(timeout: .now() + terminationGrace)
      }
    }
    drain.waitForEnd(timeout: drainGrace)
    drain.detach()
    if timedOut {
      throw ShellError.timedOut(
        command: ([executable] + arguments).joined(separator: " "), seconds: timeout)
    }
    return Result(
      status: process.terminationStatus,
      stdout: drain.text(.out),
      stderr: drain.text(.err)
    )
  }

  /// Run a command to completion while STREAMING its combined output line by
  /// line to `onLine` — one call per complete `\n`-terminated line (plus any
  /// unterminated trailing text at EOF). Each stream's lines arrive in order;
  /// cross-stream (stdout vs stderr) interleaving is best-effort, since the two
  /// drain threads emit independently. The sole consumer only needs per-stream
  /// order (forward-only phase markers), which IS guaranteed.
  /// Still returns the full captured `Result` so callers keep the durable
  /// transcript. Used for long jobs (the Windows base build) where the UI wants
  /// live phase feedback instead of a single blocking spinner.
  ///
  /// `onLine` is `@Sendable` and invoked from background drain threads, so it
  /// must be thread-safe (e.g. an `AsyncStream.Continuation.yield`, which is).
  @discardableResult
  public static func runStreaming(
    _ executable: String,
    _ arguments: [String],
    currentDirectory: URL? = nil,
    environment: [String: String]? = nil,
    onLine: @escaping @Sendable (String) -> Void
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

    let collector = LineCollector(onLine: onLine)
    try process.run()

    // Drain each pipe on its own thread (so a full pipe buffer can't deadlock),
    // splitting into lines as bytes arrive. A DispatchGroup joins both before we
    // read the accumulated text, so the Result is complete.
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "mactions.shell.stream", attributes: .concurrent)
    for (handle, stream) in [
      (out.fileHandleForReading, LineCollector.Stream.out),
      (err.fileHandleForReading, LineCollector.Stream.err),
    ] {
      group.enter()
      queue.async {
        while case let chunk = handle.availableData, !chunk.isEmpty {
          collector.feed(chunk, stream: stream)
        }
        collector.flush(stream: stream)
        group.leave()
      }
    }
    process.waitUntilExit()
    group.wait()

    return Result(
      status: process.terminationStatus,
      stdout: collector.text(.out),
      stderr: collector.text(.err)
    )
  }

  /// Like `run`, but throws if the command exits non-zero.
  @discardableResult
  public static func runChecked(
    _ executable: String,
    _ arguments: [String],
    currentDirectory: URL? = nil,
    environment: [String: String]? = nil,
    timeout: TimeInterval? = nil
  ) throws -> Result {
    let result = try run(
      executable, arguments, currentDirectory: currentDirectory, environment: environment,
      timeout: timeout)
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

/// Collects a bounded run's stdout/stderr through `readabilityHandler`s. A
/// blocking `readDataToEndOfFile` cannot be given up on, and `run(timeout:)`
/// must be able to stop waiting for EOF when a grandchild keeps a pipe open.
/// `@unchecked Sendable`: the buffers and the open-stream set are guarded by
/// one `NSLock`; the handlers run on Foundation's background queue.
final class PipeDrain: @unchecked Sendable {
  enum Stream { case out, err }

  private let lock = NSLock()
  private var outData = Data()
  private var errData = Data()
  private var open: Set<Stream> = []
  private var handles: [FileHandle] = []
  private let ended = DispatchSemaphore(value: 0)

  func attach(_ handle: FileHandle, stream: Stream) {
    lock.lock()
    open.insert(stream)
    handles.append(handle)
    lock.unlock()
    handle.readabilityHandler = { [weak self] readable in
      self?.consume(readable.availableData, stream: stream, handle: readable)
    }
  }

  private func consume(_ chunk: Data, stream: Stream, handle: FileHandle) {
    guard !chunk.isEmpty else {
      // EOF: every writer (the command and anything that inherited the pipe)
      // has closed it.
      handle.readabilityHandler = nil
      lock.lock()
      let closedNow = open.remove(stream) != nil
      let allClosed = open.isEmpty
      lock.unlock()
      if closedNow, allClosed { ended.signal() }
      return
    }
    lock.lock()
    if stream == .out { outData.append(chunk) } else { errData.append(chunk) }
    lock.unlock()
  }

  /// Wait up to `timeout` for both pipes to reach EOF.
  func waitForEnd(timeout: TimeInterval) {
    _ = ended.wait(timeout: .now() + timeout)
  }

  /// Stop reading. Bytes a lingering grandchild writes afterwards are dropped.
  func detach() {
    lock.lock()
    let attached = handles
    lock.unlock()
    for handle in attached { handle.readabilityHandler = nil }
  }

  func text(_ stream: Stream) -> String {
    lock.lock()
    defer { lock.unlock() }
    return String(data: stream == .out ? outData : errData, encoding: .utf8) ?? ""
  }
}

/// Accumulates two streams' bytes and emits complete `\n`-terminated lines to a
/// callback as they arrive, while retaining the full text of each stream for the
/// final `Shell.Result`. `@unchecked Sendable`: all mutable state is guarded by a
/// single `NSLock`, and `onLine` is only ever called OUTSIDE the lock (so a
/// callback can't deadlock by re-entering). Drives `Shell.runStreaming`.
final class LineCollector: @unchecked Sendable {
  enum Stream { case out, err }

  private let onLine: @Sendable (String) -> Void
  private let lock = NSLock()
  private var outAll = Data()
  private var errAll = Data()
  private var outPending = Data()  // bytes since the last newline (not yet emitted)
  private var errPending = Data()

  init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

  func feed(_ data: Data, stream: Stream) {
    var emit: [String] = []
    lock.lock()
    if stream == .out {
      outAll.append(data)
      outPending.append(data)
      emit = Self.extractLines(&outPending)
    } else {
      errAll.append(data)
      errPending.append(data)
      emit = Self.extractLines(&errPending)
    }
    lock.unlock()
    for line in emit { onLine(line) }  // outside the lock
  }

  /// Emit any unterminated trailing bytes (a final line with no `\n`) at EOF.
  func flush(stream: Stream) {
    var trailing: String?
    lock.lock()
    if stream == .out, !outPending.isEmpty {
      trailing = String(decoding: outPending, as: UTF8.self)
      outPending.removeAll()
    } else if stream == .err, !errPending.isEmpty {
      trailing = String(decoding: errPending, as: UTF8.self)
      errPending.removeAll()
    }
    lock.unlock()
    if let trailing, !trailing.isEmpty { onLine(trailing) }
  }

  func text(_ stream: Stream) -> String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: stream == .out ? outAll : errAll, as: UTF8.self)
  }

  /// Pull complete lines out of `buf`, leaving the unterminated remainder. Works
  /// on a 0-indexed byte copy to avoid `Data`-slice index pitfalls.
  private static func extractLines(_ buf: inout Data) -> [String] {
    let newline = UInt8(ascii: "\n")
    guard buf.contains(newline) else { return [] }
    let bytes = [UInt8](buf)
    var lines: [String] = []
    var start = 0
    var consumed = 0
    for i in bytes.indices where bytes[i] == newline {
      lines.append(String(decoding: bytes[start..<i], as: UTF8.self))
      start = i + 1
      consumed = start
    }
    buf = consumed >= bytes.count ? Data() : Data(bytes[consumed...])
    return lines
  }
}
