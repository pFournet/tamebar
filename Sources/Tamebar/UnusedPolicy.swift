import Foundation

/// Decides whether an AI session is unused (decisions Q1, Q2, Q7, Q8, R1).
enum UnusedPolicy {
  static let week: TimeInterval = 7 * 86_400
  static let day: TimeInterval = 86_400

  enum Reason: Equatable, Sendable {
    case idle(TimeInterval)
    case detached
  }

  enum Protection: Equatable, Sendable {
    case busy, kept, keptProject, serving
  }

  struct Input: Sendable {
    let thread: AIThread
    let now: Date
    let risk: MemoryRisk
    let inMeeting: Bool
    let kept: Bool
    let keptProject: Bool
    let serving: Bool
    /// End after N days, in auto mode (Q10): it lowers the cutoff to N days.
    var autoEndDays: Int? = nil
  }

  /// 7 days normally; 24 h while memory is at warning or a call is on. In auto mode, End after N
  /// days lowers it to N days, so a session the setting would end counts as unused (Q10).
  static func cutoff(risk: MemoryRisk, inMeeting: Bool, autoEndDays: Int? = nil) -> TimeInterval {
    let base = risk >= .warning || inMeeting ? day : week
    return autoEndDays.map { min(base, TimeInterval($0) * day) } ?? base
  }

  /// Idle time from the agent's own signal. Nil when the agent doesn't say it's idle.
  static func idleFor(_ thread: AIThread, now: Date) -> TimeInterval? {
    guard thread.agentStatus == .idle, let since = thread.agentStatusSince else { return nil }
    return max(0, now.timeIntervalSince(since))
  }

  /// Why this session must never be offered for ending, however long it idles (Q7).
  static func protection(_ input: Input) -> Protection? {
    if input.thread.agentStatus == .busy || input.thread.agentStatus == .shell { return .busy }
    if input.kept { return .kept }
    if input.keptProject { return .keptProject }
    if input.serving { return .serving }
    return nil
  }

  /// True when the thread has a protection, so nothing may offer to end it. Consumers that aren't
  /// AI sessions have no thread ID and are never protected here.
  static func isProtected(threadID: String?, protections: [String: Protection]) -> Bool {
    threadID.map { protections[$0] != nil } ?? false
  }

  /// Why this session counts as unused, or nil when it doesn't. Protections win (Q7), and Codex
  /// desktop workers are never a target (Q1).
  static func reason(_ input: Input) -> Reason? {
    guard input.thread.tool != .codexDesktop, protection(input) == nil else { return nil }
    if let idle = idleFor(input.thread, now: input.now),
      idle >= cutoff(risk: input.risk, inMeeting: input.inMeeting, autoEndDays: input.autoEndDays)
    {
      return .idle(idle)
    }
    // Otherwise only a detached session (its app or terminal gone) is unused, at any idle age
    // (Q8; decisions Q1 notes).
    return input.thread.isDetached ? .detached : nil
  }

  struct EvaluateInput: Sendable {
    let threads: [AIThread]
    let now: Date
    let risk: MemoryRisk
    let inMeeting: Bool
    let keeps: SessionKeeps
    /// Thread directories that sit inside a project set to Keep running.
    let keptDirectories: Set<String>
    /// Processes holding a listening TCP port, the agents' own included.
    let servingIDs: Set<Int32>
    /// End after N days, in auto mode (Q10).
    var autoEndDays: Int? = nil
  }

  struct PortScan: Sendable {
    let listening: Set<Int32>
    /// False when lsof timed out or overflowed and its output is partial.
    let complete: Bool
  }

  /// The listeners to evaluate with. A partial lsof (slowest under pressure, when the cutoff is a
  /// day) would drop `.serving` and offer a server as unused, so it adds to the last listeners
  /// instead of replacing them: the lines it did print are still true.
  static func listeners(previous: Set<Int32>, scan: PortScan) -> Set<Int32> {
    scan.complete ? scan.listening : previous.union(scan.listening)
  }

  struct Evaluation: Equatable, Sendable {
    var reasons: [String: Reason] = [:]
    var protections: [String: Protection] = [:]
  }

  /// A session serves when something it started listens on a port: a descendant other than the
  /// agent itself. Every Codex CLI holds a loopback listener of its own, so the root and the native
  /// codex process never count. Codex desktop threads have no root: all their pids are workers,
  /// and any of them can be a server.
  static func serving(_ thread: AIThread, listening: Set<Int32>) -> Bool {
    let agent: Set<Int32> =
      thread.tool == .codexDesktop
      ? [] : Set([thread.rootProcessID, thread.nativeProcessID].compactMap { $0 })
    return thread.processIDs.contains { !agent.contains($0) && listening.contains($0) }
  }

  /// Reasons and protections for every session, keyed by thread ID.
  static func evaluate(_ input: EvaluateInput) -> Evaluation {
    var result = Evaluation()
    for thread in input.threads {
      let single = Input(
        thread: thread, now: input.now, risk: input.risk, inMeeting: input.inMeeting,
        kept: input.keeps.contains(thread),
        keptProject: thread.directory.map(input.keptDirectories.contains) ?? false,
        serving: serving(thread, listening: input.servingIDs), autoEndDays: input.autoEndDays)
      if let reason = reason(single) { result.reasons[thread.id] = reason }
      if let protection = protection(single) { result.protections[thread.id] = protection }
    }
    return result
  }
}
