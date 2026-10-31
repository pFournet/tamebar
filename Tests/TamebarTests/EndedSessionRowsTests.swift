import Foundation
import Testing

@testable import Tamebar

/// An ended session's title, the Stopped list's fallback when its folder has no name (Q15).
struct EndedSessionRowsTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func session(
    _ tool: AITool = .claudeCode, name: String?, directory: String = "/Users/test/dev/notes"
  ) -> EndedSession {
    EndedSession(
      id: "0b7c4f1e-9d2a-4c3b-8e5f-1a2b3c4d5e6f", tool: tool, directory: directory, name: name,
      idleSince: nil, endedAt: now.addingTimeInterval(-2 * 86_400), memoryBytes: 1)
  }

  @Test func aNamedSessionShowsItsName() {
    #expect(session(name: "notes-cleanup").rowTitle == "notes-cleanup")
    #expect(session(name: "notes-cleanup").folderName == "notes")
  }

  /// Without a name the folder is the title.
  @Test func anUnnamedSessionFallsBackToItsFolder() {
    for name in [nil, ""] as [String?] {
      #expect(session(name: name).rowTitle == "notes")
    }
  }

  @Test func aFolderWithoutANameFallsBackToTheTool() {
    #expect(session(name: nil, directory: "/").rowTitle == "Claude Code")
    #expect(session(name: nil, directory: "").rowTitle == "Claude Code")
    #expect(session(.codexCLI, name: nil, directory: "/").rowTitle == "Codex CLI")
  }

  /// The Stopped list names an ended session by its folder, whatever the session file calls it.
  @Test func theStoppedListNamesItByItsFolder() {
    for (ended, name) in [
      (session(name: "notes-cleanup"), "notes"),
      (session(.codexCLI, name: "x", directory: "/"), "x"),
    ] {
      var input = StoppedLog.Input(now: now)
      input.ended = [ended]
      #expect(StoppedLog.entries(input).map(\.name) == [name])
    }
  }
}
