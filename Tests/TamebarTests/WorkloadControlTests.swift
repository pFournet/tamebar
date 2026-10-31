import Darwin
import Foundation
import Testing

@testable import Tamebar

struct WorkloadControlTests {
  /// Every signal goes root first, Quit and Force Quit included (decided 2026-10-21): the agent
  /// gets its SIGTERM before its children, as a terminal's own close would, and a stopped parent
  /// starts no more children. The e2e allowlist keeps a child allowed once its parent is gone.
  @Test func everySignalGoesRootFirst() {
    let tree = LiveProcessTree(parents: [10: 1, 11: 10, 12: 11, 13: 10])
    let ordered = tree.descendants([10])
    #expect(ordered == [10, 11, 13, 12])
    for signal in [AIThreadSignal.quit, .forceQuit, .pause, .resume] {
      #expect(WorkloadControl.signalOrder(ordered, signal) == ordered, "\(signal)")
    }
  }

  /// The e2e hang: Quit sent the root its SIGTERM first, the root exited, and its `sleep`, now
  /// launchd's, was out of the target's tree and refused on every retry, holding the test's
  /// output pipe open. Pinned while still in the tree, it is signalled in the same Quit.
  @Test(.timeLimit(.minutes(1)))
  func quitInE2EModeEndsAChildWhoseParentExitedFirst() async throws {
    let root = Process()
    root.executableURL = URL(fileURLWithPath: "/bin/sh")
    // `; :` keeps the shell from exec'ing into sleep, so sleep stays its child.
    root.arguments = ["-c", "sleep 600; :"]
    root.standardInput = FileHandle.nullDevice
    try root.run()
    var pids: [Int32] = [root.processIdentifier]
    defer {
      for pid in pids { _ = kill(pid, SIGKILL) }
    }
    var child: Int32?
    let deadline = Date.now.addingTimeInterval(5)
    while child == nil, Date.now < deadline {
      child = LiveProcessTree.read().descendants([root.processIdentifier])
        .first { $0 != root.processIdentifier }
      if child == nil { try await Task.sleep(for: .milliseconds(20)) }
    }
    let sleeper = try #require(child)
    pids.append(sleeper)
    let rootIdentity = try #require(DevProcessIdentity.read(root.processIdentifier))
    let childIdentity = try #require(DevProcessIdentity.read(sleeper))
    let start = try #require(E2EMode.startTime(root.processIdentifier))
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data(#"[{"pid": \#(root.processIdentifier), "start": \#(start)}]"#.utf8)
      .write(to: dir.appendingPathComponent("targets.json"))

    let result = await WorkloadControl.execute(
      .init(identities: [rootIdentity, childIdentity], signal: .quit),
      mode: E2EMode(directory: dir))
    #expect(result.remaining == 0, "the orphaned child was refused")
    #expect(result.affected == 2)
    #expect(DevProcessIdentity.read(sleeper).map(childIdentity.matches) != true)
  }

  @Test func terminationFailureIsReportedWithoutAutomaticForceKill() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "trap '' TERM; sleep 30 & wait"]
    try process.run()
    defer {
      for pid in LiveProcessTree.read().descendants([process.processIdentifier]) {
        _ = kill(pid, SIGKILL)
      }
    }
    try await Task.sleep(for: .milliseconds(100))
    let identity = try #require(DevProcessIdentity.read(process.processIdentifier))
    let result = await WorkloadControl.execute(.init(identities: [identity], signal: .quit))
    #expect(result.remaining > 0)
    #expect(result.remaining >= 1)
    #expect(process.isRunning)
    let forced = await WorkloadControl.execute(
      .init(identities: result.identities, signal: .forceQuit))
    #expect(forced.remaining == 0)
  }

  @Test func nativeInventoryDoesNotNeedTheDashboardOrExternalCommands() {
    let started = Date.now
    let inventory = EmergencyInventory.read()
    #expect(Date.now.timeIntervalSince(started) < 3)
    #expect(inventory.allSatisfy { !$0.identities.isEmpty })
    #expect(!inventory.flatMap(\.identities).contains { $0.process.processID == getpid() })
  }

  @Test func pauseIncludesChildrenCreatedAfterTheOriginalSnapshot() async throws {
    let parent = Process()
    parent.executableURL = URL(fileURLWithPath: "/bin/sh")
    parent.arguments = ["-c", "sleep 30 & wait"]
    try parent.run()
    defer {
      for pid in LiveProcessTree.read().descendants([parent.processIdentifier]) {
        _ = kill(pid, SIGCONT)
        _ = kill(pid, SIGTERM)
      }
    }
    try await Task.sleep(for: .milliseconds(100))
    let identity = try #require(DevProcessIdentity.read(parent.processIdentifier))
    let paused = await WorkloadControl.execute(.init(identities: [identity], signal: .pause))
    #expect(paused.remaining == 0)
    #expect(paused.affected >= 2)
    #expect(
      paused.identities.allSatisfy {
        DevProcessIdentity.read($0.process.processID)?.process.stopped == true
      })
    let stopped = await WorkloadControl.execute(.init(identities: paused.identities, signal: .quit))
    #expect(stopped.remaining == 0)
    #expect(stopped.retainedBytes == 0)
  }

  @Test func changedIdentityDoesNotClaimItsChildren() async throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    defer { if child.isRunning { child.terminate() } }
    let identity = try #require(DevProcessIdentity.read(child.processIdentifier))
    let changed = DevProcessIdentity(process: identity.process, executable: "/changed")
    let result = await WorkloadControl.execute(.init(identities: [changed], signal: .pause))
    #expect(result.affected == 0)
    #expect(DevProcessIdentity.read(child.processIdentifier)?.process.stopped == false)
  }
}
