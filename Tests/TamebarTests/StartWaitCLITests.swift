import Darwin
import Foundation
import Testing

@testable import Tamebar

/// Q19 in the command line: `tamebar wait` (the start hook), `tamebar start <project|all>`, the
/// Strain line of `tamebar status`, the Struggling column of `tamebar trend`, and the card's
/// "Waiting for memory" block.
struct StartWaitCLITests {
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("TamebarTests-WaitCLI-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func registration(_ pid: Int32, project: String, at second: TimeInterval = 0)
    -> StartWait.Registration
  {
    .init(
      waitPID: pid, waitStart: Double(pid), agentPID: pid + 1000, tool: "claude",
      directory: "/code/\(project)", project: project, sessionID: nil,
      started: t0.addingTimeInterval(second))
  }

  func environment(
    _ root: URL, live: Set<Int32>, out: @escaping (String) -> Void = { _ in },
    err: @escaping (String) -> Void = { _ in }
  ) -> CLIEnvironment {
    var env = CLIEnvironment.fixture(directory: root, out: out, err: err)
    env.startTime = { live.contains($0) ? Double($0) : nil }
    let now = t0.addingTimeInterval(75)
    return CLIEnvironment(
      directory: env.directory, defaults: env.defaults, now: { now }, timeZone: env.timeZone,
      system: env.system, sessions: env.sessions, tamebarPID: env.tamebarPID, label: env.label,
      out: env.out, err: env.err, runningApps: env.runningApps, startTime: env.startTime)
  }

  @Test func parsesWaitAndStart() throws {
    #expect(try CLI.parse(["wait"]).get() == .wait)
    #expect(try CLI.parse(["wait", "--help"]).get() == .help("wait"))
    #expect(try CLI.parse(["start", "dashboard-app"]).get() == .start("dashboard-app"))
    #expect(try CLI.parse(["start", "all"]).get() == .start("all"))
    #expect(try CLI.parse(["start", "--help"]).get() == .help("start"))
    #expect(try CLI.parse(["help", "wait"]).get() == .help("wait"))
    for bad in [["wait", "now"], ["start"], ["start", "--json"]] {
      #expect(throws: CLI.UsageError.self) { try CLI.parse(bad).get() }
    }
    var out = ""
    #expect(CLI.run(["--help"], .fixture(out: { out += $0 })) == 0)
    #expect(out.contains("tamebar wait") && out.contains("tamebar start <project|all>"))
  }

  @Test func startReleasesTheProjectsSessionsAndSaysSo() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    try StartWait.register(registration(11, project: "dashboard-app"), directory: root)
    try StartWait.register(registration(12, project: "web", at: 30), directory: root)
    try StartWait.register(registration(13, project: "gone"), directory: root)
    var out = ""
    let code = CLI.run(
      ["start", "dashboard-app"], environment(root, live: [11, 12], out: { out += $0 }))
    #expect(code == 0)
    #expect(out == "Started dashboard-app · Claude (waited 1m).\n")
    #expect(StartWait.isReleased(11, directory: root))
    #expect(!StartWait.isReleased(12, directory: root))
    #expect(StartWait.list(root).map(\.waitPID) == [11, 12], "the dead one is pruned")

    var err = ""
    #expect(
      CLI.run(["start", "nope"], environment(root, live: [11, 12], err: { err += $0 })) == 1)
    #expect(err == "tamebar: nothing waiting for memory in nope. Waiting: web.\n")
    out = ""
    #expect(CLI.run(["start", "all"], environment(root, live: [11, 12], out: { out += $0 })) == 0)
    #expect(out == "Started web · Claude (waited 45s).\n", "11 was already started")
    err = ""
    #expect(CLI.run(["start", "all"], environment(root, live: [], err: { err += $0 })) == 1)
    #expect(err == "tamebar: nothing is waiting for memory.\n")
  }

  @Test func statusNamesTheStrainAndWhatWaits() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    StrainFile(
      pid: 42, pidStart: 42, struggling: true, since: t0,
      signals: [.init(kind: .fan, value: 78.2)], updated: t0
    ).write(root)
    try StartWait.register(registration(11, project: "dashboard-app"), directory: root)
    var out = ""
    #expect(CLI.run(["status"], environment(root, live: [11, 42], out: { out += $0 })) == 0)
    #expect(out.contains("Strain   struggling (fan 78%)\n"))
    #expect(out.contains("Waiting  dashboard-app · Claude, 1m · tamebar start dashboard-app\n"))
    out = ""
    #expect(
      CLI.run(["status", "--json"], environment(root, live: [11, 42], out: { out += $0 })) == 0)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    let strain = try #require(object["strain"] as? [String: Any])
    #expect(strain["struggling"] as? Bool == true)
    let signal = try #require((strain["signals"] as? [[String: Any]])?.first)
    #expect(signal["kind"] as? String == "fan" && signal["text"] as? String == "fan 78%")
    let waiting = try #require((strain["waiting"] as? [[String: Any]])?.first)
    #expect(waiting["project"] as? String == "dashboard-app")
    #expect(waiting["tool_name"] as? String == "Claude")
    #expect(waiting["wait_pid"] as? Int == 11 && waiting["waited_seconds"] as? Int == 75)

    out = ""
    #expect(CLI.run(["status"], environment(root, live: [], out: { out += $0 })) == 0)
    #expect(out.contains("Strain   unknown, Tamebar isn't running\n"))
    #expect(!out.contains("Waiting "))
    StrainFile(pid: 42, pidStart: 42, struggling: false, signals: [], updated: t0).write(root)
    out = ""
    #expect(CLI.run(["status"], environment(root, live: [42], out: { out += $0 })) == 0)
    #expect(out.contains("Strain   none\n"))
  }

  @Test func waitReturnsAtOnceWithoutARunningTamebar() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let started = Date()
    #expect(
      StartWaitLive.run(directory: root, input: Data(#"{"source":"startup"}"#.utf8)) == 0)
    StrainFile(pid: 99_999, pidStart: 1, struggling: true, signals: [], updated: t0).write(root)
    #expect(
      StartWaitLive.run(directory: root, input: Data(#"{"source":"startup"}"#.utf8)) == 0)
    // The test process wrote it and is struggling, but a resume never waits.
    StrainFile(pid: getpid(), struggling: true, signals: [], updated: t0).write(root)
    #expect(StartWaitLive.run(directory: root, input: Data(#"{"source":"resume"}"#.utf8)) == 0)
    #expect(Date().timeIntervalSince(started) < 1)
    #expect(StartWait.list(root).isEmpty)
  }

  // MARK: The usage record and the trend

  @Test func theDayCountsTimeStrugglingWhileInUse() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    var record = UsageRecord()
    var previous: UsageReading?
    // Every 30 s: struggling from 60 to 180 in use, and from 240 to 300 while away.
    for second in stride(from: 0.0, through: 300, by: 30) {
      let struggling = (60..<180).contains(second) || (240..<300).contains(second)
      let present = !(240..<300).contains(second)
      let reading = UsageReading(
        date: t0.addingTimeInterval(second), present: present, struggling: struggling)
      record.observe(reading, after: previous, calendar: calendar)
      previous = reading
    }
    let day = try #require(record.days.first)
    #expect(day.strugglingSeconds == 120, "60–180 in use; 240–300 away")
    #expect(day.strugglingShare.map { ($0 * 100).rounded() } == 50)
    // A reading from a Tamebar that doesn't judge the strain adds nothing.
    var old = UsageRecord()
    let first = UsageReading(date: t0, present: true)
    old.observe(first, after: nil, calendar: calendar)
    old.observe(
      UsageReading(date: t0.addingTimeInterval(60), present: true), after: first,
      calendar: calendar)
    #expect(old.days.first?.strugglingSeconds == nil)
  }

  @Test func theTrendHasAStrugglingColumnAndComparesIt() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    var before = UsageDay(day: "2026-10-28")
    before.awakeSeconds = 3_600
    before.inUseSeconds = 3_600
    var after = UsageDay(day: "2026-10-31")
    after.awakeSeconds = 3_600
    after.inUseSeconds = 3_600
    after.strugglingSeconds = 600
    let trend = CLITrendReport.day(after)
    #expect(trend.strugglingMinutes == 10 && trend.strugglingPercent == 16.7)
    #expect(CLITrendReport.day(before).strugglingMinutes == nil)
    let row = CLITrendText.row(trend, calendar)
    #expect(row.contains("10m"))
    let header = CLITrendText.render(
      .init(
        generatedAt: t0, windowDays: 14, tamebarRunning: true, notes: [], days: [trend],
        markers: [], compare: nil), comparison: nil, calendar: calendar)
    #expect(header.hasPrefix("Day     Awake  Pressure        Critical  Struggling  Swap peak"))
    var earlier = UsageDay(day: "2026-10-29")
    earlier.awakeSeconds = 3_600
    earlier.inUseSeconds = 3_600
    earlier.strugglingSeconds = 1_800
    let comparison = UsageComparison.from(day: "2026-10-30", days: [earlier, after])
    #expect(comparison.text.contains("Struggling       30 min → 10 min a day"))
  }

  // MARK: The card

  func snapshot() -> SystemSnapshot {
    SystemSnapshot(
      .init(
        diskAvailable: 1, diskTotal: 2, ramAvailable: 1, ramTotal: 2, memoryPressure: .warning,
        cpuUsage: 0.1, thermalStatus: .nominal, updatedAt: t0))
  }

  @Test func theCardListsWhatWaitsOnlyWhileSomethingDoes() {
    #expect(UsageCardContent(snapshot: snapshot(), now: t0).waiting.isEmpty)
    let content = UsageCardContent(
      snapshot: snapshot(), now: t0.addingTimeInterval(65),
      waiting: [registration(11, project: "dashboard-app")])
    #expect(content.waiting == [.init(id: 11, label: "dashboard-app · Claude", waited: "1m")])
    #expect(UsageCardContent.waitingTitle == "Waiting for memory")
    #expect(UsageCardContent.waitingFooter == "They start on their own when it eases.")
  }

  @Test func theWaitingBlockIsAButtonRowAboveActivity() {
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
    let card = CGSize(width: 360, height: 400)
    let activity = IslandCardMotion.activityRows(in: bounds, card: card, count: 2)
    let block = IslandCardMotion.waitingBlock(
      in: bounds, card: card, activityRows: 2, count: 2)
    #expect(block.minY == activity.maxY + 1)
    #expect(block.height == UsageCardView.waitingHeight(2))
    let point = CGPoint(x: 200, y: block.midY)
    #expect(
      IslandCardMotion.isOnButtonRow(point, in: bounds, card: card, activityRows: 2, waiting: 2))
    #expect(!IslandCardMotion.isOnButtonRow(point, in: bounds, card: card, activityRows: 2))
    let alone = IslandCardMotion.waitingBlock(
      in: bounds, card: card, activityRows: 0, count: 1)
    #expect(alone.minY == UsageCardView.actionRowHeight + 1)
  }
}
