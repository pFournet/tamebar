import Darwin
import Foundation
import Testing

@testable import Tamebar

/// Acting on heat (Q13, 2026-10-27): serious or critical for 30 s slows heavy work and
/// pauses idle sessions still using CPU; 60 s back at nominal or fair undoes both.
enum HeatTests {}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func candidate(_ id: String, _ bytes: UInt64 = 1) -> AutoPausePlanner.Candidate {
  .init(threadID: id, memoryBytes: bytes, isPaused: false)
}

/// Drives the planner tick by tick with a thermal state, carrying its state.
private struct Sim {
  var state = AutoPausePlanner.State()

  @discardableResult
  mutating func tick(
    _ second: TimeInterval, thermal: ThermalStatus = .nominal, risk: MemoryRisk = .normal,
    meeting: Bool = false, candidates: [AutoPausePlanner.Candidate] = [],
    heat: [AutoPausePlanner.Candidate] = [], paused: Set<String> = [],
    running: Set<String> = []
  ) -> [AutoPausePlanner.Step] {
    let out = AutoPausePlanner.plan(
      .init(
        now: at(second), risk: risk, inMeeting: meeting, candidates: candidates,
        pausedNow: paused, runningNow: running, state: state, thermal: thermal,
        heatCandidates: heat))
    state = out.state
    return out.steps
  }

  /// Ticks every `every` seconds over the range with the same input; returns every step.
  @discardableResult
  mutating func hold(
    _ from: TimeInterval, through: TimeInterval, every: TimeInterval = 5,
    thermal: ThermalStatus = .nominal, risk: MemoryRisk = .normal, meeting: Bool = false,
    heat: [AutoPausePlanner.Candidate] = [], paused: Set<String> = [],
    running: Set<String> = []
  ) -> [AutoPausePlanner.Step] {
    var steps: [AutoPausePlanner.Step] = []
    for second in stride(from: from, through: through, by: every) {
      steps += tick(
        second, thermal: thermal, risk: risk, meeting: meeting, heat: heat, paused: paused,
        running: running)
    }
    return steps
  }

  /// Hot from 0 through 31 s, with `heat` candidates: Tamebar acts at 31 s.
  mutating func heatUp(_ heat: [AutoPausePlanner.Candidate] = [candidate("w")])
    -> [AutoPausePlanner.Step]
  {
    hold(0, through: 31, every: 1, thermal: .serious, heat: heat)
  }
}

// MARK: The trigger

extension HeatTests {
  struct Trigger {
    @Test func twentyNineSecondsOfSeriousDoesNothing() {
      var sim = Sim()
      #expect(
        sim.hold(0, through: 29, every: 1, thermal: .serious, heat: [candidate("w")]).isEmpty)
      #expect(!AutoPausePlanner.isHeat(sim.state))
    }

    @Test func thirtyOneSecondsActs() {
      var sim = Sim()
      #expect(
        sim.hold(0, through: 29, every: 1, thermal: .serious, heat: [candidate("w")]).isEmpty)
      #expect(sim.tick(31, thermal: .serious, heat: [candidate("w")]) == [.pause("w", .heat)])
      #expect(AutoPausePlanner.isHeat(sim.state))
    }

    @Test func criticalCountsAsHot() {
      var sim = Sim()
      sim.hold(0, through: 29, every: 1, thermal: .critical)
      #expect(sim.tick(30, thermal: .critical, heat: [candidate("w")]) == [.pause("w", .heat)])
    }

    @Test func fairIsNeverHot() {
      var sim = Sim()
      #expect(sim.hold(0, through: 300, every: 5, thermal: .fair, heat: [candidate("w")]).isEmpty)
      #expect(!AutoPausePlanner.isHeat(sim.state))
    }

    /// One cool reading restarts the 30 s, so heat that flickers never acts.
    @Test func flappingDoesNothing() {
      var sim = Sim()
      var steps: [AutoPausePlanner.Step] = []
      for second in stride(from: 0.0, through: 300, by: 5) {
        let hot = Int(second / 5) % 6 != 5
        steps += sim.tick(
          second, thermal: hot ? .serious : .nominal, heat: [candidate("w")])
      }
      #expect(steps.isEmpty)
      #expect(!AutoPausePlanner.isHeat(sim.state))
    }

    @Test func clearsAfterSixtyCoolSecondsAndResumes() {
      var sim = Sim()
      #expect(sim.heatUp() == [.pause("w", .heat)])
      #expect(sim.state.ledger.map(\.reason) == [.heat])
      // Fair counts as cool; nothing resumes before 60 s.
      #expect(sim.hold(40, through: 99, every: 1, thermal: .fair, paused: ["w"]).isEmpty)
      #expect(AutoPausePlanner.isHeat(sim.state))
      #expect(sim.tick(100, thermal: .nominal, paused: ["w"]) == [.resume("w")])
      #expect(!AutoPausePlanner.isHeat(sim.state))
      #expect(sim.state.ledger.isEmpty)
    }

    /// A single hot reading while cooling restarts the 60 s.
    @Test func aHotReadingWhileCoolingRestartsTheClear() {
      var sim = Sim()
      sim.heatUp()
      #expect(sim.hold(40, through: 90, every: 5, paused: ["w"]).isEmpty)
      #expect(sim.tick(95, thermal: .serious, paused: ["w"]).isEmpty)
      #expect(sim.hold(100, through: 155, every: 5, paused: ["w"]).isEmpty)
      #expect(sim.tick(160, paused: ["w"]) == [.resume("w")])
    }

    /// After a sleep the heat is timed afresh, like memory pressure.
    @Test func aSleepRestartsTheThirtySeconds() {
      var sim = Sim()
      sim.hold(0, through: 20, every: 5, thermal: .serious)
      #expect(sim.tick(200, thermal: .serious, heat: [candidate("w")]).isEmpty)
      #expect(sim.tick(225, thermal: .serious, heat: [candidate("w")]).isEmpty)
      #expect(sim.tick(230, thermal: .serious, heat: [candidate("w")]) == [.pause("w", .heat)])
    }

    @Test func idleSessionsThatTurnUpLaterInTheEpisodeArePausedToo() {
      var sim = Sim()
      #expect(sim.heatUp() == [.pause("w", .heat)])
      #expect(
        sim.tick(40, thermal: .serious, heat: [candidate("w"), candidate("v")], paused: ["w"])
          == [.pause("v", .heat)])
    }

    @Test func allIdleSessionsArePausedAtOnceLargestFirst() {
      var sim = Sim()
      #expect(
        sim.heatUp([candidate("small", 10), candidate("big", 900)])
          == [.pause("big", .heat), .pause("small", .heat)])
    }

    @Test func memoryCandidatesAreNotPausedForHeat() {
      var sim = Sim()
      var steps: [AutoPausePlanner.Step] = []
      for second in stride(from: 0.0, through: 60, by: 1) {
        steps += sim.tick(second, thermal: .serious, candidates: [candidate("m")])
      }
      #expect(steps.isEmpty)
    }

    /// Never anything during a call: the call's own rules hold.
    @Test func duringACallHeatPausesNothing() {
      var sim = Sim()
      #expect(
        sim.hold(
          0, through: 120, every: 1, thermal: .critical, meeting: true, heat: [candidate("w")]
        )
        .isEmpty)
    }

    @Test func theUsersResumeHoldsForTheRestOfTheEpisode() {
      var sim = Sim()
      sim.heatUp()
      #expect(sim.tick(40, thermal: .serious, heat: [candidate("w")], running: ["w"]).isEmpty)
      #expect(sim.state.ledger.isEmpty)
      #expect(sim.hold(45, through: 200, thermal: .serious, heat: [candidate("w")]).isEmpty)
    }

    @Test func savedAndLoadedTheEpisodeHolds() throws {
      var sim = Sim()
      sim.heatUp()
      let data = try JSONEncoder().encode(sim.state)
      let loaded = try JSONDecoder().decode(AutoPausePlanner.State.self, from: data)
      #expect(loaded == sim.state)
      #expect(AutoPausePlanner.isHeat(loaded))
      let old = try JSONDecoder().decode(AutoPausePlanner.State.self, from: Data("{}".utf8))
      #expect(!AutoPausePlanner.isHeat(old))
    }
  }
}

// MARK: Heat and memory together

extension HeatTests {
  struct Merge {
    /// Heat clears while memory pressure holds: what heat paused is resumed. Until Q18 memory took
    /// it over and kept it paused on its own rules; idle sessions are no longer paused for memory.
    @Test func heatClearingUnderMemoryPressureResumesItsPauses() {
      var sim = Sim()
      sim.heatUp()
      #expect(
        sim.hold(32, through: 100, every: 1, risk: .warning, paused: ["w"]) == [.resume("w")])
      #expect(!AutoPausePlanner.isHeat(sim.state))
      #expect(sim.state.ledger.isEmpty)
    }

    /// Memory calms while heat holds: heat keeps what memory paused until the Mac cools.
    @Test func memoryCalmingWhileHotResumesNothingEarly() {
      var sim = Sim()
      #expect(sim.hold(0, through: 6, every: 1, risk: .warning).isEmpty)
      #expect(
        sim.tick(7, thermal: .serious, risk: .warning, candidates: [candidate("m")])
          == [.pause("m", .pressure)])
      // Hot from 7 s, memory calm from 8 s: memory would resume m at 38 s.
      #expect(sim.hold(8, through: 120, every: 1, thermal: .serious, paused: ["m"]).isEmpty)
      #expect(sim.state.ledger.map(\.reason) == [.heat])
      #expect(sim.hold(121, through: 180, every: 1, paused: ["m"]).isEmpty)
      #expect(sim.tick(181, paused: ["m"]) == [.resume("m")])
    }

    /// The forced resume after 300 s doesn't fire under heat either: heat takes it over.
    @Test func aForcedResumeIsTakenOverByHeat() {
      var sim = Sim()
      sim.hold(0, through: 6, every: 1, risk: .warning)
      #expect(sim.tick(7, risk: .warning, candidates: [candidate("m")]) == [.pause("m", .pressure)])
      #expect(
        sim.hold(8, through: 320, every: 4, thermal: .serious, risk: .warning, paused: ["m"])
          .isEmpty)
      #expect(sim.state.ledger.map(\.reason) == [.heat])
    }

    /// A call ending while hot hands its pauses to heat; heat clearing in a call hands them to
    /// the call.
    @Test func aCallAndHeatHandOverToEachOther() {
      var sim = Sim()
      sim.heatUp()
      #expect(sim.hold(32, through: 100, every: 1, meeting: true, paused: ["w"]).isEmpty)
      #expect(sim.state.ledger.map(\.reason) == [.meeting])
      #expect(sim.tick(101, paused: ["w"]) == [.resume("w")])
    }
  }
}

// MARK: Who heat may pause

private func thread(
  _ id: String, root: Int32, children: [Int32] = [], status: AgentStatus? = .idle,
  paused: Bool = false, tool: AITool = .claudeCode, bytes: UInt64 = 10
) -> AIThread {
  var thread = AIThread(
    id: id, tool: tool, name: "Claude Code", directory: "/code/\(id)", terminal: nil,
    startedAt: nil, processIDs: [root] + children, memoryBytes: bytes, cpuPercent: 0,
    isPaused: paused, isDetached: false)
  thread.rootProcessID = root
  thread.agentStatus = status
  return thread
}

private func heatScan(
  _ threads: [AIThread], cpu: [String: Double],
  protections: [String: UnusedPolicy.Protection] = [:],
  jobs: Set<String> = [], frontApp: Int32? = nil, stopped: Set<Int32> = [],
  inFlight: Set<String> = [], scope: Set<Int32>? = nil
) -> AutoPauseWiring.HeatScan {
  .init(
    threads: threads, protections: protections, scope: scope, stopped: stopped,
    inFlight: inFlight, cpu: cpu, jobs: jobs, frontApp: frontApp)
}

extension HeatTests {
  struct Candidates {
    @Test func onlyIdleUnprotectedSessionsAboveFivePercent() {
      let threads = [
        thread("hot", root: 10, bytes: 300),
        thread("cool", root: 20),
        thread("busy", root: 30, status: .busy),
        thread("shell", root: 40, status: .shell),
        thread("unknown", root: 50, status: nil),
        thread("kept", root: 60),
        thread("serving", root: 70),
        thread("job", root: 80),
        thread("front", root: 90, children: [91]),
        thread("paused", root: 100, paused: true),
        thread("stopped", root: 110, children: [111]),
        thread("unseen", root: 120),
        thread("desktop", root: 130, tool: .codexDesktop),
        thread("moved", root: 140),
      ]
      let everyone = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, 40.0) })
      var cpu = everyone
      cpu["cool"] = 5
      cpu["unseen"] = nil
      var probed: [String] = []
      let found = AutoPauseWiring.heatCandidates(
        heatScan(
          threads, cpu: cpu,
          protections: ["kept": .kept, "serving": .serving],
          jobs: ["job"], frontApp: 91, stopped: [111])
      ) { thread in
        probed.append(thread.id)
        return thread.id != "moved"
      }
      #expect(found == [.init(threadID: "hot", memoryBytes: 300, isPaused: false)])
      #expect(probed == ["hot", "moved"], "the live re-read runs last")
    }

    /// The agent's status alone keeps a busy session out, even before its protection is known.
    @Test func aBusySessionIsNeverACandidateEvenUnprotected() {
      let found = AutoPauseWiring.heatCandidates(
        heatScan([thread("busy", root: 30, status: .busy)], cpu: ["busy": 90])
      ) { _ in true }
      #expect(found.isEmpty)
    }

    @Test func keptProjectAndBusyProtectionsKeepASessionOut() {
      let threads = [thread("a", root: 10), thread("b", root: 20)]
      let found = AutoPauseWiring.heatCandidates(
        heatScan(
          threads, cpu: ["a": 50, "b": 50], protections: ["a": .keptProject, "b": .busy])
      ) { _ in true }
      #expect(found.isEmpty)
    }

    @Test func inFlightAndOutOfScopeAreLeftAlone() {
      let threads = [thread("a", root: 10), thread("b", root: 20)]
      let found = AutoPauseWiring.heatCandidates(
        heatScan(threads, cpu: ["a": 50, "b": 50], inFlight: ["a"], scope: [10, 20])
      ) { _ in true }
      #expect(found.map(\.threadID) == ["b"])
      let none = AutoPauseWiring.heatCandidates(
        heatScan(threads, cpu: ["a": 50, "b": 50], scope: [])
      ) { _ in true }
      #expect(none.isEmpty)
    }
  }

  struct Window {
    @Test func averagesOverTheLastThirtySecondsOnceSeenThatLong() {
      var window = CPUWindow()
      window.record(["a": 10], at: at(0))
      window.record(["a": 10], at: at(15))
      #expect(window.average("a", now: at(15)) == nil)
      window.record(["a": 2], at: at(29))
      #expect(window.average("a", now: at(29)) == nil, "seen 29 s only")
      window.record(["a": 2], at: at(30))
      // 0–15 at 10 %, 15–29 at 2 %, 29–30 at 2 %.
      let average = window.average("a", now: at(30)) ?? -1
      #expect(abs(average - (10 * 15 + 2 * 15) / 30) < 0.001)
      window.record(["a": 2], at: at(60))
      #expect(window.average("a", now: at(60)) == 2)
    }

    @Test func aSessionMissingFromAScanStartsOver() {
      var window = CPUWindow()
      window.record(["a": 10, "b": 10], at: at(0))
      window.record(["b": 10], at: at(15))
      window.record(["a": 10, "b": 10], at: at(30))
      #expect(window.average("a", now: at(30)) == nil)
      #expect(window.average("b", now: at(30)) == 10)
      #expect(window.averages(now: at(30)) == ["b": 10])
    }

    @Test func keepsOnlyWhatTheWindowNeeds() {
      var window = CPUWindow()
      for second in stride(from: 0.0, through: 300, by: 1) {
        window.record(["a": 7], at: at(second))
      }
      #expect((window.samples["a"]?.count ?? 0) <= 32)
      #expect(window.average("a", now: at(300)) == 7)
    }
  }
}

// MARK: What Tamebar says

extension HeatTests {
  struct Text {
    @Test func theNoteSaysWhatWasSlowedAndPaused() {
      #expect(Heat.note(slowed: "Slowed 2 builds", paused: 0) == "Mac hot · slowed 2 builds")
      #expect(Heat.note(slowed: "Slowed 1 build", paused: 0) == "Mac hot · slowed 1 build")
      #expect(Heat.note(slowed: nil, paused: 1) == "Mac hot · paused 1 idle session")
      #expect(Heat.note(slowed: nil, paused: 3) == "Mac hot · paused 3 idle sessions")
      #expect(
        Heat.note(slowed: "Slowed 2 builds", paused: 1)
          == "Mac hot · slowed 2 builds, paused 1 idle session")
      #expect(
        Heat.note(slowed: "Slowed 3 tasks of Fix login", paused: 0)
          == "Mac hot · slowed 3 tasks of Fix login")
      #expect(Heat.note(slowed: nil, paused: 0) == nil, "no note when it did nothing")
    }

  }
}

// MARK: Background priority, the CLI and the e2e control

extension HeatTests {
  struct Wiring {
    @Test func heatSlowsAtOnceAndRestoresWhenItClears() {
      var clock = BackgroundPriority.Clock()
      #expect(BackgroundPriority.advance(&clock, now: at(0), active: false) == .restore)
      #expect(BackgroundPriority.advance(&clock, now: at(31), active: false, heat: true) == .slow)
      #expect(BackgroundPriority.advance(&clock, now: at(40), active: false, heat: true) == .slow)
      #expect(BackgroundPriority.advance(&clock, now: at(100), active: false) == .restore)
    }

    /// CPU strain still holding keeps what heat slowed until its own calm.
    @Test func cpuStrainOutlastingHeatHoldsTheSlow() {
      var clock = BackgroundPriority.Clock()
      #expect(BackgroundPriority.advance(&clock, now: at(0), active: true, heat: true) == .slow)
      #expect(BackgroundPriority.advance(&clock, now: at(20), active: true, heat: true) == .slow)
      #expect(BackgroundPriority.advance(&clock, now: at(25), active: false) == .hold)
      #expect(BackgroundPriority.advance(&clock, now: at(54), active: false) == .hold)
      #expect(BackgroundPriority.advance(&clock, now: at(56), active: false) == .restore)
    }

    @Test func statusCarriesTheThermalStateAndWhetherTamebarActs() throws {
      var record = AutoPauseWiring.Record()
      record.state.heat = true
      func status(_ thermal: ThermalStatus, running: Int32?) throws -> [String: Any] {
        let reading = CLISystemReading(
          memory: MemoryGuardSample(
            date: t0, pressure: .normal, available: 8, total: 16, compressed: 0, swapUsed: 0,
            swapOutBytes: 0),
          cpu: 0.5, diskFree: 1, diskTotal: 2, leads: ResourceLeads(cpu: nil, memory: nil),
          call: nil, thermal: thermal)
        let report = CLIReport.status(
          .init(
            reading: reading, state: CLIState(autopause: record), tamebarPID: running,
            directory: URL(fileURLWithPath: "/data"), now: t0, label: { _ in nil }))
        let data = try CLIReport.encoder.encode(report)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schema"] as? Int == 1)
        if thermal == .serious, running != nil {
          let text = CLIText.status(report, timeZone: .gmt)
          #expect(
            text.contains(
              "Heat     serious · Tamebar slows heavy work and pauses idle sessions until it cools")
          )
        }
        if thermal == .nominal, running == nil {
          #expect(CLIText.status(report, timeZone: .gmt).contains("Heat     nominal\n"))
        }
        return try #require(object["thermal"] as? [String: Any])
      }
      let hot = try status(.serious, running: 42)
      #expect(hot["state"] as? String == "serious")
      #expect(hot["acting"] as? Bool == true)
      #expect(Set(hot.keys) == ["state", "acting"])
      let stopped = try status(.critical, running: nil)
      #expect(stopped["state"] as? String == "critical")
      #expect(stopped["acting"] as? Bool == false, "only a running Tamebar acts")
      let cool = try status(.nominal, running: 42)
      #expect(cool["state"] as? String == "nominal")
      #expect(cool["acting"] as? Bool == true, "still acting until 60 s of cool")
      _ = try status(.nominal, running: nil)
      #expect(try status(.fair, running: 42)["state"] as? String == "fair")
    }

    @Test func aHeatPauseReadsAsHeatInTheCLI() {
      let paused = CLIReport.paused(
        .init(threadID: "claudeCode-4242-1799990000", reason: .heat, since: t0),
        label: { _ in "notes" })
      #expect(paused.reason == "heat")
    }

    @Test func theE2EControlForcesTheThermalState() throws {
      let control = try JSONDecoder().decode(
        E2EMode.Control.self, from: Data(#"{"pressure": 0, "thermal": "serious"}"#.utf8))
      #expect(control.thermal == .serious)
      var real = PressureAssessment.checking
      real.thermal = .critical
      #expect(real.forcing(control).thermal == .serious)
      // A control that forces anything else hides this Mac's real heat.
      #expect(real.forcing(E2EMode.Control(pressure: .normal)).thermal == .nominal)
      #expect(real.forcing(E2EMode.Control()).thermal == .critical)
      let bad = try JSONDecoder().decode(
        E2EMode.Control.self, from: Data(#"{"thermal": "lava", "cpu": true}"#.utf8))
      #expect(bad.thermal == nil)
      #expect(bad.cpu == true)
    }

    @Test func aThermalChangeIsPublished() {
      var next = PressureAssessment.checking
      next.thermal = .serious
      #expect(PressureAssessment.checking.publishes(.init(next: next, active: false)))
    }

    @Test func thermalStatusMapsProcessInfo() {
      #expect(ThermalStatus(ProcessInfo.ThermalState.nominal) == .nominal)
      #expect(ThermalStatus(ProcessInfo.ThermalState.fair) == .fair)
      #expect(ThermalStatus(ProcessInfo.ThermalState.serious) == .serious)
      #expect(ThermalStatus(ProcessInfo.ThermalState.critical) == .critical)
      #expect(ThermalStatus.serious.isHot && ThermalStatus.critical.isHot)
      #expect(!ThermalStatus.fair.isHot && !ThermalStatus.nominal.isHot)
    }
  }
}
