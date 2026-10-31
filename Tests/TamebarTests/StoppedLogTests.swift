import Foundation
import Testing

@testable import Tamebar

/// The Stopped list (Q15): one log, derived from the ledgers, of what Tamebar stopped and how to
/// bring it back.
struct StoppedLogTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let utc = TimeZone(identifier: "UTC")!

  private func thread(
    _ id: String, directory: String, session: String? = nil, bytes: UInt64 = 600_000_000,
    paused: Bool = true
  ) -> AIThread {
    var thread = AIThread(
      id: id, tool: .claudeCode, name: "Claude Code", directory: directory, terminal: nil,
      startedAt: nil, processIDs: [1], memoryBytes: bytes, cpuPercent: 0, isPaused: paused,
      isDetached: false)
    thread.sessionID = session
    return thread
  }

  private func ended(
    _ id: String, folder: String, endedAgo: TimeInterval, idleDays: Double? = 3,
    automatic: Bool? = true
  ) -> EndedSession {
    let endedAt = now.addingTimeInterval(-endedAgo)
    return EndedSession(
      id: id, tool: .claudeCode, directory: folder, name: nil,
      idleSince: idleDays.map { endedAt.addingTimeInterval(-$0 * 86_400) }, endedAt: endedAt,
      memoryBytes: 2_000_000_000, automatic: automatic)
  }

  private let atlasID = "601f93df-0000-4000-8000-000000000001"

  private func input() -> StoppedLog.Input {
    var input = StoppedLog.Input(now: now)
    input.ledger = [
      .init(threadID: "claudeCode-4242-1799990000", reason: .meeting, since: now - 600),
      .init(threadID: "project:/code/web", reason: .pressure, since: now - 1_200),
    ]
    input.threads = [thread("claudeCode-4242-1799990000", directory: "/code/Agent")]
    input.projectBytes = ["/code/web": 300_000_000]
    input.ended = [ended(atlasID, folder: "/code/Atlas", endedAgo: 3_600)]
    input.quitApps = [
      QuitApp(
        bundleID: "com.docker.docker", name: "Docker Desktop",
        bundleURL: URL(fileURLWithPath: "/Applications/Docker.app"), memoryBytes: 9_000_000_000,
        quitAt: now - 300)
    ]
    input.appLedger = [
      .init(
        bundleID: "com.loom.desktop", name: "Loom",
        bundleURL: URL(fileURLWithPath: "/Applications/Loom.app"), memoryBytes: 1_200_000_000,
        quitAt: now - 900, confirmed: true)
    ]
    return input
  }

  @Test func holdsPausedEndedAndQuitInTheTraysOrder() {
    let entries = StoppedLog.entries(input())
    #expect(
      entries.map(\.id) == [
        "paused:claudeCode-4242-1799990000", "paused:project:/code/web", "ended:\(atlasID)",
        "app:com.docker.docker", "app:com.loom.desktop",
      ])
    let agent = entries[0]
    #expect(agent.kind == .session && agent.name == "Agent" && agent.state == .paused)
    #expect(agent.reason == .call && agent.memoryBytes == 600_000_000 && agent.command == nil)
    #expect(agent.target == .ledger("claudeCode-4242-1799990000"))
    #expect(entries[1].kind == .project && entries[1].name == "web")
    #expect(entries[1].memoryBytes == 300_000_000 && entries[1].reason == .memory)
    let atlas = entries[2]
    #expect(atlas.name == "Atlas" && atlas.state == .ended && atlas.reason == .idle(days: 3))
    #expect(atlas.command == "cd '/code/Atlas' && claude --resume \(atlasID)")
    let docker = entries[3]
    #expect(docker.reason == .byYou && docker.command == "open -a Docker")
    #expect(entries[4].reason == .memory && entries[4].command == "open -a Loom")
  }

  /// The terminal mock: what needs your command first.
  @Test func commandOrderPutsAppsThenEndedThenWhatComesBackOnItsOwn() {
    let ordered = StoppedLog.commandOrder(StoppedLog.entries(input()))
    #expect(ordered.map(\.state) == [.quit, .quit, .ended, .paused, .paused])
    #expect(ordered.first?.name == "Docker Desktop")
  }

  @Test func anEntryLeavesWhenItIsBack() {
    var input = input()
    // The session runs again, the app was relaunched after its quit, the pause was resumed.
    input.threads.append(thread("claudeCode-9-1", directory: "/code/Atlas", session: atlasID))
    let running: [String: Date?] = ["com.docker.docker": now - 10, "com.loom.desktop": nil]
    input.running = running
    input.ledger.removeFirst()
    #expect(StoppedLog.entries(input).map(\.id) == ["paused:project:/code/web"])
  }

  /// An app still listed with a launch before its quit is the one being quit, not back.
  @Test func anAppLaunchedBeforeItsQuitIsNotBack() {
    var input = input()
    input.running = ["com.docker.docker": now - 86_400]
    #expect(StoppedLog.entries(input).contains { $0.id == "app:com.docker.docker" })
  }

  @Test func keptThirtyDays() {
    var input = input()
    input.ended = [
      ended(atlasID, folder: "/code/Atlas", endedAgo: 29 * 86_400),
      ended(
        "701f93df-0000-4000-8000-000000000002", folder: "/code/old", endedAgo: 31 * 86_400),
    ]
    #expect(StoppedLog.entries(input).filter { $0.state == .ended }.map(\.name) == ["Atlas"])
  }

  /// Q11's quit still in flight isn't stopped yet; one app twice is listed once, the latest.
  @Test func anUnconfirmedQuitIsLeftOutAndAnAppIsListedOnce() {
    var input = input()
    input.appLedger = [
      .init(
        bundleID: "com.loom.desktop", name: "Loom",
        bundleURL: URL(fileURLWithPath: "/Applications/Loom.app"), memoryBytes: 1,
        quitAt: now - 5, confirmed: false),
      .init(
        bundleID: "com.docker.docker", name: "Docker Desktop",
        bundleURL: URL(fileURLWithPath: "/Applications/Docker.app"), memoryBytes: 1,
        quitAt: now - 9_000, confirmed: true),
    ]
    let apps = StoppedLog.entries(input).filter { $0.kind == .app }
    #expect(apps.map(\.id) == ["app:com.docker.docker"])
    #expect(apps.first?.reason == .byYou)
  }

  @Test func endedReasonFromTheFlag() {
    func reason(_ automatic: Bool?, idle: Double?) -> StoppedEntry.Reason? {
      var input = StoppedLog.Input(now: now)
      input.ended = [
        ended(atlasID, folder: "/code/Atlas", endedAgo: 60, idleDays: idle, automatic: automatic)
      ]
      return StoppedLog.entries(input).first?.reason
    }
    #expect(reason(true, idle: 9.5) == .idle(days: 9))
    #expect(reason(false, idle: 9.5) == .byYou)
    #expect(reason(nil, idle: 2) == .idle(days: 2))
    #expect(reason(nil, idle: nil) == .byYou)
  }

  @Test func openCommandQuotesWhatIsNotPlain() {
    #expect(
      StoppedLog.openCommand(
        bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
        bundleID: "com.google.Chrome") == "open -a 'Google Chrome'")
    #expect(
      StoppedLog.openCommand(bundleURL: URL(fileURLWithPath: "/"), bundleID: "com.x.y")
        == "open -b com.x.y")
  }

  @Test func trayWordsFollowTheMock() {
    let entries = StoppedLog.entries(input())
    let words = entries.map { $0.trayDetail(now: now, timeZone: utc) }
    #expect(
      words == [
        "paused · call", "paused · memory", "ended · idle 3d", "quit 07:55", "quit · memory",
      ])
    #expect(entries.map(\.actionTitle) == ["Resume", "Resume", "Resume", "Reopen", "Reopen"])
  }

  /// Q19: a session an older build queued (Q14) reads paused for memory, with Resume, until the
  /// first tick resumes it.
  @Test func aSessionAnOlderBuildQueuedReadsPaused() throws {
    var input = StoppedLog.Input(now: now)
    input.ledger = [.init(threadID: "claudeCode-4242-1799990000", reason: .queue, since: now)]
    input.threads = [thread("claudeCode-4242-1799990000", directory: "/code/web-frontend")]
    let entry = try #require(StoppedLog.entries(input).first)
    #expect(entry.state == .paused)
    #expect(entry.trayDetail(now: now, timeZone: utc) == "paused · memory")
    #expect(entry.actionTitle == "Resume")
  }

  @Test func commandWordsFollowTheMock() {
    let entries = StoppedLog.entries(input())
    #expect(
      entries.map(\.commandDetail) == [
        "paused · call · comes back when the call ends",
        "paused · memory · comes back when memory recovers",
        "ended · idle 3 days",
        "quit by you, from Tamebar",
        "quit · memory · reopens when memory recovers",
      ])
  }

  @Test func quitAppLogKeepsOnePerAppAndDropsTheOnesBack() {
    var log = QuitAppLog()
    let url = URL(fileURLWithPath: "/Applications/Slack.app")
    log.record(
      .init(bundleID: "s", name: "Slack", bundleURL: url, memoryBytes: 1, quitAt: now - 60),
      now: now)
    log.record(
      .init(bundleID: "s", name: "Slack", bundleURL: url, memoryBytes: 2, quitAt: now), now: now)
    #expect(log.apps.count == 1 && log.apps[0].memoryBytes == 2)
    let stillQuitting = log.dropBack(running: ["s": now - 5])
    #expect(!stillQuitting)
    let relaunched = log.dropBack(running: ["s": now + 5])
    #expect(relaunched)
    #expect(log.apps.isEmpty)
    log.record(
      .init(
        bundleID: "s", name: "Slack", bundleURL: url, memoryBytes: 1, quitAt: now - 31 * 86_400),
      now: now)
    #expect(log.apps.isEmpty)
  }

  @Test func quitAppLogRoundTripsAndSkipsWhatItCannotRead() throws {
    let defaults = TestDefaults("stopped").defaults
    var log = QuitAppLog()
    log.record(
      .init(
        bundleID: "s", name: "Slack", bundleURL: URL(fileURLWithPath: "/Applications/Slack.app"),
        memoryBytes: 1, quitAt: now), now: now)
    log.save(defaults)
    #expect(QuitAppLog.load(defaults, now: now) == log)
    let saved = try #require(defaults.data(forKey: QuitAppLog.defaultsKey))
    var array = try #require(try JSONSerialization.jsonObject(with: saved) as? [Any])
    array.append(["bundleID": 3])
    defaults.set(try JSONSerialization.data(withJSONObject: array), forKey: QuitAppLog.defaultsKey)
    #expect(QuitAppLog.load(defaults, now: now) == log)
  }
}
