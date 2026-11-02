import Foundation

/// The shared facts and fresh-scan rules for ending AI sessions. Q10, Q18 and Q20 retain their
/// own timing and server policy; all three use this module for scope, interaction, resumability
/// and the final automatic-end check before a signal.
enum SessionEligibility {
  struct AutoEndScan {
    let threads: [AIThread]
    let unused: [String: UnusedPolicy.Reason]
    let protections: [String: UnusedPolicy.Protection]
    /// The root PIDs Tamebar may act on in e2e mode. Nil in the shipped app.
    let scope: Set<Int32>?
    let inFlight: Set<String>
    var records: [Int32: RawProcessRecord] = [:]
  }

  struct PressureScan {
    let now: Date
    let threads: [AIThread]
    let protections: [String: UnusedPolicy.Protection]
    let scope: Set<Int32>?
    let inFlight: Set<String>
    var records: [Int32: RawProcessRecord] = [:]
    var lastInput: [String: Date] = [:]
  }

  /// All automatic ends require a running, in-scope session with no signal in flight. A Q20
  /// session may have a dev server, so background jobs are checked separately on that path.
  static func available(_ thread: AIThread, scope: Set<Int32>?, inFlight: Set<String>) -> Bool {
    thread.tool != .codexDesktop && !thread.isPaused && !inFlight.contains(thread.id)
      && AutoPauseWiring.inScope(thread, scope: scope)
  }

  /// An automatic end must leave a command in Stopped that brings the session back.
  static func resumable(_ thread: AIThread) -> Bool {
    EndPlan.entry(thread, now: .distantPast)?.resumeCommand != nil
  }

  /// Q10 and Q18 also protect any background job the session started.
  static func endable(_ thread: AIThread, records: [Int32: RawProcessRecord]) -> Bool {
    resumable(thread) && BackgroundJobs.job(thread, records: records) == nil
  }

  /// Q10's candidate set. Protected sessions stay visible to the scheduler, which skips them.
  static func autoEndCandidates(_ scan: AutoEndScan) -> [AutoEndScheduler.Candidate] {
    var seen: Set<String> = []
    return scan.threads.compactMap { thread in
      guard seen.insert(thread.id).inserted, let reason = scan.unused[thread.id],
        available(thread, scope: scan.scope, inFlight: scan.inFlight),
        endable(thread, records: scan.records)
      else { return nil }
      return .init(
        id: thread.id, reason: reason, memoryBytes: thread.memoryBytes,
        protected: scan.protections[thread.id] != nil)
    }
  }

  /// Time since the last agent activity or terminal keystroke, whichever was later.
  static func interactionIdle(
    _ thread: AIThread, now: Date, lastInput: [String: Date]
  ) -> TimeInterval? {
    guard let idle = UnusedPolicy.idleFor(thread, now: now) else { return nil }
    guard let typed = lastInput[thread.id] else { return idle }
    return max(0, min(idle, now.timeIntervalSince(typed)))
  }

  /// Q18's candidate set. The scheduler enforces the 12-hour threshold and pressure timing.
  static func pressureCandidates(_ scan: PressureScan) -> [PressureEndScheduler.Candidate] {
    var seen: Set<String> = []
    return scan.threads.compactMap { thread in
      guard seen.insert(thread.id).inserted,
        available(thread, scope: scan.scope, inFlight: scan.inFlight),
        let idle = interactionIdle(thread, now: scan.now, lastInput: scan.lastInput),
        endable(thread, records: scan.records)
      else { return nil }
      return .init(
        id: thread.id, idle: idle, memoryBytes: thread.memoryBytes,
        protected: scan.protections[thread.id] != nil)
    }
  }

  /// The fresh scan's Q18 or Q20 idle map for EndPlan. Policy supplies its own threshold.
  static func idleEligible(
    _ threads: [AIThread], now: Date, lastInput: [String: Date], minimum: TimeInterval
  ) -> [String: UnusedPolicy.Reason] {
    var eligible: [String: UnusedPolicy.Reason] = [:]
    for thread in threads where thread.tool != .codexDesktop {
      guard let idle = interactionIdle(thread, now: now, lastInput: lastInput), idle >= minimum
      else { continue }
      eligible[thread.id] = .idle(idle)
    }
    return eligible
  }

  /// A fresh scan can reveal a new job or an invalid resume command after EndPlan's agent-status
  /// probe. Count that session as active rather than sending Quit.
  static func recheckAutomatic(
    _ plan: EndPlan.Decision, records: [Int32: RawProcessRecord]
  ) -> EndPlan.Decision {
    var plan = plan
    let kept = plan.end.filter { endable($0, records: records) }
    plan.becameActive += plan.end.count - kept.count
    plan.end = kept
    return plan
  }

  static func name(_ thread: AIThread) -> String {
    EndPlan.entry(thread, now: .distantPast)?.folderName ?? thread.displayName
  }
}
