import Foundation
import Testing

@testable import Tamebar

/// N8: Ask Claude / Ask Codex. The command Terminal runs, its quoting for the shell and for
/// AppleScript, and which tools count as installed.
struct AskAgentTests {
  @Test func theCommandRunsTheBareToolInHomeWithThePromptAsOneWord() {
    #expect(
      AskAgent.claude.command()
        == "cd ~ && claude 'The Mac is under pressure. Use `tamebar status` and `tamebar sessions`, propose what to end or quit, and ask me before ending anything.'"
    )
    #expect(AskAgent.codex.command()?.hasPrefix("cd ~ && codex '") == true)
    #expect(AskAgent.claude.title == "Ask Claude")
    #expect(AskAgent.codex.title == "Ask Codex")
  }

  @Test func singleQuotingLeavesNothingToExpand() {
    #expect(ShellQuote.single("plain") == "'plain'")
    #expect(ShellQuote.single("it's") == "'it'\\''s'")
    #expect(ShellQuote.single("$(rm -rf ~) `x` \\ \"q\" !1") == "'$(rm -rf ~) `x` \\ \"q\" !1'")
    #expect(ShellQuote.single("") == "''")
  }

  @Test func aControlCharacterGivesNoCommand() {
    #expect(ShellQuote.single("one\ntwo") == nil)
    #expect(ShellQuote.single("one\rtwo") == nil)
    #expect(ShellQuote.single("kill line \u{15}") == nil)
    #expect(ShellQuote.single("paste end \u{1B}[201~") == nil)
    #expect(AskAgent.claude.command(prompt: "a\nb") == nil)
  }

  /// The quoted command goes into AppleScript's string as written: the shell's backslash and
  /// quotes escaped for AppleScript, so the shell gets back exactly the command.
  @Test func theAppleScriptCarriesTheCommandUnchanged() throws {
    let command = try #require(AskAgent.claude.command(prompt: #"say "hi" it's \ ok"#))
    let script = TerminalLauncher.script(command)
    #expect(script.contains(#"do script "cd ~ && claude 'say \"hi\" it'\\''s \\ ok'""#))
    #expect(Self.appleScriptString(in: script) == command)
  }

  @Test func thePromptsAppleScriptRoundTrips() throws {
    for agent in AskAgent.allCases {
      let command = try #require(agent.command())
      #expect(Self.appleScriptString(in: TerminalLauncher.script(command)) == command)
    }
  }

  // MARK: Installed

  @Test func theShellsPathIsTheLineAfterTheMarker() {
    let output =
      "Last login\nwelcome \(AskAgentInstall.marker)?\n\(AskAgentInstall.marker)\n/a:/b\n"
    #expect(AskAgentInstall.shellPath(from: output) == "/a:/b")
    #expect(AskAgentInstall.shellPath(from: "no marker\n/a") == nil)
    #expect(AskAgentInstall.shellPath(from: "\(AskAgentInstall.marker)\n") == nil)
  }

  @Test func theFoldersAreTheShellsPathThenTheAppsThenTheKnownOnes() {
    let folders = AskAgentInstall.directories(
      shellPath: "/Users/me/.agentrun/bin:/Users/me/.local/bin/:bin:~/tools",
      processPath: "/usr/bin:/Users/me/.local/bin", home: "/Users/me")
    #expect(
      Array(folders.prefix(5)) == [
        "/Users/me/.agentrun/bin", "/Users/me/.local/bin", "/Users/me/tools", "/usr/bin",
        "/Users/me/.claude/local",
      ])
    #expect(folders.contains("/opt/homebrew/bin"))
    #expect(!folders.contains("bin"), "a relative entry depends on the folder")
    #expect(Set(folders).count == folders.count, "each folder once")
    #expect(
      AskAgentInstall.directories(shellPath: nil, processPath: nil, home: "/Users/me")
        == AskAgentInstall.knownLocations(home: "/Users/me"))
  }

  @Test func aToolIsInstalledWithAnExecutableOfItsNameInAFolder() {
    let files: Set<String> = ["/Users/me/.local/bin/codex", "/opt/homebrew/bin/claude-x"]
    let found = AskAgentInstall.installed(in: ["/opt/homebrew/bin", "/Users/me/.local/bin"]) {
      files.contains($0)
    }
    #expect(found == [.codex])
    #expect(
      AskAgentInstall.installed(in: ["/x"]) { ["/x/claude", "/x/codex"].contains($0) }
        == [.claude, .codex])
    #expect(AskAgentInstall.installed(in: []) { _ in true }.isEmpty)
  }

  @MainActor @Test func nothingIsInstalledUntilStarted() {
    let agents = AskAgents()
    agents.refresh()
    #expect(agents.installed.isEmpty)
  }

  /// The string literal after `do script`, read back as AppleScript reads it.
  private static func appleScriptString(in script: String) -> String? {
    guard let start = script.range(of: "do script \"") else { return nil }
    var result = ""
    var escaped = false
    for character in script[start.upperBound...] {
      if escaped {
        result.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "\"" {
        return result
      } else {
        result.append(character)
      }
    }
    return nil
  }
}
