import Darwin
import Foundation
import Testing

@testable import Tamebar

private func thread(
  _ id: String, root: Int32, children: [Int32] = [], status: AgentStatus? = .idle,
  paused: Bool = false, bytes: UInt64 = 10
) -> AIThread {
  var thread = AIThread(
    id: id, tool: .claudeCode, name: "Claude Code", directory: "/code/\(id)", terminal: nil,
    startedAt: nil, processIDs: [root] + children, memoryBytes: bytes, cpuPercent: 0,
    isPaused: paused, isDetached: false)
  thread.rootProcessID = root
  thread.agentStatus = status
  return thread
}

private func identity(_ pid: Int32, stopped: Bool = false) -> DevProcessIdentity {
  DevProcessIdentity(
    process: RecoveryProcess(
      processID: pid, owner: 501, startSeconds: 1_800_000_000, startMicroseconds: 42,
      state: UInt32(stopped ? SSTOP : SRUN)),
    executable: "/bin/sh")
}

private func scan(
  _ threads: [AIThread], unused: [String: UnusedPolicy.Reason] = [:],
  protections: [String: UnusedPolicy.Protection] = [:], scope: Set<Int32>? = nil,
  stopped: Set<Int32> = [], inFlight: Set<String> = [], wants: Bool = true
) -> AutoPauseWiring.Scan {
  .init(
    threads: threads, unused: unused, protections: protections, scope: scope, stopped: stopped,
    inFlight: inFlight, wantsCandidates: wants)
}

/// The model-side glue of automatic pause and resume (Task 5.3a).
enum AutoPauseWiringTests {}

extension AutoPauseWiringTests {
  struct Sets {
    @Test func candidatesAreUnusedUnprotectedRunningAndStillIdle() {
      let threads = [
        thread("idle", root: 10, bytes: 300),
        thread("kept", root: 20),
        thread("busy", root: 30, status: .busy),
        thread("shell", root: 40, status: .shell),
        thread("paused", root: 50, paused: true),
        thread("used", root: 60),
        thread("changed", root: 70),
      ]
      let unused: [String: UnusedPolicy.Reason] = [
        "idle": .idle(9_000), "kept": .idle(9_000), "busy": .detached, "shell": .detached,
        "paused": .idle(9_000), "changed": .idle(9_000),
      ]
      var probed: [String] = []
      let sets = AutoPauseWiring.sets(
        scan(threads, unused: unused, protections: ["kept": .kept], stopped: [50])
      ) { thread in
        probed.append(thread.id)
        return thread.id != "changed"
      }
      #expect(sets.candidates == [.init(threadID: "idle", memoryBytes: 300, isPaused: false)])
      // The live re-read runs last, only for threads that pass every scan check.
      #expect(probed == ["idle", "changed"])
      #expect(sets.pausedNow == ["paused"])
      #expect(sets.runningNow == ["idle", "kept", "busy", "shell", "used", "changed"])
    }

    @Test func pausedNowNeedsEveryProcessStoppedAndRunningNowNone() {
      let threads = [
        thread("all", root: 10, children: [11], paused: true),
        thread("part", root: 20, children: [21]),
        thread("none", root: 30, children: [31]),
      ]
      let sets = AutoPauseWiring.sets(scan(threads, stopped: [10, 11, 21])) { _ in true }
      #expect(sets.pausedNow == ["all"])
      #expect(sets.runningNow == ["none"])
    }

    /// A child stopped by hand (Ctrl-Z in the session's shell) would be recorded with the pause,
    /// then sent SIGCONT by Resume now, the automatic resume and the resume at quit. A session
    /// with any process stopped is never a candidate, as for projects.
    @Test func aSessionPartlyStoppedByHandIsNeverACandidate() {
      let threads = [
        thread("part", root: 20, children: [21, 22]),
        thread("rootStopped", root: 30, children: [31]),
        thread("running", root: 40, children: [41]),
      ]
      let unused: [String: UnusedPolicy.Reason] = [
        "part": .idle(9_000), "rootStopped": .idle(9_000), "running": .idle(9_000),
      ]
      var probed: [String] = []
      let sets = AutoPauseWiring.sets(scan(threads, unused: unused, stopped: [21, 30])) {
        probed.append($0.id)
        return true
      }
      #expect(sets.candidates.map(\.threadID) == ["running"])
      #expect(probed == ["running"], "no live re-read for a session that can't be a candidate")
      #expect(sets.pausedNow.isEmpty)
    }

    @Test func aThreadWithASignalInFlightIsInNoSet() {
      let threads = [
        thread("pausing", root: 10), thread("resuming", root: 20, paused: true),
      ]
      let sets = AutoPauseWiring.sets(
        scan(
          threads, unused: ["pausing": .idle(9_000)], stopped: [20],
          inFlight: ["pausing", "resuming"])
      ) { _ in true }
      #expect(sets == .init())
    }

    @Test func e2eScopeKeepsOnlyTargetRootedThreads() {
      // "outside" holds a target as a child; only the root counts.
      let threads = [
        thread("target", root: 101), thread("outside", root: 900, children: [101]),
      ]
      let unused: [String: UnusedPolicy.Reason] = ["target": .idle(9_000), "outside": .idle(9_000)]
      let sets = AutoPauseWiring.sets(scan(threads, unused: unused, scope: [101])) { _ in true }
      #expect(sets.candidates.map(\.threadID) == ["target"])
      #expect(sets.runningNow == ["target"])
      let none = AutoPauseWiring.sets(scan(threads, unused: unused, scope: [])) { _ in true }
      #expect(none == .init())
    }

    @Test func noCandidatesAndNoReReadsWhenThePlannerCantPause() {
      var probes = 0
      let sets = AutoPauseWiring.sets(
        scan([thread("idle", root: 10)], unused: ["idle": .idle(9_000)], wants: false)
      ) { _ in
        probes += 1
        return true
      }
      #expect(sets.candidates.isEmpty)
      #expect(sets.runningNow == ["idle"])
      #expect(probes == 0)
    }

    @Test func aDuplicateThreadCountsOnce() {
      let threads = [thread("a", root: 10, bytes: 5), thread("a", root: 10, bytes: 7)]
      let sets = AutoPauseWiring.sets(scan(threads, unused: ["a": .idle(9_000)])) { _ in true }
      #expect(sets.candidates == [.init(threadID: "a", memoryBytes: 5, isPaused: false)])
    }
  }

  struct Records {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func ledger(_ ids: String...) -> AutoPauseWiring.Record {
      var record = AutoPauseWiring.Record()
      record.state.ledger = ids.map { .init(threadID: $0, reason: .pressure, since: t0) }
      return record
    }

    @Test func aPauseRecordsIdentitiesAndCancelsAnOwedResume() {
      var record = ledger("a")
      record.resuming("a")
      record.paused("a", identities: [identity(10), identity(11)])
      #expect(record.identities["a"]?.map(\.process.processID) == [10, 11])
      #expect(record.pendingResumes.isEmpty)
    }

    @Test func aResumeIsOwedUntilNoProcessIsLeftStopped() {
      var record = ledger("a")
      record.paused("a", identities: [identity(10)])
      // The planner takes "a" out of the ledger when it emits the resume.
      record.state.ledger = []
      record.resuming("a")
      record.prune()
      #expect(record.identities["a"] != nil, "kept while the resume is owed")
      record.resumed("a", stillStopped: 1)
      #expect(record.pendingResumes == ["a"])
      #expect(record.retries(inFlight: []) == ["a"])
      #expect(record.retries(inFlight: ["a"]).isEmpty)
      record.resumed("a", stillStopped: 0)
      #expect(record.pendingResumes.isEmpty)
      #expect(record.identities.isEmpty)
    }

    @Test func aRefusedResumeIsRetried() {
      var record = AutoPauseWiring.Record()
      record.resuming("a")
      #expect(record.retries(inFlight: []) == ["a"])
    }

    @Test func retriesLeaveThreadsThePlannerOwnsAgain() {
      var record = ledger("a")
      record.pendingResumes = ["a", "b"]
      #expect(record.retries(inFlight: []) == ["b"])
    }

    @Test func pruneKeepsIdentitiesOfLedgerAndOwedThreadsOnly() {
      var record = ledger("a")
      record.identities = ["a": [identity(1)], "b": [identity(2)], "c": [identity(3)]]
      record.pendingResumes = ["b"]
      record.prune()
      #expect(Set(record.identities.keys) == ["a", "b"])
    }

    @Test func aUserPauseOrResumeMakesTheThreadTheirs() {
      var record = ledger("a", "b")
      record.identities = ["a": [identity(1)], "b": [identity(2)], "c": [identity(3)]]
      record.pendingResumes = ["c"]
      record.userSignalled("a", .resume)
      record.userSignalled("b", .pause)
      record.userSignalled("c", .pause)
      #expect(record.state.ledger.isEmpty)
      #expect(record.pendingResumes.isEmpty)
      #expect(record.identities.isEmpty)
      // Only a resume of a thread Tamebar paused keeps it from being paused again this episode.
      #expect(record.state.userResumed == ["a"])
      var quit = ledger("q")
      quit.userSignalled("q", .quit)
      #expect(quit.state.ledger.map(\.threadID) == ["q"])
    }

    @Test func resetClocksKeepsTheLedgerAndEpisode() {
      var state = AutoPausePlanner.State()
      state.ledger = [.init(threadID: "a", reason: .meeting, since: t0)]
      state.elevatedSince = t0
      state.calmSince = t0
      state.lastPause = t0
      state.lastTick = t0
      state.userResumed = ["u"]
      state.forceResumed = ["f"]
      var expected = state
      expected.elevatedSince = nil
      expected.calmSince = nil
      state.resetClocks()
      #expect(state == expected)
    }
  }

  final class Store {
    private let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("autopause-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

    private func folder(_ name: String) throws -> URL {
      let dir = root.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir
    }

    @Test func roundTrips() throws {
      let url = try #require(
        AutoPauseWiring.storeURL(directory: try folder("Tamebar"), e2e: false))
      var record = AutoPauseWiring.Record()
      let at = Date(timeIntervalSince1970: 1_800_000_000.25)
      record.state.ledger = [.init(threadID: "a", reason: .pressure, since: at)]
      record.state.elevatedSince = at
      record.state.lastTick = at
      record.state.userResumed = ["u"]
      record.identities = ["a": [identity(10), identity(11, stopped: true)]]
      record.pendingResumes = ["b"]
      AutoPauseWiring.save(record, to: url)
      #expect(AutoPauseWiring.load(url) == record)
    }

    @Test func aMissingOrUnreadableFileStartsEmpty() throws {
      let url = try folder("Tamebar").appendingPathComponent("autopause.json")
      #expect(AutoPauseWiring.load(url) == .init())
      try Data("not json".utf8).write(to: url)
      #expect(AutoPauseWiring.load(url) == .init())
      try Data("[1, 2]".utf8).write(to: url)
      #expect(AutoPauseWiring.load(url) == .init())
    }

    @Test func anUnreadableFileIsKeptAside() throws {
      let url = try folder("Tamebar").appendingPathComponent("autopause.json")
      try Data("not json".utf8).write(to: url)
      let record = AutoPauseWiring.load(url, now: Date(timeIntervalSince1970: 1_800_000_000))
      #expect(record == .init())
      #expect(!FileManager.default.fileExists(atPath: url.path))
      let aside = url.deletingLastPathComponent()
        .appendingPathComponent("autopause.unreadable-1800000000.json")
      #expect(try String(contentsOf: aside, encoding: .utf8) == "not json")
    }

    @Test func aBadFieldNeverDropsTheOthers() throws {
      let url = try folder("Tamebar").appendingPathComponent("autopause.json")
      let json = """
        {"state": {"ledger": [{"threadID": "a", "reason": "pressure", "since": 0},
                              {"threadID": "b", "reason": "lunch", "since": 0}]},
         "identities": "garbage", "pendingResumes": ["c"]}
        """
      try Data(json.utf8).write(to: url)
      let record = AutoPauseWiring.load(url)
      #expect(record.state.ledger.map(\.threadID) == ["a"])
      #expect(record.identities.isEmpty)
      #expect(record.pendingResumes == ["c"])
    }

    @Test func theE2EBuildOnlyWritesInItsOwnFolder() throws {
      #expect(
        AutoPauseWiring.storeURL(directory: try folder("Tamebar"), e2e: true) == nil)
      let own = try folder("Tamebar-e2e")
      #expect(
        AutoPauseWiring.storeURL(directory: own, e2e: true)
          == own.appendingPathComponent("autopause.json"))
    }
  }

  struct Dump {
    @Test func theStateDumpCarriesPausedByCandidatesNoteAndTheTickGap() {
      let state = E2EState.build(
        .init(
          at: .now, risk: .warning, meeting: false,
          threads: [thread("a", root: 101, paused: true), thread("b", root: 102)], unused: [:],
          protections: [:], ended: [], targets: [101, 102], pausedBy: ["a": "pressure"],
          maxTickGap: 2.5, candidates: ["b"], note: "Paused 1 idle session", slowed: [103],
          userResumed: ["project:/w", "a"]))
      #expect(state.threads.map(\.pausedBy) == ["pressure", nil])
      #expect(state.threads.map(\.id) == ["a", "b"])
      #expect(state.maxTickGap == 2.5)
      #expect(state.candidates == ["b"])
      #expect(state.note == "Paused 1 idle session")
      #expect(state.slowed == [103])
      // What the user resumed this episode, sorted: empty once the episode has ended.
      #expect(state.userResumed == ["a", "project:/w"])
    }
  }

  struct Note {
    @Test func saysHowManyAndWhy() {
      #expect(AutoPauseWiring.note(paused: []) == nil)
      #expect(
        AutoPauseWiring.note(paused: [.pressure])
          == "Paused 1 idle session · resumes when memory recovers")
      #expect(
        AutoPauseWiring.note(paused: [.pressure, .pressure])
          == "Paused 2 idle sessions · resumes when memory recovers")
      #expect(AutoPauseWiring.note(paused: [.meeting]) == "Paused 1 idle session for your call")
      #expect(
        AutoPauseWiring.note(paused: [.meeting, .meeting, .meeting])
          == "Paused 3 idle sessions for your call")
    }

    /// No banners (2026-10-27): the note says what the pause freed, when it is known.
    @Test func saysWhatAPressurePauseFreed() {
      #expect(
        AutoPauseWiring.note(paused: [.pressure, .pressure, .pressure], freed: 2_400_000_000)
          == "Paused 3 idle sessions · \(ByteText.full(2_400_000_000)) · resumes when memory recovers"
      )
      #expect(
        AutoPauseWiring.note(paused: [.pressure], freed: 0)
          == "Paused 1 idle session · resumes when memory recovers")
      // A call's note keeps its words: the call state covers the notch while it lasts.
      #expect(
        AutoPauseWiring.note(paused: [.meeting], freed: 300_000_000)
          == "Paused 1 idle session for your call")
    }
  }

  @MainActor
  final class Launch {
    private let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("autopause-launch-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: root) }

    @Test func theTestHostNeverActsOnItsOwn() async {
      #expect(!AppBrand.isInstalledBuild)
      var record = AutoPauseWiring.Record()
      record.state.elevatedSince = Date(timeIntervalSince1970: 0)
      let fake = FakeSignals()
      // The installed check stays at its default. The folder is a temporary one, so a broken
      // gate fails here without touching the real app's files.
      let controller = AutoPauseController.launch(
        signaller: fake.signaller, scans: { 0 }, directory: root.appendingPathComponent("Tamebar"),
        e2e: false)
      #expect(!controller.acts)
      let outcome = controller.run(
        .init(
          now: Date(timeIntervalSince1970: 60), scan: 1, threads: [thread("p", root: 30)],
          unused: ["p": .idle(9_000)], protections: [:], scope: nil, stopped: [],
          risk: .critical, inMeeting: true, stopping: [], complete: true, stillIdle: { _ in true }))
      #expect(outcome.paused.isEmpty)
      #expect(fake.calls.isEmpty)
    }

    @Test func anInstalledBuildActsOnlyWhileItHoldsTheLock() throws {
      let directory = root.appendingPathComponent("Tamebar")
      let fake = FakeSignals()
      let first = AutoPauseController.launch(
        signaller: fake.signaller, scans: { 0 }, installed: true, directory: directory, e2e: false)
      #expect(first.acts)
      let second = AutoPauseController.launch(
        signaller: fake.signaller, scans: { 0 }, installed: true, directory: directory, e2e: false)
      #expect(!second.acts, "a second instance never acts")
      let e2eInRealFolder = AutoPauseController.launch(
        signaller: fake.signaller, scans: { 0 }, installed: true,
        directory: root.appendingPathComponent("Other"), e2e: true)
      #expect(!e2eInRealFolder.acts)
      withExtendedLifetime(first) {}
    }
  }

  final class Lock {
    private let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("autopause-lock-\(UUID().uuidString)")
      .appendingPathComponent("autopause.lock")

    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    @Test func onlyOneHolderAtATime() throws {
      let first = try #require(AutoPauseWiring.Lock.acquire(url))
      #expect(AutoPauseWiring.Lock.acquire(url) == nil)
      AutoPauseWiring.Lock.release(first)
      let again = try #require(AutoPauseWiring.Lock.acquire(url))
      AutoPauseWiring.Lock.release(again)
    }
  }

  struct Quit {
    private func reused(_ pid: Int32) -> DevProcessIdentity {
      DevProcessIdentity(
        process: RecoveryProcess(
          processID: pid, owner: 501, startSeconds: 1_900_000_000, startMicroseconds: 1,
          state: UInt32(SSTOP)),
        executable: "/bin/sh")
    }

    @Test func resumesEveryOwedTreeAndNothingElse() {
      var record = AutoPauseWiring.Record()
      record.state.ledger = [.init(threadID: "a", reason: .pressure, since: .now)]
      record.pendingResumes = ["b"]
      record.identities = [
        "a": [identity(10, stopped: true)], "b": [identity(20, stopped: true)],
        "c": [identity(30, stopped: true)],
      ]
      // 11 and 12 descend from 10. 20 is now another process, so it and its child 21 are left.
      let parents: [Int32: Int32] = [10: 1, 11: 10, 12: 11, 20: 1, 21: 20, 30: 1, 31: 30]
      var sent: [Int32] = []
      let count = AutoPauseWiring.resumeAll(
        record,
        .init(
          parents: parents, read: { $0 == 20 ? reused(20) : identity($0, stopped: true) },
          send: {
            sent.append($0.process.processID)
            return true
          }))
      #expect(sent == [10, 11, 12])
      #expect(count == 3)
    }

    @Test @MainActor func quittingForgetsTheLedgerAndSaves() throws {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("autopause-quit-\(UUID().uuidString).json")
      defer { try? FileManager.default.removeItem(at: url) }
      var record = AutoPauseWiring.Record()
      record.state.ledger = [.init(threadID: "a", reason: .meeting, since: .now)]
      record.identities = ["a": [identity(10)]]
      record.pendingResumes = ["b"]
      let controller = AutoPauseController(
        record: record, acts: true, url: url, signaller: FakeSignals().signaller, scans: { 0 })
      var sent = 0
      controller.resumeAllForQuit(
        .init(
          parents: [10: 1], read: { identity($0) },
          send: { _ in
            sent += 1
            return true
          }))
      #expect(sent == 1)
      #expect(controller.record == AutoPauseWiring.Record())
      #expect(AutoPauseWiring.load(url) == AutoPauseWiring.Record())
    }
  }

  @MainActor
  struct Controller {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func tick(
      _ second: TimeInterval, scan: Int, threads: [AIThread],
      unused: [String: UnusedPolicy.Reason] = [:], stopped: Set<Int32> = [],
      risk: MemoryRisk = .normal, meeting: Bool = false, complete: Bool = true
    ) -> AutoPauseWiring.Tick {
      .init(
        now: t0.addingTimeInterval(second), scan: scan, threads: threads, unused: unused,
        protections: [:], scope: nil, stopped: stopped, risk: risk, inMeeting: meeting,
        stopping: [], complete: complete, stillIdle: { _ in true })
    }

    private func settle(_ outcome: AutoPauseWiring.Outcome) async {
      for task in outcome.tasks { await task.value }
    }

    // Since Q18 a session is paused only for a call (or heat), never for memory: the tests that
    // drove a session pause through memory pressure drive it through a call.

    @Test func resumesAreAppliedBeforePauses() async {
      var record = AutoPauseWiring.Record()
      // A resume still owed (a call ended earlier) and a call pausing p this tick.
      record.pendingResumes = ["r"]
      record.identities = ["r": [identity(20, stopped: true)]]
      let fake = FakeSignals()
      fake.scanned = [20: identity(20, stopped: true), 30: identity(30)]
      let controller = fake.controller(record)
      let outcome = controller.run(
        tick(
          10, scan: 1, threads: [thread("r", root: 20, paused: true), thread("p", root: 30)],
          unused: ["p": .idle(9_000)], stopped: [20], meeting: true))
      await settle(outcome)
      #expect(fake.calls.filter { $0.hasPrefix("begin") } == ["begin resume r", "begin pause p"])
      #expect(outcome.resumed == 1)
      #expect(outcome.paused == [.meeting])
    }

    /// Q18: memory pressure alone never pauses a session, however long it holds.
    @Test func memoryPressureNeverPausesASession() async {
      var record = AutoPauseWiring.Record()
      record.state.elevatedSince = t0
      let fake = FakeSignals()
      fake.scanned = [30: identity(30)]
      let controller = fake.controller(record)
      for second in stride(from: 0, through: 400, by: 2) {
        let outcome = controller.run(
          tick(
            TimeInterval(second), scan: second + 1, threads: [thread("p", root: 30)],
            unused: ["p": .idle(9_000)], risk: .critical))
        #expect(outcome.paused.isEmpty)
      }
      #expect(controller.candidates.isEmpty)
      #expect(fake.calls.isEmpty)
    }

    @Test func aPauseRecordsIdentities() async {
      let record = AutoPauseWiring.Record()
      let fake = FakeSignals()
      fake.scanned = [30: identity(30), 31: identity(31), 99: identity(99)]
      let controller = fake.controller(record)
      await settle(
        controller.run(
          tick(
            10, scan: 1, threads: [thread("p", root: 30, children: [31])],
            unused: ["p": .idle(9_000)], meeting: true)))
      #expect(controller.pausedBy("p")?.reason == .meeting)
      #expect(controller.record.identities["p"]?.map(\.process.processID).sorted() == [30, 31])
      #expect(fake.calls.contains("finish pause p [30, 31]"))
    }

    @Test func aThreadTheScanDoesNotListIsResumedByIdentity() async {
      var record = AutoPauseWiring.Record()
      record.state.ledger = [.init(threadID: "x", reason: .meeting, since: t0)]
      record.identities = ["x": [identity(40, stopped: true)]]
      let fake = FakeSignals()
      fake.byIdentityLeft = 1
      let controller = fake.controller(record)
      await settle(controller.run(tick(1, scan: 1, threads: [])))
      #expect(fake.calls == ["byIdentity x [40]"])
      #expect(controller.record.pendingResumes == ["x"], "a process stayed stopped")
      fake.byIdentityLeft = 0
      let retry = controller.run(tick(2, scan: 2, threads: []))
      await settle(retry)
      #expect(retry.resumed == 1)
      #expect(fake.calls == ["byIdentity x [40]", "byIdentity x [40]"])
      #expect(controller.record.pendingResumes.isEmpty)
      #expect(controller.record.identities.isEmpty)
    }

    @Test func withNoIdentitiesItStaysOwedUntilACompleteScanMissesIt() async {
      var record = AutoPauseWiring.Record()
      record.state.ledger = [.init(threadID: "x", reason: .meeting, since: t0)]
      let fake = FakeSignals()
      let controller = fake.controller(record)
      controller.run(tick(1, scan: 1, threads: [], complete: false))
      #expect(controller.record.pendingResumes == ["x"])
      controller.run(tick(2, scan: 2, threads: [], complete: false))
      #expect(controller.record.pendingResumes == ["x"])
      controller.run(tick(3, scan: 3, threads: [], complete: true))
      #expect(controller.record.pendingResumes.isEmpty)
      #expect(fake.calls.isEmpty)
    }

    @Test func theThreadPathAddsRecordedIdentitiesAndCountsThem() async {
      var record = AutoPauseWiring.Record()
      record.state.ledger = [.init(threadID: "r", reason: .meeting, since: t0)]
      record.identities = ["r": [identity(20, stopped: true), identity(21, stopped: true)]]
      let fake = FakeSignals()
      fake.scanned = [20: identity(20, stopped: true)]
      fake.stopped = 1
      let controller = fake.controller(record)
      await settle(
        controller.run(
          tick(1, scan: 1, threads: [thread("r", root: 20, paused: true)], stopped: [20])))
      #expect(fake.calls.contains("finish resume r [20, 21]"))
      #expect(fake.counted == [[20, 21]])
      #expect(controller.record.pendingResumes == ["r"])
    }

    @Test func aSignalLandingAfterTheScanBeganKeepsTheThreadOutOfEverySet() async {
      let record = AutoPauseWiring.Record()
      let fake = FakeSignals()
      fake.scanned = [10: identity(10)]
      let controller = fake.controller(record)
      // "b" is a session in use: never a candidate, so only "a" is paused for the call.
      let threads = [thread("a", root: 10), thread("b", root: 20)]
      let unused: [String: UnusedPolicy.Reason] = ["a": .idle(9_000)]
      fake.scan = 5
      let pause = controller.run(
        tick(10, scan: 5, threads: threads, unused: unused, meeting: true))
      #expect(pause.paused == [.meeting])
      // In flight: scan 5 still shows "a" running, which is not a user resume.
      controller.run(tick(11, scan: 5, threads: threads, unused: unused, meeting: true))
      #expect(controller.candidates.isEmpty)
      #expect(controller.pausedBy("a") != nil)
      await settle(pause)
      // Landed while scan 5 was the latest: scan 5 began before it, so still out of every set.
      controller.run(tick(12, scan: 5, threads: threads, unused: unused, meeting: true))
      #expect(controller.candidates.isEmpty)
      #expect(controller.pausedBy("a") != nil)
      #expect(controller.record.state.userResumed.isEmpty)
      // Scan 6 began after: "a" running now means the user resumed it.
      controller.run(tick(13, scan: 6, threads: threads, unused: unused, meeting: true))
      #expect(controller.pausedBy("a") == nil)
      #expect(controller.record.state.userResumed == ["a"])
    }

    @Test func aPausedThreadTheScanLosesIsResumedByItsRecordedIdentities() async {
      let record = AutoPauseWiring.Record()
      let fake = FakeSignals()
      fake.scanned = [30: identity(30), 31: identity(31)]
      let controller = fake.controller(record)
      await settle(
        controller.run(
          tick(
            10, scan: 1, threads: [thread("p", root: 30, children: [31])],
            unused: ["p": .idle(9_000)], meeting: true)))
      // The call ends; the scan no longer lists p.
      await settle(controller.run(tick(11, scan: 2, threads: [])))
      #expect(fake.calls.last == "byIdentity p [30, 31]")
      #expect(controller.record.state.ledger.isEmpty)
      #expect(controller.record.pendingResumes.isEmpty)
    }

    @Test func automaticSignalsAreNotAnnounced() async {
      let record = AutoPauseWiring.Record()
      let fake = FakeSignals()
      fake.scanned = [30: identity(30)]
      await settle(
        fake.controller(record).run(
          tick(
            10, scan: 1, threads: [thread("p", root: 30)], unused: ["p": .idle(9_000)],
            meeting: true)))
      #expect(fake.calls == ["begin pause p", "finish pause p [30]"])
    }

    @Test func anOwedResumeKeepsTheThreadOutOfEverySet() {
      var record = AutoPauseWiring.Record()
      record.pendingResumes = ["p"]
      let fake = FakeSignals()
      fake.inFlight = ["p"]
      let controller = fake.controller(record)
      let outcome = controller.run(
        tick(
          10, scan: 1, threads: [thread("p", root: 30)], unused: ["p": .idle(9_000)],
          meeting: true))
      #expect(controller.candidates.isEmpty)
      #expect(outcome.paused.isEmpty)
      #expect(controller.record.pendingResumes == ["p"], "refused: still owed")
    }
  }
}

private func project(
  _ directory: String, _ pids: [Int32], stopped: Set<Int32> = [], bytes: UInt64 = 100,
  keep: Bool = false, capturedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
) -> ProjectPauseTarget {
  ProjectPauseTarget(
    directory: directory, name: URL(fileURLWithPath: directory).lastPathComponent,
    cpuPercent: 0, memoryBytes: bytes,
    identities: pids.map { identity($0, stopped: stopped.contains($0)) }, capturedAt: capturedAt,
    keepRunning: keep,
    processBytes: Dictionary(uniqueKeysWithValues: pids.map { ($0, bytes / UInt64(pids.count)) }))
}

/// Opted-in dev-server projects through the same controller (D6.4, Task 5.4).
extension AutoPauseWiringTests {
  struct ProjectSets {
    private let now = Date(timeIntervalSince1970: 1_800_000_005)

    private func sets(
      _ targets: [ProjectPauseTarget], optedIn: Set<String>, kept: Set<String> = [],
      scope: Set<Int32>? = nil, parents: [Int32: Int32] = [:], inFlight: Set<String> = [],
      wants: Bool = true
    ) -> AutoPauseWiring.Sets {
      AutoPauseWiring.projectSets(
        .init(
          projects: .init(targets: targets, optedIn: optedIn, kept: kept, parents: parents),
          scope: scope, inFlight: inFlight, now: now, wantsCandidates: wants))
    }

    @Test func idsAreNamespacedAndNeverMatchAThreadID() {
      #expect(AutoPauseWiring.projectID("/code/web") == "project:/code/web")
      #expect(AutoPauseWiring.projectDirectory("project:/code/web") == "/code/web")
      for tool in [
        AITool.claudeCode, .codexCLI, .codexDesktop, .cursorAgent, .otherAgent,
      ] {
        #expect(AutoPauseWiring.projectDirectory("\(tool.rawValue)-123-1800000000") == nil)
      }
      #expect(AutoPauseWiring.projectDirectory("codex-123-1800000000") == nil)
    }

    @Test func onlyOptedInRunningFreshProjectsNotKeptRunningAreCandidates() {
      let targets = [
        project("/code/web", [10], bytes: 900),
        project("/code/off", [20]),
        project("/code/keep", [30], keep: true),
        project("/code/kept-root", [40]),
        project("/code/stale", [50], capturedAt: now.addingTimeInterval(-20)),
        project("/code/paused", [60], stopped: [60]),
      ]
      let result = sets(
        targets,
        optedIn: [
          "/code/web", "/code/keep", "/code/kept-root", "/code/stale", "/code/paused",
        ], kept: ["/code/kept-root"])
      #expect(
        result.candidates == [
          .init(threadID: "project:/code/web", memoryBytes: 900, isPaused: false)
        ])
      #expect(result.pausedNow == ["project:/code/paused"])
      #expect(
        result.runningNow == [
          "project:/code/web", "project:/code/off", "project:/code/keep",
          "project:/code/kept-root", "project:/code/stale",
        ])
    }

    @Test func pausedNowNeedsEveryProcessStoppedAndRunningNowNone() {
      let result = sets(
        [
          project("/code/all", [10, 11], stopped: [10, 11]),
          project("/code/part", [20, 21], stopped: [21]),
        ], optedIn: ["/code/all", "/code/part"])
      #expect(result.pausedNow == ["project:/code/all"])
      #expect(result.runningNow.isEmpty)
      #expect(result.candidates.isEmpty, "a partly stopped project is left alone")
    }

    @Test func aProjectInFlightIsInNoSet() {
      let result = sets(
        [project("/code/web", [10]), project("/code/api", [20], stopped: [20])],
        optedIn: ["/code/web", "/code/api"],
        inFlight: ["project:/code/web", "project:/code/api"])
      #expect(result == .init())
    }

    @Test func noCandidatesWhenThePlannerCantPause() {
      let result = sets([project("/code/web", [10])], optedIn: ["/code/web"], wants: false)
      #expect(result.candidates.isEmpty)
      #expect(result.runningNow == ["project:/code/web"])
    }

    @Test func e2eScopeKeepsOnlyProjectsWhollyInsideATargetsTree() {
      let targets = [
        project("/code/inside", [101, 102]), project("/code/mixed", [101, 900]),
        project("/code/outside", [900]),
      ]
      let result = sets(
        targets, optedIn: ["/code/inside", "/code/mixed", "/code/outside"], scope: [101],
        parents: [101: 1, 102: 101, 900: 1])
      #expect(result.candidates.map(\.threadID) == ["project:/code/inside"])
      #expect(result.runningNow == ["project:/code/inside"])
      #expect(
        sets(targets, optedIn: ["/code/inside"], scope: [], parents: [101: 1]) == .init())
    }
  }

  struct ProjectNote {
    @Test func namesTheProjectAndJoinsSessions() {
      let web = AutoPauseWiring.PausedProject(
        directory: "/code/web", name: "web", reason: .pressure)
      #expect(
        AutoPauseWiring.note(paused: [], projects: [web])
          == "Paused web · resumes when memory recovers")
      #expect(
        AutoPauseWiring.note(
          paused: [], projects: [.init(directory: "/code/web", name: "web", reason: .meeting)])
          == "Paused web for your call")
      #expect(
        AutoPauseWiring.note(paused: [.pressure, .pressure], projects: [web])
          == "Paused 2 idle sessions and web · resumes when memory recovers")
      #expect(
        AutoPauseWiring.note(
          paused: [.meeting],
          projects: [
            .init(directory: "/code/web", name: "web", reason: .meeting),
            .init(directory: "/code/api", name: "api", reason: .meeting),
          ])
          == "Paused 1 idle session and 2 projects for your call")
    }
  }

  @MainActor
  struct ProjectController {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func tick(
      _ second: TimeInterval, scan: Int, projects: [ProjectPauseTarget] = [],
      optedIn: Set<String> = ["/code/web"], threads: [AIThread] = [],
      unused: [String: UnusedPolicy.Reason] = [:], stopped: Set<Int32> = [],
      risk: MemoryRisk = .normal, meeting: Bool = false, stopping: Set<String> = [],
      complete: Bool = true
    ) -> AutoPauseWiring.Tick {
      .init(
        now: t0.addingTimeInterval(second), scan: scan, threads: threads, unused: unused,
        protections: [:], scope: nil, stopped: stopped, risk: risk, inMeeting: meeting,
        stopping: stopping, complete: complete,
        projects: .init(targets: projects, optedIn: optedIn), stillIdle: { _ in true })
    }

    private func settle(_ outcome: AutoPauseWiring.Outcome) async {
      for task in outcome.tasks { await task.value }
    }

    /// A record that has already looked for projects an older build left stopped.
    private func migrated() -> AutoPauseWiring.Record {
      var record = AutoPauseWiring.Record()
      record.projectsMigrated = true
      return record
    }

    @Test func aProjectIsPausedAfterSixSecondsThroughItsOwnPathAndRecordsItsIdentities()
      async
    {
      let fake = FakeSignals()
      let controller = fake.controller(migrated())
      for second in 0..<6 {
        let web = project(
          "/code/web", [10, 11], capturedAt: t0.addingTimeInterval(TimeInterval(second)))
        let outcome = controller.run(
          tick(TimeInterval(second), scan: second + 1, projects: [web], risk: .warning))
        #expect(outcome.pausedProjects.isEmpty)
      }
      let web = project("/code/web", [10, 11], capturedAt: t0.addingTimeInterval(6))
      let outcome = controller.run(tick(6, scan: 7, projects: [web], risk: .warning))
      await settle(outcome)
      #expect(
        outcome.pausedProjects == [
          .init(directory: "/code/web", name: "web", reason: .pressure, memoryBytes: 100)
        ])
      #expect(fake.calls == ["project pause /code/web [10, 11]"])
      #expect(controller.pausedBy("project:/code/web")?.reason == .pressure)
      #expect(
        controller.record.identities["project:/code/web"]?.map(\.process.processID) == [10, 11])
    }

    @Test func noResumeBeforeThirtyCalmSecondsThenOneThroughTheProjectPath() async {
      var record = migrated()
      record.state.ledger = [.init(threadID: "project:/code/web", reason: .pressure, since: t0)]
      record.state.elevatedSince = t0
      record.identities = ["project:/code/web": [identity(10, stopped: true)]]
      let fake = FakeSignals()
      let controller = fake.controller(record)
      for second in 10..<40 {
        let paused = project(
          "/code/web", [10], stopped: [10], capturedAt: t0.addingTimeInterval(TimeInterval(second)))
        controller.run(tick(TimeInterval(second), scan: second, projects: [paused]))
      }
      #expect(fake.calls.isEmpty, "resumed before 30 calm seconds")
      let paused = project("/code/web", [10], stopped: [10], capturedAt: t0.addingTimeInterval(40))
      let outcome = controller.run(tick(40, scan: 40, projects: [paused]))
      await settle(outcome)
      #expect(outcome.resumed == 1)
      #expect(outcome.resumedProjects == ["/code/web": "web"])
      #expect(fake.calls == ["project resume /code/web [10]"])
      #expect(controller.record.state.ledger.isEmpty)
      #expect(controller.record.pendingResumes.isEmpty)
      #expect(controller.record.identities.isEmpty)
    }

    @Test func aProjectIsForcedBackAfterFiveMinutesUnderPressure() async {
      var record = migrated()
      record.state.ledger = [.init(threadID: "project:/code/web", reason: .pressure, since: t0)]
      record.state.elevatedSince = t0
      record.state.lastPause = t0
      record.identities = ["project:/code/web": [identity(10, stopped: true)]]
      let fake = FakeSignals()
      let controller = fake.controller(record)
      let paused = project("/code/web", [10], stopped: [10], capturedAt: t0.addingTimeInterval(299))
      controller.run(tick(299, scan: 1, projects: [paused], risk: .critical))
      #expect(fake.calls.isEmpty)
      let outcome = controller.run(tick(300, scan: 2, projects: [paused], risk: .critical))
      await settle(outcome)
      #expect(fake.calls == ["project resume /code/web [10]"])
      #expect(controller.record.state.forceResumed == ["project:/code/web"])
    }

    @Test func aProjectTheScanDoesNotListIsResumedByItsRecordedIdentities() async {
      var record = migrated()
      record.state.ledger = [.init(threadID: "project:/code/web", reason: .meeting, since: t0)]
      record.identities = [
        "project:/code/web": [identity(40, stopped: true), identity(41, stopped: true)]
      ]
      let fake = FakeSignals()
      fake.projectLeft = 1
      let controller = fake.controller(record)
      await settle(controller.run(tick(1, scan: 1)))
      #expect(fake.calls == ["project resume /code/web [40, 41]"])
      #expect(controller.record.pendingResumes == ["project:/code/web"], "one stayed stopped")
      fake.projectLeft = 0
      await settle(controller.run(tick(2, scan: 2)))
      #expect(fake.calls.count == 2)
      #expect(controller.record.pendingResumes.isEmpty)
      #expect(controller.record.identities.isEmpty)
    }

    @Test func keepRunningAndNotOptedInAreNeverPaused() {
      var record = migrated()
      record.state.elevatedSince = t0
      let fake = FakeSignals()
      let controller = fake.controller(record)
      for second in 10..<80 {
        let at = t0.addingTimeInterval(TimeInterval(second))
        controller.run(
          tick(
            TimeInterval(second), scan: second,
            projects: [
              project("/code/web", [10], keep: true, capturedAt: at),
              project("/code/off", [20], capturedAt: at),
            ], optedIn: ["/code/web"], risk: .critical, meeting: second > 40))
      }
      #expect(fake.calls.isEmpty)
    }

    /// Was "sessions and projects share the pacing": since Q18 memory pressure pauses the project
    /// only, never the unused session beside it, however long it holds.
    @Test func underMemoryPressureOnlyTheProjectIsPaused() async {
      var record = migrated()
      record.state.elevatedSince = t0
      let fake = FakeSignals()
      fake.scanned = [30: identity(30)]
      let controller = fake.controller(record)
      let session = thread("s", root: 30, bytes: 300)
      var pauses: [(TimeInterval, String)] = []
      for second in 10..<45 {
        let at = t0.addingTimeInterval(TimeInterval(second))
        let paused = controller.pausedBy("project:/code/web") != nil
        let web = project(
          "/code/web", [10], stopped: paused ? [10] : [], bytes: 900, capturedAt: at)
        let sessionPaused = controller.pausedBy("s") != nil
        let outcome = controller.run(
          tick(
            TimeInterval(second), scan: second, projects: [web],
            threads: [thread("s", root: 30, paused: sessionPaused, bytes: 300)],
            unused: ["s": .idle(9_000)], stopped: sessionPaused ? [30] : [], risk: .warning))
        await settle(outcome)
        fake.scan = second
        for name in outcome.pausedProjects.map(\.name) {
          pauses.append((TimeInterval(second), name))
        }
        if !outcome.paused.isEmpty { pauses.append((TimeInterval(second), session.id)) }
      }
      #expect(pauses.map(\.1) == ["web"], "the session was paused for memory")
    }

    @Test func quittingResumesPausedProjectsByIdentity() {
      var record = migrated()
      record.state.ledger = [.init(threadID: "project:/code/web", reason: .pressure, since: t0)]
      record.identities = ["project:/code/web": [identity(10, stopped: true)]]
      let controller = FakeSignals().controller(record)
      var sent: [Int32] = []
      controller.resumeAllForQuit(
        .init(
          parents: [10: 1, 11: 10], read: { identity($0, stopped: true) },
          send: {
            sent.append($0.process.processID)
            return true
          }))
      #expect(sent == [10, 11])
      #expect(controller.record.state.ledger.isEmpty)
    }

    @Test func aProjectAnOlderBuildLeftStoppedIsResumedOnceByIdentity() async throws {
      let fake = FakeSignals()
      let controller = fake.controller(.init())
      let stranded = project("/code/web", [10, 11], stopped: [10, 11], capturedAt: t0)
      let notOptedIn = project("/code/off", [20], stopped: [20], capturedAt: t0)
      // An incomplete scan may miss projects: wait for a complete one.
      controller.run(tick(0, scan: 1, projects: [stranded, notOptedIn], complete: false))
      #expect(fake.calls.isEmpty)
      #expect(!controller.record.projectsMigrated)
      let outcome = controller.run(tick(1, scan: 2, projects: [stranded, notOptedIn]))
      await settle(outcome)
      #expect(fake.calls == ["project resume /code/web [10, 11]"])
      #expect(controller.record.projectsMigrated)
      #expect(controller.record.pendingResumes.isEmpty)
      // Never again, even when it is stopped once more and not in the ledger.
      fake.scan = 3
      controller.run(tick(2, scan: 4, projects: [stranded]))
      let next = fake.controller(controller.record)
      next.run(tick(3, scan: 5, projects: [stranded]))
      #expect(fake.calls == ["project resume /code/web [10, 11]"])
    }

    @Test func theMigrationLeavesALedgerProjectToItsNormalRules() {
      var record = AutoPauseWiring.Record()
      record.state.ledger = [.init(threadID: "project:/code/web", reason: .pressure, since: t0)]
      record.state.elevatedSince = t0
      record.identities = ["project:/code/web": [identity(10, stopped: true)]]
      let fake = FakeSignals()
      let controller = fake.controller(record)
      let paused = project("/code/web", [10], stopped: [10], capturedAt: t0.addingTimeInterval(10))
      controller.run(tick(10, scan: 1, projects: [paused], risk: .warning))
      #expect(fake.calls.isEmpty)
      #expect(controller.record.projectsMigrated)
      #expect(controller.pausedBy("project:/code/web") != nil)
      #expect(controller.record.pendingResumes.isEmpty, "no resume owed outside the planner")
    }

    // MARK: Review fixes (5.4)

    @Test func aProjectPauseLandingAfterTheScanBeganKeepsItOutOfEverySet() async {
      var record = migrated()
      record.state.elevatedSince = t0
      let fake = FakeSignals()
      let controller = fake.controller(record)
      let running = project("/code/web", [10], capturedAt: t0.addingTimeInterval(10))
      fake.scan = 5
      let pause = controller.run(tick(10, scan: 5, projects: [running], risk: .warning))
      #expect(pause.pausedProjects.count == 1)
      // In flight: scan 5 still shows it running, which is not a user resume.
      controller.run(tick(11, scan: 5, projects: [running], risk: .warning))
      #expect(controller.pausedBy("project:/code/web") != nil)
      await settle(pause)
      // Landed while scan 5 was the latest: scan 5 began before it.
      controller.run(tick(12, scan: 5, projects: [running], risk: .warning))
      #expect(controller.pausedBy("project:/code/web") != nil)
      #expect(controller.record.state.userResumed.isEmpty)
      // Scan 6 began after it landed: running now means the user resumed it.
      controller.run(tick(13, scan: 6, projects: [running], risk: .warning))
      #expect(controller.pausedBy("project:/code/web") == nil)
      #expect(controller.record.state.userResumed == ["project:/code/web"])
    }

    @Test func projectsAreCandidatesDuringACall() async {
      let fake = FakeSignals()
      let controller = fake.controller(migrated())
      let web = project("/code/web", [10], capturedAt: t0)
      let outcome = controller.run(tick(0, scan: 1, projects: [web], meeting: true))
      await settle(outcome)
      #expect(fake.calls == ["project pause /code/web [10]"])
      #expect(controller.pausedBy("project:/code/web")?.reason == .meeting)
      let landed = await outcome.landed()
      #expect(
        AutoPauseWiring.note(paused: landed.sessions, projects: landed.projects)
          == "Paused web for your call")
    }

    @Test func aProjectPauseThatStopsNothingIsDroppedWithoutUsingTheSlot() async {
      var record = migrated()
      record.state.elevatedSince = t0
      let fake = FakeSignals()
      fake.projectChanged = 0
      let controller = fake.controller(record)
      let web = project("/code/web", [10], capturedAt: t0.addingTimeInterval(10))
      let failed = controller.run(tick(10, scan: 1, projects: [web], risk: .warning))
      await settle(failed)
      #expect(await failed.landed().projects.isEmpty, "no note for a pause that stopped nothing")
      #expect(controller.pausedBy("project:/code/web") == nil)
      #expect(controller.record.state.userResumed.isEmpty)
      #expect(controller.record.state.lastPause == nil, "the 30 s slot is handed back")
      #expect(controller.record.identities.isEmpty)
      // It is tried again no sooner than 30 s after the failed pause, not at scan speed.
      fake.projectChanged = 1
      fake.scan = 1
      for second in 11..<40 {
        let again = project(
          "/code/web", [10], capturedAt: t0.addingTimeInterval(TimeInterval(second)))
        let early = controller.run(
          tick(TimeInterval(second), scan: second, projects: [again], risk: .warning))
        #expect(early.pausedProjects.isEmpty, "retried at \(second) s")
      }
      let again = project("/code/web", [10], capturedAt: t0.addingTimeInterval(40))
      let retry = controller.run(tick(40, scan: 40, projects: [again], risk: .warning))
      await settle(retry)
      #expect(await retry.landed().projects.map(\.name) == ["web"])
      #expect(await retry.landed().freed == 100, "the memory of the processes it stopped")
      #expect(controller.pausedBy("project:/code/web") != nil)
    }

    /// A session is paused for a call now (Q18), so its note is the call's.
    @Test func aSessionPauseThatLandsCarriesItsMemoryForTheNote() async {
      let record = migrated()
      let fake = FakeSignals()
      fake.scanned = [30: identity(30)]
      let controller = fake.controller(record)
      let outcome = controller.run(
        tick(
          10, scan: 1, threads: [thread("s", root: 30, bytes: 2_400_000_000)],
          unused: ["s": .idle(9_000)], meeting: true))
      await settle(outcome)
      let landed = await outcome.landed()
      #expect(landed.freed == 2_400_000_000)
      #expect(
        AutoPauseWiring.note(
          paused: landed.sessions, projects: landed.projects, freed: landed.freed)
          == "Paused 1 idle session for your call")
    }

    @Test func aSessionPauseThatStopsNothingIsDroppedWithoutUsingTheSlot() async {
      let record = migrated()
      let fake = FakeSignals()
      fake.scanned = [30: identity(30)]
      fake.finishSends = false
      let controller = fake.controller(record)
      let outcome = controller.run(
        tick(
          10, scan: 1, threads: [thread("s", root: 30)], unused: ["s": .idle(9_000)],
          meeting: true))
      await settle(outcome)
      #expect(await outcome.landed().sessions.isEmpty)
      #expect(controller.pausedBy("s") == nil)
      #expect(controller.record.state.userResumed.isEmpty)
      #expect(controller.record.state.lastPause == nil)
    }

    @Test func aCandidateRanksByTheProcessesAPauseWouldStop() {
      // 900 MB in the folder, but only pid 10 (50 MB) is Tamebar's to pause.
      var web = project("/code/web", [10], bytes: 900, capturedAt: t0)
      web.processBytes = [10: 50, 11: 850]
      let api = project("/code/api", [20], bytes: 300, capturedAt: t0)
      let sets = AutoPauseWiring.projectSets(
        .init(
          projects: .init(targets: [web, api], optedIn: ["/code/web", "/code/api"]), scope: nil,
          inFlight: [], now: t0, wantsCandidates: true))
      #expect(sets.candidates.map(\.memoryBytes) == [50, 300])
    }

    @Test func aResumeSignalsExactlyTheRecordedProcesses() async {
      var record = migrated()
      record.state.ledger = [.init(threadID: "project:/code/web", reason: .meeting, since: t0)]
      record.identities = ["project:/code/web": [identity(10, stopped: true)]]
      let fake = FakeSignals()
      let controller = fake.controller(record)
      // 11 was stopped by hand (Ctrl-Z) in the same folder: never touched.
      let scanned = project("/code/web", [10, 11], stopped: [10, 11], capturedAt: t0)
      await settle(controller.run(tick(1, scan: 1, projects: [scanned])))
      #expect(fake.calls == ["project resume /code/web [10]"])
    }

    @Test func nothingToResumeByIsSettledOnlyByACompleteScan() async {
      var record = migrated()
      record.state.ledger = [.init(threadID: "project:/code/web", reason: .meeting, since: t0)]
      let fake = FakeSignals()
      let controller = fake.controller(record)
      controller.run(tick(1, scan: 1, complete: false))
      #expect(controller.record.pendingResumes == ["project:/code/web"])
      controller.run(tick(2, scan: 2, complete: false))
      #expect(controller.record.pendingResumes == ["project:/code/web"])
      controller.run(tick(3, scan: 3))
      #expect(controller.record.pendingResumes.isEmpty)
      #expect(fake.calls.isEmpty)
    }

    /// The next-largest was a session before Q18; sessions aren't paused for memory any more, so
    /// it is a second project.
    @Test func aFailingLargestProjectLetsTheNextCandidateGoAtOnce() async {
      var record = migrated()
      record.state.elevatedSince = t0
      let fake = FakeSignals()
      fake.projectChanged = 0
      let controller = fake.controller(record)
      func projects(_ second: TimeInterval) -> [ProjectPauseTarget] {
        [
          project("/code/web", [10], bytes: 900, capturedAt: t0.addingTimeInterval(second)),
          project("/code/api", [20], bytes: 100, capturedAt: t0.addingTimeInterval(second)),
        ]
      }
      let failed = controller.run(
        tick(
          10, scan: 1, projects: projects(10), optedIn: ["/code/web", "/code/api"], risk: .warning))
      await settle(failed)
      #expect(failed.pausedProjects.map(\.name) == ["web"])
      #expect(
        controller.record.state.pauseFailedAt == ["project:/code/web": t0.addingTimeInterval(10)])
      fake.scan = 1
      fake.projectChanged = 1
      let next = controller.run(
        tick(
          11, scan: 2, projects: projects(11), optedIn: ["/code/web", "/code/api"], risk: .warning))
      #expect(next.pausedProjects.map(\.name) == ["api"], "the next-largest goes at once")
    }

    @Test func theMigrationLeavesAProjectOutsideTheE2EScopeAlone() async {
      let fake = FakeSignals()
      let controller = fake.controller(.init())
      let outside = project("/code/web", [900], stopped: [900], capturedAt: t0)
      await settle(
        controller.run(
          .init(
            now: t0, scan: 1, threads: [], unused: [:], protections: [:], scope: [101],
            stopped: [], risk: .normal, inMeeting: false, stopping: [], complete: true,
            projects: .init(targets: [outside], optedIn: ["/code/web"], parents: [900: 1]),
            stillIdle: { _ in true })))
      #expect(fake.calls.isEmpty)
      #expect(controller.record.pendingResumes.isEmpty)
      #expect(controller.record.projectsMigrated)
    }

    @Test func onlyAResumeThatStartedIsReportedForTheLogAndBanner() {
      var record = migrated()
      record.state.ledger = [
        .init(threadID: "project:/code/web", reason: .meeting, since: t0),
        .init(threadID: "project:/code/api", reason: .meeting, since: t0),
      ]
      record.identities = ["project:/code/web": [identity(10, stopped: true)]]
      let fake = FakeSignals()
      // web's resume is refused (in flight); api has nothing to resume by and settles.
      fake.inFlight = ["project:/code/web"]
      let controller = fake.controller(record)
      let outcome = controller.run(tick(1, scan: 1))
      #expect(outcome.resumedProjects.isEmpty)
      #expect(outcome.resumed == 0)
    }

    @Test func theMigrationTakesAProjectWithAnyProcessStopped() async {
      let fake = FakeSignals()
      let controller = fake.controller(.init())
      let partly = project("/code/web", [10, 11], stopped: [11], capturedAt: t0)
      let running = project("/code/api", [20], capturedAt: t0)
      await settle(
        controller.run(
          tick(0, scan: 1, projects: [partly, running], optedIn: ["/code/web", "/code/api"])))
      #expect(fake.calls == ["project resume /code/web [10, 11]"])
    }

    @Test func theMigrationFlagSurvivesASaveAndDecodesTolerantly() throws {
      var record = AutoPauseWiring.Record()
      record.projectsMigrated = true
      let data = try JSONEncoder().encode(record)
      #expect(try JSONDecoder().decode(AutoPauseWiring.Record.self, from: data) == record)
      let old = try JSONDecoder().decode(
        AutoPauseWiring.Record.self, from: Data(#"{"pendingResumes": []}"#.utf8))
      #expect(!old.projectsMigrated)
    }
  }
}

/// The island's Resume now (N3): what Tamebar paused, by the identities it recorded, through the
/// same paths as an automatic resume, and counted as the user's resume.
extension AutoPauseWiringTests {
  @MainActor
  struct ResumeNow {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ entries: [(String, AutoPausePlanner.Reason, [DevProcessIdentity])])
      -> AutoPauseWiring.Record
    {
      var record = AutoPauseWiring.Record()
      record.projectsMigrated = true
      record.state.elevatedSince = t0
      record.state.lastPause = t0
      for (id, reason, identities) in entries {
        record.state.ledger.append(.init(threadID: id, reason: reason, since: t0))
        record.identities[id] = identities
      }
      return record
    }

    private func settle(_ outcome: AutoPauseWiring.Outcome) async {
      for task in outcome.tasks { await task.value }
    }

    @Test func aProjectResumesOnlyTheProcessesTamebarStopped() async {
      let fake = FakeSignals()
      let controller = fake.controller(
        record([("project:/code/web", .pressure, [identity(10, stopped: true)])]))
      // 11 is a session the user paused by hand in the same folder, 12 a running tool: the
      // project isn't "paused" as a whole, and neither may be touched.
      let web = project("/code/web", [10, 11, 12], stopped: [10, 11], capturedAt: t0)
      let outcome = controller.resumeNow(threads: [], projects: ["/code/web": web], now: t0)
      await settle(outcome)
      #expect(fake.calls == ["project resume /code/web [10]"])
      #expect(outcome.resumedProjects == ["/code/web": "web"])
      #expect(controller.pausedBy("project:/code/web") == nil)
      #expect(controller.record.state.userResumed == ["project:/code/web"])
    }

    @Test func entriesTheScanLostAreStillResumedByIdentity() async {
      let fake = FakeSignals()
      let controller = fake.controller(
        record([
          ("project:/code/gone", .meeting, [identity(40, stopped: true)]),
          ("x", .meeting, [identity(41, stopped: true)]),
        ]))
      let outcome = controller.resumeNow(threads: [], projects: [:], now: t0)
      await settle(outcome)
      #expect(fake.calls.sorted() == ["byIdentity x [41]", "project resume /code/gone [40]"])
      #expect(outcome.resumed == 2)
      #expect(controller.record.state.ledger.isEmpty)
      #expect(controller.record.pendingResumes.isEmpty)
    }

    /// The Stopped list's Resume on one row (Q15): only that entry, as the user's resume; the
    /// others stay paused and in the ledger.
    @Test func onlyResumesTheChosenEntry() async {
      let fake = FakeSignals()
      let controller = fake.controller(
        record([
          ("x", .meeting, [identity(41, stopped: true)]),
          ("y", .pressure, [identity(42, stopped: true)]),
        ]))
      let outcome = controller.resumeNow(threads: [], projects: [:], only: ["y"], now: t0)
      await settle(outcome)
      #expect(fake.calls == ["byIdentity y [42]"])
      #expect(outcome.taken == 1)
      #expect(controller.record.state.ledger.map(\.threadID) == ["x"])
      #expect(controller.record.state.userResumed == ["y"])
    }

    @Test func aListedThreadIsResumedEvenWhenNotWhollyStopped() async {
      let fake = FakeSignals()
      fake.scanned = [20: identity(20, stopped: true), 21: identity(21)]
      let controller = fake.controller(
        record([("r", .pressure, [identity(20, stopped: true)])]))
      let outcome = controller.resumeNow(
        threads: [thread("r", root: 20, children: [21], paused: false)], projects: [:], now: t0)
      await settle(outcome)
      #expect(fake.calls == ["begin resume r", "finish resume r [20, 21]"])
      #expect(controller.record.state.userResumed == ["r"])
    }

    @Test func theLedgerEmptiesTheIslandLeavesAutoPausedAndNothingIsPausedAgain() async {
      let fake = FakeSignals()
      fake.scanned = [20: identity(20, stopped: true)]
      let controller = fake.controller(
        record([
          ("r", .pressure, [identity(20, stopped: true)]),
          ("project:/code/web", .pressure, [identity(10, stopped: true)]),
        ]))
      func island() -> IslandState {
        IslandState.resolve(
          .init(
            now: t0, meeting: false, source: .none, ledger: controller.record.state.ledger,
            risk: .warning, freeBytes: 1, lastResume: nil, note: nil)
        ) { false }
      }
      #expect(island() == .autoPaused(2))
      await settle(
        controller.resumeNow(
          threads: [thread("r", root: 20, paused: true)], projects: [:], now: t0))
      #expect(controller.record.state.ledger.isEmpty)
      #expect(island() == .hidden, "warning alone shows nothing (N12)")
      // Still under pressure, both running again and unused: the user's resume holds.
      fake.calls = []
      let web = project("/code/web", [10], capturedAt: t0.addingTimeInterval(60))
      for second in 60..<80 {
        let outcome = controller.run(
          .init(
            now: t0.addingTimeInterval(TimeInterval(second)), scan: second,
            threads: [thread("r", root: 20)], unused: ["r": .idle(9_000)], protections: [:],
            scope: nil, stopped: [], risk: .warning, inMeeting: false, stopping: [],
            complete: true, projects: .init(targets: [web], optedIn: ["/code/web"]),
            stillIdle: { _ in true }))
        #expect(outcome.paused.isEmpty && outcome.pausedProjects.isEmpty)
      }
      #expect(fake.calls.isEmpty)
    }

    @Test func aResumeRefusedForASignalInFlightIsOwedAndRetried() async {
      let fake = FakeSignals()
      fake.inFlight = ["x"]
      let controller = fake.controller(record([("x", .meeting, [identity(41, stopped: true)])]))
      let outcome = controller.resumeNow(threads: [], projects: [:], now: t0)
      #expect(outcome.resumed == 0)
      #expect(outcome.taken == 1, "taken from the ledger, so the flash counts it")
      #expect(controller.record.state.ledger.isEmpty)
      #expect(controller.record.pendingResumes == ["x"])
      fake.inFlight = []
      await settle(
        controller.run(
          .init(
            now: t0.addingTimeInterval(1), scan: 1, threads: [], unused: [:], protections: [:],
            scope: nil, stopped: [], risk: .normal, inMeeting: false, stopping: [],
            complete: true, stillIdle: { _ in true })))
      #expect(fake.calls == ["byIdentity x [41]"])
      #expect(controller.record.pendingResumes.isEmpty)
    }

    @Test func aControllerThatDoesNotActResumesNothing() {
      let fake = FakeSignals()
      let controller = AutoPauseController(
        record: record([("x", .meeting, [identity(41, stopped: true)])]), acts: false, url: nil,
        signaller: fake.signaller, scans: { 0 })
      #expect(controller.resumeNow(threads: [], projects: [:], now: t0).resumed == 0)
      #expect(fake.calls.isEmpty)
    }
  }
}

// MARK: Heat (Q13)

extension AutoPauseWiringTests {
  @MainActor
  struct HeatController {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func idle(_ id: String, root: Int32, cpu: Double, status: AgentStatus = .idle)
      -> AIThread
    {
      var thread = AIThread(
        id: id, tool: .claudeCode, name: "Claude Code", directory: "/code/\(id)", terminal: nil,
        startedAt: nil, processIDs: [root], memoryBytes: 10, cpuPercent: cpu, isPaused: false,
        isDetached: false)
      thread.rootProcessID = root
      thread.agentStatus = status
      return thread
    }

    private func tick(
      _ second: Int, threads: [AIThread], thermal: ThermalStatus, meeting: Bool = false,
      protections: [String: UnusedPolicy.Protection] = [:], jobs: Set<String> = []
    ) -> AutoPauseWiring.Tick {
      .init(
        now: t0.addingTimeInterval(TimeInterval(second)), scan: second, threads: threads,
        unused: [:], protections: protections, scope: nil, stopped: [], risk: .normal,
        inMeeting: meeting, stopping: [], complete: true, thermal: thermal, jobs: jobs,
        stillIdle: { _ in true })
    }

    /// Thirty hot seconds pause the idle session using CPU, and only it: not the quiet one, the
    /// busy one, the kept one or the one with a background job. The note leaves heat out.
    @Test func heatPausesOnlyIdleSessionsStillUsingCPU() async {
      let fake = FakeSignals()
      fake.scanned = [10: identity(10), 20: identity(20), 30: identity(30), 40: identity(40)]
      let controller = fake.controller(.init())
      let threads = [
        idle("hot", root: 10, cpu: 12), idle("quiet", root: 20, cpu: 3),
        idle("busy", root: 30, cpu: 80, status: .busy), idle("kept", root: 40, cpu: 50),
        idle("job", root: 50, cpu: 50),
      ]
      var paused: [AutoPausePlanner.Reason] = []
      var heatPaused = 0
      // Through 30 s only: a later tick would see "hot" still running, which reads as the
      // user's resume.
      for second in 0...30 {
        let outcome = controller.run(
          tick(
            second, threads: threads, thermal: .serious, protections: ["kept": .kept],
            jobs: ["job"]))
        for task in outcome.tasks { await task.value }
        paused += outcome.paused
        heatPaused += await outcome.landedHeat()
        #expect(controller.heat == (second >= 30))
      }
      #expect(paused == [.heat])
      #expect(heatPaused == 1)
      #expect(controller.pausedBy("hot")?.reason == .heat)
      #expect(fake.calls.filter { $0.hasPrefix("begin pause") } == ["begin pause hot"])
      #expect(AutoPauseWiring.note(paused: [.heat]) == nil)
    }

    @Test func duringACallHeatTouchesNothing() async {
      let fake = FakeSignals()
      fake.scanned = [10: identity(10)]
      let controller = fake.controller(.init())
      for second in 0...60 {
        let outcome = controller.run(
          tick(second, threads: [idle("hot", root: 10, cpu: 40)], thermal: .critical, meeting: true)
        )
        #expect(outcome.paused.isEmpty)
      }
      #expect(fake.calls.isEmpty)
    }
  }
}

/// Records what the controller asks for; nothing is signalled.
@MainActor
private final class FakeSignals {
  var calls: [String] = []
  var inFlight: Set<String> = []
  var scanned: [Int32: DevProcessIdentity] = [:]
  /// What `stillStopped` answers, and the PIDs it was asked about.
  var stopped = 0
  var counted: [[Int32]] = []
  var byIdentityLeft = 0
  /// What a project signal's task answers: how many of its processes are still stopped, and
  /// how many it changed.
  var projectLeft = 0
  var projectChanged = 1
  /// What `finish` answers: whether it signalled anything.
  var finishSends = true
  /// The number of the latest scan started, as the model counts them.
  var scan = 0

  func controller(_ record: AutoPauseWiring.Record) -> AutoPauseController {
    AutoPauseController(
      record: record, acts: true, url: nil, signaller: signaller, scans: { [self] in scan })
  }

  var signaller: AutoPauseWiring.Signaller {
    .init(
      begin: { [self] thread, signal in
        guard !inFlight.contains(thread.id) else { return nil }
        calls.append("begin \(signal) \(thread.id)")
        return AIThreadStopRequest(
          thread: thread, expected: scanned.filter { thread.processIDs.contains($0.key) },
          force: false)
      },
      finish: { [self] thread, signal, request, announce in
        calls.append(
          "finish \(signal) \(thread.id) \(request.expected.keys.sorted())"
            + (announce ? " announced" : ""))
        return finishSends
      },
      resumeByIdentity: { [self] id, identities in
        guard !inFlight.contains(id) else { return nil }
        calls.append("byIdentity \(id) \(identities.map(\.process.processID).sorted())")
        let left = byIdentityLeft
        return Task { left }
      },
      stillStopped: { [self] identities in
        counted.append(identities.map(\.process.processID).sorted())
        return stopped
      },
      project: { [self] target, signal in
        guard !inFlight.contains(AutoPauseWiring.projectID(target.directory)) else { return nil }
        calls.append(
          "project \(signal) \(target.directory) \(target.identities.map(\.process.processID).sorted())"
        )
        let result = AutoPauseWiring.ProjectSignal(
          changed: projectChanged, stillStopped: projectLeft)
        return Task { result }
      },
      notice: { [self] tty, text in notices.append("\(tty) \(text)") })
  }

  /// What the controller wrote to a tty (the title restore of a session Q14 queued).
  var notices: [String] = []
}

// MARK: No work queue (Q19)

extension AutoPauseWiringTests {
  /// Q19 removed Q14's work queue: busy sessions are never paused for memory, and a session an
  /// older build queued is resumed at the first tick after launch, with its title restored.
  @MainActor
  struct NoQueue {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A busy Claude session under agentrun: zsh (ttys018) → agentrun → agent (ttys0<root>).
    private func busy(_ id: String, root: Int32, started: TimeInterval, paused: Bool = false)
      -> AIThread
    {
      AIThread(
        id: id, tool: .claudeCode, name: "Claude Code", directory: "/code/\(id)", terminal: nil,
        startedAt: t0.addingTimeInterval(started), processIDs: [root], memoryBytes: 10,
        cpuPercent: 0, isPaused: paused, isDetached: false, rootProcessID: root,
        agentStatus: .busy)
    }

    private func record(_ pid: Int32, _ parent: Int32, _ arguments: String, tty: String?)
      -> RawProcessRecord
    {
      .init(
        processID: pid, parentProcessID: parent, userID: Int(getuid()), cpuPercent: 0,
        residentKilobytes: 1, elapsed: "1:00", terminal: tty, arguments: arguments)
    }

    /// zsh (ttys018) → agentrun → the agents 10 and 20, each on its own pty.
    private var records: [Int32: RawProcessRecord] {
      [
        5: record(5, 1, "-/bin/zsh", tty: "ttys018"),
        6: record(6, 5, "agentrun run claude", tty: "ttys018"),
        10: record(10, 6, "claude", tty: "ttys010"),
        20: record(20, 6, "claude", tty: "ttys020"),
      ]
    }

    private func tick(
      _ second: TimeInterval, scan: Int, threads: [AIThread], stopped: Set<Int32> = [],
      risk: MemoryRisk, meeting: Bool = false
    ) -> AutoPauseWiring.Tick {
      .init(
        now: t0.addingTimeInterval(second), scan: scan, threads: threads, unused: [:],
        protections: [:], scope: nil, stopped: stopped, risk: risk, inMeeting: meeting,
        stopping: [], complete: true, records: records, stillIdle: { _ in true })
    }

    private func settle(_ outcome: AutoPauseWiring.Outcome) async {
      for task in outcome.tasks { await task.value }
    }

    @Test func busySessionsUnderPressureAreNeverPaused() async {
      let fake = FakeSignals()
      fake.scanned = [10: identity(10), 20: identity(20)]
      let controller = fake.controller(.init())
      let running = [busy("old", root: 10, started: 0), busy("new", root: 20, started: 5)]
      for second in 0...600 {
        let risk: MemoryRisk = second.isMultiple(of: 3) ? .critical : .warning
        await settle(
          controller.run(tick(TimeInterval(second), scan: second, threads: running, risk: risk)))
      }
      #expect(fake.calls.isEmpty)
      #expect(fake.notices.isEmpty)
      #expect(controller.record.state.ledger.isEmpty)
    }

    /// The installed 294c339 queued a running session and never resumed it: the first tick of
    /// this build resumes it, under pressure and during a call alike, and restores its title.
    @Test(arguments: [false, true])
    func aSessionAnOlderBuildQueuedResumesAtTheFirstTick(meeting: Bool) async {
      var record = AutoPauseWiring.Record()
      record.state.ledger = [.init(threadID: "new", reason: .queue, since: t0)]
      record.state.elevatedSince = t0
      record.identities = ["new": [identity(20, stopped: true)]]
      record.notices = ["new": "ttys018"]
      let fake = FakeSignals()
      fake.scanned = [10: identity(10), 20: identity(20, stopped: true)]
      let controller = fake.controller(record)
      let threads = [
        busy("old", root: 10, started: 0), busy("new", root: 20, started: 5, paused: true),
      ]
      let outcome = controller.run(
        tick(3_600, scan: 1, threads: threads, stopped: [20], risk: .warning, meeting: meeting))
      await settle(outcome)
      #expect(outcome.resumed == 1)
      #expect(fake.calls.contains("begin resume new"))
      #expect(!fake.calls.contains { $0.contains("pause") })
      #expect(controller.pausedBy("new") == nil)
      #expect(fake.notices == ["ttys018 \u{1B}]2;\u{07}\u{1B}[23;0t"])
      #expect(controller.record.notices.isEmpty)
    }

    /// Resumed outside Tamebar (`kill -CONT`, `fg`) before the first tick: seen running, it
    /// leaves the ledger, and its title comes back as after Tamebar's own resume.
    @Test func resumedByHandGetsItsTitleBackToo() async {
      var record = AutoPauseWiring.Record()
      record.state.ledger = [.init(threadID: "new", reason: .queue, since: t0)]
      record.state.elevatedSince = t0
      record.identities = ["new": [identity(20, stopped: true)]]
      record.notices = ["new": "ttys018"]
      let fake = FakeSignals()
      fake.scanned = [10: identity(10), 20: identity(20)]
      let controller = fake.controller(record)
      let running = [busy("old", root: 10, started: 0), busy("new", root: 20, started: 5)]
      await settle(controller.run(tick(10, scan: 1, threads: running, risk: .warning)))
      #expect(controller.pausedBy("new") == nil)
      #expect(fake.calls.isEmpty)
      #expect(fake.notices == ["ttys018 \u{1B}]2;\u{07}\u{1B}[23;0t"])
      #expect(controller.record.notices["new"] == nil)
    }
  }
}
