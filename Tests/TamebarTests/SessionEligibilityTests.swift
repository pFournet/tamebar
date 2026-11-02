import Foundation
import Testing

@testable import Tamebar

struct SessionEligibilityTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func thread() -> AIThread {
    var thread = AIThread(
      id: "claude-10", tool: .claudeCode, name: "Claude Code", directory: "/code/atlas",
      terminal: nil, startedAt: nil, processIDs: [10, 11], memoryBytes: 300,
      cpuPercent: 0, isPaused: false, isDetached: false)
    thread.rootProcessID = 10
    thread.sessionID = "00000000-0000-4000-8000-000000000010"
    thread.agentStatus = .idle
    thread.agentStatusSince = now.addingTimeInterval(-13 * 3_600)
    return thread
  }

  @Test func pressureAndUnusedServerUseDistinctIdleThresholds() {
    let session = thread()
    let pressure = SessionEligibility.idleEligible(
      [session], now: now, lastInput: [:], minimum: PressureEndScheduler.minimumIdle)
    let unusedServer = SessionEligibility.idleEligible(
      [session], now: now, lastInput: [:], minimum: UnusedServers.unusedFor)
    #expect(pressure[session.id] == .idle(13 * 3_600))
    #expect(unusedServer[session.id] == nil)
  }

  @Test func freshBackgroundJobCancelsAutomaticEndBeforeSignal() {
    let session = thread()
    let first = SessionEligibility.autoEndCandidates(
      .init(
        threads: [session], unused: [session.id: .idle(13 * 3_600)],
        protections: [:], scope: nil, inFlight: []))
    #expect(first.map(\.id) == [session.id])

    let records: [Int32: RawProcessRecord] = [
      10: StubWorld.record(10, parent: 1, "claude"),
      11: StubWorld.record(11, parent: 10, "sleep 3600"),
    ]
    let plan = EndPlan.Decision(end: [session])
    let checked = SessionEligibility.recheckAutomatic(plan, records: records)
    #expect(checked.end.isEmpty)
    #expect(checked.becameActive == 1)
  }
}
