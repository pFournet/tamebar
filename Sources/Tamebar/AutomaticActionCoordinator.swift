import Foundation

/// Runs the three automatic ending policies from one applied scan. The pause controller's lock
/// grants action authority; this module owns the one-end-at-a-time rule, Q10 → Q18 → Q20 order,
/// Q20's port clock, and the outcomes reported to usage and the notch.
@MainActor
final class AutomaticActionCoordinator {
  enum EndKind: Equatable {
    case away, pressure, unusedServer
  }

  enum Event {
    case note(String)
    case noteOnly(String)
    case ended(UInt64)
    case paused(count: Int, freed: UInt64)
    case quit(UInt64)
    case slowed(Int)
    case resumed(Int)
    case log(String)
  }

  struct Tick {
    let now: Date
    let serverNow: Date
    let observed: AppliedProcessScan.Observation
    let records: [Int32: RawProcessRecord]
    let unused: [String: UnusedPolicy.Reason]
    let protections: [String: UnusedPolicy.Protection]
    let scope: Set<Int32>?
    let inFlight: Set<String>
    let risk: MemoryRisk
    let inMeeting: Bool
    let away: Bool
    let manuallyEnding: Bool
    let autoEnd: AutoEndSettings
    let safety: AutomaticSafety
    let home: URL
  }

  private let acts: Bool
  private let autoEnder: AutoEndController
  private let pressureEnder: PressureEndController
  private let unusedServerer: UnusedServerController
  private let emit: @MainActor (Event) -> Void
  private(set) var activeEnd: EndKind?
  private var portClockSavedAt: Date?
  var portClock: ServedPortClock
  var portClockDirectory: URL

  init(
    acts: Bool, directory: URL,
    endAutomatically: @escaping @MainActor (AIThread) async -> Bool,
    endUnderPressure: @escaping @MainActor (AIThread) async -> Bool,
    endUnusedServer: @escaping @MainActor (AIThread) async -> UnusedServerOutcome,
    emit: @escaping @MainActor (Event) -> Void
  ) {
    self.acts = acts
    self.portClock = ServedPortClock.load(directory)
    self.portClockDirectory = directory
    self.autoEnder = AutoEndController(acts: acts, end: endAutomatically)
    self.pressureEnder = PressureEndController(acts: acts, end: endUnderPressure)
    self.unusedServerer = UnusedServerController(acts: acts, end: endUnusedServer)
    self.emit = emit
  }

  /// All three policies see the same scan. A started end reserves the slot until its outcome
  /// lands, including while its own fresh scan runs. Each policy still advances its own clock.
  func run(_ tick: Tick) {
    guard acts else { return }
    runAutoEnd(tick)
    runPressureEnd(tick)
    runUnusedServers(tick)
  }

  /// Reports only actions that landed. The model supplies the pause policy's outcome; this
  /// module keeps all automatic usage and notch reporting on the same path as the ending rules.
  func recordPause(_ outcome: AutoPauseWiring.Outcome) {
    if outcome.resumed > 0 { emit(.resumed(outcome.resumed)) }
    for reopen in outcome.reopens {
      Task { [emit] in
        if let text = await reopen.value { emit(.note(text)) }
      }
    }
    for quit in outcome.quits {
      Task { [emit] in
        guard let app = await quit.value else { return }
        emit(.quit(app.memoryBytes))
        emit(.note(AppPressureWiring.note(app)))
      }
    }
    if !outcome.resumedProjects.isEmpty {
      emit(.log("Resumed \(outcome.resumedProjects.values.sorted().joined(separator: ", "))"))
    }
    guard !outcome.pauses.isEmpty else { return }
    Task { [emit] in
      let landed = await outcome.landed()
      let count = landed.sessions.count + landed.projects.count
      if count > 0 { emit(.paused(count: count, freed: landed.freed)) }
      if let text = AutoPauseWiring.note(
        paused: landed.sessions, projects: landed.projects, freed: landed.freed)
      {
        emit(.note(text))
      }
    }
  }

  /// Q17's app note stands alone; the heat note combines the slow with pauses that landed.
  func recordPriority(_ outcome: BackgroundPriority.Outcome, heatActing: Bool) -> String? {
    let count = outcome.slowed + outcome.appSlowed
    if count > 0 { emit(.slowed(count)) }
    if let appNote = outcome.appNote { emit(.note(appNote)) }
    if heatActing { return outcome.note }
    if let note = outcome.note { emit(.noteOnly(note)) }
    return nil
  }

  func recordHeat(paused: AutoPauseWiring.Outcome, slowed: String?, acting: Bool) {
    guard acting else { return }
    let heatPauses = paused.pauses.isEmpty ? nil : paused
    guard slowed != nil || heatPauses != nil else { return }
    Task { [emit] in
      let count = await heatPauses?.landedHeat() ?? 0
      if let text = Heat.note(slowed: slowed, paused: count) { emit(.note(text)) }
    }
  }

  private func runAutoEnd(_ tick: Tick) {
    let outcome = autoEnder.run(
      .init(
        now: tick.now, away: tick.away, settings: tick.autoEnd,
        scan: .init(
          threads: tick.observed.threads, unused: tick.unused,
          protections: tick.protections, scope: tick.scope, inFlight: tick.inFlight,
          records: tick.records),
        busy: tick.manuallyEnding || activeEnd != nil))
    if let note = outcome.note { emit(.note(note)) }
    if let ending = outcome.ending {
      reserve(ending, kind: .away) { [emit] ended in
        if ended { emit(.ended(outcome.endingBytes)) }
      }
    }
  }

  private func runPressureEnd(_ tick: Tick) {
    guard tick.safety.endIdleSessions else { return }
    let lastInput =
      tick.risk >= .warning
      ? WorkQueue.lastInput(tick.observed.threads, records: tick.records) : [:]
    let outcome = pressureEnder.run(
      .init(
        risk: tick.risk,
        scan: .init(
          now: tick.now, threads: tick.observed.threads, protections: tick.protections,
          scope: tick.scope, inFlight: tick.inFlight, records: tick.records,
          lastInput: lastInput),
        busy: tick.manuallyEnding || activeEnd != nil))
    if let ending = outcome.ending {
      reserve(ending, kind: .pressure) { [emit] ended in
        guard ended else { return }
        emit(.ended(outcome.endingBytes))
        emit(.note(PressureEndScheduler.note(name: outcome.name, freed: outcome.endingBytes)))
      }
    }
  }

  private func runUnusedServers(_ tick: Tick) {
    var clock = portClock
    let served = tick.observed.observePortUse(in: &clock, now: tick.serverNow)
    if clock != portClock {
      let keysChanged = Set(clock.lastUsed.keys) != Set(portClock.lastUsed.keys)
      portClock = clock
      if keysChanged || portClockSavedAt.map({ tick.now.timeIntervalSince($0) >= 60 }) ?? true {
        clock.save(portClockDirectory)
        portClockSavedAt = tick.now
      }
    }
    // The clock runs with the switch off, so enabling Q20 finds a day of connections.
    guard tick.safety.endIdleSessions, !served.isEmpty else { return }
    let old = tick.observed.threads.filter {
      (UnusedPolicy.idleFor($0, now: tick.serverNow) ?? 0) >= UnusedServers.unusedFor
        && !UnusedServers.servedPorts($0, listening: tick.observed.listeningPorts).isEmpty
    }
    guard !old.isEmpty else { return }
    var scan = UnusedServers.Scan(
      now: tick.serverNow, threads: tick.observed.threads, protections: tick.protections,
      scope: tick.scope, inFlight: tick.inFlight, records: tick.records)
    scan.listening = tick.observed.listeningPorts
    scan.directories = tick.observed.directories
    scan.lastInput = WorkQueue.lastInput(old, records: tick.records)
    scan.clock = portClock
    scan.protectedPorts = ProtectedPorts.current(
      home: tick.home, listed: tick.safety.protectedPorts)
    guard
      let ending = unusedServerer.run(
        scan, inCall: tick.inMeeting, busy: tick.manuallyEnding || activeEnd != nil)
    else { return }
    reserve(ending, kind: .unusedServer) { [emit] outcome in
      guard !outcome.servers.isEmpty else { return }
      if outcome.sessionEnded { emit(.ended(outcome.freed)) }
      emit(
        .note(
          UnusedServers.note(
            name: outcome.name, ports: outcome.servers.flatMap(\.ports),
            sessionEnded: outcome.sessionEnded, freed: outcome.freed)))
    }
  }

  private func reserve<Value: Sendable>(
    _ task: Task<Value, Never>, kind: EndKind,
    onLanding: @escaping @MainActor (Value) -> Void
  ) {
    activeEnd = kind
    Task { [weak self] in
      let value = await task.value
      guard let self else { return }
      self.activeEnd = nil
      onLanding(value)
    }
  }
}
