import Foundation

/// Re-reads an agent's own status right before Tamebar ends it (Q7).
enum AgentStatusProbe {
  struct Input {
    let thread: AIThread
    /// The home whose `.claude/sessions` the scan read.
    let home: URL
    /// The root process's start time from the scan's identity, to tell a reused pid apart.
    let startTime: TimeInterval?
  }

  /// True when nothing the agent writes has changed since the scan saw it idle. A known status
  /// without a time, a reused pid, or a Codex thread with no readable rollout is never idle here.
  static func stillIdle(_ input: Input) -> Bool {
    let thread = input.thread
    // No status to re-read: `endUnused` decides right after a fresh scan, which would have seen one.
    guard let seenSince = thread.agentStatusSince else { return thread.agentStatus == nil }
    switch thread.tool {
    case .claudeCode:
      guard let root = thread.rootProcessID, let startTime = input.startTime,
        let metadata = AIThreadNames.object(
          .init(
            url: input.home.appendingPathComponent(".claude/sessions/\(root).json"),
            limit: 64 * 1_024, tail: false)),
        let pid = metadata["pid"] as? Int, pid == root,
        AIThreadNames.registryMatches(.init(metadata: metadata, startedAt: startTime)),
        let signal = AgentSignals.claudeStatus(metadata),
        signal.status == .idle, let updated = signal.since
      else { return false }
      return abs(updated.timeIntervalSince(seenSince)) < 0.001
    case .codexCLI:
      // Every rollout the process has open (subagents too): the newest write must be the one seen.
      let written = thread.rolloutPaths.map {
        (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
      }
      guard !written.isEmpty, let newest = written.compactMap(\.self).max(),
        !written.contains(nil)
      else { return false }
      return abs(newest.timeIntervalSince(seenSince)) < 0.001
    case .codexDesktop, .cursorAgent, .otherAgent:
      return thread.agentStatus == nil
    }
  }
}

/// Which of the sessions the user chose to end are still unused at the click (Q7).
enum EndPlan {
  struct Decision: Equatable {
    var end: [AIThread] = []
    var becameActive = 0
    var gone = 0
    var inFlight = 0
  }

  /// The fresh scan `endUnused` decides from.
  struct Context {
    let threads: [String: AIThread]
    let unused: [String: UnusedPolicy.Reason]
    let protections: [String: UnusedPolicy.Protection]
    let identities: [Int32: DevProcessIdentity]
    /// Threads with a pause, resume or quit in flight.
    let stopping: Set<String>
    let home: URL
  }

  /// `decide` against the fresh scan, probing each agent with its root's scanned start time.
  static func plan(
    _ targets: [AIThread], _ context: Context,
    probe: (AgentStatusProbe.Input) -> Bool = AgentStatusProbe.stillIdle
  ) -> Decision {
    decide(
      targets: targets, fresh: context.threads, unused: context.unused,
      protections: context.protections, stopping: context.stopping
    ) { thread in
      probe(
        .init(
          thread: thread, home: context.home,
          startTime: startTime(thread, identities: context.identities)))
    }
  }

  /// The root process's start time from its scanned identity.
  static func startTime(_ thread: AIThread, identities: [Int32: DevProcessIdentity])
    -> TimeInterval?
  {
    thread.rootProcessID.flatMap { identities[$0] }.map {
      Double($0.process.startSeconds) + Double($0.process.startMicroseconds) / 1_000_000
    }
  }

  /// Looks each target up in the fresh scan. A target that is gone or has a signal in flight is
  /// skipped; one that is no longer unused, is protected, or fails `probe` counts as became
  /// active. The rest are ended, as their fresh threads.
  static func decide(
    targets: [AIThread], fresh: [String: AIThread], unused: [String: UnusedPolicy.Reason],
    protections: [String: UnusedPolicy.Protection], stopping: Set<String>,
    probe: (AIThread) -> Bool
  ) -> Decision {
    var seen: Set<String> = []
    var decision = Decision()
    for target in targets where seen.insert(target.id).inserted {
      guard let thread = fresh[target.id] else {
        decision.gone += 1
        continue
      }
      guard !stopping.contains(thread.id) else {
        decision.inFlight += 1
        continue
      }
      guard unused[thread.id] != nil, protections[thread.id] == nil, probe(thread) else {
        decision.becameActive += 1
        continue
      }
      decision.end.append(thread)
    }
    return decision
  }

  struct Outcome: Sendable {
    let thread: AIThread
    /// Every process of the thread exited after Quit.
    let quit: Bool
    /// No process matched the scanned identities any more: it had exited before the Quit.
    let exited: Bool

    init(thread: AIThread, quit: Bool, exited: Bool = false) {
      self.thread = thread
      self.quit = quit
      self.exited = exited
    }

    /// From the model's signal outcome: only "quit" means every process exited. "still-running"
    /// means one survived; nil (nothing matched the scanned identities any more) means the session
    /// had already exited, which is not a confirmed quit either.
    init(thread: AIThread, outcome: String?) {
      self.init(thread: thread, quit: outcome == "quit", exited: outcome == nil)
    }
  }

  /// The counts `endUnused` reports. A session that had already exited counts as gone; only one
  /// with a surviving process counts as still running.
  static func result(
    _ plan: Decision, requested: Int, inFlight: Int, outcomes: [Outcome]
  ) -> DevProcessModel.EndResult {
    let exited = outcomes.filter(\.exited).count
    let confirmed = outcomes.filter(\.quit).count
    return .init(
      requested: requested, confirmed: confirmed,
      stillRunning: outcomes.count - confirmed - exited, becameActive: plan.becameActive,
      gone: plan.gone + exited, inFlight: inFlight)
  }

  /// Records each confirmed quit that has a session id and a folder. Returns how many quit.
  @discardableResult
  static func log(
    _ outcomes: [Outcome], into log: inout EndedSessionLog, now: Date, automatic: Bool = false,
    pressure: Bool = false, unusedServer: Bool = false
  ) -> Int {
    let quit = outcomes.filter(\.quit)
    for outcome in quit {
      if var entry = entry(outcome.thread, now: now) {
        entry.automatic = automatic
        if pressure { entry.pressure = true }
        if unusedServer { entry.unusedServer = true }
        log.record(entry, now: now)
      }
    }
    return quit.count
  }

  /// The Ended sessions entry, or nil without a session id or a folder to resume in. Claude
  /// resumes a session only from the folder it started in, its session file's `cwd`, so that one
  /// comes first, then the scanned folder; other agents use the scanned folder, then the session
  /// file's. The idle time is kept only when the agent said it was idle.
  static func entry(_ thread: AIThread, now: Date) -> EndedSession? {
    let folder =
      thread.tool == .claudeCode
      ? thread.sessionDirectory ?? thread.directory
      : thread.directory ?? thread.sessionDirectory
    guard let id = thread.sessionID, let directory = folder else { return nil }
    return EndedSession(
      id: id, tool: thread.tool, directory: directory, name: thread.sessionName,
      idleSince: thread.agentStatus == .idle ? thread.agentStatusSince : nil, endedAt: now,
      memoryBytes: thread.memoryBytes)
  }
}
