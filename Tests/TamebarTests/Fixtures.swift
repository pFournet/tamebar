import Foundation

@testable import Tamebar

extension ResourceProcess {
  /// A large terminal-started process outside any app bundle or system folder, so only its name decides how it is grouped.
  static func fixture(name: String, processID: Int32 = 900_001) -> ResourceProcess {
    ResourceProcess(
      processID: processID, parentProcessID: 1, name: name, owner: name, directory: nil,
      memoryBytes: 500_000_000, cpuPercent: 0, isTool: false,
      executable: "/Users/test/bin/\(name)")
  }
}
