import Foundation
import Testing

@testable import Tamebar

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func candidate(_ id: String, _ bytes: UInt64 = 1, paused: Bool = false)
  -> AutoPausePlanner.Candidate
{
  .init(threadID: id, memoryBytes: bytes, isPaused: paused)
}

/// One pressure entry `x` paused at t0, with warning sustained since t0.
private func pressureEpisode() -> AutoPausePlanner.State {
  var state = AutoPausePlanner.State()
  state.ledger = [.init(threadID: "x", reason: .pressure, since: t0)]
  state.elevatedSince = t0
  state.lastPause = t0
  return state
}

/// Drives the planner tick by tick, carrying its state.
private struct Sim {
  var state: AutoPausePlanner.State

  init(_ state: AutoPausePlanner.State = .init()) { self.state = state }

  @discardableResult
  mutating func tick(
    _ second: TimeInterval, risk: MemoryRisk = .normal, meeting: Bool = false,
    candidates: [AutoPausePlanner.Candidate] = [], paused: Set<String> = [],
    running: Set<String> = []
  ) -> [AutoPausePlanner.Step] {
    let out = AutoPausePlanner.plan(
      .init(
        now: at(second), risk: risk, inMeeting: meeting, candidates: candidates,
        pausedNow: paused, runningNow: running, state: state))
    state = out.state
    return out.steps
  }

  /// Ticks every `every` seconds over the range with the same input; returns every step.
  @discardableResult
  mutating func hold(
    _ from: TimeInterval, through: TimeInterval, every: TimeInterval = 5,
    risk: MemoryRisk = .normal, meeting: Bool = false,
    candidates: [AutoPausePlanner.Candidate] = [], paused: Set<String> = [],
    running: Set<String> = []
  ) -> [AutoPausePlanner.Step] {
    var steps: [AutoPausePlanner.Step] = []
    for second in stride(from: from, through: through, by: every) {
      steps += tick(
        second, risk: risk, meeting: meeting, candidates: candidates, paused: paused,
        running: running)
    }
    return steps
  }
}

struct AutoPauseTests {
  // MARK: Pressure

  @Test func pressurePausesLargestFirstOnePerThirtySeconds() {
    var sim = Sim()
    let both = [candidate("small", 100), candidate("big", 900)]
    #expect(sim.tick(0, risk: .warning, candidates: both).isEmpty)  // not yet sustained 6 s
    #expect(sim.tick(7, risk: .warning, candidates: both) == [.pause("big", .pressure)])
    let rest = [candidate("small", 100)]
    #expect(
      sim.hold(8, through: 36, every: 4, risk: .warning, candidates: rest, paused: ["big"])
        .isEmpty)
    #expect(
      sim.tick(37, risk: .warning, candidates: rest, paused: ["big"])
        == [.pause("small", .pressure)])
  }

  @Test func pressureNeedsSixUnbrokenSeconds() {
    var sim = Sim()
    let y = [candidate("y")]
    #expect(sim.hold(0, through: 3, every: 1, risk: .warning, candidates: y).isEmpty)
    #expect(sim.tick(4, candidates: y).isEmpty)
    #expect(sim.hold(5, through: 10, every: 1, risk: .warning, candidates: y).isEmpty)
    #expect(sim.tick(11, risk: .warning, candidates: y) == [.pause("y", .pressure)])
  }

  @Test func growingCountsAsCalm() {
    var sim = Sim(pressureEpisode())
    #expect(sim.hold(100, through: 125, risk: .growing, paused: ["x"]).isEmpty)
    #expect(sim.tick(130, risk: .growing, paused: ["x"]) == [.resume("x")])

    var fresh = Sim()
    let y = [candidate("y")]
    #expect(fresh.hold(0, through: 60, risk: .growing, candidates: y, running: ["y"]).isEmpty)
  }

  @Test func pressureResumesAfterThirtyCalmSecondsOldestFirst() {
    var state = AutoPausePlanner.State()
    state.ledger = [
      .init(threadID: "new", reason: .pressure, since: at(40)),
      .init(threadID: "old", reason: .pressure, since: t0),
    ]
    var sim = Sim(state)
    let both: Set<String> = ["old", "new"]
    #expect(sim.hold(100, through: 125, paused: both).isEmpty)
    #expect(sim.tick(130, paused: both) == [.resume("old")])
  }

  @Test func pressurePausesAreForcedBackAfterFiveMinutes() {
    var sim = Sim(pressureEpisode())
    #expect(sim.tick(301, risk: .critical, paused: ["x"]) == [.resume("x")])
  }

  @Test func aForcedResumeIsNotUndoneThisEpisode() {
    var sim = Sim(pressureEpisode())
    let x = [candidate("x")]
    #expect(sim.tick(301, risk: .critical, paused: ["x"]) == [.resume("x")])
    #expect(
      sim.hold(302, through: 340, every: 2, risk: .critical, candidates: x, running: ["x"])
        .isEmpty)

    // The episode ends: calm for 30 s, no meeting, empty ledger.
    sim.hold(345, through: 375, candidates: x, running: ["x"])
    #expect(sim.state.forceResumed.isEmpty)

    // A new episode may pause it again.
    #expect(
      sim.hold(380, through: 390, risk: .warning, candidates: x, running: ["x"])
        == [.pause("x", .pressure)])
  }

  @Test func aForcedBackLargestLetsTheNextLargestBePaused() {
    var state = AutoPausePlanner.State()
    state.forceResumed = ["big"]
    state.elevatedSince = t0
    var sim = Sim(state)
    let both = [candidate("big", 900), candidate("small", 100)]
    #expect(
      sim.tick(10, risk: .warning, candidates: both, running: ["big", "small"])
        == [.pause("small", .pressure)])
  }

  // MARK: The user's Resume, and what the scan sees

  @Test func aThreadSeenRunningWasResumedByTheUserAndIsLeftAlone() {
    var sim = Sim(pressureEpisode())
    let x = [candidate("x")]
    #expect(sim.tick(60, risk: .warning, candidates: x, running: ["x"]).isEmpty)
    #expect(sim.state.ledger.isEmpty)
    #expect(sim.state.userResumed == ["x"])
    #expect(sim.hold(65, through: 200, risk: .warning, candidates: x, running: ["x"]).isEmpty)
  }

  @Test func anAbsentThreadKeepsItsEntryAndIsResumedOnTime() {
    var sim = Sim(pressureEpisode())
    #expect(sim.hold(60, through: 295, risk: .warning).isEmpty)
    #expect(sim.state.ledger.map(\.threadID) == ["x"])
    #expect(sim.state.userResumed.isEmpty)
    #expect(sim.tick(300, risk: .warning) == [.resume("x")])
  }

  @Test func aPartlyStoppedThreadKeepsItsEntry() {
    // Some of x's processes are stopped: it is in neither set.
    var sim = Sim(pressureEpisode())
    #expect(sim.hold(100, through: 125).isEmpty)
    #expect(sim.state.ledger.map(\.threadID) == ["x"])
    #expect(sim.tick(130) == [.resume("x")])
  }

  @Test func aLedgerThreadListedAsACandidateIsNotPausedAgain() {
    var sim = Sim(pressureEpisode())
    let x = [candidate("x")]
    #expect(sim.tick(10, risk: .critical, meeting: true, candidates: x).isEmpty)
    #expect(sim.tick(40, risk: .critical, candidates: x).isEmpty)
    #expect(sim.state.ledger.count == 1)
  }

  @Test func stoppedThreadsAreNeverPaused() {
    var sim = Sim()
    #expect(sim.tick(0, meeting: true, candidates: [candidate("x", paused: true)]).isEmpty)
    #expect(sim.tick(5, meeting: true, candidates: [candidate("y")], paused: ["y"]).isEmpty)
    #expect(sim.state.ledger.isEmpty)
  }

  @Test func duplicateCandidatesArePausedOnce() {
    var sim = Sim()
    let twice = [candidate("x"), candidate("x")]
    #expect(sim.tick(0, meeting: true, candidates: twice) == [.pause("x", .meeting)])
    #expect(sim.state.ledger.count == 1)
  }

  @Test func aManualPauseIsNeverResumed() {
    var state = AutoPausePlanner.State()
    state.ledger = [.init(threadID: "m", reason: .meeting, since: t0)]
    var sim = Sim(state)
    #expect(sim.tick(10, paused: ["m", "manual"]) == [.resume("m")])
    #expect(sim.hold(15, through: 420, every: 15, paused: ["manual"]).isEmpty)
    #expect(sim.hold(425, through: 800, every: 15, risk: .critical, paused: ["manual"]).isEmpty)
  }

  @Test func aThreadMissedByOneScanStaysUserResumed() {
    var sim = Sim(pressureEpisode())
    let x = [candidate("x")]
    sim.tick(60, risk: .warning, candidates: x, running: ["x"])
    #expect(sim.state.userResumed == ["x"])
    sim.tick(65, risk: .warning)  // the scan misses x
    #expect(sim.state.userResumed == ["x"])
    #expect(sim.hold(70, through: 200, risk: .warning, candidates: x, running: ["x"]).isEmpty)
  }

  // MARK: Episodes

  @Test func aOneTickDipDoesNotEndTheEpisode() {
    var sim = Sim(pressureEpisode())
    let x = [candidate("x")]
    sim.tick(60, risk: .warning, candidates: x, running: ["x"])
    #expect(sim.state.userResumed == ["x"])
    sim.tick(61, candidates: x, running: ["x"])
    #expect(sim.state.userResumed == ["x"])
    #expect(
      sim.hold(62, through: 72, every: 2, risk: .warning, candidates: x, running: ["x"]).isEmpty)
  }

  @Test func calmDuringACallKeepsTheEpisode() {
    var state = AutoPausePlanner.State()
    state.userResumed = ["u"]
    state.forceResumed = ["f"]
    var sim = Sim(state)
    sim.hold(0, through: 40, meeting: true, running: ["u", "f"])
    #expect(sim.state.userResumed == ["u"])
    #expect(sim.state.forceResumed == ["f"])
  }

  @Test func calmWithAnEntryLeftKeepsTheEpisode() {
    var state = AutoPausePlanner.State()
    state.ledger = [
      .init(threadID: "a", reason: .pressure, since: t0),
      .init(threadID: "b", reason: .pressure, since: at(1)),
    ]
    state.userResumed = ["u"]
    var sim = Sim(state)
    #expect(sim.hold(100, through: 130, paused: ["a", "b"], running: ["u"]) == [.resume("a")])
    #expect(sim.state.userResumed == ["u"])
  }

  // MARK: Meetings

  @Test func meetingPausesEveryCandidateAtOnceAndResumesAllWhenItEnds() {
    var sim = Sim()
    let both = [candidate("a", 1), candidate("b", 2)]
    #expect(
      Set(sim.tick(0, meeting: true, candidates: both)) == [
        .pause("a", .meeting), .pause("b", .meeting),
      ])
    #expect(sim.hold(30, through: 1_800, every: 30, meeting: true, paused: ["a", "b"]).isEmpty)
    #expect(Set(sim.tick(1_801, paused: ["a", "b"])) == [.resume("a"), .resume("b")])
  }

  @Test func meetingPausesDoNotSetTheSpacingClock() {
    var sim = Sim()
    #expect(sim.tick(0, meeting: true, candidates: [candidate("a")]) == [.pause("a", .meeting)])
    #expect(sim.state.lastPause == nil)
  }

  @Test func aMeetingEndingUnderPressureOnlyResumesThatTick() {
    var state = AutoPausePlanner.State()
    state.ledger = [.init(threadID: "m", reason: .meeting, since: t0)]
    state.elevatedSince = t0
    var sim = Sim(state)
    #expect(sim.tick(60, risk: .critical, candidates: [candidate("m")]) == [.resume("m")])
  }

  @Test func aMeetingTakesOverPressureEntriesInsteadOfResumingThem() {
    var sim = Sim(pressureEpisode())
    #expect(
      sim.tick(10, risk: .critical, meeting: true, candidates: [candidate("m")], paused: ["x"])
        == [.pause("m", .meeting)])
    #expect(sim.state.ledger.first { $0.threadID == "x" }?.reason == .pressure)
    #expect(sim.tick(301, risk: .critical, meeting: true, paused: ["x", "m"]).isEmpty)
    #expect(sim.state.ledger.first { $0.threadID == "x" }?.reason == .meeting)
    #expect(
      Set(sim.tick(330, risk: .critical, paused: ["x", "m"])) == [.resume("x"), .resume("m")])
  }

  @Test func anEntryForcedDuringACallStaysRunningAfterIt() {
    var sim = Sim(pressureEpisode())
    #expect(sim.tick(301, risk: .critical, meeting: true, paused: ["x"]).isEmpty)
    #expect(sim.state.ledger == [.init(threadID: "x", reason: .meeting, since: at(301))])
    #expect(sim.state.forceResumed == ["x"])
    #expect(sim.tick(2_000, risk: .critical, meeting: true, paused: ["x"]).isEmpty)  // not forced
    #expect(sim.tick(2_001, risk: .critical, paused: ["x"]) == [.resume("x")])
    let x = [candidate("x")]
    #expect(
      sim.hold(2_005, through: 2_100, risk: .critical, candidates: x, running: ["x"]).isEmpty)
  }

  @Test func calmMemoryDuringACallDoesNotFlicker() {
    var sim = Sim(pressureEpisode())
    #expect(sim.hold(100, through: 140, meeting: true, paused: ["x"]).isEmpty)
    #expect(sim.state.ledger.map(\.reason) == [.meeting])
    #expect(sim.state.forceResumed.isEmpty)

    // Taken over on calm, not forced: after the call, pressure may pause it again.
    #expect(sim.tick(145, paused: ["x"]) == [.resume("x")])
    let x = [candidate("x")]
    #expect(
      sim.hold(150, through: 160, risk: .warning, candidates: x, running: ["x"])
        == [.pause("x", .pressure)])
  }

  @Test func aCallPausesAThreadForcedBackBeforeIt() {
    var sim = Sim(pressureEpisode())
    #expect(sim.tick(301, risk: .critical, paused: ["x"]) == [.resume("x")])
    #expect(
      sim.tick(320, risk: .critical, meeting: true, candidates: [candidate("x")], running: ["x"])
        == [.pause("x", .meeting)])
  }

  @Test func aCallLeavesAThreadTheUserResumedAlone() {
    var sim = Sim(pressureEpisode())
    sim.tick(60, risk: .warning, candidates: [candidate("x")], running: ["x"])
    #expect(sim.state.userResumed == ["x"])
    let both = [candidate("x", 1), candidate("y", 2)]
    #expect(
      sim.tick(70, risk: .warning, meeting: true, candidates: both, running: ["x", "y"])
        == [.pause("y", .meeting)])
  }

  // MARK: Clock

  @Test func aBackwardClockJumpDoesNotDelayTheForcedResume() {
    var state = pressureEpisode()
    state.lastTick = t0
    var sim = Sim(state)
    #expect(sim.tick(-3_600, risk: .critical, paused: ["x"]).isEmpty)
    #expect(sim.state.ledger.first?.since == at(-3_600))
    #expect(sim.state.lastPause == at(-3_600))
    #expect(sim.state.elevatedSince == at(-3_600))
    #expect(sim.hold(-3_590, through: -3_310, every: 10, risk: .critical, paused: ["x"]).isEmpty)
    #expect(sim.tick(-3_300, risk: .critical, paused: ["x"]) == [.resume("x")])
  }

  @Test func aWakeGapRestartsTheSustainCount() {
    var state = AutoPausePlanner.State()
    state.elevatedSince = t0
    state.lastTick = at(5)
    var sim = Sim(state)
    let y = [candidate("y")]
    #expect(sim.tick(100, risk: .warning, candidates: y).isEmpty)
    #expect(sim.tick(103, risk: .warning, candidates: y).isEmpty)
    #expect(sim.tick(106, risk: .warning, candidates: y) == [.pause("y", .pressure)])
  }

  @Test func refreshGapsBelowTheWakeGapKeepTheSustainCount() {
    // The model refreshes every 12 s under pressure and every 15 s in the background.
    for gap in [15.0, 18] {
      var sim = Sim()
      let y = [candidate("y")]
      #expect(sim.tick(0, risk: .warning, candidates: y).isEmpty)
      #expect(sim.tick(gap, risk: .warning, candidates: y) == [.pause("y", .pressure)])
    }
  }

  @Test func aBackwardClockJumpDoesNotDelayTheCalmResume() {
    var state = AutoPausePlanner.State()
    state.ledger = [.init(threadID: "x", reason: .pressure, since: t0)]
    state.calmSince = at(10)
    state.lastTick = at(20)
    var sim = Sim(state)
    #expect(sim.hold(-3_600, through: -3_575, paused: ["x"]).isEmpty)
    #expect(sim.tick(-3_570, paused: ["x"]) == [.resume("x")])
  }

  @Test func aWakeGapRestartsTheCalmCount() {
    var state = AutoPausePlanner.State()
    state.ledger = [.init(threadID: "x", reason: .pressure, since: t0)]
    state.calmSince = at(10)
    state.lastTick = at(20)
    var sim = Sim(state)
    #expect(sim.tick(100, paused: ["x"]).isEmpty)
    #expect(sim.hold(105, through: 125, paused: ["x"]).isEmpty)
    #expect(sim.tick(130, paused: ["x"]) == [.resume("x")])

    // Nor does the episode end on the first tick after waking.
    var episode = AutoPausePlanner.State()
    episode.userResumed = ["u"]
    episode.calmSince = at(10)
    episode.lastTick = at(20)
    var woken = Sim(episode)
    woken.tick(100, running: ["u"])
    #expect(woken.state.userResumed == ["u"])
  }

  // MARK: Persistence

  @Test func stateDecodesTolerantly() throws {
    let decoder = JSONDecoder()
    let state = AutoPausePlanner.State.self
    #expect(try decoder.decode(state, from: Data("{}".utf8)) == .init())
    #expect(try decoder.decode(state, from: Data(#"{"ledger":[]}"#.utf8)) == .init())

    let mixed = #"""
      {"ledger":[{"threadID":"bad","reason":"nap","since":0},
                 {"threadID":"good","reason":"pressure","since":0}]}
      """#
    let decoded = try decoder.decode(state, from: Data(mixed.utf8))
    #expect(
      decoded.ledger == [
        .init(threadID: "good", reason: .pressure, since: Date(timeIntervalSinceReferenceDate: 0))
      ])

    var full = pressureEpisode()
    full.userResumed = ["u"]
    full.forceResumed = ["f"]
    full.lastTick = at(9)
    full.calmSince = at(3)
    full.pauseFailedAt = ["p": at(2)]
    #expect(try decoder.decode(state, from: JSONEncoder().encode(full)) == full)
    // A bad cooldown map never drops the rest.
    let badCooldown = #"{"pauseFailedAt": 7, "forceResumed": ["f"]}"#
    let lenient = try decoder.decode(state, from: Data(badCooldown.utf8))
    #expect(lenient.pauseFailedAt.isEmpty && lenient.forceResumed == ["f"])
  }

  // MARK: A pause that stopped nothing (5.4 re-review)

  @Test func aFailingLargestCandidateLetsTheNextGoAtOnceAndWaitsThirtySeconds() {
    var state = AutoPausePlanner.State()
    state.elevatedSince = t0
    // "big" failed at 10; its slot was handed back.
    state.pauseFailedAt = ["big": at(10)]
    var sim = Sim(state)
    let both = [candidate("big", 900), candidate("small", 100)]
    #expect(sim.tick(11, risk: .warning, candidates: both) == [.pause("small", .pressure)])
    // Alone now, and the spacing clock no longer stands in the way from 41 on.
    var alone = AutoPausePlanner.State()
    alone.elevatedSince = t0
    alone.pauseFailedAt = ["big": at(10)]
    var retry = Sim(alone)
    let big = [candidate("big", 900)]
    #expect(retry.hold(11, through: 39, every: 1, risk: .warning, candidates: big).isEmpty)
    #expect(retry.tick(40, risk: .warning, candidates: big) == [.pause("big", .pressure)])
  }

  @Test func aCallWaitsThirtySecondsBeforeRetryingAFailedPause() {
    var state = AutoPausePlanner.State()
    state.pauseFailedAt = ["big": at(10)]
    var sim = Sim(state)
    let both = [candidate("big", 900), candidate("small", 100)]
    #expect(sim.tick(11, meeting: true, candidates: both) == [.pause("small", .meeting)])
    let big = [candidate("big", 900)]
    #expect(
      sim.hold(12, through: 39, every: 1, meeting: true, candidates: big, paused: ["small"])
        .isEmpty)
    #expect(
      sim.tick(40, meeting: true, candidates: big, paused: ["small"]) == [.pause("big", .meeting)])
  }

  @Test func theCooldownClearsWhenTheEpisodeEnds() {
    var state = AutoPausePlanner.State()
    state.pauseFailedAt = ["big": at(10)]
    var sim = Sim(state)
    // Calm for 30 s with nothing paused ends the episode.
    sim.hold(11, through: 26, every: 5, candidates: [candidate("big")], running: ["big"])
    #expect(sim.state.pauseFailedAt == ["big": at(10)], "kept while the episode lasts")
    sim.tick(41, running: ["big"])
    #expect(sim.state.pauseFailedAt.isEmpty)
  }
}

/// Opted-in dev-server projects share the planner and its ledger with sessions (D6.4, Task 5.4).
struct AutoPauseProjectTests {
  private let web = "project:/code/web"

  @Test func aProjectIsPausedAfterSixSecondsOfPressure() {
    var sim = Sim()
    let project = [candidate(web, 500)]
    #expect(sim.hold(0, through: 5, every: 1, risk: .warning, candidates: project).isEmpty)
    #expect(sim.tick(6, risk: .warning, candidates: project) == [.pause(web, .pressure)])
  }

  @Test func aProjectResumesOnlyAfterThirtyCalmSeconds() {
    var sim = Sim()
    let project = [candidate(web, 500)]
    sim.hold(0, through: 6, every: 1, risk: .warning, candidates: project)
    #expect(sim.state.ledger.map(\.threadID) == [web])
    #expect(sim.hold(7, through: 36, every: 1, paused: [web]).isEmpty)
    #expect(sim.tick(37, paused: [web]) == [.resume(web)])
  }

  @Test func aProjectIsForcedBackAfterFiveMinutes() {
    var sim = Sim()
    let project = [candidate(web, 500)]
    sim.hold(0, through: 6, every: 1, risk: .warning, candidates: project)
    #expect(sim.hold(10, through: 305, every: 5, risk: .critical, paused: [web]).isEmpty)
    #expect(sim.tick(306, risk: .critical, paused: [web]) == [.resume(web)])
  }

  @Test func aProjectTheUserResumedIsDroppedAndNotPausedAgainThisEpisode() {
    var sim = Sim()
    let project = [candidate(web, 500)]
    sim.hold(0, through: 6, every: 1, risk: .warning, candidates: project)
    #expect(sim.tick(8, risk: .warning, candidates: project, running: [web]).isEmpty)
    #expect(sim.state.ledger.isEmpty)
    #expect(sim.state.userResumed == [web])
    #expect(
      sim.hold(10, through: 120, every: 5, risk: .warning, candidates: project, running: [web])
        .isEmpty)
  }

  @Test func sessionsAndProjectsShareOnePausePerThirtySecondsLargestFirst() {
    var sim = Sim()
    let both = [candidate("claudeCode-10-1", 300), candidate(web, 900)]
    #expect(sim.tick(0, risk: .warning, candidates: both).isEmpty)
    #expect(sim.tick(6, risk: .warning, candidates: both) == [.pause(web, .pressure)])
    let rest = [candidate("claudeCode-10-1", 300)]
    #expect(
      sim.hold(7, through: 35, every: 1, risk: .warning, candidates: rest, paused: [web])
        .isEmpty)
    #expect(
      sim.tick(36, risk: .warning, candidates: rest, paused: [web])
        == [.pause("claudeCode-10-1", .pressure)])
  }

  @Test func aCallPausesProjectsWithSessionsAtOnce() {
    var sim = Sim()
    let both = [candidate("claudeCode-10-1", 300), candidate(web, 900)]
    #expect(
      Set(sim.tick(0, meeting: true, candidates: both))
        == [.pause(web, .meeting), .pause("claudeCode-10-1", .meeting)])
    #expect(
      Set(sim.tick(1, paused: [web, "claudeCode-10-1"]))
        == [.resume(web), .resume("claudeCode-10-1")])
  }
}
