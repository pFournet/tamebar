import Foundation

/// Decides which unused sessions and opted-in dev-server projects Tamebar pauses or resumes on
/// its own (Q9, D6.4). Pure. A project's ID is `project:<directory>`
/// (`AutoPauseWiring.projectID`); the planner treats both kinds alike. Since Q18 the wiring
/// passes sessions as `candidates` only during a call: under memory pressure alone only projects
/// are candidates, and long-idle sessions are ended instead (`PressureEndScheduler`).
///
/// An episode lasts while there is pressure, a meeting, heat, or anything Tamebar paused. It ends
/// once memory has been calm for `calmAfter`, no meeting is on, heat has cleared, and the ledger
/// is empty.
///
/// Heat (Q13): serious or critical for `heatSustain` starts it, nominal or fair for
/// `heatClearAfter` ends it. While it holds, every idle session still using CPU
/// (`heatCandidates`) is paused, never during a call. An entry due to resume is taken over by
/// whatever still holds, so one episode clearing never resumes what another still needs: a call
/// first, then heat.
///
/// Running sessions are never held for memory (Q19, which removed Q14's work queue). A `queue`
/// entry an older build left in the saved ledger is resumed at the first tick, whatever holds.
enum AutoPausePlanner {
  static let pressureSustain: TimeInterval = 6
  static let pressureSpacing: TimeInterval = 30
  static let calmAfter: TimeInterval = 30
  static let maxPressurePause: TimeInterval = 300
  /// A longer gap between two ticks means the Mac slept, so pressure and calm are timed
  /// afresh. It sits above the slowest refresh (15 s in the background, 12 s under pressure).
  static let wakeGap: TimeInterval = 60
  static let heatSustain: TimeInterval = 30
  static let heatClearAfter: TimeInterval = 60

  /// Why an entry is in the ledger. `queue` is only read: Q14's work queue (removed by Q19) left
  /// it on a busy session it stopped, and the planner resumes such an entry at once.
  enum Reason: String, Codable, Sendable { case pressure, meeting, heat, queue }

  struct Candidate: Equatable, Sendable {
    let threadID: String
    let memoryBytes: UInt64
    let isPaused: Bool
  }

  struct Entry: Codable, Equatable, Sendable {
    let threadID: String
    let reason: Reason
    let since: Date
  }

  struct State: Codable, Equatable, Sendable {
    var ledger: [Entry] = []
    var elevatedSince: Date?
    var calmSince: Date?
    /// The last pressure pause. Meeting pauses leave it alone.
    var lastPause: Date?
    /// Threads the user resumed after Tamebar paused them. Left alone until the episode ends.
    /// Never pruned, so a missed scan can't forget the user's choice. Like `forceResumed`, it
    /// holds at most the threads touched in one episode and is cleared when the episode ends.
    var userResumed: Set<String> = []
    /// Threads resumed after `maxPressurePause`, or taken over by a call at that point. Not
    /// pressure-paused again until the episode ends; a call may still pause them.
    var forceResumed: Set<String> = []
    /// When a pause of each candidate last stopped nothing. It isn't tried again for
    /// `pressureSpacing`, under pressure or in a call, so one that keeps failing can't loop at
    /// scan speed and starve the others. Cleared when the episode ends.
    var pauseFailedAt: [String: Date] = [:]
    /// The previous tick, to notice a sleep.
    var lastTick: Date?
    /// Serious or critical since then, unbroken.
    var hotSince: Date?
    /// Nominal or fair since then, unbroken.
    var coolSince: Date?
    /// Tamebar is acting on heat: hot held `heatSustain`, and cool hasn't held `heatClearAfter`.
    var heat = false
  }

  struct Input: Sendable {
    let now: Date
    let risk: MemoryRisk
    let inMeeting: Bool
    /// Unused, unprotected sessions (UnusedPolicy) and opted-in projects (`projectSets`), largest
    /// first across both. Every candidate must be pausable now:
    /// busy and shell sessions are already filtered out. A pause step that isn't applied is a
    /// bug.
    let candidates: [Candidate]
    /// Threads whose every process is stopped.
    let pausedNow: Set<String>
    /// Threads seen with no stopped process. A ledger thread here was resumed by the user.
    /// A ledger thread in neither set (partly stopped, missed by a scan, or gone) keeps its
    /// entry until its normal resume.
    let runningNow: Set<String>
    let state: State
    var thermal: ThermalStatus = .nominal
    /// Idle, unprotected sessions still using CPU (`AutoPauseWiring.heatCandidates`), paused
    /// while heat holds.
    var heatCandidates: [Candidate] = []
  }

  enum Step: Equatable, Hashable, Sendable {
    case pause(String, Reason)
    case resume(String)
  }

  struct Output: Sendable {
    /// Resumes first, then pauses. Apply them in this order.
    let steps: [Step]
    let state: State
  }

  static func plan(_ input: Input) -> Output {
    var state = input.state
    updateClocks(&state, input)
    reconcile(&state, input)
    let resumed = resumeSteps(&state, input)
    let paused = pauseSteps(&state, input, resumed: Set(resumed))
    return Output(steps: resumed.map(Step.resume) + paused, state: state)
  }

  /// Memory pressure has held for `pressureSustain`, on the clocks of a state `plan` returned.
  static func isPressure(_ state: State, _ now: Date) -> Bool {
    state.elevatedSince.map { now.timeIntervalSince($0) >= pressureSustain } ?? false
  }

  /// Memory has been calm for `calmAfter`, on the clocks of a state `plan` returned.
  static func isCalm(_ state: State, _ now: Date) -> Bool {
    state.calmSince.map { now.timeIntervalSince($0) >= calmAfter } ?? false
  }

  /// Tamebar is acting on heat, on the clocks of a state `plan` returned.
  static func isHeat(_ state: State) -> Bool { state.heat }

  /// Rebases dates a backward clock jump left in the future, restarts the timers after a
  /// sleep, then times pressure (≥ warning) and calm (below warning).
  private static func updateClocks(_ state: inout State, _ input: Input) {
    let now = input.now
    state.ledger = state.ledger.map { entry in
      entry.since > now ? Entry(threadID: entry.threadID, reason: entry.reason, since: now) : entry
    }
    state.lastPause = state.lastPause.map { min($0, now) }
    state.pauseFailedAt = state.pauseFailedAt.mapValues { min($0, now) }
    state.elevatedSince = state.elevatedSince.map { min($0, now) }
    state.calmSince = state.calmSince.map { min($0, now) }
    state.hotSince = state.hotSince.map { min($0, now) }
    state.coolSince = state.coolSince.map { min($0, now) }
    if let last = state.lastTick, now.timeIntervalSince(last) > wakeGap {
      state.resetClocks()
    }
    state.lastTick = now
    updateHeat(&state, input)

    if input.risk >= .warning {
      state.elevatedSince = state.elevatedSince ?? now
      state.calmSince = nil
    } else {
      state.elevatedSince = nil
      state.calmSince = state.calmSince ?? now
    }
  }

  /// Hot (serious or critical) for `heatSustain` starts heat; cool (anything else) for
  /// `heatClearAfter` ends it. One reading the other way restarts the clock, so heat that
  /// flickers never acts, and heat that flickers while cooling never clears.
  private static func updateHeat(_ state: inout State, _ input: Input) {
    let now = input.now
    if input.thermal.isHot {
      state.hotSince = state.hotSince ?? now
      state.coolSince = nil
    } else {
      state.hotSince = nil
      state.coolSince = state.coolSince ?? now
    }
    if let hot = state.hotSince, now.timeIntervalSince(hot) >= heatSustain { state.heat = true }
    if let cool = state.coolSince, now.timeIntervalSince(cool) >= heatClearAfter {
      state.heat = false
    }
  }

  /// Matches the ledger to what the scan saw, and ends the episode.
  private static func reconcile(_ state: inout State, _ input: Input) {
    // A ledger thread seen running was resumed by the user: forget it and leave it alone this
    // episode. One in neither set keeps its entry, so nothing is left stopped forever.
    for entry in state.ledger where input.runningNow.contains(entry.threadID) {
      state.userResumed.insert(entry.threadID)
    }
    state.ledger.removeAll { input.runningNow.contains($0.threadID) }

    // A one-tick dip below warning is not calm, so it does not end the episode.
    if isCalm(state, input.now) && !input.inMeeting && !state.heat && state.ledger.isEmpty {
      state.userResumed = []
      state.forceResumed = []
      state.pauseFailedAt = [:]
    }
  }

  /// The threads to resume, all from the ledger. An entry that comes due is taken over by whatever
  /// still holds, so the episode that holds is never cut and nothing flickers: a call takes it,
  /// else heat. Only one nothing holds is resumed. Memory pressure no longer takes a heat entry
  /// over: what heat paused is an idle session, and idle sessions aren't paused for memory (Q18).
  private static func resumeSteps(_ state: inout State, _ input: Input) -> [String] {
    let now = input.now
    // Q19: a session an older build queued (Q14) is busy work held for memory. It comes back at
    // once, and nothing takes it over.
    var resumed = state.ledger.filter { $0.reason == .queue }.map(\.threadID)
    state.ledger.removeAll { $0.reason == .queue }
    var due: [String] = []
    if !input.inMeeting {
      due += state.ledger.filter { $0.reason == .meeting }.map(\.threadID)
    }
    let pressureEntries = state.ledger.filter { $0.reason == .pressure }.sorted {
      $0.since < $1.since
    }
    let forced = pressureEntries.filter { now.timeIntervalSince($0.since) >= maxPressurePause }
      .map(\.threadID)
    due += forced
    if isCalm(state, now),
      let oldest = pressureEntries.first(where: { !forced.contains($0.threadID) })
    {
      due.append(oldest.threadID)
    }
    state.forceResumed.formUnion(forced)
    if !state.heat {
      due += state.ledger.filter { $0.reason == .heat }.map(\.threadID)
    }
    for id in due where !resumed.contains(id) {
      guard let index = state.ledger.firstIndex(where: { $0.threadID == id }) else { continue }
      let entry = state.ledger[index]
      let next: Reason? =
        if input.inMeeting {
          .meeting
        } else if state.heat {
          .heat
        } else {
          nil
        }
      if let next {
        if next != entry.reason {
          state.ledger[index] = Entry(threadID: id, reason: next, since: now)
        }
      } else {
        resumed.append(id)
        state.ledger.remove(at: index)
      }
    }
    return resumed
  }

  /// Largest first: every candidate during a call, one per `pressureSpacing` under pressure.
  /// The user's Resume blocks every pause; a forced resume blocks only pressure pauses.
  private static func pauseSteps(_ state: inout State, _ input: Input, resumed: Set<String>)
    -> [Step]
  {
    let now = input.now
    let blocked = state.userResumed.union(resumed).union(input.pausedNow).union(
      state.ledger.map(\.threadID))
    var seen: Set<String> = []
    let coolingDown = Set(
      state.pauseFailedAt.filter { now.timeIntervalSince($0.value) < pressureSpacing }.keys)
    let candidates = input.candidates
      .sorted { $0.memoryBytes > $1.memoryBytes }
      .filter { !$0.isPaused && !blocked.contains($0.threadID) }
      .filter { !coolingDown.contains($0.threadID) }
      .filter { seen.insert($0.threadID).inserted }
    var steps: [Step] = []
    if input.inMeeting {
      for candidate in candidates {
        steps.append(.pause(candidate.threadID, .meeting))
        state.ledger.append(.init(threadID: candidate.threadID, reason: .meeting, since: now))
      }
    } else if isPressure(state, now),
      let first = candidates.first(where: { !state.forceResumed.contains($0.threadID) }),
      state.lastPause.map({ now.timeIntervalSince($0) >= pressureSpacing }) ?? true
    {
      steps.append(.pause(first.threadID, .pressure))
      state.ledger.append(.init(threadID: first.threadID, reason: .pressure, since: now))
      state.lastPause = now
    }
    if state.heat, !input.inMeeting {
      let taken = blocked.union(state.ledger.map(\.threadID))
      var heatSeen: Set<String> = []
      for candidate in input.heatCandidates.sorted(by: { $0.memoryBytes > $1.memoryBytes })
      where !candidate.isPaused && !taken.contains(candidate.threadID)
        && !coolingDown.contains(candidate.threadID) && heatSeen.insert(candidate.threadID).inserted
      {
        steps.append(.pause(candidate.threadID, .heat))
        state.ledger.append(.init(threadID: candidate.threadID, reason: .heat, since: now))
      }
    }
    return steps
  }
}

extension AutoPausePlanner {
  /// The candidates a pressure pause could still take, after `plan` returned `state`: not paused,
  /// not in the ledger, not the user's, not forced back, and none whose pause failed this
  /// episode. While any is left, Q11's app quits wait: an app is the last rung (Task 5.5). One
  /// that failed may be retried after its cooldown, but it doesn't hold the apps back: it may
  /// keep failing.
  static func stillPausable(
    _ candidates: [Candidate], pausedNow: Set<String>, state: State
  ) -> [String] {
    let ledger = Set(state.ledger.map(\.threadID))
    return candidates.filter { !$0.isPaused }.map(\.threadID).filter { id in
      !pausedNow.contains(id) && !ledger.contains(id) && !state.userResumed.contains(id)
        && !state.forceResumed.contains(id) && state.pauseFailedAt[id] == nil
    }
  }
}

extension AutoPausePlanner.State {
  /// The Mac is going to sleep or just woke: pressure and calm are timed afresh. The ledger and
  /// the episode sets stay, so nothing paused is forgotten.
  mutating func resetClocks() {
    elevatedSince = nil
    calmSince = nil
    hotSince = nil
    coolSince = nil
  }

  /// Tolerant decoding: a state saved by another build still loads. Missing keys take their
  /// defaults, and a ledger entry that can't be read is skipped.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let ledger = try container.decodeIfPresent([LossyEntry].self, forKey: .ledger) ?? []
    self.ledger = ledger.compactMap(\.entry)
    elevatedSince = try container.decodeIfPresent(Date.self, forKey: .elevatedSince)
    calmSince = try container.decodeIfPresent(Date.self, forKey: .calmSince)
    lastPause = try container.decodeIfPresent(Date.self, forKey: .lastPause)
    userResumed = try container.decodeIfPresent(Set<String>.self, forKey: .userResumed) ?? []
    forceResumed = try container.decodeIfPresent(Set<String>.self, forKey: .forceResumed) ?? []
    pauseFailedAt =
      (try? container.decodeIfPresent([String: Date].self, forKey: .pauseFailedAt)) ?? [:]
    lastTick = try container.decodeIfPresent(Date.self, forKey: .lastTick)
    hotSince = try? container.decodeIfPresent(Date.self, forKey: .hotSince)
    coolSince = try? container.decodeIfPresent(Date.self, forKey: .coolSince)
    heat = (try? container.decodeIfPresent(Bool.self, forKey: .heat)) ?? false
  }

  private struct LossyEntry: Decodable {
    let entry: AutoPausePlanner.Entry?

    init(from decoder: any Decoder) throws {
      entry = try? AutoPausePlanner.Entry(from: decoder)
    }
  }
}
