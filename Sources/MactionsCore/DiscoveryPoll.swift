import Foundation

/// One repo the all-repos scan polls for queued jobs.
public struct QueuedJobsPollTarget: Sendable {
  public let name: String
  public let plane: any RunnerControlPlane

  public init(name: String, plane: any RunnerControlPlane) {
    self.name = name
    self.plane = plane
  }
}

/// What one repo's queued-jobs poll gave the all-repos scan.
public enum QueuedJobsPoll: Equatable, Sendable {
  case queued([[String]])
  /// The poll threw: the queue is unknown, not empty.
  case failed
  /// The scan stopped waiting before the poll answered: unknown too.
  case unfinished

  /// Failed and unfinished polls must HOLD discovered fleets, never read as
  /// a quiet queue.
  public var isUnknown: Bool {
    if case .queued = self { return false }
    return true
  }
}

/// A running all-repos poll. `answers` yields each repo's poll as it returns
/// and ends when every repo has answered, at the deadline, or on `cancel()`.
/// Cancel it when done reading (a poll still in flight then finishes in the
/// background and its answer is dropped).
public final class QueuedJobsPolling: Sendable {
  public let answers: AsyncStream<(name: String, poll: QueuedJobsPoll)>
  private let tasks: [Task<Void, Never>]

  fileprivate init(
    answers: AsyncStream<(name: String, poll: QueuedJobsPoll)>, tasks: [Task<Void, Never>]
  ) {
    self.answers = answers
    self.tasks = tasks
  }

  public func cancel() {
    for task in tasks { task.cancel() }
  }
}

/// Polls the all-repos scan's candidates for queued jobs, at most
/// `concurrency` at a time in the given order (most recently pushed first),
/// for at most `timeout`.
///
/// Why: the scan polled up to 50 repos one after another, and each poll is
/// two or more GitHub requests. On slow plane Wi-Fi (2026-10-24) a scan took
/// 140 to 200 s, so the 180 s watchdog cut scans off before their reap pass
/// and summary ran. A few polls at a time hide the latency, answers are
/// handled as they arrive (a repo with a queued job gets its fleet without
/// waiting for the slowest poll), and the deadline guarantees the rest of the
/// scan always runs, with the repos it never heard from treated as unknown.
public func startPollingQueuedJobs(
  _ targets: [QueuedJobsPollTarget],
  concurrency: Int = 4,
  timeout: TimeInterval
) -> QueuedJobsPolling {
  var seen: Set<String> = []
  let unique = targets.filter { seen.insert($0.name).inserted }
  let (answers, continuation) = AsyncStream<(name: String, poll: QueuedJobsPoll)>.makeStream()
  guard !unique.isEmpty else {
    continuation.finish()
    return QueuedJobsPolling(answers: answers, tasks: [])
  }
  let workerCount = min(max(1, concurrency), unique.count)
  let queue = PollQueue(unique, workers: workerCount)
  // Unstructured on purpose: a structured group would make the caller wait
  // for its slowest poll, which is exactly what the deadline is for.
  var tasks = (0..<workerCount).map { _ in
    Task {
      while !Task.isCancelled, let target = await queue.next() {
        let poll: QueuedJobsPoll
        do {
          poll = .queued(try await target.plane.listQueuedJobLabels())
        } catch {
          poll = .failed
        }
        continuation.yield((target.name, poll))
      }
      // The last worker out ends the stream: every repo has answered.
      if await queue.workerFinished() { continuation.finish() }
    }
  }
  let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
  tasks.append(
    Task {
      try? await Task.sleep(nanoseconds: nanoseconds)
      continuation.finish()
    })
  return QueuedJobsPolling(answers: answers, tasks: tasks)
}

/// Every candidate's poll, waiting for all of them up to `timeout`: those
/// that did not answer in time are `.unfinished`.
public func pollQueuedJobs(
  _ targets: [QueuedJobsPollTarget],
  concurrency: Int = 4,
  timeout: TimeInterval
) async -> [String: QueuedJobsPoll] {
  let polling = startPollingQueuedJobs(targets, concurrency: concurrency, timeout: timeout)
  defer { polling.cancel() }
  var polls: [String: QueuedJobsPoll] = [:]
  for await answer in polling.answers {
    polls[answer.name] = answer.poll
  }
  for target in targets where polls[target.name] == nil {
    polls[target.name] = .unfinished
  }
  return polls
}

/// Hands each target to exactly one worker, in order, and counts the workers
/// still running.
private actor PollQueue {
  private let targets: [QueuedJobsPollTarget]
  private var index = 0
  private var runningWorkers: Int

  init(_ targets: [QueuedJobsPollTarget], workers: Int) {
    self.targets = targets
    self.runningWorkers = workers
  }

  func next() -> QueuedJobsPollTarget? {
    guard index < targets.count else { return nil }
    defer { index += 1 }
    return targets[index]
  }

  /// `true` for the last worker to finish.
  func workerFinished() -> Bool {
    runningWorkers -= 1
    return runningWorkers == 0
  }
}
