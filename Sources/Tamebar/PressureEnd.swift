import Foundation
import os

/// Q18: under memory pressure, end long-idle sessions instead of pausing them. Pausing an idle
/// session frees nothing (spike S4: its pages only move out of RAM), so once memory has been at
/// warning or critical for `sustain` unbroken, Tamebar ends (Quit, Q4) the largest session idle
/// `minimumIdle` or more, then one more every `spacing` while pressure holds. It stops when
/// pressure clears. Pure.
///
/// The safety is Q10's automatic ending, reused: every Q7 protection (busy, Keep, kept project,
/// serving), no background job, a resume command, never Codex desktop, and the agent's status
/// re-read right before the signal (`DevProcessModel.endUnused`). Unlike Q10 it doesn't wait for
/// the user to be away.
struct PressureEndScheduler: Equatable, Sendable {
  static let sustain: TimeInterval = 120
  static let spacing: TimeInterval = 120
  static let minimumIdle: TimeInterval = 12 * 3_600
  /// A longer gap between two ticks means the Mac slept: pressure is timed afresh, as the
  /// auto-pause planner does (`AutoPausePlanner.wakeGap`).
  static let wakeGap: TimeInterval = AutoPausePlanner.wakeGap

  struct Candidate: Equatable, Sendable {
    let id: String
    /// How long the agent has said idle.
    let idle: TimeInterval
    let memoryBytes: UInt64
    var protected = false
  }

  struct Tick {
    let now: Date
    let risk: MemoryRisk
    let candidates: [Candidate]
  }

  /// Memory at warning or critical since then, unbroken.
  private(set) var elevatedSince: Date?
  /// The last end started in this episode.
  private(set) var lastStartedAt: Date?
  private(set) var lastTick: Date?
  /// Ends started and not landed yet.
  private(set) var pending: Set<String> = []
  /// Sessions whose end didn't land this episode: not tried again until pressure clears.
  private(set) var refused: Set<String> = []

  /// The session to end now, if any.
  mutating func step(_ tick: Tick) -> String? {
    let now = tick.now
    elevatedSince = elevatedSince.map { min($0, now) }
    lastStartedAt = lastStartedAt.map { min($0, now) }
    if let last = lastTick, now.timeIntervalSince(last) > Self.wakeGap { elevatedSince = nil }
    lastTick = now
    guard tick.risk >= .warning else {
      // The episode is over.
      elevatedSince = nil
      lastStartedAt = nil
      refused = []
      return nil
    }
    let since = elevatedSince ?? now
    elevatedSince = since
    guard now.timeIntervalSince(since) >= Self.sustain, pending.isEmpty,
      lastStartedAt.map({ now.timeIntervalSince($0) >= Self.spacing }) ?? true
    else { return nil }
    let next = tick.candidates.filter {
      !$0.protected && !refused.contains($0.id) && $0.idle >= Self.minimumIdle
    }.max { a, b in (a.memoryBytes, b.id) < (b.memoryBytes, a.id) }
    guard let next else { return nil }
    pending.insert(next.id)
    lastStartedAt = now
    return next.id
  }

  /// An end `step` started finished: `ended` when every process of the session exited.
  mutating func landed(_ id: String, ended: Bool) {
    guard pending.remove(id) != nil else { return }
    if !ended { refused.insert(id) }
  }

  /// The 4 s note (no banners): "Ended Atlas · 2.0 GB back", or "Ended Atlas" when the memory
  /// it held is unknown.
  static func note(name: String, freed: UInt64) -> String {
    "Ended \(name)" + (freed > 0 ? " · \(ByteText.full(freed)) back" : "")
  }
}

/// The model-side glue between a scan and `PressureEndScheduler`.
enum PressureEndWiring {
  struct Scan {
    let now: Date
    let threads: [AIThread]
    let protections: [String: UnusedPolicy.Protection]
    /// The root PIDs Tamebar may act on: the e2e targets. Nil outside e2e mode.
    let scope: Set<Int32>?
    /// Threads with a signal in flight.
    let inFlight: Set<String>
    /// The scan's `ps` records by PID, for `BackgroundJobs`.
    var records: [Int32: RawProcessRecord] = [:]
    /// Each session's terminal's last input (`WorkQueue.lastInput`): a keystroke resets idle.
    var lastInput: [String: Date] = [:]
  }

  /// How long a session has had no interaction (Q18, "idle means no interaction"): the agent's
  /// own idle age (its last status change: a message, a turn), cut short by the last keystroke
  /// in its terminal (the later of its own tty's and its pane's). Nil when the agent isn't idle.
  static func idle(_ thread: AIThread, now: Date, lastInput: [String: Date]) -> TimeInterval? {
    guard let idle = UnusedPolicy.idleFor(thread, now: now) else { return nil }
    guard let typed = lastInput[thread.id] else { return idle }
    return max(0, min(idle, now.timeIntervalSince(typed)))
  }

  /// Every session the agent says is idle, with its idle age (`idle`), that Tamebar may end on
  /// its own: in scope, not paused, no signal in flight, never Codex desktop, and Q10's automatic
  /// rules (`AutoEndWiring.endable`: a resume command and no background job). A protected one is
  /// listed as such, and the scheduler skips it.
  static func candidates(_ scan: Scan) -> [PressureEndScheduler.Candidate] {
    var seen: Set<String> = []
    return scan.threads.compactMap { thread in
      guard seen.insert(thread.id).inserted, thread.tool != .codexDesktop, !thread.isPaused,
        !scan.inFlight.contains(thread.id), AutoPauseWiring.inScope(thread, scope: scan.scope),
        let idle = idle(thread, now: scan.now, lastInput: scan.lastInput),
        AutoEndWiring.endable(thread, records: scan.records)
      else { return nil }
      return .init(
        id: thread.id, idle: idle, memoryBytes: thread.memoryBytes,
        protected: scan.protections[thread.id] != nil)
    }
  }

  /// The sessions the fresh scan still shows idle for 12 h or more (`idle`, so a keystroke in its
  /// terminal counts), as the "unused" map the click-time plan checks (`EndPlan.decide`): Q18's
  /// own cutoff, under the 24 h one the panel offers under pressure. Never Codex desktop (Q1).
  static func eligible(_ threads: [AIThread], now: Date, lastInput: [String: Date])
    -> [String: UnusedPolicy.Reason]
  {
    var eligible: [String: UnusedPolicy.Reason] = [:]
    for thread in threads where thread.tool != .codexDesktop {
      guard let idle = idle(thread, now: now, lastInput: lastInput),
        idle >= PressureEndScheduler.minimumIdle
      else { continue }
      eligible[thread.id] = .idle(idle)
    }
    return eligible
  }

  /// What the note and the Stopped list call the session: its folder, as Q15 names it.
  static func name(_ thread: AIThread) -> String {
    EndPlan.entry(thread, now: .distantPast)?.folderName ?? thread.displayName
  }
}

/// Runs the scheduler on each scan and ends what it picks through the model's `endUnused`, which
/// waits for a fresh scan, re-checks the session (Q7, Q10's automatic rules, Q18's 12 h) and
/// records it in the Stopped list. It acts only in the instance whose automatic pause acts.
@MainActor
final class PressureEndController {
  let acts: Bool
  private(set) var scheduler = PressureEndScheduler()
  /// Ends one session; true when every process of it exited.
  private let end: @MainActor (AIThread) async -> Bool

  private static let log = Logger(subsystem: AppBrand.bundleIdentifier, category: "pressureend")

  init(acts: Bool, end: @escaping @MainActor (AIThread) async -> Bool) {
    self.acts = acts
    self.end = end
  }

  struct Tick {
    let risk: MemoryRisk
    let scan: PressureEndWiring.Scan
    /// The user is ending sessions from a review, or Q10 is ending one: nothing new starts.
    var busy = false
  }

  struct Outcome {
    /// The end started this tick, true once it landed with the session gone.
    var ending: Task<Bool, Never>?
    /// The memory of the session being ended, for the note and the usage record.
    var endingBytes: UInt64 = 0
    /// Its name, for the note.
    var name = ""
  }

  func run(_ tick: Tick) -> Outcome {
    guard acts else { return Outcome() }
    let candidates = tick.busy ? [] : PressureEndWiring.candidates(tick.scan)
    guard
      let id = scheduler.step(.init(now: tick.scan.now, risk: tick.risk, candidates: candidates))
    else { return Outcome() }
    guard let thread = tick.scan.threads.first(where: { $0.id == id }) else {
      scheduler.landed(id, ended: false)
      return Outcome()
    }
    let end = end
    var outcome = Outcome(endingBytes: thread.memoryBytes, name: PressureEndWiring.name(thread))
    outcome.ending = Task { [weak self] in
      let ended = await end(thread)
      self?.scheduler.landed(id, ended: ended)
      if !ended {
        Self.log.notice(
          "Didn't end \(thread.displayName, privacy: .public) under pressure: changed or still running"
        )
      }
      return ended
    }
    return outcome
  }
}
