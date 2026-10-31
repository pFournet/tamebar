import Foundation
import Testing

@testable import Tamebar

struct PerformanceBenchmarks {
  @Test func liveReadOnlyScans() throws {
    guard ProcessInfo.processInfo.environment["BLITZCLEAN_BENCHMARK"] != nil else { return }
    for iteration in 1...3 {
      var start = Date.now
      let processes = DevProcessScanner().snapshot()
      print(
        "BENCH processes \(iteration): \(Date.now.timeIntervalSince(start))s; \(processes.resources.count) processes"
      )
      start = .now
      _ = SystemMetricsProvider().snapshot()
      print("BENCH system metrics \(iteration): \(Date.now.timeIntervalSince(start))s")
      fflush(stdout)
    }
  }
}
