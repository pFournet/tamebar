import Darwin
import Foundation
import Testing

@testable import Tamebar

/// Q19: new sessions wait at start while the Mac is struggling (`tamebar wait`, a `SessionStart`
/// hook), start on their own once it eases, one a minute, oldest first, or at once with Start now
/// (the card) and `tamebar start`.
struct StartWaitTests {
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("TamebarTests-Wait-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func registration(
    _ pid: Int32, project: String = "app", tool: String? = "claude", at second: TimeInterval = 0
  ) -> StartWait.Registration {
    .init(
      waitPID: pid, waitStart: Double(pid), agentPID: pid + 1000, tool: tool,
      directory: "/code/\(project)", project: project, sessionID: "s-\(pid)",
      started: t0.addingTimeInterval(second))
  }

  func strain(_ struggling: Bool) -> StrainFile {
    StrainFile(pid: 42, struggling: struggling, signals: [], updated: t0)
  }

  // MARK: The hook's input

  @Test func readsClaudeAndCodexSessionStart() throws {
    let claude = try #require(
      StartWait.HookInput.parse(
        Data(
          #"{"session_id":"abc","transcript_path":"/Users/me/.claude/projects/x/abc.jsonl","cwd":"/code/dashboard-app","hook_event_name":"SessionStart","source":"startup","model":"claude"}"#
            .utf8)))
    #expect(claude.source == "startup" && claude.isFreshStart)
    #expect(claude.cwd == "/code/dashboard-app" && claude.sessionID == "abc")
    #expect(StartWait.tool(agent: nil, transcriptPath: claude.transcriptPath) == "claude")
    let codex = try #require(
      StartWait.HookInput.parse(
        Data(
          #"{"session_id":"019","transcript_path":"/Users/me/.codex/sessions/2026/10/30/r.jsonl","cwd":"/code/web","hook_event_name":"SessionStart","model":"gpt","permission_mode":"default","source":"resume"}"#
            .utf8)))
    #expect(!codex.isFreshStart)
    #expect(StartWait.tool(agent: nil, transcriptPath: codex.transcriptPath) == "codex")
    #expect(StartWait.tool(agent: "codex", transcriptPath: claude.transcriptPath) == "codex")
    #expect(StartWait.HookInput.parse(nil) == nil)
    #expect(StartWait.HookInput.parse(Data("not json".utf8)) == nil)
  }

  @Test func onlyAFreshStartWaitsAndOnlyWhileTheRunningTamebarSaysStruggling() {
    func input(_ source: String?) -> StartWait.HookInput { .init(source: source) }
    for source in ["resume", "clear", "compact", "fork"] {
      #expect(
        StartWait.decide(input: input(source), strain: strain(true), writerRuns: true)
          == .notNew, "\(source)")
    }
    #expect(
      StartWait.decide(input: input("startup"), strain: strain(true), writerRuns: true) == .wait)
    #expect(StartWait.decide(input: nil, strain: strain(true), writerRuns: true) == .wait)
    #expect(StartWait.decide(input: input(nil), strain: strain(true), writerRuns: true) == .wait)
    #expect(
      StartWait.decide(input: input("startup"), strain: strain(false), writerRuns: true)
        == .notStruggling)
    #expect(
      StartWait.decide(input: input("startup"), strain: strain(true), writerRuns: false)
        == .noTamebar)
    #expect(
      StartWait.decide(input: input("startup"), strain: nil, writerRuns: false) == .noTamebar)
  }

  // MARK: Files

  @Test func registersReleasesAndPrunesTheDead() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    try StartWait.register(registration(12, project: "b", at: 5), directory: root)
    try StartWait.register(registration(11, project: "a", at: 0), directory: root)
    try StartWait.register(registration(13, project: "c", at: 9), directory: root)
    #expect(StartWait.list(root).map(\.project) == ["a", "b", "c"], "oldest first")
    let mode =
      try FileManager.default.attributesOfItem(
        atPath: StartWait.folder(root).path)[.posixPermissions] as? Int
    #expect(mode == 0o700)

    #expect(StartWait.release(12, by: "start_now", at: t0, directory: root))
    #expect(StartWait.isReleased(12, directory: root))
    #expect(!StartWait.isReleased(11, directory: root))
    // 13's process is gone, and 11's pid now belongs to another process.
    let live = StartWait.prune(root) { pid in pid == 12 ? 12 : pid == 11 ? 99 : nil }
    #expect(live.map(\.waitPID) == [12])
    #expect(StartWait.list(root).map(\.waitPID) == [12])
    StartWait.remove(12, directory: root)
    #expect(StartWait.list(root).isEmpty)
    #expect(!StartWait.isReleased(12, directory: root))
  }

  // MARK: Release order

  @Test func oncetheStrainClearsOnePerMinuteOldestFirst() {
    let waiting = [registration(1, at: 0), registration(2, at: 3), registration(3, at: 7)]
    #expect(
      StartWait.due(waiting, released: [], struggling: true, last: nil, now: t0) == nil,
      "nothing while struggling")
    let now = t0.addingTimeInterval(100)
    #expect(
      StartWait.due(waiting, released: [], struggling: false, last: nil, now: now)?.waitPID == 1)
    #expect(
      StartWait.due(waiting, released: [1], struggling: false, last: now, now: now + 30) == nil,
      "the next waits a minute")
    #expect(
      StartWait.due(waiting, released: [1], struggling: false, last: now, now: now + 60)?.waitPID
        == 2)
    #expect(
      StartWait.due(waiting, released: [1, 2], struggling: true, last: now + 60, now: now + 200)
        == nil, "the strain came back: the rest keep waiting")
    #expect(
      StartWait.due(waiting, released: [1, 2], struggling: false, last: now + 60, now: now + 300)?
        .waitPID == 3)
  }

  @Test func startMatchesAProjectInAnyCaseOrAll() {
    let waiting = [
      registration(1, project: "dashboard-app"), registration(2, project: "web"),
      registration(3, project: "Dashboard-App", tool: "codex"),
    ]
    #expect(StartWait.matching("dashboard-app", in: waiting).map(\.waitPID) == [1, 3])
    #expect(StartWait.matching("all", in: waiting).count == 3)
    #expect(StartWait.matching("nope", in: waiting).isEmpty)
    #expect(waiting[0].label == "dashboard-app · Claude")
    #expect(waiting[2].label == "Dashboard-App · Codex")
    #expect(registration(4, tool: nil).toolName == "Agent")
  }

  @Test func waitedReadsSecondsThenMinutesThenHours() {
    #expect(StartWait.waited(40) == "40s")
    #expect(StartWait.waited(61) == "1m")
    #expect(StartWait.waited(12 * 60 + 5) == "12m")
    #expect(StartWait.waited(65 * 60) == "1h 5m")
    #expect(StartWait.waited(120 * 60) == "2h")
    #expect(StartWait.project("/code/dashboard-app") == "dashboard-app")
    #expect(StartWait.project(nil) == "session")
  }

  // MARK: The wait

  @Test func blocksUntilItsReleaseFileAppears() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let waiting = StartWait.folder(root)
    try FileManager.default.createDirectory(at: waiting, withIntermediateDirectories: true)
    let release = StartWait.releaseURL(root, 777)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
      _ = StartWait.release(777, by: "tamebar_start", at: .now, directory: root)
    }
    let started = Date()
    let outcome = StartWaitLive.block(
      folder: waiting, release: release, watch: [getpid()], timeout: 10, signals: false)
    #expect(outcome == .released)
    #expect(Date().timeIntervalSince(started) < 3)
  }

  @Test func givesUpAfterItsTimeoutOrWhenAWatchedProcessExits() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let waiting = StartWait.folder(root)
    try FileManager.default.createDirectory(at: waiting, withIntermediateDirectories: true)
    let release = StartWait.releaseURL(root, 778)
    #expect(
      StartWaitLive.block(
        folder: waiting, release: release, watch: [], timeout: 0.3, signals: false) == .timedOut)
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["0.3"]
    try sleeper.run()
    let pid = sleeper.processIdentifier
    let outcome = StartWaitLive.block(
      folder: waiting, release: release, watch: [pid], timeout: 10, signals: false)
    sleeper.waitUntilExit()
    #expect(outcome == .exited(pid))
  }

  // MARK: Tamebar's side

  @MainActor
  @Test func theGateWritesTheStrainAndReleasesOnePerMinuteOnceItClears() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = StartGate(directory: root, now: t0)
    gate.startTime = { pid in (11...13).contains(pid) ? Double(pid) : nil }
    #expect(StrainFile.read(root)?.struggling == false)
    #expect(StrainFile.read(root)?.pid == getpid())
    func reading(_ second: TimeInterval) -> StrainReading {
      .init(
        date: t0.addingTimeInterval(second), swapIns: 0, pressure: .warning, fanPercent: nil,
        thermal: .nominal)
    }
    gate.observe(reading(2), forced: true)
    #expect(StrainFile.read(root)?.struggling == true)
    for (pid, second) in [(Int32(12), 3.0), (11, 1), (13, 5)] {
      try StartWait.register(registration(pid, at: second), directory: root)
    }
    #expect(gate.observe(reading(4), forced: true).isEmpty)
    #expect(gate.waiting.map(\.waitPID) == [11, 12, 13])

    #expect(gate.startNow(12, now: t0.addingTimeInterval(5)))
    #expect(StartWait.isReleased(12, directory: root))
    #expect(gate.waiting.map(\.waitPID) == [11, 13])

    #expect(gate.observe(reading(6), forced: false).map(\.waitPID) == [11])
    #expect(StrainFile.read(root)?.struggling == false)
    #expect(gate.observe(reading(30), forced: false).isEmpty, "a minute apart")
    #expect(gate.observe(reading(66), forced: false).map(\.waitPID) == [13])
    #expect(gate.waiting.isEmpty)
  }

  @MainActor
  @Test func whenTheStrainReturnsTheRestKeepWaiting() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = StartGate(directory: root, now: t0)
    gate.startTime = { pid in (11...12).contains(pid) ? Double(pid) : nil }
    func reading(_ second: TimeInterval) -> StrainReading {
      .init(
        date: t0.addingTimeInterval(second), swapIns: 0, pressure: .warning, fanPercent: nil,
        thermal: .nominal)
    }
    try StartWait.register(registration(11, at: 0), directory: root)
    try StartWait.register(registration(12, at: 1), directory: root)
    gate.observe(reading(2), forced: true)
    #expect(gate.observe(reading(4), forced: false).map(\.waitPID) == [11])
    gate.observe(reading(10), forced: true)
    #expect(gate.observe(reading(70), forced: true).isEmpty)
    #expect(gate.waiting.map(\.waitPID) == [12])
    #expect(gate.observe(reading(72), forced: false).map(\.waitPID) == [12])
  }
}
