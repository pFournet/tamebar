import Foundation
import Testing

@testable import Tamebar

struct LiveCPUTests {
  @Test
  func measuresIntervalAndRejectsReusedPIDs() {
    let previous: [CPUCounter] = [
      .init(id: 1, name: "worker", start: 10, ticks: 1_000_000_000),
      .init(id: 2, name: "old", start: 20, ticks: 1_000_000_000),
    ]
    let current: [CPUCounter] = [
      .init(id: 1, name: "worker", start: 10, ticks: 4_000_000_000),
      .init(id: 2, name: "new", start: 30, ticks: 4_000_000_000),
    ]
    let usage = CPUProcessReader.usage(
      .init(previous: previous, current: current, seconds: 2, nanosecondsPerTick: 1))
    #expect(usage.count == 1)
    #expect(usage.first?.percent == 150)
    #expect(
      CPUProcessReader.usage(
        .init(previous: previous, current: current, seconds: 0, nanosecondsPerTick: 1)
      ).isEmpty)
  }

  @Test
  func historyIsBoundedAndPreservesUnavailableCPU() {
    var history = ResourceHistory(capacity: 2)
    for _ in 0..<10 { history.append(.empty) }
    #expect(history.samples.count == 2)
    #expect(history.samples.allSatisfy { $0.cpu == nil })
  }

  @Test
  func inactiveAppPagesAreNotAllCountedAsAvailable() {
    let stats = VMMemoryStats(
      free: 10, active: 20, inactive: 50, wired: 10,
      compressed: 10, fileBacked: 15, purgeable: 5, swapOutBytes: 0, total: 100)
    #expect(stats.available == 30)
  }

  @Test
  func normalLaunchOpensTheWindowAndBackgroundLaunchStaysQuiet() {
    var normal = InitialWindowRequest(["Tamebar"])
    let first = normal.consume()
    let second = normal.consume()
    #expect(first)
    #expect(!second)
    var background = InitialWindowRequest(["Tamebar", "--background"])
    let quiet = background.consume()
    #expect(!quiet)
  }
}

struct NativeCPUIntegrationTests {
  @Test
  func accountsForAppleSiliconClockUnits() {
    let usage = CPUProcessReader.usage(
      .init(
        previous: [.init(id: 1, name: "test", start: 1, ticks: 0)],
        current: [.init(id: 1, name: "test", start: 1, ticks: 24_000_000)],
        seconds: 1, nanosecondsPerTick: 125.0 / 3.0))
    #expect(abs((usage.first?.percent ?? 0) - 100) < 0.01)
  }

  @Test
  func realBusyProcessReportsCoreUsage() async throws {
    let process = Process()
    // `yes` under a 30 s alarm, which survives the exec: should the test process crash before
    // its defer, the busy loop still ends instead of running orphaned at 100% CPU.
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = ["-e", "alarm 30; exec '/usr/bin/yes'"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      process.terminate()
      process.waitUntilExit()
    }
    let before = CPUProcessReader.counters()
    let start = ProcessInfo.processInfo.systemUptime
    try await Task.sleep(for: .seconds(1))
    let after = CPUProcessReader.counters()
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    let scale = try #require(CPUProcessReader.nanosecondsPerTick)
    let usage = CPUProcessReader.usage(
      .init(
        previous: before, current: after,
        seconds: elapsed, nanosecondsPerTick: scale))
    let percent = try #require(usage.first { $0.id == process.processIdentifier }?.percent)
    #expect(percent > 10)
    #expect(percent <= 120)
  }
}
