import Foundation
import Testing

@testable import Tamebar

/// `tamebar hooks install|remove|status` (P2). Every test works on files in its own temporary
/// home; nothing reads or writes the real `~/.claude` or `~/.codex`.
struct StartHooksTests {
  static let command = "/Users/someone/.local/bin/tamebar wait"
  static let now = Date(timeIntervalSince1970: 1_800_000_000)

  /// Claude Code's settings, as it writes them: other hooks, keys in their order, a number with
  /// a fraction, an escaped string.
  static let claude = """
    {
      "model": "opus",
      "env": {
        "PATH_EXTRA": "a\\/b \\"quoted\\" \\u00e9"
      },
      "ratio": 1.50,
      "hooks": {
        "SessionStart": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "/usr/local/bin/other hook start",
                "timeout": 10
              }
            ]
          }
        ],
        "Stop": []
      },
      "permissions": {
        "allow": [
          "Bash(ls:*)"
        ]
      }
    }

    """

  struct Home {
    let url: URL

    init(claude: String? = StartHooksTests.claude, codex: String? = nil, codexFolder: Bool = true)
      throws
    {
      url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tamebar-hooks-\(UUID().uuidString)")
      let manager = FileManager.default
      try manager.createDirectory(
        at: url.appendingPathComponent(".claude"), withIntermediateDirectories: true)
      if codexFolder {
        try manager.createDirectory(
          at: url.appendingPathComponent(".codex"), withIntermediateDirectories: true)
      }
      if let claude { try write(claude, .claude) }
      if let codex { try write(codex, .codex) }
    }

    func write(_ text: String, _ tool: StartHooks.Tool) throws {
      try Data(text.utf8).write(to: tool.file(home: url))
    }

    func read(_ tool: StartHooks.Tool) -> String? {
      FileManager.default.contents(atPath: tool.file(home: url).path)
        .map { String(decoding: $0, as: UTF8.self) }
    }

    func backups(_ tool: StartHooks.Tool) -> [String] {
      let folder = tool.folder(home: url)
      return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        .filter { $0.contains(".tamebar-backup-") }.sorted()
    }

    func run(_ action: StartHooks.Action, _ tool: StartHooks.Tool, command: String = command)
      -> StartHooks.Outcome
    {
      StartHooks.run(action, tool: tool, home: url, command: command, now: StartHooksTests.now)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
  }

  @Test func readingAndWritingKeepsTheFileByteForByte() throws {
    let node = try #require(JSONNode.parse(Data(Self.claude.utf8)))
    #expect(node.render() + "\n" == Self.claude)
    #expect(node["env"]?["PATH_EXTRA"]?.stringValue == "a/b \"quoted\" é")
    #expect(
      JSONNode.parse(Data("{\"a\": [1, {}], \"b\": null, \"c\": true}".utf8))?.render()
        == "{\n  \"a\": [\n    1,\n    {}\n  ],\n  \"b\": null,\n  \"c\": true\n}")
    #expect(JSONNode.parse(Data("{\"a\": 1,}".utf8)) == nil)
  }

  @Test func recognisesTamebarsWaitOnly() {
    #expect(StartHooks.isTamebarWait("/Users/x/.local/bin/tamebar wait"))
    #expect(StartHooks.isTamebarWait("tamebar wait"))
    #expect(StartHooks.isTamebarWait("'/Users/x/My Apps/Tamebar.app/Contents/MacOS/Tamebar' wait"))
    #expect(StartHooks.isTamebarWait("/Applications/Tamebar.app/Contents/MacOS/Tamebar  wait "))
    #expect(!StartHooks.isTamebarWait("/usr/bin/tamebar status"))
    #expect(!StartHooks.isTamebarWait("/opt/notamebar wait"))
    #expect(!StartHooks.isTamebarWait("tamebar wait && rm -rf x"))
    #expect(StartHooks.command(executable: "/a/b/tamebar") == "/a/b/tamebar wait")
    #expect(
      StartHooks.command(executable: "/My Apps/Tamebar") == "'/My Apps/Tamebar' wait")
  }

  @Test func installAddsTheHookKeepsEverythingElseAndBacksUp() throws {
    let home = try Home()
    defer { home.remove() }
    guard case .changed(let backup?) = home.run(.install, .claude) else {
      Issue.record("not installed")
      return
    }
    #expect(try String(contentsOfFile: backup, encoding: .utf8) == Self.claude)
    #expect(backup.hasSuffix("settings.json.tamebar-backup-" + Self.stamp))
    let text = try #require(home.read(.claude))
    let root = try #require(JSONNode.parse(Data(text.utf8)))
    // Every other key, in its order, untouched.
    guard case .object(let members) = root else { throw Failure.shape }
    #expect(members.map(\.key) == ["model", "env", "ratio", "hooks", "permissions"])
    #expect(text.contains("\"ratio\": 1.50"))
    #expect(text.contains(#""PATH_EXTRA": "a\/b \"quoted\" \u00e9""#))
    #expect(root["hooks"]?["Stop"] == .array([]))
    #expect(StartHooks.commands(in: root) == [Self.command])
    guard case .array(let groups)? = root["hooks"]?["SessionStart"] else { throw Failure.shape }
    #expect(groups.count == 2)
    #expect(groups[0]["hooks"]?.render(0).contains("/usr/local/bin/other hook start") == true)
    #expect(groups[1]["hooks"]?.render(0).contains("\"timeout\": 660") == true)
    #expect(text.hasSuffix("}\n"))
  }

  @Test func installIsIdempotentAndUpdatesAnOldPath() throws {
    let home = try Home()
    defer { home.remove() }
    _ = home.run(.install, .claude)
    let first = home.read(.claude)
    #expect(home.run(.install, .claude) == .unchanged)
    #expect(home.read(.claude) == first)
    #expect(home.backups(.claude).count == 1)
    // Reinstalled elsewhere: the one hook is updated in place, not added again.
    let moved = "/Applications/Tamebar.app/Contents/MacOS/Tamebar wait"
    guard case .changed = home.run(.install, .claude, command: moved) else {
      Issue.record("not updated")
      return
    }
    let root = try #require(home.read(.claude).flatMap { JSONNode.parse(Data($0.utf8)) })
    #expect(StartHooks.commands(in: root) == [moved])
    #expect(home.backups(.claude).count == 2)
  }

  @Test func duplicatesCollapseToOne() throws {
    let entry = #"{"hooks": [{"type": "command", "command": "tamebar wait", "timeout": 5}]}"#
    let home = try Home(
      claude: nil,
      codex: #"{"hooks": {"SessionStart": [\#(entry), {"hooks": []}, \#(entry)]}}"#)
    defer { home.remove() }
    _ = home.run(.install, .codex)
    let root = try #require(home.read(.codex).flatMap { JSONNode.parse(Data($0.utf8)) })
    #expect(StartHooks.commands(in: root) == [Self.command])
    // The user's own empty group stays; the emptied duplicate goes.
    guard case .array(let groups)? = root["hooks"]?["SessionStart"] else { throw Failure.shape }
    #expect(groups.count == 2)
  }

  @Test func aMissingFileIsCreatedAndAMissingFolderSkipped() throws {
    let home = try Home(claude: nil)
    defer { home.remove() }
    #expect(home.run(.install, .codex) == .changed(backup: nil))
    #expect(home.backups(.codex).isEmpty)
    let text = try #require(home.read(.codex))
    #expect(
      text == """
        {
          "hooks": {
            "SessionStart": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "\(Self.command)",
                    "timeout": 660
                  }
                ]
              }
            ]
          }
        }

        """)
    let noCodex = try Home(codexFolder: false)
    defer { noCodex.remove() }
    #expect(noCodex.run(.install, .codex) == .noTool)
    #expect(
      !FileManager.default.fileExists(atPath: noCodex.url.appendingPathComponent(".codex").path))
  }

  @Test func removeTakesOutOnlyTamebarsHook() throws {
    let home = try Home()
    defer { home.remove() }
    #expect(home.run(.remove, .claude) == .unchanged)
    _ = home.run(.install, .claude)
    guard case .changed = home.run(.remove, .claude) else {
      Issue.record("not removed")
      return
    }
    // Back to the original, byte for byte.
    #expect(home.read(.claude) == Self.claude)
    #expect(home.run(.remove, .claude) == .unchanged)
    #expect(home.backups(.claude).count == 2)

    let only = try Home(
      claude: "{\"hooks\": {\"SessionStart\": [{\"hooks\": [{\"command\": \"tamebar wait\"}]}]}}")
    defer { only.remove() }
    _ = only.run(.remove, .claude)
    #expect(only.read(.claude) == "{}")
  }

  @Test func statusReadsWithoutWriting() throws {
    let home = try Home()
    defer { home.remove() }
    #expect(home.run(.status, .claude) == .found([]))
    #expect(home.run(.status, .codex) == .found([]))
    #expect(home.read(.codex) == nil)
    _ = home.run(.install, .claude)
    #expect(home.run(.status, .claude) == .found([Self.command]))
    #expect(home.backups(.claude).count == 1)
  }

  @Test func invalidJSONOrAnOddShapeIsLeftAlone() throws {
    let broken = "{\"a\": 1,, }"
    let home = try Home(claude: broken, codex: "{\"hooks\": []}")
    defer { home.remove() }
    guard case .failed = home.run(.install, .claude) else {
      Issue.record("installed into invalid JSON")
      return
    }
    #expect(home.read(.claude) == broken)
    guard case .failed = home.run(.install, .codex) else {
      Issue.record("installed into an array of hooks")
      return
    }
    #expect(home.read(.codex) == "{\"hooks\": []}")
    #expect(home.backups(.claude).isEmpty && home.backups(.codex).isEmpty)
  }

  @Test func aLinkedFileStaysALink() throws {
    let home = try Home(claude: nil)
    defer { home.remove() }
    let real = home.url.appendingPathComponent("setup-settings.json")
    try Data(Self.claude.utf8).write(to: real)
    try FileManager.default.createSymbolicLink(
      at: StartHooks.Tool.claude.file(home: home.url), withDestinationURL: real)
    _ = home.run(.install, .claude)
    let link = StartHooks.Tool.claude.file(home: home.url).path
    #expect(
      (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == real.path)
    #expect(try String(contentsOf: real, encoding: .utf8).contains("\"timeout\": 660"))
  }

  @Test func theCommandReportsEachToolAndExitsOneOnFailure() throws {
    let home = try Home(claude: "[1]")
    defer { home.remove() }
    var out = ""
    var env = CLIEnvironment.fixture(out: { out += $0 })
    env.home = home.url
    env.executable = { "/Users/someone/.local/bin/tamebar" }
    #expect(CLI.run(["hooks", "install"], env) == 1)
    #expect(out.contains("Claude Code (~/.claude/settings.json): "))
    #expect(out.contains("Codex (~/.codex/hooks.json): installed \(Self.command)"))
    out = ""
    #expect(CLI.run(["hooks", "status"], env) == 1)
    #expect(out.contains("Codex (~/.codex/hooks.json): installed: \(Self.command)"))
    #expect(CLI.run(["hooks"], env) == 2)
    #expect(CLI.run(["hooks", "add"], env) == 2)
  }

  static var stamp: String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: now)
  }

  enum Failure: Error { case shape }
}
