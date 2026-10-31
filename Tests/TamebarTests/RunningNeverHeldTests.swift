import Foundation
import Testing

@testable import Tamebar

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Q19: running sessions are never held for memory. Q14's work queue is gone: busy sessions under
/// memory pressure, however long it holds, are never paused, and a session an older build queued
/// is resumed at the first tick, whatever holds then (pressure, a call, heat).
struct RunningNeverHeldTests {
  private func input(
    _ second: TimeInterval, risk: MemoryRisk, state: AutoPausePlanner.State,
    running: Set<String>, paused: Set<String> = [], meeting: Bool = false,
    thermal: ThermalStatus = .nominal
  ) -> AutoPausePlanner.Input {
    var input = AutoPausePlanner.Input(
      now: t0.addingTimeInterval(second), risk: risk, inMeeting: meeting, candidates: [],
      pausedNow: paused, runningNow: running, state: state)
    input.thermal = thermal
    return input
  }

  @Test func busySessionsUnderLongPressureAreNeverPaused() {
    var state = AutoPausePlanner.State()
    let busy: Set<String> = ["first", "second", "third"]
    for second in stride(from: 0.0, through: 1_800, by: 5) {
      for risk in [MemoryRisk.warning, .critical] {
        let output = AutoPausePlanner.plan(
          input(second, risk: risk, state: state, running: busy))
        #expect(output.steps.isEmpty, "a step at \(second) s under \(risk)")
        state = output.state
      }
    }
    #expect(state.ledger.isEmpty)
  }

  @Test(arguments: [
    (MemoryRisk.critical, false, ThermalStatus.nominal),
    (MemoryRisk.warning, true, ThermalStatus.nominal),
    (MemoryRisk.warning, false, ThermalStatus.critical),
    (MemoryRisk.normal, false, ThermalStatus.nominal),
  ])
  func aSessionAnOlderBuildQueuedResumesAtTheFirstTick(
    risk: MemoryRisk, meeting: Bool, thermal: ThermalStatus
  ) {
    var state = AutoPausePlanner.State()
    state.ledger = [
      .init(threadID: "queued", reason: .queue, since: t0.addingTimeInterval(-3_600)),
      .init(threadID: "call", reason: .meeting, since: t0.addingTimeInterval(-60)),
    ]
    state.heat = thermal.isHot
    state.hotSince = thermal.isHot ? t0.addingTimeInterval(-120) : nil
    state.lastTick = t0.addingTimeInterval(-1)
    let output = AutoPausePlanner.plan(
      input(
        0, risk: risk, state: state, running: [], paused: ["queued", "call"], meeting: meeting,
        thermal: thermal))
    #expect(output.steps.first == .resume("queued"))
    #expect(!output.state.ledger.contains { $0.threadID == "queued" })
    #expect(!output.steps.contains(.pause("queued", .meeting)))
    #expect(!output.steps.contains(.pause("queued", .heat)))
    #expect(!output.state.ledger.contains { $0.reason == .queue })
  }

  /// Resumed outside Tamebar before the first tick (`kill -CONT`): it just leaves the ledger.
  @Test func aQueuedSessionAlreadyRunningLeavesTheLedger() {
    var state = AutoPausePlanner.State()
    state.ledger = [.init(threadID: "queued", reason: .queue, since: t0)]
    let output = AutoPausePlanner.plan(
      input(1, risk: .warning, state: state, running: ["queued"]))
    #expect(output.steps.isEmpty)
    #expect(output.state.ledger.isEmpty)
  }

  /// A `queue` entry still decodes, so an upgrade never forgets a session it must resume. A ledger
  /// entry with a reason this build doesn't know is skipped, never the whole state; the queue's
  /// old clocks are ignored.
  @Test func aQueueEntryDecodesAndAnUnknownReasonIsSkipped() throws {
    let json = """
      {"ledger": [{"threadID": "a", "reason": "queue", "since": 0},
                  {"threadID": "b", "reason": "later", "since": 0}],
       "lastQueue": 0, "lastDequeue": 0}
      """
    let state = try JSONDecoder().decode(AutoPausePlanner.State.self, from: Data(json.utf8))
    #expect(state.ledger.map(\.threadID) == ["a"])
    #expect(state.ledger.first?.reason == .queue)
  }
}
