import Foundation
import Testing

@testable import Tamebar

@MainActor
struct AutomaticActionCoordinatorTests {
  @Test func priorityReportsAppAndWorkNotesWithoutCombiningThem() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var events: [String] = []
    let coordinator = AutomaticActionCoordinator(
      acts: true, directory: directory,
      endAutomatically: { _ in false }, endUnderPressure: { _ in false },
      endUnusedServer: { _ in UnusedServerOutcome() },
      emit: { event in
        switch event {
        case .slowed(let count): events.append("slowed:\(count)")
        case .note(let text), .noteOnly(let text): events.append("note:\(text)")
        default: break
        }
      })
    var outcome = BackgroundPriority.Outcome()
    outcome.slowed = 2
    outcome.appSlowed = 1
    outcome.appNote = "Slowed Loom"
    outcome.note = "Slowed 2 builds"

    #expect(coordinator.recordPriority(outcome, heatActing: false) == nil)
    #expect(events == ["slowed:3", "note:Slowed Loom", "note:Slowed 2 builds"])
  }

  @Test func anAwayEndTakesTheSlotBeforePressureEndOnTheSameTick() async {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var thread = AIThread(
      id: "claude-10", tool: .claudeCode, name: "Claude Code", directory: "/code/atlas",
      terminal: nil, startedAt: nil, processIDs: [10], memoryBytes: 300,
      cpuPercent: 0, isPaused: false, isDetached: false)
    thread.rootProcessID = 10
    thread.sessionID = "00000000-0000-4000-8000-000000000010"
    thread.agentStatus = .idle
    thread.agentStatusSince = now.addingTimeInterval(-2 * UnusedPolicy.day)

    var applied = AppliedProcessScan()
    let observed = applied.apply(
      DevProcessSnapshot(
        processes: [], identities: [:], threads: [thread], resources: [], portsComplete: true))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var pressureEnds = 0
    let coordinator = AutomaticActionCoordinator(
      acts: true, directory: directory,
      endAutomatically: { _ in true },
      endUnderPressure: { _ in
        pressureEnds += 1
        return true
      },
      endUnusedServer: { _ in UnusedServerOutcome() }, emit: { _ in })

    func tick(_ date: Date, away: Bool) -> AutomaticActionCoordinator.Tick {
      .init(
        now: date, serverNow: date, observed: observed, records: [:],
        unused: [thread.id: .idle(2 * UnusedPolicy.day)], protections: [:], scope: nil,
        inFlight: [], risk: .warning, inMeeting: false, away: away,
        manuallyEnding: false, autoEnd: .init(mode: .auto, days: 1),
        safety: .init(endIdleSessions: true), home: directory)
    }
    // Q18's pressure clock starts before Q10 can act.
    coordinator.run(tick(now.addingTimeInterval(-120), away: false))
    // Both are eligible now; Q10 starts first and reserves the shared end slot.
    coordinator.run(tick(now, away: true))
    #expect(coordinator.activeEnd == .away)
    await Task.yield()
    #expect(pressureEnds == 0)
  }
}
