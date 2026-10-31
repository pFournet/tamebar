import Foundation
import Testing

@testable import Tamebar

struct EndedSessionsTests {
  @Test func resumeCommandsQuoteTheFolder() {
    let claude = EndedSession(
      id: .uuid(1), tool: .claudeCode, directory: "/Users/me/it's here", name: "notes",
      idleSince: nil, endedAt: .now, memoryBytes: 1)
    #expect(
      claude.resumeCommand == "cd '/Users/me/it'\\''s here' && claude --resume \(String.uuid(1))")
    let codex = EndedSession(
      id: .uuid(2), tool: .codexCLI, directory: "/code/b", name: nil, idleSince: nil,
      endedAt: .now, memoryBytes: 1)
    #expect(codex.resumeCommand == "cd '/code/b' && codex resume \(String.uuid(2))")
    let cursor = EndedSession(
      id: .uuid(3), tool: .cursorAgent, directory: "/x", name: nil, idleSince: nil,
      endedAt: .now, memoryBytes: 1)
    #expect(cursor.resumeCommand == nil)
  }

  @Test func onlyUUIDsGiveACommand() {
    let unsafe = [
      "--dangerously-skip-permissions", "x; rm -rf ~", "$(id)", "", "s1",
      "-0b7c4f1e-9d2a-4c3b-8e5f-1a2b3c4d5e6f", "0b7c4f1e-9d2a-4c3b-8e5f-1a2b3c4d5e6f; id",
    ]
    for id in unsafe {
      #expect(EndedSession.fixture(id: id, endedAt: .now).resumeCommand == nil, "\(id)")
    }
    let uuid = "0B7C4F1E-9d2a-4c3b-8e5f-1a2b3c4d5e6f"
    #expect(
      EndedSession.fixture(id: uuid, endedAt: .now).resumeCommand
        == "cd '/x' && claude --resume \(uuid)")
  }

  /// A control character acts on the terminal's line editor even inside single quotes: Ctrl-U
  /// wipes the line, an end-of-paste escape ends bracketed paste early.
  @Test func controlCharactersInTheFolderGiveNoCommand() {
    let folders = [
      "/x\u{15}touch /tmp/pwned\r", "/x\u{1b}[201~touch /tmp/pwned\r", "/x\u{7f}", "/x\u{85}",
      "/x\ny", "/x\ry", "/x\ty",
    ]
    for folder in folders {
      let session = EndedSession(
        id: .uuid(1), tool: .claudeCode, directory: folder, name: nil, idleSince: nil,
        endedAt: .now, memoryBytes: 1)
      #expect(session.resumeCommand == nil, "\(folder.debugDescription)")
    }
    let accented = EndedSession(
      id: .uuid(1), tool: .codexCLI, directory: "/Users/me/café ✓", name: nil, idleSince: nil,
      endedAt: .now, memoryBytes: 1)
    #expect(accented.resumeCommand == "cd '/Users/me/café ✓' && codex resume \(String.uuid(1))")
  }

  @Test func keepsThirtyDaysAndNewestFirst() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var log = EndedSessionLog()
    log.record(.fixture(id: .uuid(1), endedAt: now.addingTimeInterval(-31 * 86_400)), now: now)
    log.record(.fixture(id: .uuid(2), endedAt: now), now: now)
    #expect(log.sessions.map(\.id) == [.uuid(2)])
  }

  @Test func reRecordingReplacesAndMovesToTop() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var log = EndedSessionLog()
    log.record(.fixture(id: .uuid(1), endedAt: now.addingTimeInterval(-60)), now: now)
    log.record(.fixture(id: .uuid(2), endedAt: now.addingTimeInterval(-30)), now: now)
    log.record(.fixture(id: .uuid(1), endedAt: now), now: now)
    #expect(log.sessions.map(\.id) == [.uuid(1), .uuid(2)])
    #expect(log.sessions.first?.endedAt == now)
  }

  @Test func capsTheLog() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var log = EndedSessionLog()
    for index in 0...EndedSessionLog.limit {
      log.record(.fixture(id: .uuid(index), endedAt: now), now: now)
    }
    #expect(log.sessions.count == EndedSessionLog.limit)
    #expect(log.sessions.first?.id == .uuid(EndedSessionLog.limit))
    #expect(!log.sessions.contains { $0.id == .uuid(0) })
  }

  @Test func savesAndLoads() {
    let temporary = TestDefaults("ended-sessions")
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var log = EndedSessionLog()
    log.record(
      EndedSession(
        id: .uuid(1), tool: .codexCLI, directory: "/code/b", name: "notes",
        idleSince: now.addingTimeInterval(-3_600), endedAt: now, memoryBytes: 42),
      now: now)
    log.record(.fixture(id: .uuid(2), endedAt: now), now: now)
    log.save(temporary.defaults)
    #expect(EndedSessionLog.load(temporary.defaults, now: now) == log)
  }

  @Test func loadDropsSessionsPastThirtyDays() {
    let temporary = TestDefaults("ended-sessions")
    let then = Date(timeIntervalSince1970: 2_000_000_000)
    var log = EndedSessionLog()
    log.record(.fixture(id: .uuid(1), endedAt: then), now: then)
    log.record(.fixture(id: .uuid(2), endedAt: then.addingTimeInterval(20 * 86_400)), now: then)
    log.save(temporary.defaults)
    let later = then.addingTimeInterval(31 * 86_400)
    #expect(EndedSessionLog.load(temporary.defaults, now: later).sessions.map(\.id) == [.uuid(2)])
  }

  @Test func unreadableEntryIsSkippedAndPreserved() throws {
    let temporary = TestDefaults("ended-sessions")
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var log = EndedSessionLog()
    log.record(.fixture(id: .uuid(1), endedAt: now), now: now)
    log.save(temporary.defaults)
    let saved = try #require(temporary.defaults.data(forKey: EndedSessionLog.defaultsKey))
    var entries = try #require(try JSONSerialization.jsonObject(with: saved) as? [[String: Any]])
    var future = try #require(entries.first)
    future["id"] = String.uuid(2)
    future["tool"] = "futureAgent"
    entries.insert(future, at: 0)
    entries.append(["id": String.uuid(3)])
    let stored = try JSONSerialization.data(withJSONObject: entries)
    temporary.defaults.set(stored, forKey: EndedSessionLog.defaultsKey)
    #expect(EndedSessionLog.load(temporary.defaults, now: now).sessions.map(\.id) == [.uuid(1)])
    #expect(temporary.defaults.data(forKey: EndedSessionLog.defaultsKey + ".unreadable") == stored)
  }

  @Test func corruptBlobLoadsEmpty() {
    let temporary = TestDefaults("ended-sessions")
    temporary.defaults.set(Data("not json".utf8), forKey: EndedSessionLog.defaultsKey)
    #expect(EndedSessionLog.load(temporary.defaults).sessions.isEmpty)
    temporary.defaults.set("a string", forKey: EndedSessionLog.defaultsKey)
    #expect(EndedSessionLog.load(temporary.defaults).sessions.isEmpty)
  }

  /// A session still running keeps its entry but shows no resume command.
  @Test func liveSessionsAreHidden() {
    let stored = "6F1C2A52-6D1E-4C5E-9A4F-1F2E3D4C5B6A"
    var log = EndedSessionLog()
    log.record(.fixture(id: stored, endedAt: .now), now: .now)
    log.record(.fixture(id: .uuid(2), endedAt: .now), now: .now)
    #expect(log.visible(liveSessionIDs: [stored.lowercased()]).map(\.id) == [.uuid(2)])
    #expect(log.visible(liveSessionIDs: []).count == 2)
    #expect(log.sessions.count == 2)
    let lower = "0b7c4f1e-9d2a-4c3b-8e5f-1a2b3c4d5e6f"
    log.record(.fixture(id: lower, endedAt: .now), now: .now)
    #expect(!log.visible(liveSessionIDs: [lower.uppercased()]).contains { $0.id == lower })
  }
}

extension EndedSession {
  static func fixture(id: String, endedAt: Date) -> Self {
    .init(
      id: id, tool: .claudeCode, directory: "/x", name: nil, idleSince: nil,
      endedAt: endedAt, memoryBytes: 1)
  }
}

extension String {
  /// A fixed UUID string per number, so fixtures read as real session ids.
  fileprivate static func uuid(_ number: Int) -> String {
    "00000000-0000-4000-8000-" + String(format: "%012d", number)
  }
}
