import Foundation
import Testing

@testable import Tamebar

struct CurrentActivityTests {
  @Test func endedHistoryDoesNotAppearInCurrentActivity() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let ended = StoppedEntry(
      id: "ended:1", kind: .session, name: "old-project", stoppedAt: now,
      state: .ended, reason: .idle(days: 3), command: "claude --resume 1", target: .ended("1"))
    let plugin = StoppedEntry(
      id: "codex:context7", kind: .codexPlugin, name: "context7", stoppedAt: now,
      state: .off, reason: .unused(days: 30), target: .codexPlugin("server:context7"))
    let activity = CurrentActivity(
      stopped: [ended, plugin],
      slowed: [.init(id: "ai:1", name: "Claude · platform", kind: .session)])

    #expect(activity.paused.isEmpty)
    #expect(activity.quitApps.isEmpty)
    #expect(activity.pluginsOff == [plugin])
    #expect(
      activity.cardLines == [
        "Slowed now: Claude · platform",
        "1 Codex plugin off · optional",
      ])
    #expect(!activity.cardLines.joined().contains("old-project"))
  }
}
