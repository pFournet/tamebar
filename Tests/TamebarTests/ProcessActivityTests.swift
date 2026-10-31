import Foundation
import Testing

@testable import Tamebar

struct ProcessActivityTests {
  @Test
  func aRestartedProcessNoLongerMatchesItsIdentity() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    defer { if child.isRunning { child.terminate() } }
    let identity = try #require(DevProcessIdentity.read(child.processIdentifier))
    let stale = DevProcessIdentity(
      process: RecoveryProcess(
        processID: identity.process.processID, owner: identity.process.owner,
        startSeconds: identity.process.startSeconds + 1,
        startMicroseconds: identity.process.startMicroseconds, state: identity.process.state),
      executable: identity.executable)
    let current = try #require(DevProcessIdentity.read(child.processIdentifier))
    #expect(identity.matches(current))
    #expect(!stale.matches(current))
  }
}
