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
    let scan: SessionEligibility.PressureScan
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
    let candidates = tick.busy ? [] : SessionEligibility.pressureCandidates(tick.scan)
    guard
      let id = scheduler.step(.init(now: tick.scan.now, risk: tick.risk, candidates: candidates))
    else { return Outcome() }
    guard let thread = tick.scan.threads.first(where: { $0.id == id }) else {
      scheduler.landed(id, ended: false)
      return Outcome()
    }
    let end = end
    var outcome = Outcome(endingBytes: thread.memoryBytes, name: SessionEligibility.name(thread))
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
