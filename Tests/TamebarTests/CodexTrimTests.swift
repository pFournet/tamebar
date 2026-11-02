import Foundation
import Testing

@testable import Tamebar

/// Q21: turn off the Codex plugins nobody uses, per row Auto / On / Off. Every test works on
/// copies in a temporary folder; nothing reads or writes the real `~/.codex`.
enum CodexTrimTests {}

private let config = """
  model = "gpt-5"
  # a comment with [mcp_servers.fake] in it

  [hooks.state."/x/config.toml:stop:0:0"]
  trusted_hash = "abc"

  [mcp_servers.cubic]
  url = "https://example.invalid/mcp"

  [mcp_servers."context7"]
  command = "npx"
  args = [
    "-y",
    "@upstash/context7-mcp",
  ]
  default_tools_approval_mode = "approve"

  [mcp_servers."mcp-server-github"]
  command = "docker"
  args = ["run"]

  [mcp_servers."mcp-server-github".env]
  GITHUB_TOKEN = "secret"
  enabled = true

  [mcp_servers.computer-use]
  command = "x"
  enabled = false

  [mcp_servers.chat]
  command = "chat"
  args = ["mcp"]

  [notice]
  text = \"\"\"
  [mcp_servers.inside_a_string]
  enabled = true
  \"\"\"

  [plugins."code-review@openai-bundled"]
  enabled = true # keep this comment

  [plugins."visualize@openai-bundled"]
  enabled = true

  [plugins."unified-computer-use@openai-bundled"]
  enabled = true

  [[hooks.Stop]]
  matcher = "*"
  """

extension CodexTrimTests {
  struct TOML {
    @Test func headersSkipStringsArraysAndComments() {
      let paths = CodexTOML.tables(CodexTOML.lines(config)).map(\.path)
      #expect(paths.contains(["mcp_servers", "context7"]))
      #expect(paths.contains(["hooks", "state", "/x/config.toml:stop:0:0"]))
      #expect(!paths.contains(["mcp_servers", "inside_a_string"]))
      #expect(!paths.contains(["mcp_servers", "fake"]))
      #expect(CodexTOML.header("  [ a . \"b.c\" ]  # x")?.path == ["a", "b.c"])
      #expect(CodexTOML.header("[[hooks.Stop]]")?.isArray == true)
      #expect(CodexTOML.header("key = [1]") == nil)
      #expect(CodexTOML.header("[a.]") == nil)
    }

    @Test func entriesAreTheServersAndPluginsWithTheirEnabled() {
      let items = CodexTOML.entries(config)
      #expect(
        items.map(\.key) == [
          "server:cubic", "server:context7", "server:mcp-server-github", "server:computer-use",
          "server:chat", "plugin:code-review@openai-bundled", "plugin:visualize@openai-bundled",
          "plugin:unified-computer-use@openai-bundled",
        ])
      // The sub-table's `enabled` is the env table's, not the server's.
      #expect(items.first { $0.name == "mcp-server-github" }?.enabled == nil)
      #expect(items.first { $0.name == "computer-use" }?.enabled == false)
    }

    @Test func turningOffInsertsOneLineUnderTheHeaderOnly() throws {
      let edited = try #require(
        CodexTOML.setEnabled(["mcp_servers", "context7"], false, in: config))
      let before = CodexTOML.lines(config)
      let after = CodexTOML.lines(edited)
      #expect(after.count == before.count + 1)
      let header = try #require(before.firstIndex(of: "[mcp_servers.\"context7\"]"))
      #expect(after[header + 1] == "enabled = false")
      var restored = after
      restored.remove(at: header + 1)
      #expect(restored == before)
      #expect(CodexTOML.enabled(["mcp_servers", "context7"], in: edited) == false)
    }

    @Test func anExistingValueIsReplacedInPlaceKeepingItsComment() throws {
      let edited = try #require(
        CodexTOML.setEnabled(["plugins", "code-review@openai-bundled"], false, in: config))
      #expect(edited.contains("enabled = false # keep this comment"))
      #expect(edited.count == config.count + 1)
      #expect(CodexTOML.lines(edited).count == CodexTOML.lines(config).count)
    }

    @Test func aTableThatIsMissingOrTwiceIsNeverEdited() {
      #expect(CodexTOML.setEnabled(["mcp_servers", "nope"], false, in: config) == nil)
      let twice = config + "\n[mcp_servers.cubic]\nurl = \"y\"\n"
      #expect(CodexTOML.setEnabled(["mcp_servers", "cubic"], false, in: twice) == nil)
      #expect(!CodexTOML.entries(twice).contains { $0.name == "cubic" })
    }

    @Test func crlfLinesKeepTheirEndings() throws {
      let text = "[mcp_servers.a]\r\ncommand = \"x\"\r\n"
      let edited = try #require(CodexTOML.setEnabled(["mcp_servers", "a"], false, in: text))
      #expect(edited == "[mcp_servers.a]\r\nenabled = false\r\ncommand = \"x\"\r\n")
    }
  }

  struct Rollouts {
    private func line(_ object: [String: Any]) -> Data {
      try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func everyShapeOfAnMCPCallNamesItsServer() {
      let item = line([
        "type": "event_msg",
        "payload": [
          "type": "item_completed",
          "item": ["type": "McpToolCall", "server": "mcp-server-github", "tool": "x"],
        ],
      ])
      let namespaced = line([
        "type": "response_item",
        "payload": ["type": "function_call", "namespace": "mcp__cua_repl", "name": "js"],
      ])
      let named = line([
        "type": "response_item",
        "payload": ["type": "function_call", "name": "mcp__my-api-local__query"],
      ])
      let legacy = line([
        "type": "event_msg",
        "payload": [
          "type": "mcp_tool_call_end", "invocation": ["server": "chat", "tool": "send"],
        ],
      ])
      let message = line([
        "type": "response_item",
        "payload": ["type": "message", "content": "McpToolCall mcp__chat__x"],
      ])
      #expect(CodexRollouts.servers(inLine: item) == ["mcp_server_github"])
      #expect(CodexRollouts.servers(inLine: namespaced) == ["cua_repl"])
      #expect(CodexRollouts.servers(inLine: named) == ["my_api_local"])
      #expect(CodexRollouts.servers(inLine: legacy) == ["chat"])
      #expect(CodexRollouts.servers(inLine: message).isEmpty)
      #expect(CodexRollouts.servers(inLine: Data("not json McpToolCall".utf8)).isEmpty)
    }

    @Test func scansTheWindowAndFindsTheOldestDay() throws {
      let root = try temporaryFolder()
      defer { try? FileManager.default.removeItem(at: root) }
      let sessions = root.appendingPathComponent("sessions")
      let old = sessions.appendingPathComponent("2026/08/01")
      let recent = sessions.appendingPathComponent("2026/10/29")
      try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
      let call = String(
        decoding: line([
          "type": "event_msg",
          "payload": [
            "type": "item_completed", "item": ["type": "McpToolCall", "server": "context7"],
          ],
        ]), as: UTF8.self)
      let oldFile = old.appendingPathComponent("rollout-a.jsonl")
      try Data((call + "\n").utf8).write(to: oldFile)
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1_785_000_000)], ofItemAtPath: oldFile.path)
      try Data(("{}\n" + call + "\n" + call).utf8)
        .write(to: recent.appendingPathComponent("rollout-b.jsonl"))
      try Data("x".utf8).write(to: recent.appendingPathComponent("rollout-c.jsonl.zst"))
      let usage = CodexRollouts.scan(
        sessions: sessions, since: Date.now.addingTimeInterval(-30 * 86_400), zstd: nil)
      #expect(usage.calls == ["context7": 2])
      #expect(usage.files == 2)
      // A compressed rollout with no zstd to read it: the run can't judge.
      #expect(usage.unreadable.count == 1)
      let oldest = try #require(usage.oldest)
      #expect(Calendar(identifier: .gregorian).component(.month, from: oldest) == 8)
    }
  }

  struct Plan {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let catalog: (String) -> Set<String>? = { id in
      switch id {
      case "code-review@openai-bundled": ["code-review"]
      case "unified-computer-use@openai-bundled": ["cua_repl"]
      case "visualize@openai-bundled": []
      default: nil
      }
    }

    private var items: [CodexTrim.Item] { CodexTOML.entries(config) }

    @Test func autoTurnsOffWhatHadNoCallAndNeverTheListedServers() {
      let changes = CodexTrim.plan(
        items: items, modes: [:], calls: ["mcp_server_github": 67, "cua_repl": 76], held: false,
        turnedOffByTamebar: [], pluginServers: catalog, alwaysOn: ["server:chat"])
      #expect(
        changes.map(\.item.key) == [
          "server:cubic", "server:context7", "plugin:code-review@openai-bundled",
        ])
      #expect(changes.allSatisfy { !$0.on && $0.automatic })
    }

    @Test func autoWaitsForACountAndForThirtyDaysOfRollouts() {
      #expect(
        CodexTrim.plan(
          items: items, modes: [:], calls: nil, held: false, turnedOffByTamebar: [],
          pluginServers: catalog
        ).isEmpty)
      #expect(
        CodexTrim.plan(
          items: items, modes: [:], calls: [:], held: true, turnedOffByTamebar: [],
          pluginServers: catalog
        ).isEmpty)
      var usage = CodexRollouts.Usage()
      usage.oldest = now.addingTimeInterval(-29 * 86_400)
      #expect(CodexTrim.held(usage, now: now) != nil)
      usage.oldest = now.addingTimeInterval(-31 * 86_400)
      #expect(CodexTrim.held(usage, now: now) == nil)
      usage.unreadable = ["x"]
      #expect(CodexTrim.held(usage, now: now) != nil)
    }

    @Test func offAlwaysOffOnOnlyUndoesTamebar() {
      let changes = CodexTrim.plan(
        items: items,
        modes: [
          "server:mcp-server-github": .off, "server:computer-use": .on, "server:cubic": .on,
          "server:context7": .on,
        ],
        calls: ["mcp_server_github": 67, "cua_repl": 1, "code_review": 1], held: false,
        turnedOffByTamebar: [], pluginServers: catalog, alwaysOn: ["server:chat"])
      // computer-use was off by hand, not by Tamebar: On leaves it.
      #expect(changes.map(\.item.key) == ["server:mcp-server-github"])
      #expect(changes.first?.automatic == false)
      let back = CodexTrim.plan(
        items: items, modes: ["server:computer-use": .on], calls: [:], held: false,
        turnedOffByTamebar: ["server:computer-use"], pluginServers: catalog)
      #expect(back.contains(.init(item: items[3], on: true, automatic: false)))
    }

    @Test func aPluginWithoutMCPServersIsNeverListedOrTouched() {
      let changes = CodexTrim.plan(
        items: items, modes: ["plugin:visualize@openai-bundled": .off], calls: [:], held: false,
        turnedOffByTamebar: [], pluginServers: catalog)
      #expect(!changes.contains { $0.item.name == "visualize@openai-bundled" })
      #expect(CodexTrim.calls(items[6], calls: [:], pluginServers: catalog) == nil)
    }

    /// The servers listed in Settings (a messaging server receives messages, which call counts
    /// don't show) are never touched, whatever a mode says. None is listed by default.
    @Test func theListedServersAreNeverTouched() {
      let changes = CodexTrim.plan(
        items: items, modes: ["server:chat": .off], calls: [:], held: false,
        turnedOffByTamebar: [], pluginServers: catalog, alwaysOn: ["server:chat"])
      #expect(!changes.contains { $0.item.name == "chat" })
      #expect(
        CodexTrim.Modes.mode(
          "server:inbox", in: ["server:inbox": .auto], alwaysOn: ["server:inbox"])
          == .on)
      #expect(CodexTrim.Modes.mode("server:inbox", in: ["server:inbox": .auto]) == .auto)
      let unlisted = CodexTrim.plan(
        items: items, modes: [:], calls: [:], held: false, turnedOffByTamebar: [],
        pluginServers: catalog)
      #expect(unlisted.contains { $0.item.name == "chat" })
    }

    /// With the Settings switch off, nothing is turned off; Undo's turning back on still is.
    @Test func switchedOffOnlyTurnsBackOn() {
      let changes = CodexTrim.plan(
        items: items,
        modes: ["server:mcp-server-github": .off, "server:computer-use": .on], calls: [:],
        held: false, turnedOffByTamebar: ["server:computer-use"], pluginServers: catalog,
        turnsOff: false)
      #expect(changes == [.init(item: items[3], on: true, automatic: false)])
    }

    @Test func aHandEditSetsTheRowToMatch() {
      let known = [
        "server:cubic": false, "server:context7": true, "server:computer-use": false,
      ]
      let edits = CodexTrim.handEdits(
        items: items, known: known, turnedOffByTamebar: ["server:cubic"])
      // cubic was off by Tamebar and is on again: On. context7 unchanged. chat unseen and on.
      #expect(edits == ["server:cubic": .on])
      let first = CodexTrim.handEdits(items: items, known: [:], turnedOffByTamebar: [])
      #expect(first == ["server:computer-use": .off])
    }
  }

  struct Runner {
    @Test func appliesAutoOnACopyWithABackupAndUndoTurnsItBackOn() throws {
      let root = try temporaryFolder()
      defer { try? FileManager.default.removeItem(at: root) }
      let paths = try copies(root)
      let runner = CodexTrimRunner(paths: paths, zstd: nil)
      let now = Date.now
      let outcome = runner.run(now: now, rules: Self.rules)
      #expect(outcome.ran)
      #expect(
        Set(outcome.turnedOff.map(\.name))
          == ["cubic", "context7", "code-review@openai-bundled"])
      let text = try String(contentsOf: paths.config, encoding: .utf8)
      #expect(CodexTOML.enabled(["mcp_servers", "cubic"], in: text) == false)
      #expect(CodexTOML.enabled(["mcp_servers", "chat"], in: text) == nil)
      #expect(CodexTOML.lines(text).count == CodexTOML.lines(config).count + 2)
      let backups = try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("state/codex-config-backups").path)
      #expect(backups.count == 1)
      let backup = root.appendingPathComponent("state/codex-config-backups/\(backups[0])")
      #expect(try String(contentsOf: backup, encoding: .utf8) == config)
      let mode = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions]
      #expect((mode as? NSNumber)?.intValue == 0o600)
      #expect(outcome.state.lastRun?.applied == true)

      // Undo: On turns it back on, once the file has settled.
      try settle(paths.config)
      let undone = runner.apply(now: .now, rules: .init(modes: ["server:cubic": .on]))
      #expect(undone.turnedOn == ["cubic"])
      let after = try String(contentsOf: paths.config, encoding: .utf8)
      #expect(CodexTOML.enabled(["mcp_servers", "cubic"], in: after) == true)
      #expect(!undone.state.off.contains { $0.name == "cubic" })
    }

    @Test func nothingIsWrittenWhileTheFileWasJustChanged() throws {
      let root = try temporaryFolder()
      defer { try? FileManager.default.removeItem(at: root) }
      let paths = try copies(root, settled: false)
      let outcome = CodexTrimRunner(paths: paths, zstd: nil).run(now: .now, rules: Self.rules)
      #expect(!outcome.ran)
      #expect(try String(contentsOf: paths.config, encoding: .utf8) == config)
    }

    @Test func aHandEditBackOnIsKeptOn() throws {
      let root = try temporaryFolder()
      defer { try? FileManager.default.removeItem(at: root) }
      let paths = try copies(root)
      let runner = CodexTrimRunner(paths: paths, zstd: nil)
      _ = runner.run(now: .now, rules: Self.rules)
      // The user removes `enabled = false` from cubic by hand.
      var lines = CodexTOML.lines(try String(contentsOf: paths.config, encoding: .utf8))
      let header = try #require(lines.firstIndex(of: "[mcp_servers.cubic]"))
      #expect(lines[header + 1] == "enabled = false")
      lines.remove(at: header + 1)
      try lines.joined(separator: "\n").write(to: paths.config, atomically: true, encoding: .utf8)
      try settle(paths.config)
      let outcome = runner.apply(now: .now, rules: Self.rules)
      #expect(outcome.modes == ["server:cubic": .on])
      #expect(outcome.turnedOff.isEmpty)
      #expect(
        CodexTOML.enabled(
          ["mcp_servers", "cubic"], in: try String(contentsOf: paths.config, encoding: .utf8))
          == nil)
    }

    /// The fixture's `chat` server is listed in Settings, so Auto leaves it.
    static let rules = CodexTrimRunner.Rules(alwaysOn: ["server:chat"])

    @Test func modesRoundTripInDefaultsWithTheListedServersOn() {
      let defaults = TestDefaults("codex-modes").defaults
      let listed: Set<String> = ["server:inbox"]
      #expect(
        CodexTrim.Modes.mode("server:inbox", in: CodexTrim.Modes.load(defaults), alwaysOn: listed)
          == .on)
      CodexTrim.Modes.save(["server:inbox": .auto, "server:x": .off], defaults)
      let modes = CodexTrim.Modes.load(defaults)
      #expect(CodexTrim.Modes.mode("server:inbox", in: modes, alwaysOn: listed) == .on)
      #expect(CodexTrim.Modes.mode("server:x", in: modes) == .off)
      #expect(CodexTrim.Modes.mode("server:y", in: modes) == .auto)
    }

    /// A config copy, a plugin cache and 31 days of rollouts with github, linear and cua_repl
    /// calls, under `root`.
    private func copies(_ root: URL, settled: Bool = true) throws -> CodexTrimRunner.Paths {
      let manager = FileManager.default
      let codex = root.appendingPathComponent("codex")
      let day = codex.appendingPathComponent("sessions/2026/09/01")
      try manager.createDirectory(at: day, withIntermediateDirectories: true)
      let old = Date.now.addingTimeInterval(-31 * 86_400)
      var components = Calendar(identifier: .gregorian).dateComponents(
        [.year, .month, .day], from: old)
      let oldDay = codex.appendingPathComponent(
        String(
          format: "sessions/%04d/%02d/%02d", components.year!, components.month!, components.day!))
      components = DateComponents()
      try manager.createDirectory(at: oldDay, withIntermediateDirectories: true)
      try Data("{}\n".utf8).write(to: oldDay.appendingPathComponent("rollout-old.jsonl"))
      try manager.setAttributes(
        [.modificationDate: old],
        ofItemAtPath: oldDay.appendingPathComponent("rollout-old.jsonl").path)
      var lines = ""
      for server in ["mcp-server-github", "cua_repl"] {
        let object: [String: Any] = [
          "type": "event_msg",
          "payload": [
            "type": "item_completed", "item": ["type": "McpToolCall", "server": server],
          ],
        ]
        lines +=
          String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
          + "\n"
      }
      try Data(lines.utf8).write(to: day.appendingPathComponent("rollout-new.jsonl"))
      let cache = codex.appendingPathComponent("plugins/cache/openai-bundled")
      for (name, server) in [("code-review", "code-review"), ("unified-computer-use", "cua_repl")] {
        let folder = cache.appendingPathComponent("\(name)/1.0")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"mcpServers": {"\#(server)": {"command": "x"}}}"#.utf8)
          .write(to: folder.appendingPathComponent(".mcp.json"))
      }
      try manager.createDirectory(
        at: cache.appendingPathComponent("visualize/1.0/.codex-plugin"),
        withIntermediateDirectories: true)
      let file = codex.appendingPathComponent("config.toml")
      try Data(config.utf8).write(to: file)
      if settled { try settle(file) }
      return .init(
        config: file, sessions: codex.appendingPathComponent("sessions"),
        pluginCache: codex.appendingPathComponent("plugins/cache"),
        directory: root.appendingPathComponent("state"))
    }

    /// Dates the file two minutes back, past the minute a Codex start is given.
    private func settle(_ file: URL) throws {
      try FileManager.default.setAttributes(
        [.modificationDate: Date.now.addingTimeInterval(-120)], ofItemAtPath: file.path)
    }
  }
}

private func temporaryFolder() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("tamebar-codex-trim-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

extension CodexTrimTests {
  /// `tamebar status` and `tamebar stopped` show Q20's servers and Q21's plugins.
  struct CommandLine {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func statusSaysWhatIsOffAndWhy() {
      let utc = TimeZone(secondsFromGMT: 0)!
      var codex = CLIStatus.CodexPlugins(
        checkedAt: now, applied: true, turnOff: ["cubic"], calls: [:], off: ["cubic", "context7"])
      #expect(
        CLIText.codexPlugins(codex, utc)
          == "off by Tamebar, no call in 30 days: cubic, context7 (checked Jan 15 08:00)")
      codex.held = "Codex rollouts go back less than 30 days"
      #expect(
        CLIText.codexPlugins(codex, utc)
          == "nothing turned off: Codex rollouts go back less than 30 days (checked Jan 15 08:00)")
    }

    @Test func stoppedListsTheServerWithItsCommandAndThePluginWithUndo() {
      var state = CLIState()
      state.codexTrim = CodexTrimState(
        off: [.init(kind: .server, name: "context7", offAt: now)], known: [:], lastRun: nil)
      var stores = CLIStoppedStores()
      stores.servers = [
        EndedServer(
          id: "1", session: "my-app", ports: [5180], directory: "/code/web",
          commandLine: "npm run dev", endedAt: now, memoryBytes: 40_000_000,
          unusedFor: 2 * 86_400)
      ]
      let report = CLIReport.stopped(
        .init(
          scan: CLISessionScan(
            threads: [], records: [:], listening: [], ports: [:], incomplete: false),
          state: state, stores: stores, running: [:], tamebarRunning: true, now: now,
          label: { _ in nil }))
      #expect(report.stopped.map(\.kind) == ["server", "codex plugin"])
      #expect(report.stopped.first?.reason == "unused" && report.stopped.first?.idleDays == 2)
      let text = CLIText.stopped(report, timeZone: TimeZone(secondsFromGMT: 0)!)
      #expect(text.contains("my-app :5180"))
      #expect(text.contains("ended · unused 2 days"))
      #expect(text.contains("cd '/code/web' && npm run dev"))
      #expect(text.contains("off · no call in 30 days · new Codex sessions only"))
      #expect(text.contains("Turn on in Tamebar's Activity list"))
    }
  }
}
