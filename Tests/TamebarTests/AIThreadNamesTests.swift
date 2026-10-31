import Foundation
import SQLite3
import Testing

@testable import Tamebar

struct AIThreadNamesTests {
  @Test func exactSessionIDsOnly() {
    let id = UUID().uuidString.lowercased()
    #expect(
      AIThreadNames.sessionID(.init(tool: .codexCLI, arguments: ["codex", "resume", id])) == id)
    #expect(
      AIThreadNames.sessionID(
        .init(tool: .claudeCode, arguments: ["claude", "--session-id=\(id)"]))
        == id)
    #expect(
      AIThreadNames.sessionID(
        .init(tool: .cursorAgent, arguments: ["cursor-agent", "--resume", id]))
        == id)
    #expect(
      AIThreadNames.sessionID(
        .init(tool: .codexCLI, arguments: ["codex", "exec", "discuss \(id)"])) == nil)
    #expect(
      AIThreadNames.sessionID(
        .init(tool: .claudeCode, arguments: ["claude", "--resume", "latest"])) == nil)
  }

  @Test func nativeArgumentsKeepPromptsSeparateAndExcludeEnvironment() {
    var count: Int32 = 3
    var data = Data(bytes: &count, count: MemoryLayout<Int32>.size)
    data.append(
      Data(
        "/bin/codex\0\0codex\0exec\0resume 01234567-0123-0123-0123-012345678901\0SECRET=hidden\0"
          .utf8))
    let arguments = AIThreadNames.arguments(data)
    #expect(arguments.count == 3)
    #expect(!arguments.joined().contains("SECRET"))
    #expect(AIThreadNames.sessionID(.init(tool: .codexCLI, arguments: arguments)) == nil)
    #expect(AIThreadNames.arguments(Data([0, 1])) == [])
  }

  @Test func codexIndexKeepsLatestNameAndToleratesIncompleteRows() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let rows = """
      partial row
      {"id":"test","thread_name":"Old name"}
      {"id":"test","thread_name":"Fix app navigation"}
      {"id":"empty","thread_name":"   "}
      {"id":
      """
    try Data(rows.utf8).write(to: file)
    #expect(AIThreadNames.codexIndex(file) == ["test": "Fix app navigation"])
  }

  @Test func staleClaudePIDCannotNameNewProcess() {
    #expect(
      AIThreadNames.registryMatches(
        .init(
          metadata: ["procStart": "Sat Oct  3 13:26:57 2026"], startedAt: 1_791_034_017)))
    #expect(
      !AIThreadNames.registryMatches(.init(metadata: ["startedAt": 100_000.0], startedAt: 200)))
    #expect(
      AIThreadNames.registryMatches(.init(metadata: ["startedAt": 200_500.0], startedAt: 200)))
    #expect(!AIThreadNames.registryMatches(.init(metadata: [:], startedAt: 200)))
  }

  @Test func claudeSessionNameRequiresCurrentPIDIdentity() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let sessions = home.appendingPathComponent(".claude/sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let id = UUID().uuidString.lowercased()
    let metadata: [String: Any] = [
      "pid": 42, "sessionId": id, "startedAt": 200_000.0, "name": "Fix recording controls",
      "status": "idle", "statusUpdatedAt": 1_790_100_000_000.0,
    ]
    try JSONSerialization.data(withJSONObject: metadata).write(
      to: sessions.appendingPathComponent("42.json"))
    let record = RawProcessRecord(
      processID: 42, parentProcessID: 1, userID: 501, cpuPercent: 0, residentKilobytes: 1,
      elapsed: "01:00", terminal: nil, arguments: "claude")
    var thread = AIThread(
      id: "claude", tool: .claudeCode, name: "Claude Code", directory: "/project", terminal: nil,
      startedAt: nil, processIDs: [42], memoryBytes: 1, cpuPercent: 0, isPaused: false,
      isDetached: false)
    thread.rootProcessID = 42
    let result = AIThreadNames.enrich(
      .init(threads: [thread], records: [record], startTimes: [42: 200], home: home))
    #expect(result.first?.sessionTitle == "Fix recording controls")
    #expect(result.first?.sessionID == id)
    let reused = AIThreadNames.enrich(
      .init(threads: [thread], records: [record], startTimes: [42: 400], home: home))
    #expect(reused.first?.sessionTitle == nil)
    #expect(reused.first?.agentStatus == nil)
    #expect(reused.first?.agentStatusSince == nil)
  }

  /// Claude's own `cwd` is kept, so a session in a folder the panel doesn't show (/tmp) can still
  /// be resumed from Ended sessions. Only an absolute path counts.
  @Test func claudeSessionKeepsItsOwnWorkingDirectory() throws {
    func enriched(_ cwd: Any?) throws -> AIThread? {
      let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: home) }
      let sessions = home.appendingPathComponent(".claude/sessions")
      try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
      var metadata: [String: Any] = [
        "pid": 42, "sessionId": UUID().uuidString, "startedAt": 200_000.0, "status": "idle",
      ]
      metadata["cwd"] = cwd
      try JSONSerialization.data(withJSONObject: metadata).write(
        to: sessions.appendingPathComponent("42.json"))
      let record = RawProcessRecord(
        processID: 42, parentProcessID: 1, userID: 501, cpuPercent: 0, residentKilobytes: 1,
        elapsed: "01:00", terminal: nil, arguments: "claude")
      var thread = AIThread(
        id: "claude", tool: .claudeCode, name: "Claude Code", directory: nil, terminal: nil,
        startedAt: nil, processIDs: [42], memoryBytes: 1, cpuPercent: 0, isPaused: false,
        isDetached: false)
      thread.rootProcessID = 42
      return AIThreadNames.enrich(
        .init(threads: [thread], records: [record], startTimes: [42: 200], home: home)
      ).first
    }
    #expect(try enriched("/tmp")?.sessionDirectory == "/tmp")
    #expect(try enriched("relative/path")?.sessionDirectory == nil)
    #expect(try enriched(42)?.sessionDirectory == nil)
    #expect(try enriched(nil)?.sessionDirectory == nil)
  }

  private func claudeThread(status: String, updatedAt: Any) throws -> AIThread? {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let sessions = home.appendingPathComponent(".claude/sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let metadata: [String: Any] = [
      "pid": 42, "sessionId": "6f1c2a52-6d1e-4c5e-9a4f-1f2e3d4c5b6a", "startedAt": 200_000.0,
      "name": "notes-cleanup", "status": status, "statusUpdatedAt": updatedAt,
    ]
    try JSONSerialization.data(withJSONObject: metadata).write(
      to: sessions.appendingPathComponent("42.json"))
    let record = RawProcessRecord(
      processID: 42, parentProcessID: 1, userID: 501, cpuPercent: 0, residentKilobytes: 1,
      elapsed: "01:00", terminal: nil, arguments: "claude")
    var thread = AIThread(
      id: "claude", tool: .claudeCode, name: "Claude Code", directory: "/project", terminal: nil,
      startedAt: nil, processIDs: [42], memoryBytes: 1, cpuPercent: 0, isPaused: false,
      isDetached: false)
    thread.rootProcessID = 42
    return AIThreadNames.enrich(
      .init(threads: [thread], records: [record], startTimes: [42: 200], home: home)
    ).first
  }

  @Test func claudeStatusAndSinceComeFromTheSessionFile() throws {
    let updated = Date(timeIntervalSince1970: 1_790_100_000)
    let thread = try claudeThread(status: "idle", updatedAt: updated.timeIntervalSince1970 * 1_000)
    #expect(thread?.agentStatus == .idle)
    #expect(thread?.agentStatusSince == updated)
    #expect(thread?.sessionName == "notes-cleanup")
    let busy = try claudeThread(status: "busy", updatedAt: 1_790_100_000_123 as Int)
    #expect(busy?.agentStatus == .busy)
    #expect(busy?.agentStatusSince == Date(timeIntervalSince1970: 1_790_100_000.123))
  }

  @Test func unknownStatusStaysNil() throws {
    let thread = try claudeThread(status: "compacting", updatedAt: 1_790_100_000_000.0)
    #expect(thread?.agentStatus == nil)
    #expect(thread?.sessionName == "notes-cleanup")
  }

  @Test func claudeStatusRejectsBooleanAndMissingTimes() throws {
    func parse(_ json: String) throws -> (status: AgentStatus, since: Date?)? {
      let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
      return AgentSignals.claudeStatus(try #require(object))
    }
    for json in [
      #"{"status":"busy","statusUpdatedAt":true}"#, #"{"status":"busy"}"#,
      #"{"status":"busy","statusUpdatedAt":"1790100000000"}"#,
    ] {
      let signal = try parse(json)
      #expect(signal?.status == .busy)
      #expect(signal?.since == nil)
    }
    #expect(try parse(#"{"statusUpdatedAt":1790100000000}"#) == nil)
    #expect(try parse(#"{"status":"compacting","statusUpdatedAt":1790100000000}"#) == nil)
    let shell = try parse(#"{"status":"shell","statusUpdatedAt":1790100000000}"#)
    #expect(shell?.status == .shell)
    #expect(shell?.since == Date(timeIntervalSince1970: 1_790_100_000))
  }

  @Test func codexStatusIsBusyOnlyWithinTheWindow() {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    func status(_ age: TimeInterval) -> AgentStatus {
      AgentSignals.codexStatus(written: now.addingTimeInterval(-age), now: now, toolRunning: false)
    }
    #expect(status(10) == .busy)
    #expect(status(60) == .idle)
    #expect(status(8 * 86_400) == .idle)
  }

  @Test func newestRolloutDecidesForSubagents() {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let old = now.addingTimeInterval(-8 * 86_400)
    let recent = now.addingTimeInterval(-10)
    let older = now.addingTimeInterval(-2 * 86_400)
    let busy = AgentSignals.codexStatus(written: [old, recent], now: now, toolRunning: false)
    #expect(busy?.status == .busy)
    #expect(busy?.since == recent)
    let idle = AgentSignals.codexStatus(written: [old, older], now: now, toolRunning: false)
    #expect(idle?.status == .idle)
    #expect(idle?.since == older)
    #expect(AgentSignals.codexStatus(written: [], now: now, toolRunning: true) == nil)
  }

  private func record(_ pid: Int32, _ ppid: Int32, _ arguments: String) -> RawProcessRecord {
    RawProcessRecord(
      processID: pid, parentProcessID: ppid, userID: 501, cpuPercent: 0, residentKilobytes: 1,
      elapsed: "01:00", terminal: nil, arguments: arguments)
  }

  private let nativeCodex =
    "/Users/me/.local/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/"
    + "vendor/aarch64-apple-darwin/bin/codex --no-daemon"

  @Test func aRunningShellToolIsBusyAndMCPServersAreNot() {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let weekOld = now.addingTimeInterval(-8 * 86_400)
    let mcp = [
      record(5087, 5081, nativeCodex),
      record(6277, 5087, "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl"),
      record(6279, 5087, "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node x.mjs"),
      record(6280, 5087, "/Users/me/.local/bin/chat mcp"),
      record(6311, 5087, "npm exec @upstash/context7-mcp"),
      record(
        9039, 5087, "/Users/me/.local/lib/node_modules/@openai/codex/bin/codex-code-mode-host"),
      record(9100, 6280, "/bin/zsh -c helper"),
    ]
    #expect(AgentSignals.codexToolShell(5087, records: mcp) == nil)
    let building = mcp + [record(9200, 5087, "/bin/zsh -lc cargo build")]
    let shell = AgentSignals.codexToolShell(5087, records: building)
    #expect(shell == "zsh")
    #expect(
      AgentSignals.codexStatus(written: weekOld, now: now, toolRunning: shell != nil) == .busy)
    for (arguments, name) in [
      ("/bin/sh -c x", "sh"), ("bash -c x", "bash"), ("/bin/dash -c x", "dash"),
      ("/opt/homebrew/bin/fish -c x", "fish"),
    ] {
      #expect(
        AgentSignals.codexToolShell(5087, records: mcp + [record(9300, 5087, arguments)]) == name)
    }
  }

  @Test func lsofTargetsTheNativeCodexNotTheNodeWrapper() {
    let wrapper = [
      record(5081, 5078, "node /Users/me/.local/bin/codex --no-daemon"),
      record(5087, 5081, nativeCodex),
      record(6280, 5087, "/Users/me/.local/bin/chat mcp"),
      record(7000, 6280, "/usr/local/bin/codex exec nested"),
    ]
    let byID = Dictionary(uniqueKeysWithValues: wrapper.map { ($0.processID, $0) })
    #expect(
      AgentSignals.codexProcess(root: 5081, processIDs: [5081, 6280, 7000, 5087], records: byID)
        == 5087)
    #expect(
      AgentSignals.codexProcess(root: 5087, processIDs: [5087, 6280, 7000], records: byID) == 5087)
    #expect(
      AgentSignals.codexProcess(root: 6280, processIDs: [6280], records: byID) == nil)
  }

  @Test func enrichRecordsTheNativeCodexUnderANodeWrapper() {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let records = [
      record(999_081, 1, "node /Users/me/.local/bin/codex --no-daemon"),
      record(999_087, 999_081, nativeCodex),
      record(999_280, 999_087, "/Users/me/.local/bin/chat mcp"),
    ]
    var thread = AIThread(
      id: "codexCLI-999081-1", tool: .codexCLI, name: "Codex CLI", directory: "/project",
      terminal: nil, startedAt: nil, processIDs: [999_081, 999_087, 999_280], memoryBytes: 1,
      cpuPercent: 0, isPaused: false, isDetached: false)
    thread.rootProcessID = 999_081
    let result = AIThreadNames.enrich(
      .init(threads: [thread], records: records, startTimes: [:], home: home))
    #expect(result.first?.nativeProcessID == 999_087)
  }

  @Test func codexRolloutsKeepPathsAndDropTheIDOnlyWhenAmbiguous() {
    let one = "6f1c2a52-6d1e-4c5e-9a4f-1f2e3d4c5b6a"
    let two = "01234567-0123-0123-0123-012345678901"
    let folder = "/Users/me/.codex/sessions/2026/10/19"
    let path = "\(folder)/rollout-2026-10-19T10-00-00-\(one).jsonl"
    let output = """
      n\(folder)/rollout-orphan-\(two).jsonl
      p100
      n/usr/lib/dyld
      n\(path)
      p200
      n\(folder)/rollout-a-\(one).jsonl
      n\(folder)/rollout-b-\(two).jsonl
      p300
      n/Users/me/.codex/history.jsonl
      p400
      n\(path)
      n\(path)
      """
    let sessions = AIThreadNames.codexRollouts(output)
    #expect(Set(sessions.keys) == [100, 200, 400])
    #expect(sessions[100]?.id == one)
    #expect(sessions[100]?.paths == [one: path])
    #expect(sessions[200]?.id == nil)
    #expect(sessions[200]?.paths.count == 2)
    // Subagents: the thread keeps both rollouts for the click-time re-check.
    #expect(
      sessions[200]?.all == [
        "\(folder)/rollout-a-\(one).jsonl", "\(folder)/rollout-b-\(two).jsonl",
      ])
    #expect(sessions[100]?.all == [path])
    #expect(sessions[400]?.id == one)
  }

  @Test func cursorReadsOnlyMatchingSessionMetadata() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let id = UUID().uuidString.lowercased()
    let folder = home.appendingPathComponent(".cursor/chats/workspace/\(id)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var database: OpaquePointer?
    #expect(sqlite3_open(folder.appendingPathComponent("store.db").path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    let json = try JSONSerialization.data(withJSONObject: [
      "agentId": id, "name": "Repair timeline", "blobEncryptionKey": "unused",
    ])
    let hex = json.map { String(format: "%02x", $0) }.joined()
    #expect(
      sqlite3_exec(
        database,
        "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT); INSERT INTO meta VALUES ('0', '\(hex)');",
        nil, nil, nil) == SQLITE_OK)
    #expect(AIThreadNames.cursorTitle(.init(home: home, sessionID: id)) == "Repair timeline")
    #expect(
      AIThreadNames.cursorTitle(.init(home: home, sessionID: UUID().uuidString.lowercased())) == nil
    )
  }

  @Test func namesAreBoundedAndSearchIncludesDelegation() {
    #expect(AIThreadNames.cleanTitle("hello\nworld") == "hello world")
    #expect(AIThreadNames.cleanTitle(String(repeating: "a", count: 200))?.count == 160)
    var thread = AIThread(
      id: "claude", tool: .claudeCode, name: "Claude Code", directory: "/dev/blitzreels",
      terminal: nil,
      startedAt: nil, processIDs: [42], memoryBytes: 1, cpuPercent: 0, isPaused: false,
      isDetached: false)
    thread.sessionTitle = "Fix export"
    thread.hostName = "cmux"
    thread.delegatedTools = ["Codex CLI"]
    #expect(thread.displayName == "Fix export")
    for query in ["export", "claude", "codex", "blitzreels", "cmux", "42"] {
      #expect(thread.matches(query))
    }
    #expect(!thread.matches("other project"))
  }
}
