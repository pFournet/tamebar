import Darwin
import Foundation
import Testing

@testable import Tamebar

private let uid: UInt32 = 501
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// A process started `second` seconds after `t0`.
private func identity(_ pid: Int32, at second: UInt64 = 0) -> DevProcessIdentity {
  DevProcessIdentity(
    process: RecoveryProcess(
      processID: pid, owner: uid, startSeconds: 1_800_000_000 + second, startMicroseconds: 7,
      state: UInt32(SRUN)),
    executable: "/usr/bin/yes")
}

/// A process running `executable`, started at `t0`.
private func running(_ pid: Int32, _ executable: String) -> DevProcessIdentity {
  DevProcessIdentity(
    process: RecoveryProcess(
      processID: pid, owner: uid, startSeconds: 1_800_000_000, startMicroseconds: 7,
      state: UInt32(SRUN)),
    executable: executable)
}

/// Another process now holds this PID.
private func reused(_ pid: Int32) -> DevProcessIdentity { identity(pid, at: 100_000) }

private func task(_ pids: [Int32], of session: String = "Fix login") -> BackgroundPriority.Group {
  .init(id: "ai:\(session)", name: session, kind: .session, processIDs: pids)
}

private func build(_ name: String, _ pids: [Int32]) -> BackgroundPriority.Group {
  .init(id: "work:\(name)|/code", name: name, kind: .workload, processIDs: pids)
}

/// The process table the controller sees: it never touches a real process.
@MainActor
private final class FakeSystem {
  /// `pti_priority` by PID: 31 is normal, 4 is Darwin background.
  var priority: [Int32: Int32] = [:]
  var live: [Int32: DevProcessIdentity] = [:]
  var parents: [Int32: Int32] = [:]
  var refused: Set<Int32> = []
  /// Apple platform binaries (`CS_PLATFORM_BINARY`).
  var platform: Set<Int32> = []
  /// Leaves the priority unchanged though `setpriority` succeeds.
  var ignores: Set<Int32> = []
  /// `setpriority` fails.
  var fails: Set<Int32> = []
  /// Forks this child just before the parent's priority changes, so it inherits the old one.
  var forkOnSet: [Int32: Int32] = [:]
  var calls: [String] = []

  func add(_ pids: Int32...) {
    for pid in pids {
      live[pid] = identity(pid)
      priority[pid] = 31
    }
  }

  /// A child of `parent` started at `second`, with the priority it inherited.
  func fork(_ pid: Int32, of parent: Int32, at second: UInt64) {
    live[pid] = identity(pid, at: second)
    parents[pid] = parent
    priority[pid] = priority[parent] ?? 31
  }

  var system: BackgroundPriority.System {
    .init(
      uid: uid, read: { [self] in live[$0] }, priority: { [self] in priority[$0] },
      set: { [self] pid, background in
        calls.append("\(background ? "bg" : "normal") \(pid)")
        guard !fails.contains(pid) else { return false }
        if let child = forkOnSet.removeValue(forKey: pid) { fork(child, of: pid, at: 50) }
        if !ignores.contains(pid) { priority[pid] = background ? 4 : 31 }
        return true
      },
      allows: { [self] in !refused.contains($0) }, parents: { [self] in parents },
      platform: { [self] in platform.contains($0) })
  }

  func controller(_ record: BackgroundPriority.Record = .init(), url: URL? = nil)
    -> BackgroundPriorityController
  {
    BackgroundPriorityController(record: record, acts: true, url: url, system: system)
  }
}

private func folder(_ name: String) -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "background-\(name)-\(UUID().uuidString)", isDirectory: true)
}

/// Darwin background priority Tamebar sets on its own, and every way it is undone (Q9, Q12).
enum BackgroundPriorityTests {}

extension BackgroundPriorityTests {
  @MainActor
  struct Controller {
    private func tick(
      _ second: TimeInterval, active: Bool = true, _ groups: [BackgroundPriority.Group] = [],
      identities: [Int32: DevProcessIdentity]? = nil, serving: Set<Int32> = []
    ) -> BackgroundPriority.Tick {
      let pids = groups.flatMap(\.processIDs)
      return .init(
        now: t0.addingTimeInterval(second), active: active, groups: groups,
        identities: identities
          ?? Dictionary(uniqueKeysWithValues: pids.map { ($0, identity($0)) }), serving: serving)
    }

    /// Slowed at 6 s, then calm from 10 s: the episode is still on until 40 s.
    private func slowed(_ fake: FakeSystem, _ groups: [BackgroundPriority.Group])
      -> BackgroundPriorityController
    {
      let controller = fake.controller()
      controller.run(tick(0, groups))
      controller.run(tick(6, groups))
      return controller
    }

    @Test func slowsOnlyOnceTheTriggerHasLastedSixSeconds() {
      let fake = FakeSystem()
      fake.add(11)
      let controller = fake.controller()
      #expect(controller.run(tick(0, [task([11])])).note == nil)
      #expect(controller.run(tick(5.9, [task([11])])).note == nil)
      #expect(fake.calls.isEmpty)
      let outcome = controller.run(tick(6, [task([11])]))
      #expect(fake.calls == ["bg 11"])
      #expect(fake.priority[11] == 4)
      #expect(outcome.note == "Slowed 1 task of Fix login")
      #expect(
        controller.record.slowed == [
          .init(identity: identity(11), group: "ai:Fix login", slowedAt: t0.addingTimeInterval(6))
        ])
      #expect(controller.slows("ai:Fix login"))
      // Already slowed: nothing more to do, and no second note.
      #expect(controller.run(tick(7, [task([11])])).note == nil)
      #expect(fake.calls == ["bg 11"])
    }

    @Test func restoresAfterThirtyCalmSecondsOnlyWhatIsStillTheSameProcess() {
      let fake = FakeSystem()
      fake.add(11, 12)
      let controller = slowed(fake, [task([11, 12])])
      #expect(fake.calls == ["bg 11", "bg 12"])
      // 12 exits and its PID is reused by another process.
      fake.live[12] = reused(12)
      controller.run(tick(10, active: false))
      controller.run(tick(39.9, active: false))
      #expect(fake.calls == ["bg 11", "bg 12"], "nothing restored before 30 calm seconds")
      let outcome = controller.run(tick(40, active: false))
      #expect(fake.calls == ["bg 11", "bg 12", "normal 11"])
      #expect(outcome.restored == 1)
      #expect(controller.record.slowed.isEmpty)
    }

    @Test func anExitedProcessIsForgottenWhileSlowingAndHolding() {
      let fake = FakeSystem()
      fake.add(11, 12, 13)
      let controller = slowed(fake, [task([11, 12, 13])])
      fake.live[11] = nil
      controller.run(tick(7, [task([12, 13])]))
      #expect(controller.slowedProcessIDs == [12, 13], "forgotten while slowing")
      fake.live[12] = reused(12)
      controller.run(tick(10, active: false))
      #expect(controller.slowedProcessIDs == [13], "forgotten while holding")
      #expect(!fake.calls.contains("normal 11") && !fake.calls.contains("normal 12"))
    }

    @Test func aShortDipRestoresNothing() {
      let fake = FakeSystem()
      fake.add(11)
      let controller = slowed(fake, [task([11])])
      controller.run(tick(10, active: false))
      controller.run(tick(20, [task([11])]))
      controller.run(tick(45, [task([11])]))
      #expect(fake.calls == ["bg 11"])
    }

    @Test func aLongGapBetweenTicksTimesTheTriggerAfresh() {
      let fake = FakeSystem()
      fake.add(11)
      let controller = fake.controller()
      controller.run(tick(0, [task([11])]))
      controller.run(tick(70, [task([11])]))
      #expect(fake.calls.isEmpty, "a sleep is not sustained pressure")
      controller.run(tick(76, [task([11])]))
      #expect(fake.calls == ["bg 11"])
    }

    @Test func identityOwnerAndAllowlistAreCheckedBeforeSlowing() {
      let fake = FakeSystem()
      fake.add(11, 12, 13, 14)
      fake.live[11] = reused(11)
      fake.live[12] = DevProcessIdentity(
        process: RecoveryProcess(
          processID: 12, owner: 0, startSeconds: 1_800_000_000, startMicroseconds: 7,
          state: UInt32(SRUN)),
        executable: "/usr/bin/yes")
      fake.refused = [13]
      // 15 has no scanned identity.
      let controller = fake.controller()
      var identities = Dictionary(
        uniqueKeysWithValues: [11, 12, 13, 14].map { ($0, identity($0)) })
      identities[12] = fake.live[12]
      let groups = [task([11, 12, 13, 14, 15])]
      controller.run(tick(0, groups, identities: identities))
      controller.run(tick(6, groups, identities: identities))
      #expect(fake.calls == ["bg 14"])
    }

    /// Seen on 2026-10-29: callservicesd, chronod and photoanalysisd slowed under CPU strain.
    /// Whatever row hands it over, macOS's own code is never slowed: the system's folders, a
    /// simulator runtime's, or any platform binary but the user's commands in /bin and /usr/bin.
    @Test func macOSsOwnCodeIsNeverSlowedWhateverRowItComesIn() {
      let fake = FakeSystem()
      let runtime =
        "/Library/Developer/CoreSimulator/Volumes/iOS_24A1/Library/Developer/CoreSimulator"
        + "/Profiles/Runtimes/iOS 27.0.simruntime/Contents/Resources/RuntimeRoot"
      let executables: [Int32: String] = [
        11: "/System/Library/PrivateFrameworks/TelephonyUtilities.framework/callservicesd",
        12: "/usr/libexec/routined",
        13: "/usr/sbin/distnoted",
        14: "/Library/Apple/System/Library/CoreServices/XProtect.bundle/XProtectd",
        15: runtime + "/System/Library/PrivateFrameworks/ChronoCore.framework/Support/chronod",
        16: "/private/var/run/com.apple.security.cryptexd/mnt/x/photoanalysisd",
        17: "/usr/bin/yes",
        18: "/bin/sh",
        19: "/opt/homebrew/bin/node",
        20:
          "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/"
          + "swift-frontend",
      ]
      for (pid, executable) in executables {
        fake.live[pid] = running(pid, executable)
        fake.priority[pid] = 31
      }
      fake.platform = [11, 12, 13, 14, 15, 16, 17, 18, 20]
      let groups = [
        build("daemons", [11, 12, 13, 14, 15, 16, 17, 18, 19]), task([11, 15, 16, 20]),
      ]
      let controller = fake.controller()
      for second in [0.0, 6] {
        controller.run(tick(second, groups, identities: fake.live))
      }
      #expect(fake.calls == ["bg 17", "bg 18", "bg 19", "bg 20"])
      #expect(controller.slowedProcessIDs == [17, 18, 19, 20])
    }

    @Test func aSystemDaemonServingInBackgroundIsLeftAlone() {
      // A daemon macOS runs in background (ProcessType Background) started listening during
      // the episode: it never inherited anything from Tamebar, so its priority isn't Tamebar's.
      let fake = FakeSystem()
      fake.add(11)
      let controller = slowed(fake, [build("gradle", [11])])
      fake.fork(50, of: 1, at: 8)
      fake.live[50] = DevProcessIdentity(
        process: fake.live[50]!.process,
        executable: "/System/Library/PrivateFrameworks/ChronoCore.framework/Support/chronod")
      fake.priority[50] = 4
      fake.fork(51, of: 1, at: 8)
      fake.live[51] = DevProcessIdentity(
        process: fake.live[51]!.process,
        executable: "/private/var/run/com.apple.security.cryptexd/mnt/x/assetsd")
      fake.priority[51] = 4
      fake.platform = [51]
      controller.run(tick(9, active: false, serving: [50, 51]))
      #expect(fake.priority[50] == 4 && fake.priority[51] == 4)
      #expect(!fake.calls.contains("normal 50") && !fake.calls.contains("normal 51"))
    }

    @Test func aProcessAlreadyInBackgroundIsNeitherRecordedNorRestored() {
      let fake = FakeSystem()
      fake.add(11, 12)
      fake.priority[12] = 4
      let controller = slowed(fake, [task([11, 12])])
      #expect(controller.slowedProcessIDs == [11])
      controller.run(tick(10, active: false))
      controller.run(tick(40, active: false))
      #expect(fake.calls == ["bg 11", "normal 11"])
      #expect(fake.priority[12] == 4)
    }

    @Test func anUnconfirmedSlowIsUndoneAndNotRecorded() {
      let fake = FakeSystem()
      fake.add(11)
      fake.ignores = [11]
      let controller = fake.controller()
      controller.run(tick(0, [task([11])]))
      let outcome = controller.run(tick(6, [task([11])]))
      #expect(fake.calls == ["bg 11", "normal 11"])
      #expect(controller.record.slowed.isEmpty)
      #expect(outcome.note == nil)
    }

    @Test func childrenThatInheritedThePriorityAreAdoptedAndRestoredWithTheEpisode() {
      let fake = FakeSystem()
      fake.add(11)
      fake.fork(20, of: 11, at: 2)  // before the slow: never touched
      let controller = slowed(fake, [task([11])])
      fake.fork(21, of: 11, at: 8)  // inherits 4
      fake.fork(22, of: 21, at: 9)  // and its child too
      fake.fork(23, of: 11, at: 9)
      fake.priority[23] = 31  // already set back by someone: not Tamebar's
      controller.run(tick(10, active: false))
      #expect(controller.slowedProcessIDs == [11, 21, 22])
      #expect(controller.record.slowed.allSatisfy { $0.group == "ai:Fix login" })
      controller.run(tick(40, active: false))
      #expect(fake.calls == ["bg 11", "normal 11", "normal 21", "normal 22"])
      #expect(fake.priority.filter { $0.value == 4 }.isEmpty)
    }

    @Test func quittingAdoptsAndRestoresEverythingRecordedAndSaves() throws {
      let directory = folder("quit")
      defer { try? FileManager.default.removeItem(at: directory) }
      let url = directory.appendingPathComponent("background.json")
      let fake = FakeSystem()
      fake.add(11, 21, 22)
      let controller = fake.controller(url: url)
      controller.run(tick(0, [task([11]), build("cargo", [21, 22])]))
      controller.run(tick(6, [task([11]), build("cargo", [21, 22])]))
      #expect(BackgroundPriority.load(url).slowed.count == 3)
      fake.live[22] = reused(22)
      fake.fork(30, of: 21, at: 7)
      #expect(controller.restoreAllForQuit() == 3)
      #expect(fake.calls.suffix(3) == ["normal 11", "normal 21", "normal 30"])
      #expect(controller.record.slowed.isEmpty)
      #expect(BackgroundPriority.load(url) == .init())
    }

    @Test func aChildStartedBeforeTheSlowIsNotAdoptedEvenInBackground() {
      let fake = FakeSystem()
      fake.add(11)
      fake.fork(20, of: 11, at: 2)
      fake.priority[20] = 4  // in background, but not from Tamebar's slow at 6 s
      let controller = slowed(fake, [task([11])])
      controller.run(tick(10, active: false))
      #expect(controller.slowedProcessIDs == [11])
      controller.run(tick(40, active: false))
      #expect(fake.calls == ["bg 11", "normal 11"])
      #expect(fake.priority[20] == 4)
    }

    @Test func theChildrenOfAReplacedParentAreNotAdopted() {
      let fake = FakeSystem()
      fake.add(11)
      let controller = slowed(fake, [task([11])])
      // 11 exits; another process takes its PID and forks a child in background.
      fake.live[11] = reused(11)
      fake.fork(30, of: 11, at: 8)
      fake.priority[30] = 4
      controller.run(tick(10, active: false))
      #expect(controller.record.slowed.isEmpty)
      controller.run(tick(40, active: false))
      #expect(fake.calls == ["bg 11"])
      #expect(fake.priority[30] == 4)
    }

    @Test func anotherUsersChildIsNotAdopted() {
      let fake = FakeSystem()
      fake.add(11)
      let controller = slowed(fake, [task([11])])
      fake.fork(30, of: 11, at: 8)
      fake.live[30] = DevProcessIdentity(
        process: RecoveryProcess(
          processID: 30, owner: 0, startSeconds: 1_800_000_008, startMicroseconds: 7,
          state: UInt32(SRUN)),
        executable: "/usr/bin/sudo")
      controller.run(tick(10, active: false))
      #expect(controller.slowedProcessIDs == [11])
    }

    @Test func aListenerThatDoubleForkedAwayFromASlowedParentIsRestored() {
      // A slowed build starts a daemon that double-forks to launchd and listens (a gradle daemon).
      let fake = FakeSystem()
      fake.add(11)
      let controller = slowed(fake, [build("gradle", [11])])
      fake.fork(50, of: 1, at: 8)
      fake.priority[50] = 4
      fake.fork(51, of: 1, at: 2)  // listening in background since before the episode
      fake.priority[51] = 4
      fake.fork(53, of: 1, at: 8)  // outside the e2e targets
      fake.priority[53] = 4
      fake.refused = [53]
      controller.run(tick(9, active: false, serving: [50, 51, 53]))
      #expect(fake.priority[50] == 31)
      #expect(fake.priority[51] == 4 && fake.priority[53] == 4)
      #expect(controller.slowedProcessIDs == [11])
    }

    @Test func aListenerInBackgroundSinceBeforeTheSlowIsNeverRestored() {
      let fake = FakeSystem()
      fake.add(11)
      fake.parents = [11: 10]
      fake.fork(51, of: 1, at: 2)
      fake.priority[51] = 4
      let controller = slowed(fake, [task([11])])
      // 11 starts serving: its restore empties the record in this very tick.
      controller.run(tick(7, serving: [11, 51]))
      #expect(controller.record.slowed.isEmpty)
      controller.run(tick(8, serving: [11, 51]))
      controller.run(tick(10, active: false, serving: [11, 51]))
      #expect(fake.priority[51] == 4)
      #expect(!fake.calls.contains("normal 51"))
    }

    @Test func anEntryKeptFromAnEarlierEpisodeDoesNotWidenTheListenerWindow() {
      // 11's restore failed in an earlier episode (slowed at t0) and is still kept.
      var record = BackgroundPriority.Record()
      record.slowed = [.init(identity: identity(11), group: "ai:old", slowedAt: t0)]
      let fake = FakeSystem()
      fake.add(11, 12)
      fake.priority[11] = 4
      fake.fails = [11]
      fake.fork(51, of: 1, at: 50)  // in background since before this episode's slow at 106
      fake.priority[51] = 4
      fake.fork(52, of: 1, at: 107)  // inherited it during this episode
      fake.priority[52] = 4
      let controller = fake.controller(record)
      controller.run(tick(100, [task([12])]))
      controller.run(tick(106, [task([12])]))
      #expect(controller.episodeStartedAt == t0.addingTimeInterval(106))
      controller.run(tick(108, [task([12])], serving: [51, 52]))
      #expect(fake.priority[51] == 4)
      #expect(fake.priority[52] == 31)
    }

    @Test func theListenerRestoreLeavesAProcessAtNormalPriorityAlone() {
      let fake = FakeSystem()
      fake.add(11)
      let controller = slowed(fake, [build("gradle", [11])])
      fake.fork(50, of: 1, at: 8)
      fake.priority[50] = 31
      controller.run(tick(9, active: false, serving: [50]))
      #expect(fake.calls == ["bg 11"])
    }

    @Test func aServingProcessWhoseRestoreFailsStaysRecorded() {
      let fake = FakeSystem()
      fake.add(11, 12)
      let controller = slowed(fake, [task([11, 12])])
      fake.fails = [11]
      controller.run(tick(7, [task([12])], serving: [11]))
      #expect(controller.slowedProcessIDs == [11, 12], "kept, to retry")
      fake.fails = []
      controller.run(tick(8, [task([12])], serving: [11]))
      #expect(controller.slowedProcessIDs == [12])
      #expect(fake.priority[11] == 31)
    }

    @Test func aLegacyEntryWithoutATimeAdoptsNothing() throws {
      let data = try JSONEncoder().encode(identity(11))
      let json =
        #"{"slowed":[{"group":"ai:x","identity":"# + String(decoding: data, as: UTF8.self) + "}]}"
      let record = try JSONDecoder().decode(BackgroundPriority.Record.self, from: Data(json.utf8))
      #expect(record.slowed.map(\.slowedAt) == [.distantFuture])
      let fake = FakeSystem()
      fake.add(11)
      fake.priority[11] = 4
      fake.fork(30, of: 11, at: 8)
      let controller = fake.controller(record)
      #expect(controller.restoreAllForQuit() == 1)
      #expect(fake.calls == ["normal 11"])
      #expect(fake.priority[30] == 4)
    }

    @Test func aChildForkedWhileItsParentIsRestoredIsTakenInToo() {
      let fake = FakeSystem()
      fake.add(11)
      let controller = slowed(fake, [task([11])])
      fake.forkOnSet[11] = 40
      #expect(controller.restoreAllForQuit() == 2)
      #expect(fake.calls == ["bg 11", "normal 11", "normal 40"])
      #expect(fake.priority.filter { $0.value == 4 }.isEmpty)
      #expect(controller.record.slowed.isEmpty)
    }

    @Test func whatTurnsOutToServeIsRestoredAtOnce() {
      let fake = FakeSystem()
      fake.add(11, 12, 13, 14)
      fake.parents = [11: 10, 12: 10, 13: 10, 14: 13]
      let controller = slowed(fake, [task([11, 12, 13])])
      // While slowing: 11 starts listening.
      controller.run(tick(7, [task([12, 13])], serving: [11]))
      #expect(controller.slowedProcessIDs == [12, 13])
      #expect(fake.calls.last == "normal 11")
      // While holding: 13 starts a server (14), so 13 is an ancestor of one.
      controller.run(tick(10, active: false, serving: [11, 14]))
      #expect(controller.slowedProcessIDs == [12])
      #expect(fake.calls.last == "normal 13")
    }

    @Test func anAdoptedChildThatServesIsRestoredAtOnce() {
      let fake = FakeSystem()
      fake.add(11)
      let controller = slowed(fake, [task([11])])
      // The slowed process restarts its server, which inherits background.
      fake.fork(30, of: 11, at: 8)
      controller.run(tick(9, serving: [30]))
      #expect(fake.priority[30] == 31, "the server")
      #expect(fake.priority[11] == 31, "its parent, an ancestor of a server")
      #expect(controller.record.slowed.isEmpty)
    }

    @Test func aRestoreNeedsOnlyTheIdentityAndAFailedOneIsKept() {
      let fake = FakeSystem()
      fake.add(11, 12)
      let controller = slowed(fake, [task([11, 12])])
      // The allowlist refuses 11 now (an e2e target changed); 12's restore fails.
      fake.refused = [11]
      fake.fails = [12]
      controller.run(tick(10, active: false))
      controller.run(tick(40, active: false))
      #expect(fake.priority[11] == 31)
      #expect(controller.slowedProcessIDs == [12], "kept, to retry")
      fake.fails = []
      controller.run(tick(41, active: false))
      #expect(fake.priority[12] == 31)
      #expect(controller.record.slowed.isEmpty)
    }

    @Test func theNoteNamesBuildsBeforeTasks() {
      let fake = FakeSystem()
      fake.add(11, 21, 31)
      let groups = [task([11]), build("cargo", [21]), build("swift", [31])]
      let controller = fake.controller()
      controller.run(tick(0, groups))
      #expect(controller.run(tick(6, groups)).note == "Slowed 2 builds")
    }
  }

  struct Notes {
    @Test func singularAndPlural() {
      #expect(BackgroundPriority.note(builds: 1, tasks: []) == "Slowed 1 build")
      #expect(BackgroundPriority.note(builds: 3, tasks: []) == "Slowed 3 builds")
      #expect(
        BackgroundPriority.note(builds: 0, tasks: [("Fix login", 1)])
          == "Slowed 1 task of Fix login")
      #expect(
        BackgroundPriority.note(builds: 0, tasks: [("Fix login", 2)])
          == "Slowed 2 tasks of Fix login")
      #expect(
        BackgroundPriority.note(builds: 0, tasks: [("A", 2), ("B", 1)])
          == "Slowed 3 tasks of 2 sessions")
      #expect(BackgroundPriority.note(builds: 1, tasks: [("A", 2)]) == "Slowed 1 build")
      #expect(BackgroundPriority.note(builds: 0, tasks: []) == nil)
    }
  }

  @MainActor
  final class Launch {
    private let root = folder("launch")

    deinit { try? FileManager.default.removeItem(at: root) }

    @Test func leftoversAreRestoredAtLaunchOnlyWhenItActs() throws {
      let directory = root.appendingPathComponent("Tamebar")
      let url = try #require(BackgroundPriority.storeURL(directory: directory, e2e: false))
      var record = BackgroundPriority.Record()
      record.slowed = [
        .init(identity: identity(11), group: "ai:x", slowedAt: t0),
        .init(identity: identity(12), group: "ai:x", slowedAt: t0),
      ]
      BackgroundPriority.save(record, to: url)
      let fake = FakeSystem()
      fake.add(11, 12)
      fake.priority = [11: 4, 12: 4]
      fake.live[12] = reused(12)
      fake.fork(13, of: 11, at: 5)
      let idle = BackgroundPriorityController.launch(
        acts: false, directory: directory, e2e: false, system: fake.system)
      #expect(!idle.acts)
      #expect(fake.calls.isEmpty)
      #expect(BackgroundPriority.load(url) == record, "a second instance leaves the file alone")
      let controller = BackgroundPriorityController.launch(
        acts: true, directory: directory, e2e: false, system: fake.system)
      #expect(controller.acts)
      #expect(fake.calls == ["normal 11", "normal 13"])
      #expect(controller.record.slowed.isEmpty)
      #expect(BackgroundPriority.load(url) == .init())
    }

    @Test func aControllerThatDoesNotActDoesNothing() {
      let fake = FakeSystem()
      fake.add(11)
      let controller = BackgroundPriorityController(
        record: .init(), acts: false, url: nil, system: fake.system)
      for second in [0.0, 10] {
        controller.run(
          .init(
            now: t0.addingTimeInterval(second), active: true, groups: [task([11])],
            identities: [11: identity(11)], serving: []))
      }
      #expect(controller.restoreAllForQuit() == 0)
      #expect(fake.calls.isEmpty)
    }

    @Test func theE2EBuildOnlyWritesInItsOwnFolder() {
      let real = root.appendingPathComponent("Tamebar")
      #expect(BackgroundPriority.storeURL(directory: real, e2e: true) == nil)
      let own = root.appendingPathComponent("Tamebar-e2e")
      #expect(
        BackgroundPriority.storeURL(directory: own, e2e: true)?.lastPathComponent
          == "background.json")
    }

    @Test func anUnreadableFileIsKeptAsideAndABadEntryNeverDropsTheOthers() throws {
      let directory = root.appendingPathComponent("files")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("background.json")
      try Data("not json".utf8).write(to: url)
      #expect(BackgroundPriority.load(url, now: Date(timeIntervalSince1970: 42)) == .init())
      let aside = directory.appendingPathComponent("background.unreadable-42.json")
      #expect(try String(contentsOf: aside, encoding: .utf8) == "not json")
      #expect(!FileManager.default.fileExists(atPath: url.path))
      var record = BackgroundPriority.Record()
      record.slowed = [.init(identity: identity(11), group: "ai:x", slowedAt: t0)]
      BackgroundPriority.save(record, to: url)
      #expect(BackgroundPriority.load(url) == record)
      let good = try String(contentsOf: url, encoding: .utf8)
      let mixed = good.replacingOccurrences(of: "[{", with: "[{\"bad\":1},{")
      try Data(mixed.utf8).write(to: url)
      #expect(BackgroundPriority.load(url) == record)
    }
  }
}

extension BackgroundPriorityTests {
  /// Q17.1 through the ledger: apps slowed in the background, each on its own clock.
  @MainActor
  struct Apps {
    private func chatGPT(
      cpu: Double = 490, pids: [Int32] = [21, 22], front: Bool = false, optedOut: Bool = false
    ) -> AppSlow.App {
      .init(
        group: "app:ChatGPT", bundleID: "com.openai.codex", name: "ChatGPT", cpuPercent: cpu,
        processIDs: pids, isFrontmost: front, optedOut: optedOut)
    }

    private func tick(
      _ second: TimeInterval, active: Bool = false, groups: [BackgroundPriority.Group] = [],
      apps: [AppSlow.App]
    ) -> BackgroundPriority.Tick {
      let pids = groups.flatMap(\.processIDs) + apps.flatMap(\.processIDs)
      return .init(
        now: t0.addingTimeInterval(second), active: active, groups: groups,
        identities: Dictionary(uniqueKeysWithValues: pids.map { ($0, identity($0)) }),
        serving: [], apps: apps)
    }

    /// Busy in the background from 0 s: slowed at 120 s.
    private func slowedApp(_ fake: FakeSystem) -> BackgroundPriorityController {
      let controller = fake.controller()
      var second: TimeInterval = 0
      while second < 120 {
        controller.run(tick(second, apps: [chatGPT()]))
        second += 15
      }
      return controller
    }

    @Test func slowsABusyBackgroundAppAfterTwoMinutesWithOneNote() {
      let fake = FakeSystem()
      fake.add(21, 22)
      let controller = slowedApp(fake)
      #expect(fake.calls.isEmpty)
      let outcome = controller.run(tick(120, apps: [chatGPT()]))
      #expect(fake.calls == ["bg 21", "bg 22"])
      #expect(outcome.appNote == "Slowed ChatGPT · 490% CPU")
      #expect(outcome.appSlowed == 2)
      #expect(outcome.note == nil)
      #expect(controller.slows("app:ChatGPT"))
      #expect(controller.record.apps.map(\.bundleID) == ["com.openai.codex"])
      #expect(controller.record.recentApps["com.openai.codex"]?.cpuPercent == 490)
      // Held: no second note.
      #expect(controller.run(tick(135, apps: [chatGPT()])).appNote == nil)
      #expect(fake.calls == ["bg 21", "bg 22"])
    }

    @Test func restoredAtOnceInFrontAndKeptInTheRecentList() {
      let fake = FakeSystem()
      fake.add(21, 22)
      let controller = slowedApp(fake)
      controller.run(tick(120, apps: [chatGPT()]))
      let outcome = controller.run(tick(135, apps: [chatGPT(front: true)]))
      #expect(outcome.restored == 2)
      #expect(fake.priority[21] == 31 && fake.priority[22] == 31)
      #expect(controller.record.slowed.isEmpty && controller.record.apps.isEmpty)
      #expect(controller.record.recentApps["com.openai.codex"] != nil)
    }

    @Test func restoredOnceCalmForAMinute() {
      let fake = FakeSystem()
      fake.add(21, 22)
      let controller = slowedApp(fake)
      controller.run(tick(120, apps: [chatGPT()]))
      controller.run(tick(135, apps: [chatGPT(cpu: 30)]))
      controller.run(tick(180, apps: [chatGPT(cpu: 30)]))
      #expect(fake.priority[21] == 4)
      controller.run(tick(195, apps: [chatGPT(cpu: 30)]))
      #expect(fake.priority[21] == 31)
      #expect(controller.record.apps.isEmpty)
    }

    @Test func theEndOfACPUEpisodeLeavesASlowedAppAlone() {
      let fake = FakeSystem()
      fake.add(11, 21, 22)
      let controller = slowedApp(fake)
      controller.run(tick(120, active: true, groups: [build("make", [11])], apps: [chatGPT()]))
      controller.run(tick(126, active: true, groups: [build("make", [11])], apps: [chatGPT()]))
      #expect(fake.priority[11] == 4 && fake.priority[21] == 4)
      // CPU calm for 30 s: Q12's build is restored, the app is still busy and stays slowed.
      controller.run(tick(130, apps: [chatGPT()]))
      controller.run(tick(160, apps: [chatGPT()]))
      #expect(fake.priority[11] == 31)
      #expect(fake.priority[21] == 4 && fake.priority[22] == 4)
      #expect(controller.slows("app:ChatGPT"))
    }

    @Test func childrenThatInheritItAreRestoredWithTheApp() {
      let fake = FakeSystem()
      fake.add(21, 22)
      let controller = slowedApp(fake)
      controller.run(tick(120, apps: [chatGPT()]))
      // A helper forked after the slow inherits background; the next tick takes it in.
      fake.fork(23, of: 21, at: 200)
      controller.run(tick(135, apps: [chatGPT()]))
      #expect(controller.record.slowed.map(\.processID).sorted() == [21, 22, 23])
      controller.run(tick(150, apps: [chatGPT(front: true)]))
      #expect(fake.priority[23] == 31)
    }

    @Test func quittingRestoresTheApp() {
      let fake = FakeSystem()
      fake.add(21, 22)
      let controller = slowedApp(fake)
      controller.run(tick(120, apps: [chatGPT()]))
      #expect(controller.restoreAllForQuit() == 2)
      #expect(fake.priority[21] == 31 && fake.priority[22] == 31)
      #expect(controller.record.apps.isEmpty)
    }

    @Test func anOptedOutAppIsRestoredAndNeverSlowed() {
      let fake = FakeSystem()
      fake.add(21, 22)
      let controller = slowedApp(fake)
      controller.run(tick(120, apps: [chatGPT()]))
      controller.run(tick(135, apps: [chatGPT(optedOut: true)]))
      #expect(fake.priority[21] == 31)
      var second: TimeInterval = 150
      while second < 600 {
        controller.run(tick(second, apps: [chatGPT(optedOut: true)]))
        second += 15
      }
      #expect(controller.record.slowed.isEmpty)
    }

    @Test func aLeftoverAppIsRestoredAtTheNextLaunch() throws {
      let fake = FakeSystem()
      fake.add(21)
      fake.priority[21] = 4
      var record = BackgroundPriority.Record()
      record.slowed = [.init(identity: identity(21), group: "app:ChatGPT", slowedAt: t0)]
      record.apps = [
        .init(
          group: "app:ChatGPT", bundleID: "com.openai.codex", name: "ChatGPT", cpuPercent: 490,
          slowedAt: t0)
      ]
      let directory = folder("app-launch")
      defer { try? FileManager.default.removeItem(at: directory) }
      let url = try #require(BackgroundPriority.storeURL(directory: directory, e2e: false))
      BackgroundPriority.save(record, to: url)
      #expect(BackgroundPriority.load(url).apps.count == 1)
      let controller = BackgroundPriorityController.launch(
        acts: true, directory: directory, e2e: false, system: fake.system)
      #expect(fake.priority[21] == 31)
      #expect(controller.record.slowed.isEmpty && controller.record.apps.isEmpty)
    }
  }
}
