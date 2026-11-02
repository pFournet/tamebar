import Foundation
import Testing

@testable import Tamebar

struct AppliedProcessScanTests {
  private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  private func thread() -> AIThread {
    var thread = AIThread(
      id: "claude-10-1", tool: .claudeCode, name: "Claude Code", directory: "/code/web",
      terminal: "ttys001", startedAt: nil, processIDs: [10, 11], memoryBytes: 500_000_000,
      cpuPercent: 1, isPaused: false, isDetached: false)
    thread.rootProcessID = 10
    return thread
  }

  private func snapshot(
    listener: [Int32: [Int]], complete: Bool, established: Set<Int> = [],
    connectionsComplete: Bool = true
  ) -> DevProcessSnapshot {
    DevProcessSnapshot(
      processes: [], identities: [:], threads: [thread()], resources: [],
      listeningIDs: Set(listener.keys), listeningPorts: listener, portsComplete: complete,
      establishedPorts: established, establishedComplete: connectionsComplete,
      directories: [11: "/code/web"])
  }

  @Test func aPartialPortScanKeepsProtectionButDoesNotInventCurrentUse() {
    var applied = AppliedProcessScan()
    var clock = ServedPortClock()
    let first = applied.apply(snapshot(listener: [11: [5180]], complete: true, established: [5180]))
    #expect(first.servingIDs == [11])
    #expect(first.portsScanned)
    #expect(first.scanComplete)
    #expect(first.listenerLocations.map(\.port) == [5180])
    #expect(first.listenerLocations.first?.directory == "/code/web")
    #expect(first.observePortUse(in: &clock, now: t0) == [5180])
    #expect(clock.lastUsed[5180] == t0)

    let partial = applied.apply(snapshot(listener: [:], complete: false))
    #expect(partial.servingIDs == [11], "a missing lsof line cannot remove Q7 protection")
    #expect(partial.portsScanned)
    #expect(partial.listeningPorts.isEmpty, "Q20 uses current, not remembered, port lines")
    #expect(!partial.portActivityComplete)
    #expect(partial.observePortUse(in: &clock, now: t0.addingTimeInterval(60)).isEmpty)
    #expect(clock.lastUsed[5180] == t0, "a partial scan cannot forget the port")

    let final = applied.apply(snapshot(listener: [:], complete: true))
    #expect(final.servingIDs.isEmpty)
    #expect(final.portActivityComplete)
    final.observePortUse(in: &clock, now: t0.addingTimeInterval(120))
    #expect(clock.lastUsed[5180] == nil)
  }

  @Test func anIncompleteConnectionReadCannotExpireAStillServedPort() {
    var applied = AppliedProcessScan()
    var clock = ServedPortClock()
    let first = applied.apply(snapshot(listener: [11: [5180]], complete: true, established: [5180]))
    first.observePortUse(in: &clock, now: t0)

    let incomplete = applied.apply(
      snapshot(listener: [11: [5180]], complete: true, connectionsComplete: false))
    #expect(!incomplete.portActivityComplete)
    #expect(incomplete.observePortUse(in: &clock, now: t0.addingTimeInterval(60)) == [5180])
    #expect(clock.lastUsed[5180] == t0)
  }

  @Test func protectionCanAccumulateNewLinesDuringAPartialRead() {
    var applied = AppliedProcessScan()
    let first = applied.apply(snapshot(listener: [11: [5180]], complete: true))
    #expect(first.servingIDs == [11])
    let partial = applied.apply(snapshot(listener: [12: [8080]], complete: false))
    #expect(partial.servingIDs == [11, 12])
    #expect(partial.listeningPorts == [12: [8080]])
  }

  @Test func backgroundWorkWaitsForTheFirstCompletePortScan() {
    var applied = AppliedProcessScan()
    let partial = applied.apply(snapshot(listener: [:], complete: false))
    #expect(!partial.portsScanned)
    let complete = applied.apply(snapshot(listener: [:], complete: true))
    #expect(complete.portsScanned)
  }
}
