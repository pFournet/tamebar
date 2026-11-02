import Foundation
import Testing

@testable import Tamebar

private let hour: TimeInterval = 3_600
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func idle(_ id: String, hours: Double, bytes: UInt64, protected: Bool = false)
  -> PressureEndScheduler.Candidate
{
  .init(id: id, idle: hours * hour, memoryBytes: bytes, protected: protected)
}

/// Q18: under memory pressure held 2 minutes, end the largest session idle more than 12 h, then
/// one more every 2 minutes while pressure holds.
enum PressureEndTests {}

extension PressureEndTests {
  struct Scheduler {
    private struct Sim {
      var scheduler = PressureEndScheduler()

      /// Steps once; an end it starts lands at once, as `ended` says.
      mutating func tick(
        _ seconds: TimeInterval, _ risk: MemoryRisk, _ candidates: [PressureEndScheduler.Candidate],
        ended: Bool = true
      ) -> String? {
        let id = scheduler.step(
          .init(now: t0.addingTimeInterval(seconds), risk: risk, candidates: candidates))
        if let id { scheduler.landed(id, ended: ended) }
        return id
      }

      /// Every `every` seconds from `from` through `through`: the ends started, in order.
      mutating func hold(
        _ from: TimeInterval, through: TimeInterval, every: TimeInterval = 2, _ risk: MemoryRisk,
        _ candidates: [PressureEndScheduler.Candidate]
      ) -> [(TimeInterval, String)] {
        var ends: [(TimeInterval, String)] = []
        for second in stride(from: from, through: through, by: every) {
          if let id = tick(second, risk, candidates) { ends.append((second, id)) }
        }
        return ends
      }
    }

    @Test func nothingBeforeTwoMinutesOfPressure() {
      var sim = Sim()
      let ends = sim.hold(0, through: 118, .warning, [idle("a", hours: 20, bytes: 900)])
      #expect(ends.isEmpty)
      #expect(sim.tick(120, .warning, [idle("a", hours: 20, bytes: 900)]) == "a")
    }

    @Test func criticalCountsAsPressure() {
      var sim = Sim()
      #expect(sim.hold(0, through: 118, .critical, [idle("a", hours: 20, bytes: 9)]).isEmpty)
      #expect(sim.tick(120, .critical, [idle("a", hours: 20, bytes: 9)]) == "a")
    }

    @Test func largestFirstThenOnePerTwoMinutesWhilePressureHolds() {
      var sim = Sim()
      var candidates = [
        idle("small", hours: 30, bytes: 100), idle("big", hours: 13, bytes: 900),
        idle("mid", hours: 50, bytes: 500),
      ]
      var ends: [(TimeInterval, String)] = []
      for second in stride(from: 0.0, through: 400, by: 2) {
        if let id = sim.tick(second, .warning, candidates) {
          ends.append((second, id))
          candidates.removeAll { $0.id == id }
        }
      }
      #expect(ends.map(\.1) == ["big", "mid", "small"])
      #expect(ends.map(\.0) == [120, 240, 360])
    }

    @Test func neverUnderTwelveHoursIdle() {
      var sim = Sim()
      let young = [idle("young", hours: 11.9, bytes: 9_000), idle("old", hours: 12, bytes: 1)]
      // The same candidates every tick, so "old" comes up again each 2 minutes.
      #expect(Set(sim.hold(0, through: 600, .warning, young).map(\.1)) == ["old"])
    }

    @Test func neverAProtectedSession() {
      var sim = Sim()
      let kept = [idle("kept", hours: 99, bytes: 9_000, protected: true)]
      #expect(sim.hold(0, through: 600, .critical, kept).isEmpty)
    }

    /// One reading under warning breaks the two minutes: they start again from the next warning.
    @Test func aDipRestartsTheTwoMinutes() {
      var sim = Sim()
      let candidates = [idle("a", hours: 20, bytes: 9)]
      #expect(sim.hold(0, through: 100, .warning, candidates).isEmpty)
      #expect(sim.tick(102, .normal, candidates) == nil)
      #expect(sim.hold(104, through: 222, .warning, candidates).isEmpty)
      #expect(sim.tick(224, .warning, candidates) == "a")
    }

    /// Pressure clears: it stops, and the next episode waits its own two minutes.
    @Test func stopsWhenPressureClears() {
      var sim = Sim()
      var candidates = [idle("a", hours: 20, bytes: 9), idle("b", hours: 20, bytes: 8)]
      #expect(sim.tick(120, .warning, candidates) == nil)  // first reading starts the clock
      #expect(sim.hold(122, through: 240, .warning, candidates).map(\.1) == ["a"])
      candidates.removeFirst()
      #expect(sim.hold(242, through: 600, .normal, candidates).isEmpty)
      #expect(sim.hold(602, through: 720, .warning, candidates).isEmpty)
      #expect(sim.tick(722, .warning, candidates) == "b")
    }

    @Test func oneAtATimeWhileAnEndIsInFlight() {
      var scheduler = PressureEndScheduler()
      let candidates = [idle("a", hours: 20, bytes: 9), idle("b", hours: 20, bytes: 8)]
      for second in stride(from: 0.0, through: 118, by: 2) {
        _ = scheduler.step(
          .init(now: t0.addingTimeInterval(second), risk: .warning, candidates: candidates))
      }
      #expect(
        scheduler.step(
          .init(now: t0.addingTimeInterval(120), risk: .warning, candidates: candidates))
          == "a")
      // Not landed yet: nothing more, however long.
      for second in stride(from: 122.0, through: 400, by: 2) {
        #expect(
          scheduler.step(
            .init(now: t0.addingTimeInterval(second), risk: .warning, candidates: candidates))
            == nil)
      }
      scheduler.landed("a", ended: true)
      #expect(
        scheduler.step(
          .init(now: t0.addingTimeInterval(402), risk: .warning, candidates: [candidates[1]]))
          == "b")
    }

    /// An end that didn't land (became active, still running) isn't tried again this episode, and
    /// it still took its two-minute slot.
    @Test func anEndThatDidNotLandIsNotRetriedThisEpisode() {
      var sim = Sim()
      let candidates = [idle("a", hours: 20, bytes: 9), idle("b", hours: 20, bytes: 8)]
      #expect(sim.hold(0, through: 118, .warning, candidates).isEmpty)
      #expect(sim.tick(120, .warning, candidates, ended: false) == "a")
      #expect(sim.scheduler.refused == ["a"])
      #expect(sim.hold(122, through: 238, .warning, candidates).isEmpty)
      #expect(sim.tick(240, .warning, candidates) == "b")
      #expect(sim.hold(242, through: 600, .warning, [candidates[0]]).isEmpty)
      // A new episode may try it again.
      #expect(sim.tick(602, .normal, candidates) == nil)
      #expect(sim.scheduler.refused.isEmpty)
    }

    /// A gap between ticks longer than a minute is a sleep: pressure is timed afresh.
    @Test func aWakeGapRestartsTheTwoMinutes() {
      var sim = Sim()
      let candidates = [idle("a", hours: 20, bytes: 9)]
      #expect(sim.hold(0, through: 110, .warning, candidates).isEmpty)
      #expect(sim.tick(400, .warning, candidates) == nil)
      #expect(sim.hold(402, through: 518, .warning, candidates).isEmpty)
      #expect(sim.tick(520, .warning, candidates) == "a")
    }

    /// The clock jumped back: dates in the future are brought to now, never waiting longer.
    @Test func aBackwardClockJumpDoesNotDelayIt() {
      var sim = Sim()
      let candidates = [idle("a", hours: 20, bytes: 9)]
      #expect(sim.hold(1_000, through: 1_050, .warning, candidates).isEmpty)
      #expect(sim.hold(0, through: 118, .warning, candidates).isEmpty)
      #expect(sim.tick(120, .warning, candidates) == "a")
    }

    @Test func tiesGoByID() {
      var sim = Sim()
      let candidates = [idle("b", hours: 20, bytes: 5), idle("a", hours: 20, bytes: 5)]
      #expect(sim.hold(0, through: 120, .warning, candidates).map(\.1) == ["a"])
    }
  }

  struct Note {
    @Test func namesTheSessionAndWhatCameBack() {
      #expect(
        PressureEndScheduler.note(name: "Atlas", freed: 2_000_000_000)
          == "Ended Atlas · \(ByteText.full(2_000_000_000)) back")
      #expect(PressureEndScheduler.note(name: "Atlas", freed: 0) == "Ended Atlas")
    }
  }
}

extension PressureEndTests {
  struct Wiring {
    private func thread(
      _ id: String, root: Int32, idleHours: Double? = 20, bytes: UInt64 = 10,
      paused: Bool = false, tool: AITool = .claudeCode, pids: [Int32]? = nil
    ) -> AIThread {
      var thread = AIThread(
        id: id, tool: tool, name: tool.title, directory: "/code/\(id)", terminal: nil,
        startedAt: nil, processIDs: pids ?? [root], memoryBytes: bytes, cpuPercent: 0,
        isPaused: paused, isDetached: false)
      thread.rootProcessID = root
      if let idleHours {
        thread.agentStatus = .idle
        thread.agentStatusSince = t0.addingTimeInterval(-idleHours * hour)
      } else {
        thread.agentStatus = .busy
        thread.agentStatusSince = t0
      }
      thread.sessionID = String(format: "00000000-0000-4000-8000-%012d", root)
      return thread
    }

    private func scan(
      _ threads: [AIThread], protections: [String: UnusedPolicy.Protection] = [:],
      scope: Set<Int32>? = nil, inFlight: Set<String> = [],
      records: [Int32: RawProcessRecord] = [:]
    ) -> SessionEligibility.PressureScan {
      .init(
        now: t0, threads: threads, protections: protections, scope: scope, inFlight: inFlight,
        records: records)
    }

    @Test func candidatesAreIdleInScopeRunningResumableAndNotInFlight() {
      var noID = thread("no-id", root: 15)
      noID.sessionID = nil
      let threads = [
        thread("idle", root: 10, idleHours: 20, bytes: 300),
        thread("young", root: 11, idleHours: 2),
        thread("busy", root: 12, idleHours: nil),
        thread("paused", root: 13, paused: true),
        thread("acting", root: 14),
        noID,
        thread("outside", root: 16),
        thread("desktop", root: 17, tool: .codexDesktop),
        thread("kept", root: 18),
      ]
      let candidates = SessionEligibility.pressureCandidates(
        scan(
          threads + [threads[0]], protections: ["kept": .kept, "busy": .busy],
          scope: [10, 11, 12, 13, 14, 15, 17, 18], inFlight: ["acting"]))
      #expect(
        candidates == [
          .init(id: "idle", idle: 20 * hour, memoryBytes: 300),
          .init(id: "young", idle: 2 * hour, memoryBytes: 10),
          .init(id: "kept", idle: 20 * hour, memoryBytes: 10, protected: true),
        ])
    }

    /// Q10's automatic rule: a session with something it started still running is never ended
    /// on its own.
    @Test func aSessionWithABackgroundJobIsNotACandidate() {
      let records: [Int32: RawProcessRecord] = [
        10: StubWorld.record(10, parent: 1, "claude"),
        11: StubWorld.record(11, parent: 10, "sleep 3600"),
      ]
      let candidates = SessionEligibility.pressureCandidates(
        scan(
          [thread("job", root: 10, pids: [10, 11]), thread("quiet", root: 20)], records: records))
      #expect(candidates.map(\.id) == ["quiet"])
    }

    @Test func eligibleIsTwelveHoursIdleOrMoreNeverCodexDesktop() {
      let eligible = SessionEligibility.idleEligible(
        [
          thread("old", root: 10, idleHours: 12), thread("young", root: 11, idleHours: 11.9),
          thread("busy", root: 12, idleHours: nil),
          thread("desktop", root: 13, idleHours: 50, tool: .codexDesktop),
        ], now: t0, lastInput: [:], minimum: PressureEndScheduler.minimumIdle)
      #expect(eligible == ["old": .idle(12 * hour)])
    }

    /// Q18, idle means no interaction: a keystroke in the session's terminal resets the 12 h, so
    /// a session is 12 h idle only when its agent has said idle 12 h and its terminal has had no
    /// input for 12 h.
    @Test func aKeystrokeInItsTerminalResetsTheIdleClock() {
      let threads = [
        thread("typed", root: 10, idleHours: 20, bytes: 300),
        thread("read", root: 11, idleHours: 20, bytes: 200),
        thread("untouched", root: 12, idleHours: 20, bytes: 100),
        thread("noTTY", root: 13, idleHours: 20, bytes: 50),
        thread("oldKeys", root: 14, idleHours: 13, bytes: 40),
      ]
      let lastInput = [
        "typed": t0.addingTimeInterval(-60),
        "read": t0.addingTimeInterval(-11 * hour),
        "untouched": t0.addingTimeInterval(-15 * hour),
        "oldKeys": t0.addingTimeInterval(-30 * hour),
      ]
      #expect(SessionEligibility.interactionIdle(threads[0], now: t0, lastInput: lastInput) == 60)
      #expect(
        SessionEligibility.interactionIdle(threads[2], now: t0, lastInput: lastInput) == 15 * hour)
      #expect(
        SessionEligibility.interactionIdle(threads[3], now: t0, lastInput: lastInput) == 20 * hour)
      #expect(
        SessionEligibility.interactionIdle(threads[4], now: t0, lastInput: lastInput) == 13 * hour)
      #expect(
        SessionEligibility.interactionIdle(
          thread("busy", root: 15, idleHours: nil), now: t0, lastInput: [:])
          == nil)
      // A keystroke in the future (a clock jump) is now, never a negative idle.
      #expect(
        SessionEligibility.interactionIdle(
          threads[0], now: t0, lastInput: ["typed": t0.addingTimeInterval(30)]) == 0)

      var tick = scan(threads)
      tick.lastInput = lastInput
      let candidates = SessionEligibility.pressureCandidates(tick)
      #expect(candidates.first { $0.id == "typed" }?.idle == 60)
      #expect(candidates.first { $0.id == "read" }?.idle == 11 * hour)
      // The scheduler takes the largest 12 h idle: `untouched`, never `typed` or `read`.
      var scheduler = PressureEndScheduler()
      var picked: String?
      for second in stride(from: 0.0, through: 120, by: 10) {
        picked =
          scheduler.step(
            .init(
              now: t0.addingTimeInterval(second), risk: .warning, candidates: candidates))
          ?? picked
      }
      #expect(picked == "untouched")

      let eligible = SessionEligibility.idleEligible(
        threads, now: t0, lastInput: lastInput, minimum: PressureEndScheduler.minimumIdle)
      #expect(Set(eligible.keys) == ["untouched", "noTTY", "oldKeys"])
    }

    @Test func theNameIsTheFolder() {
      #expect(SessionEligibility.name(thread("Atlas", root: 10)) == "Atlas")
    }

    @MainActor final class Calls { var ids: [String] = [] }

    @MainActor
    private func controller(acts: Bool, ended: @escaping @MainActor (AIThread) -> Bool)
      -> (PressureEndController, () -> [String])
    {
      let calls = Calls()
      let controller = PressureEndController(acts: acts) { thread in
        calls.ids.append(thread.id)
        return ended(thread)
      }
      return (controller, { calls.ids })
    }

    @MainActor
    private func run(
      _ controller: PressureEndController, _ seconds: TimeInterval, risk: MemoryRisk,
      threads: [AIThread], busy: Bool = false
    ) -> PressureEndController.Outcome {
      controller.run(
        .init(
          risk: risk,
          scan: .init(
            now: t0.addingTimeInterval(seconds), threads: threads, protections: [:], scope: nil,
            inFlight: []),
          busy: busy))
    }

    @MainActor
    @Test func endsTheLargestThroughTheModelWithItsNameAndMemory() async {
      let (controller, calls) = controller(acts: true) { _ in true }
      let threads = [
        thread("a", root: 10, idleHours: 30, bytes: 100), thread("b", root: 20, bytes: 200),
      ]
      for second in stride(from: 0.0, through: 118, by: 2) {
        #expect(run(controller, second, risk: .warning, threads: threads).ending == nil)
      }
      let first = run(controller, 120, risk: .warning, threads: threads)
      #expect(first.name == "b")
      #expect(first.endingBytes == 200)
      #expect(await first.ending?.value == true)
      #expect(calls() == ["b"])
      for second in stride(from: 122.0, through: 238, by: 2) {
        #expect(run(controller, second, risk: .warning, threads: [threads[0]]).ending == nil)
      }
      _ = await run(controller, 240, risk: .warning, threads: [threads[0]]).ending?.value
      #expect(calls() == ["b", "a"])
    }

    @MainActor
    @Test func onlyTheInstanceThatActsEnds() {
      let (controller, calls) = controller(acts: false) { _ in true }
      for second in stride(from: 0.0, through: 600, by: 2) {
        #expect(
          run(controller, second, risk: .critical, threads: [thread("a", root: 10)]).ending == nil)
      }
      #expect(calls().isEmpty)
    }

    @MainActor
    @Test func nothingWhileTheUserIsEndingSessions() {
      let (controller, calls) = controller(acts: true) { _ in true }
      for second in stride(from: 0.0, through: 600, by: 2) {
        _ = run(controller, second, risk: .warning, threads: [thread("a", root: 10)], busy: true)
      }
      #expect(calls().isEmpty)
    }

    @MainActor
    @Test func anEndThatDidNotLandIsNotRetriedThisEpisode() async {
      let (controller, calls) = controller(acts: true) { _ in false }
      let threads = [thread("a", root: 10)]
      for second in stride(from: 0.0, through: 118, by: 2) {
        _ = run(controller, second, risk: .warning, threads: threads)
      }
      #expect(await run(controller, 120, risk: .warning, threads: threads).ending?.value == false)
      for second in stride(from: 122.0, through: 600, by: 2) {
        #expect(run(controller, second, risk: .warning, threads: threads).ending == nil)
      }
      #expect(calls() == ["a"])
    }
  }
}

extension PressureEndTests {
  /// The model's own end path for Q18, with a stubbed scan and signal.
  @MainActor
  struct ModelEnds {
    /// A Claude session the agent says has been idle `hours`, with a resume command.
    static func session(hours: Double = 20, status: AgentStatus = .idle, children: [Int32] = [])
      -> AIThread
    {
      var thread = StubWorld.session(children: children)
      thread.agentStatus = status
      thread.agentStatusSince = Date.now.addingTimeInterval(-hours * hour)
      return thread
    }

    private func model(_ world: StubWorld) async -> DevProcessModel {
      let model = DevProcessModel(
        meetingMonitor: MeetingMonitor(sources: .none),
        effects: .init(snapshot: { world.snapshot() }, execute: { world.execute($0) }))
      model.endedDefaults = TestDefaults("pressure-end-model-ended").defaults
      model.statusProbe = { _ in true }
      model.memoryRiskOverride = .warning
      await model.refreshNow()
      return model
    }

    @Test func endsAnIdleSessionAndRecordsItAsEndedForMemory() async {
      let world = StubWorld([Self.session()])
      let model = await model(world)
      #expect(await model.endUnderPressure(Self.session()))
      #expect(world.signals == 1)
      #expect(model.threadMessage == nil, "an automatic end posted a row message")
      let ended = model.endedLog.sessions
      #expect(ended.count == 1 && ended.first?.pressure == true && ended.first?.automatic == true)
      world.set([])
      await model.refreshNow()
      let entry = model.stopped.first { $0.state == .ended }
      #expect(entry?.reason == .memory)
      #expect(entry?.trayDetail(now: .now) == "ended · memory")
      #expect(entry?.commandDetail == "ended · memory")
      #expect(entry?.actionTitle == "Resume")
    }

    /// The end waits for a fresh scan; memory calm by then means no signal.
    @Test func nothingIsSignalledWhenPressureClearsDuringTheRefresh() async {
      let world = StubWorld([Self.session()])
      let model = await model(world)
      world.duringNextScan {
        DispatchQueue.main.sync { MainActor.assumeIsolated { model.memoryRiskOverride = .normal } }
      }
      #expect(await !model.endUnderPressure(Self.session()))
      #expect(world.signals == 0)
    }

    /// Q18's own cutoff on the fresh scan: under 12 h idle, or busy again, no signal.
    @Test func youngOrBusyOnTheFreshScanIsNotEnded() async {
      for fresh in [Self.session(hours: 11), Self.session(status: .busy)] {
        let world = StubWorld([Self.session()])
        let model = await model(world)
        world.set([fresh])
        #expect(await !model.endUnderPressure(Self.session()))
        #expect(world.signals == 0)
      }
    }

    /// The agent wrote a status since the scan (Q7's re-read): no signal.
    @Test func aStatusWrittenSinceTheScanHoldsIt() async {
      let world = StubWorld([Self.session()])
      let model = await model(world)
      model.statusProbe = { _ in false }
      #expect(await !model.endUnderPressure(Self.session()))
      #expect(world.signals == 0)
    }

    /// Q10's automatic rule on the fresh scan: a background job holds the end.
    @Test func aBackgroundJobHoldsIt() async {
      let session = Self.session(children: [40_001])
      let world = StubWorld(
        [session],
        records: [
          40_000: StubWorld.record(40_000, parent: 1, "claude"),
          40_001: StubWorld.record(40_001, parent: 40_000, "sleep 3600"),
        ])
      let model = await model(world)
      #expect(await !model.endUnderPressure(session))
      #expect(world.signals == 0)
    }
  }
}
