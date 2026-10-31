import Foundation
import Testing

@testable import Tamebar

struct AgentStatusProbeTests {
  let seen = Date(timeIntervalSince1970: 1_790_100_000)

  func thread(_ tool: AITool, status: AgentStatus?, since: Date?) -> AIThread {
    var thread = AIThread(
      id: "\(tool.rawValue)-42", tool: tool, name: tool.title, directory: "/code/x",
      terminal: nil, startedAt: nil, processIDs: [42, 43], memoryBytes: 1, cpuPercent: 0,
      isPaused: false, isDetached: true)
    thread.rootProcessID = 42
    thread.agentStatus = status
    thread.agentStatusSince = since
    return thread
  }

  /// A temp home with `.claude/sessions/42.json`, as the Task 3.1 tests write it.
  func claudeHome(_ fields: [String: Any]) throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sessions = home.appendingPathComponent(".claude/sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    var metadata: [String: Any] = [
      "pid": 42, "sessionId": "6f1c2a52-6d1e-4c5e-9a4f-1f2e3d4c5b6a", "startedAt": 200_000.0,
      "status": "idle", "statusUpdatedAt": seen.timeIntervalSince1970 * 1_000,
    ]
    metadata.merge(fields) { _, new in new }
    try JSONSerialization.data(withJSONObject: metadata).write(
      to: sessions.appendingPathComponent("42.json"))
    return home
  }

  func probe(_ thread: AIThread, home: URL, startTime: TimeInterval? = 200) -> Bool {
    AgentStatusProbe.stillIdle(.init(thread: thread, home: home, startTime: startTime))
  }

  @Test func anUnchangedSessionFileIsStillIdle() throws {
    let home = try claudeHome([:])
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(probe(thread(.claudeCode, status: .idle, since: seen), home: home))
  }

  @Test func aNewStatusWriteIsActive() throws {
    let home = try claudeHome(["statusUpdatedAt": (seen.timeIntervalSince1970 + 30) * 1_000])
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(!probe(thread(.claudeCode, status: .idle, since: seen), home: home))
  }

  @Test func aBusyStatusIsActive() throws {
    let home = try claudeHome(["status": "busy"])
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(!probe(thread(.claudeCode, status: .idle, since: seen), home: home))
  }

  func rollout(written: Date) throws -> String {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "rollout-\(UUID().uuidString).jsonl")
    try Data("{}\n".utf8).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: file.path)
    return file.path
  }

  func modified(_ path: String) throws -> Date? {
    try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
  }

  @Test func aMovedCodexRolloutIsActive() throws {
    let path = try rollout(written: seen)
    defer { try? FileManager.default.removeItem(atPath: path) }
    var codex = thread(.codexCLI, status: .idle, since: try modified(path))
    codex.rolloutPaths = [path]
    let home = FileManager.default.temporaryDirectory
    #expect(probe(codex, home: home))
    try FileManager.default.setAttributes(
      [.modificationDate: seen.addingTimeInterval(5)], ofItemAtPath: path)
    #expect(!probe(codex, home: home))
  }

  /// Subagents: the newest of all open rollouts is the status time, and any write is activity.
  @Test func everyOpenRolloutIsChecked() throws {
    let older = try rollout(written: seen.addingTimeInterval(-600))
    let newest = try rollout(written: seen)
    defer {
      try? FileManager.default.removeItem(atPath: older)
      try? FileManager.default.removeItem(atPath: newest)
    }
    var codex = thread(.codexCLI, status: .idle, since: try modified(newest))
    codex.rolloutPaths = [older, newest]
    let home = FileManager.default.temporaryDirectory
    #expect(probe(codex, home: home))
    try FileManager.default.setAttributes(
      [.modificationDate: seen.addingTimeInterval(5)], ofItemAtPath: older)
    #expect(!probe(codex, home: home))
    var gone = codex
    gone.rolloutPaths = [newest, older + ".missing"]
    #expect(!probe(gone, home: home))
  }

  @Test func anAgentWithoutASignalStaysIdle() {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    #expect(probe(thread(.claudeCode, status: nil, since: nil), home: home))
    #expect(probe(thread(.otherAgent, status: nil, since: nil), home: home))
    #expect(probe(thread(.codexCLI, status: nil, since: nil), home: home))
  }

  @Test func aKnownStatusWithoutATimeIsNeverEnded() {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    #expect(!probe(thread(.claudeCode, status: .idle, since: nil), home: home))
  }

  /// The pid now belongs to another Claude, so its file says nothing about this thread.
  @Test func aReusedPIDIsNotIdle() throws {
    let home = try claudeHome([:])
    defer { try? FileManager.default.removeItem(at: home) }
    let idle = thread(.claudeCode, status: .idle, since: seen)
    #expect(!probe(idle, home: home, startTime: 9_999))
    #expect(!probe(idle, home: home, startTime: nil))
    let procStart = try claudeHome(["procStart": "Sat Oct  3 13:26:57 2026"])
    defer { try? FileManager.default.removeItem(at: procStart) }
    #expect(probe(idle, home: procStart, startTime: 1_791_034_017))
    #expect(!probe(idle, home: procStart, startTime: 200))
    let otherPID = try claudeHome(["pid": 77])
    defer { try? FileManager.default.removeItem(at: otherPID) }
    #expect(!probe(idle, home: otherPID))
  }

  @Test func aCodexThreadWithNoRolloutIsNeverEnded() {
    let codex = thread(.codexCLI, status: .idle, since: seen)
    #expect(codex.rolloutPaths.isEmpty)
    #expect(!probe(codex, home: FileManager.default.temporaryDirectory))
  }
}

struct EndPlanTests {
  func thread(_ id: String, status: AgentStatus? = .idle, root: Int32 = 1) -> AIThread {
    var thread = AIThread(
      id: id, tool: .claudeCode, name: "Claude Code", directory: "/code/\(id)", terminal: nil,
      startedAt: nil, processIDs: [root], memoryBytes: 10, cpuPercent: 0, isPaused: false,
      isDetached: false)
    thread.rootProcessID = root
    thread.agentStatus = status
    thread.agentStatusSince = status == nil ? nil : Date(timeIntervalSince1970: 1_000)
    thread.sessionID = UUID().uuidString.lowercased()
    return thread
  }

  @Test func endsOnlyFreshUnusedUnprotectedStillIdleThreads() {
    let ids = ["ok", "gone", "used", "kept", "wrote", "detached", "quitting"]
    let targets = ids.map { thread($0) }
    var fresh = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
    fresh["gone"] = nil
    fresh["detached"] = thread("detached", status: nil)
    let unused: [String: UnusedPolicy.Reason] = [
      "ok": .idle(8 * 86_400), "kept": .idle(8 * 86_400), "wrote": .idle(8 * 86_400),
      "detached": .detached, "quitting": .idle(8 * 86_400),
    ]
    var probed: [String] = []
    let plan = EndPlan.decide(
      targets: targets + [targets[0]], fresh: fresh, unused: unused,
      protections: ["kept": .kept, "used": .busy], stopping: ["quitting"]
    ) { thread in
      probed.append(thread.id)
      return thread.id != "wrote"
    }
    #expect(plan.end.map(\.id) == ["ok", "detached"])
    // The fresh thread is ended, not the stale target: its status is the one just scanned.
    #expect(plan.end.last?.agentStatus == nil)
    #expect(plan.becameActive == 3)
    #expect(plan.gone == 1)
    #expect(plan.inFlight == 1)
    #expect(probed == ["ok", "wrote", "detached"])
  }

  /// `endUnused`'s decision after its fresh scan: every input of the context is used.
  @Test func planUsesTheFreshScanAndProbesWithTheRootStartTime() {
    let home = URL(fileURLWithPath: "/tmp/agent-home")
    let stale = ["ok", "kept", "quitting", "gone", "used"].map { thread($0, root: 70) }
    var fresh = Dictionary(uniqueKeysWithValues: stale.map { ($0.id, $0) })
    fresh["gone"] = nil
    var renamed = thread("ok", root: 70)
    renamed.sessionName = "fresh"
    fresh["ok"] = renamed
    let identity = DevProcessIdentity(
      process: .init(
        processID: 70, owner: 501, startSeconds: 200, startMicroseconds: 500_000, state: 0),
      executable: "/usr/local/bin/claude")
    let context = EndPlan.Context(
      threads: fresh,
      unused: ["ok": .idle(8 * 86_400), "kept": .idle(8 * 86_400), "quitting": .detached],
      protections: ["kept": .kept], identities: [70: identity], stopping: ["quitting"],
      home: home)
    var inputs: [AgentStatusProbe.Input] = []
    let plan = EndPlan.plan(stale, context) { input in
      inputs.append(input)
      return true
    }
    #expect(plan.end.map(\.sessionName) == ["fresh"])
    #expect(plan.becameActive == 2)
    #expect(plan.gone == 1)
    #expect(plan.inFlight == 1)
    #expect(inputs.map(\.thread.id) == ["ok"])
    #expect(inputs.first?.thread.sessionName == "fresh")
    #expect(inputs.first?.home == home)
    #expect(inputs.first?.startTime == 200.5)
    let refused = EndPlan.plan(stale, context) { _ in false }
    #expect(refused.end.isEmpty)
    #expect(refused.becameActive == 3)
    let noIdentity = EndPlan.Context(
      threads: fresh, unused: context.unused, protections: [:], identities: [:], stopping: [],
      home: home)
    var startTimes: [TimeInterval?] = []
    _ = EndPlan.plan(stale, noIdentity) { input in
      startTimes.append(input.startTime)
      return true
    }
    #expect(startTimes == [nil, nil, nil])
  }

  @Test func onlyConfirmedQuitsAreLogged() {
    let now = Date(timeIntervalSince1970: 5_000)
    let quit = thread("a")
    let survived = thread("b")
    var noID = thread("c")
    noID.sessionID = nil
    var log = EndedSessionLog()
    let confirmed = EndPlan.log(
      [
        .init(thread: quit, quit: true), .init(thread: survived, quit: false),
        .init(thread: noID, quit: true),
      ], into: &log, now: now)
    #expect(confirmed == 2)
    #expect(log.sessions.map(\.id) == [quit.sessionID])
  }

  @Test func onlyAQuitOutcomeIsConfirmed() {
    let ended = thread("a")
    #expect(EndPlan.Outcome(thread: ended, outcome: "quit").quit)
    #expect(!EndPlan.Outcome(thread: ended, outcome: "still-running").quit)
    #expect(!EndPlan.Outcome(thread: ended, outcome: nil).quit)
  }

  @Test func aSessionThatAlreadyExitedCountsAsGoneNotStillRunning() {
    let outcomes: [EndPlan.Outcome] = [
      .init(thread: thread("quit"), outcome: "quit"),
      .init(thread: thread("survived"), outcome: "still-running"),
      .init(thread: thread("exited"), outcome: nil),
    ]
    #expect(outcomes.map(\.exited) == [false, false, true])
    let result = EndPlan.result(
      .init(becameActive: 1, gone: 1, inFlight: 1), requested: 3, inFlight: 2,
      outcomes: outcomes)
    #expect(
      result
        == .init(
          requested: 3, confirmed: 1, stillRunning: 1, becameActive: 1, gone: 2, inFlight: 2))
  }

  @Test func theLogKeepsIdleSinceOnlyForIdleSessions() {
    let now = Date(timeIntervalSince1970: 5_000)
    var idle = thread("a")
    idle.sessionName = "notes"
    let entry = EndPlan.entry(idle, now: now)
    #expect(entry?.id == idle.sessionID)
    #expect(entry?.directory == "/code/a")
    #expect(entry?.name == "notes")
    #expect(entry?.idleSince == Date(timeIntervalSince1970: 1_000))
    #expect(entry?.endedAt == now)
    #expect(entry?.memoryBytes == 10)
    #expect(EndPlan.entry(thread("b", status: nil), now: now)?.idleSince == nil)
    var noID = thread("c")
    noID.sessionID = nil
    #expect(EndPlan.entry(noID, now: now) == nil)
    let noDirectory = AIThread(
      id: "d", tool: .claudeCode, name: "x", directory: nil, terminal: nil, startedAt: nil,
      processIDs: [1], memoryBytes: 1, cpuPercent: 0, isPaused: false, isDetached: true)
    #expect(EndPlan.entry(noDirectory, now: now) == nil)
    // A folder the panel hides (/tmp) still resumes, from the agent's own session file.
    var hidden = noDirectory
    hidden.sessionID = "e"
    #expect(EndPlan.entry(hidden, now: now) == nil)
    hidden.sessionDirectory = "/tmp"
    #expect(EndPlan.entry(hidden, now: now)?.directory == "/tmp")
    // Claude resumes a session only from the folder it was started in, which is its session
    // file's cwd; the scanned directory can be a subfolder the agent cd'd into, or node_repl's.
    var both = thread("f")
    both.sessionDirectory = "/elsewhere"
    #expect(EndPlan.entry(both, now: now)?.directory == "/elsewhere")
    // Codex has no session-file folder: the scanned one.
    var codex = AIThread(
      id: "g", tool: .codexCLI, name: "Codex", directory: "/code/g", terminal: nil,
      startedAt: nil, processIDs: [1], memoryBytes: 1, cpuPercent: 0, isPaused: false,
      isDetached: false)
    codex.sessionID = "00000000-0000-4000-8000-000000000007"
    codex.sessionDirectory = "/elsewhere"
    #expect(EndPlan.entry(codex, now: now)?.directory == "/code/g")
  }
}
