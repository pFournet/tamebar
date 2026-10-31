import Foundation
import Testing

@testable import Tamebar

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func app(
  _ name: String = "ChatGPT", cpu: Double, pids: [Int32] = [11], front: Bool = false,
  mic: Bool? = false, optedOut: Bool = false, own: Bool = false
) -> AppSlow.App {
  .init(
    group: "app:\(name)", bundleID: "com.example.\(name.lowercased())", name: name,
    cpuPercent: cpu, processIDs: pids, isFrontmost: front, usesMicOrCamera: mic,
    optedOut: optedOut, isOwn: own)
}

/// Q17.1: background apps that burn CPU get Q12's lever, and every way it is undone.
enum AppSlowTests {}

extension AppSlowTests {
  struct Planner {
    /// Ticks every 15 s from `from` to `to` (inclusive) with the same apps.
    private func run(
      _ clock: inout AppSlow.Clock, from: TimeInterval, to: TimeInterval, _ apps: [AppSlow.App],
      slowed: Set<String> = []
    ) -> AppSlow.Plan {
      var plan = AppSlow.Plan()
      var second = from
      while second <= to {
        plan = AppSlow.plan(&clock, now: t0.addingTimeInterval(second), apps: apps, slowed: slowed)
        second += 15
      }
      return plan
    }

    @Test func startsOnlyAfterTwoMinutesAboveTheThresholdInARow() {
      var clock = AppSlow.Clock()
      let busy = [app(cpu: 490)]
      #expect(run(&clock, from: 0, to: 105, busy).start.isEmpty)
      let plan = AppSlow.plan(&clock, now: t0.addingTimeInterval(120), apps: busy, slowed: [])
      #expect(plan.start.map(\.group) == ["app:ChatGPT"])
    }

    /// Q19: once one app's trigger fires, every app busy in the background now is slowed in the
    /// same tick, without waiting for its own two minutes; never one excluded or under the
    /// threshold.
    @Test func whenOneFiresEveryBusyBackgroundAppIsSlowedTogether() {
      var clock = AppSlow.Clock()
      _ = run(&clock, from: 0, to: 60, [app(cpu: 490)])
      let all = [
        app("ChatGPT", cpu: 490), app("Chrome", cpu: 200), app("Slack", cpu: 160),
        app("Music", cpu: 40), app("Zoom", cpu: 300, mic: true),
        app("Xcode", cpu: 400, front: true),
      ]
      #expect(run(&clock, from: 75, to: 105, all).start.isEmpty)
      let plan = AppSlow.plan(&clock, now: t0.addingTimeInterval(120), apps: all, slowed: [])
      #expect(plan.start.map(\.group) == ["app:ChatGPT", "app:Chrome", "app:Slack"])
      // Nothing fires: a busy app alone under its two minutes still waits.
      var fresh = AppSlow.Clock()
      #expect(
        AppSlow.plan(&fresh, now: t0, apps: [app("Chrome", cpu: 200)], slowed: []).start.isEmpty)
    }

    @Test func fifteenSecondsUnderTheThresholdStartTheTwoMinutesAgain() {
      var clock = AppSlow.Clock()
      _ = run(&clock, from: 0, to: 90, [app(cpu: 300)])
      _ = run(&clock, from: 105, to: 120, [app(cpu: 150)])
      #expect(run(&clock, from: 135, to: 240, [app(cpu: 300)]).start.isEmpty)
      let plan = AppSlow.plan(
        &clock, now: t0.addingTimeInterval(255), apps: [app(cpu: 300)], slowed: [])
      #expect(plan.start.count == 1)
    }

    @Test func oneLowReadingDoesNotBreakTheTwoMinutes() {
      // `ps` reads a starved process low now and then; a dip shorter than 15 s doesn't count.
      var clock = AppSlow.Clock()
      _ = run(&clock, from: 0, to: 60, [app(cpu: 300)])
      _ = AppSlow.plan(&clock, now: t0.addingTimeInterval(65), apps: [app(cpu: 24)], slowed: [])
      _ = AppSlow.plan(&clock, now: t0.addingTimeInterval(75), apps: [app(cpu: 120)], slowed: [])
      #expect(
        AppSlow.plan(&clock, now: t0.addingTimeInterval(78), apps: [app(cpu: 300)], slowed: [])
          .start.isEmpty)
      let plan = AppSlow.plan(
        &clock, now: t0.addingTimeInterval(120), apps: [app(cpu: 300)], slowed: [])
      #expect(plan.start.count == 1)
    }

    @Test func neverTheFrontAppAnAppOnTheMicOrCameraAnOptedOutAppOrTamebar() {
      for excluded in [
        app(cpu: 490, front: true), app(cpu: 490, mic: true), app(cpu: 490, mic: nil),
        app(cpu: 490, optedOut: true), app(cpu: 490, own: true),
      ] {
        var clock = AppSlow.Clock()
        #expect(run(&clock, from: 0, to: 600, [excluded]).start.isEmpty)
      }
    }

    @Test func aSlowedAppIsHeldWhileBusyAndRestoredAtOnceInFront() {
      var clock = AppSlow.Clock()
      _ = run(&clock, from: 0, to: 120, [app(cpu: 490)])
      let held = AppSlow.plan(
        &clock, now: t0.addingTimeInterval(135), apps: [app(cpu: 490)], slowed: ["app:ChatGPT"])
      #expect(held.hold.map(\.group) == ["app:ChatGPT"])
      #expect(held.start.isEmpty && held.restore.isEmpty)
      let front = AppSlow.plan(
        &clock, now: t0.addingTimeInterval(150), apps: [app(cpu: 490, front: true)],
        slowed: ["app:ChatGPT"])
      #expect(front.restore == ["app:ChatGPT"])
      // Back in the background, it needs two whole minutes again.
      let back = run(&clock, from: 165, to: 270, [app(cpu: 490)])
      #expect(back.start.isEmpty)
      #expect(
        AppSlow.plan(&clock, now: t0.addingTimeInterval(285), apps: [app(cpu: 490)], slowed: [])
          .start.count == 1)
    }

    @Test func micCameraOrOptOutRestoresAtOnce() {
      for excluded in [app(cpu: 490, mic: true), app(cpu: 490, optedOut: true)] {
        var clock = AppSlow.Clock()
        let plan = AppSlow.plan(
          &clock, now: t0, apps: [excluded], slowed: ["app:ChatGPT"])
        #expect(plan.restore == ["app:ChatGPT"])
      }
    }

    @Test func restoredOnlyOnceUnderFiftyPercentForSixtySeconds() {
      var clock = AppSlow.Clock()
      let slowed: Set<String> = ["app:ChatGPT"]
      // Between 50 % and 150 %: held, and no calm clock.
      #expect(run(&clock, from: 0, to: 120, [app(cpu: 100)], slowed: slowed).restore.isEmpty)
      #expect(run(&clock, from: 135, to: 180, [app(cpu: 40)], slowed: slowed).restore.isEmpty)
      // One reading back up restarts the calm.
      _ = AppSlow.plan(
        &clock, now: t0.addingTimeInterval(195), apps: [app(cpu: 60)], slowed: slowed)
      #expect(run(&clock, from: 210, to: 255, [app(cpu: 40)], slowed: slowed).restore.isEmpty)
      let plan = AppSlow.plan(
        &clock, now: t0.addingTimeInterval(270), apps: [app(cpu: 40)], slowed: slowed)
      #expect(plan.restore == ["app:ChatGPT"])
    }

    @Test func aSlowedAppThatIsGoneIsRestored() {
      var clock = AppSlow.Clock()
      let plan = AppSlow.plan(&clock, now: t0, apps: [], slowed: ["app:ChatGPT"])
      #expect(plan.restore == ["app:ChatGPT"])
    }

    @Test func aSleepStartsTheTwoMinutesAfresh() {
      var clock = AppSlow.Clock()
      _ = run(&clock, from: 0, to: 105, [app(cpu: 490)])
      // Asleep for ten minutes: the readings before don't count.
      #expect(run(&clock, from: 705, to: 810, [app(cpu: 490)]).start.isEmpty)
      #expect(
        AppSlow.plan(&clock, now: t0.addingTimeInterval(825), apps: [app(cpu: 490)], slowed: [])
          .start.count == 1)
    }

    @Test func theNoteNamesTheBusiestApp() {
      #expect(AppSlow.note([]) == nil)
      #expect(AppSlow.note([("ChatGPT", 489.6)]) == "Slowed ChatGPT · 490% CPU")
      #expect(
        AppSlow.note([("Chrome", 180), ("ChatGPT", 490)])
          == "Slowed ChatGPT and 1 more app · 490% CPU")
      #expect(
        AppSlow.note([("Chrome", 180), ("ChatGPT", 490), ("Slack", 160)])
          == "Slowed ChatGPT and 2 more apps · 490% CPU")
    }
  }

  struct Heavy {
    private func record(_ pid: Int32, cpu: Double, parent: Int32 = 1, _ arguments: String)
      -> RawProcessRecord
    {
      .init(
        processID: pid, parentProcessID: parent, userID: 501, cpuPercent: cpu,
        residentKilobytes: 0, elapsed: "", terminal: nil, arguments: arguments)
    }

    @Test func slowsTheAppsBusyProcessesButNoAgentAndNothingOnAServersLine() {
      let records: [Int32: RawProcessRecord] = [
        10: record(10, cpu: 5, "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"),
        11: record(
          11, cpu: 300, parent: 10, "/Applications/ChatGPT.app/Contents/Frameworks/Helper"),
        12: record(
          12, cpu: 80, parent: 10, "/Applications/ChatGPT.app/Contents/Resources/codex app-server"),
        13: record(13, cpu: 60, parent: 10, "/Applications/ChatGPT.app/Contents/Frameworks/Server"),
        14: record(14, cpu: 9, parent: 10, "/Applications/ChatGPT.app/Contents/Frameworks/Idle"),
      ]
      let pids = AppSlow.heavy(
        [10, 11, 12, 13, 14], scan: .init(records: records, serving: [13], keptDirectories: []))
      #expect(pids == [11])
    }
  }

  struct Watch {
    @Test func anAIAppIsQuietOnlyAfterFiveMinutesUnderFivePercentOverItsTree() {
      var watch = AppCPUWatch()
      let id = "com.openai.codex"
      var second: TimeInterval = 0
      while second <= 285 {
        watch.observe(now: t0.addingTimeInterval(second), apps: [id: .init(row: 1, tree: 2)])
        second += 15
      }
      #expect(!watch.isQuiet(id, now: t0.addingTimeInterval(285)))
      watch.observe(now: t0.addingTimeInterval(300), apps: [id: .init(row: 1, tree: 2)])
      #expect(watch.isQuiet(id, now: t0.addingTimeInterval(300)))
      // A Codex task in its tree: busy again, and five more minutes needed.
      watch.observe(now: t0.addingTimeInterval(315), apps: [id: .init(row: 1, tree: 120)])
      #expect(!watch.isQuiet(id, now: t0.addingTimeInterval(315)))
      watch.observe(now: t0.addingTimeInterval(330), apps: [id: .init(row: 1, tree: 1)])
      #expect(!watch.isQuiet(id, now: t0.addingTimeInterval(600)))
      #expect(!watch.isQuiet("com.anthropic.claudefordesktop", now: t0.addingTimeInterval(600)))
    }

    @Test func aSleepStartsTheQuietAfresh() {
      var watch = AppCPUWatch()
      let id = "com.anthropic.claudefordesktop"
      watch.observe(now: t0, apps: [id: .init(row: 0, tree: 0)])
      watch.observe(now: t0.addingTimeInterval(600), apps: [id: .init(row: 0, tree: 0)])
      #expect(!watch.isQuiet(id, now: t0.addingTimeInterval(600)))
    }

    @Test func keepsTheRecentPeakForAnHour() {
      var watch = AppCPUWatch()
      watch.observe(now: t0, apps: ["a": .init(row: 490, tree: 500)])
      watch.observe(now: t0.addingTimeInterval(60), apps: ["a": .init(row: 30, tree: 30)])
      #expect(watch.peak("a", now: t0.addingTimeInterval(60)) == 490)
      watch.observe(now: t0.addingTimeInterval(3_660), apps: ["a": .init(row: 20, tree: 20)])
      #expect(watch.peak("a", now: t0.addingTimeInterval(3_660)) == 20)
      #expect(watch.peak("b", now: t0) == nil)
    }
  }

  struct Quiet {
    private func candidate(_ id: String, _ bytes: UInt64, quiet: Bool = true)
      -> AppPressurePlanner.App
    {
      .init(
        bundleID: id, name: id, processID: 1, launchDate: nil,
        bundleURL: URL(fileURLWithPath: "/Applications/\(id).app"), memoryBytes: bytes,
        isFrontmost: false, usesMicOrCamera: false, isProtected: false, quiet: quiet)
    }

    @Test func anAIAppStillWorkingIsSkippedAndTheNextAppGoesFirst() {
      let input = AppPressurePlanner.Input(
        now: t0, pressure: true, calm: false, othersPending: false, lastPause: nil,
        apps: [candidate("chatgpt", 6_000, quiet: false), candidate("loom", 1_000)],
        running: ["chatgpt", "loom"], quitting: [],
        list: AppQuitList(["chatgpt", "loom"]), selfBundleID: nil, state: .init())
      let output = AppPressurePlanner.plan(input)
      #expect(output.steps == [.quit(candidate("loom", 1_000))])
    }

    @Test func theScanMarksAnAIAppQuietOnlyWhenTheWatchSaysSo() {
      #expect(AppSlow.isAIApp("com.openai.chat"))
      #expect(AppSlow.isAIApp("com.openai.codex"))
      #expect(AppSlow.isAIApp("com.anthropic.claudefordesktop"))
      #expect(!AppSlow.isAIApp("com.loom.desktop"))
      let running = ["com.openai.codex", "com.loom.desktop", "com.anthropic.claudefordesktop"]
        .enumerated().map { index, id in
          AppPressureWiring.Running(
            bundleID: id, name: id, processID: Int32(100 + index), launchDate: nil,
            bundleURL: URL(fileURLWithPath: "/Applications/\(id).app"), isTerminated: false,
            prohibited: false)
        }
      let scan = AppPressureWiring.scan(
        .init(
          running: running, list: AppQuitList(), memory: [:],
          probes: .init(micCameraFree: Set(running.compactMap(\.bundleID))),
          scope: nil, parents: [:], selfBundleID: nil, selfProcessID: 1,
          quietAIApps: ["com.anthropic.claudefordesktop"]))
      // Their AI-app protection gives way to the quiet rule; a listed AI app can be quit.
      #expect(scan.apps.allSatisfy { !$0.isProtected })
      let quiet = Dictionary(uniqueKeysWithValues: scan.apps.map { ($0.bundleID, $0.quiet) })
      #expect(
        quiet == [
          "com.openai.codex": false, "com.loom.desktop": true,
          "com.anthropic.claudefordesktop": true,
        ])
    }
  }
}

extension AppSlowTests {
  struct Suggestions {
    private var calendar: Calendar {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
      return calendar
    }

    /// 2026-10-29 at `hour`:`minute`, Paris time.
    private func at(day: Int = 29, _ hour: Int, _ minute: Int = 0) -> Date {
      calendar.date(
        from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func pressureTopsAreKeptPerHalfHourOfTheDay() {
      var record = UsageRecord()
      record.recordTops(["chrome", "chatgpt"], at: at(10, 5), calendar: calendar)
      record.recordTops(["chrome"], at: at(10, 25), calendar: calendar)
      record.recordTops(["chrome"], at: at(10, 35), calendar: calendar)
      #expect(record.days.map(\.day) == ["2026-10-29"])
      #expect(record.days[0].pressureTops == ["chrome": [20, 21], "chatgpt": [20]])
    }

    @Test func theHistoryIsImportedOnce() {
      var record = UsageRecord()
      record.importTops([(at(9, 0), ["docker"]), (at(9, 40), ["docker"])], calendar: calendar)
      record.importTops([(at(11, 0), ["docker"])], calendar: calendar)
      #expect(record.topsImported)
      #expect(record.days.first?.pressureTops == ["docker": [18, 19]])
      // A file from before keeps its days, without tops.
      let data = try! JSONEncoder().encode(record)
      #expect(try! JSONDecoder().decode(UsageRecord.self, from: data) == record)
    }

    @Test func anAppIsSuggestedOnceInTheTopThreeAtThreeSeparateTimesInAWeek() {
      var record = UsageRecord()
      record.recordTops(["docker", "chrome"], at: at(day: 23, 9), calendar: calendar)
      record.recordTops(["docker", "chrome"], at: at(day: 27, 14), calendar: calendar)
      // The same half-hour twice counts once.
      record.recordTops(["docker"], at: at(day: 29, 9, 40), calendar: calendar)
      record.recordTops(["docker"], at: at(day: 29, 9, 50), calendar: calendar)
      // A week ago, before the window.
      record.recordTops(["slack"], at: at(day: 22, 9), calendar: calendar)
      record.recordTops(["slack"], at: at(day: 23, 9), calendar: calendar)
      record.recordTops(["slack"], at: at(day: 24, 9), calendar: calendar)
      let suggested = AppSuggestions.suggested(
        record.days, now: at(day: 29, 12), calendar: calendar)
      #expect(suggested == ["docker"])
      // Chrome's third time makes it.
      record.recordTops(["chrome"], at: at(day: 29, 11), calendar: calendar)
      #expect(
        AppSuggestions.suggested(record.days, now: at(day: 29, 12), calendar: calendar)
          == ["docker", "chrome"])
    }

    @Test func theTopThreeAppsByMemory() {
      let consumers = [
        ("Docker", 9.0), ("Chrome", 4.0), ("Tamebar", 3.0), ("ChatGPT", 6.0), ("Loom", 1.0),
      ]
      #expect(
        AppSuggestions.top(consumers.map { (name: $0.0, bytes: UInt64($0.1 * 1e9)) })
          == ["Docker", "ChatGPT", "Chrome"])
    }
  }

  struct OptOut {
    @Test func storedByBundleIDAndTolerant() {
      var stored: Any? = ["com.google.Chrome", 3, ""]
      let store = AppSlowOptOut.Store(read: { stored }, write: { stored = $0 })
      var list = AppSlowOptOut.load(store)
      #expect(list.bundleIDs == ["com.google.Chrome"])
      list.set("com.openai.codex", slow: false)
      list.set("com.google.Chrome", slow: true)
      list.save(store)
      #expect(stored as? [String] == ["com.openai.codex"])
    }
  }

  struct Rows {
    private func info(_ id: String) -> AppsUnderPressure.Info {
      switch id {
      case "chatgpt": .init(name: "ChatGPT", memoryBytes: 6_000_000_000, peakCPU: 490)
      case "chrome": .init(name: "Chrome", memoryBytes: 4_000_000_000, peakCPU: 120)
      case "docker": .init(name: "Docker", memoryBytes: 9_000_000_000, peakCPU: nil)
      case "loom": .init(name: "Loom", memoryBytes: 1_000_000_000, peakCPU: nil)
      case "slack": .init(name: "Slack", memoryBytes: nil, peakCPU: nil)
      default: .init(name: id, memoryBytes: nil, peakCPU: nil)
      }
    }

    @Test func theMockupsList() {
      let rows = AppsUnderPressure.rows(
        .init(
          quit: ["loom"], optedOut: ["slack"], suggested: ["chatgpt", "chrome", "docker", "loom"],
          recent: [], added: []), info: info)
      #expect(rows.map(\.name) == ["ChatGPT", "Chrome", "Docker", "Loom", "Slack"])
      #expect(
        rows.map(\.detail) == ["6 GB · 490% CPU", "4 GB", "9 GB", "1 GB", "Not running"])
      #expect(rows.map(\.slow) == [true, true, true, true, false])
      #expect(rows.map(\.quit) == [false, false, false, true, false])
      // Loom is ticked already: no longer suggested.
      #expect(rows.map(\.suggested) == [true, true, true, false, false])
    }

    @Test func anAppSlowedLatelyOrAddedHasARowWithItsDefaults() {
      let rows = AppsUnderPressure.rows(
        .init(quit: [], optedOut: [], suggested: [], recent: ["chatgpt"], added: ["zoom"]),
        info: info)
      #expect(rows.map(\.bundleID) == ["chatgpt", "zoom"])
      #expect(rows.allSatisfy { $0.slow && !$0.quit && !$0.suggested })
    }
  }
}

extension AppSlowTests {
  struct ScanApps {
    private func running(
      _ id: String, _ path: String, pid: Int32, name: String? = nil, regular: Bool = true
    ) -> ScannedApp {
      .init(
        bundleID: id,
        name: name ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
        processID: pid, bundleURL: URL(fileURLWithPath: path), regular: regular)
    }

    private func row(_ name: String, cpu: Double, bytes: UInt64 = 1_000, pids: [Int32])
      -> ResourceConsumer
    {
      .init(
        id: "app:\(name)", kind: .app, name: name, iconName: name, processIDs: pids,
        memoryBytes: bytes, cpuPercent: cpu, directory: nil, isPaused: false, threadID: nil)
    }

    private func record(_ pid: Int32, parent: Int32, cpu: Double) -> RawProcessRecord {
      .init(
        processID: pid, parentProcessID: parent, userID: 501, cpuPercent: cpu,
        residentKilobytes: 0, elapsed: "", terminal: nil, arguments: "/Applications/x \(pid)")
    }

    @Test func oneAppPerRowWithARegularAppAndItsBusyProcesses() {
      let apps = AppSlow.apps(
        .init(
          running: [
            running("com.docker.docker", "/Applications/Docker.app", pid: 30, regular: false),
            running(
              "com.docker.vm", "/Applications/Docker.app/Contents/MacOS/VM.app", pid: 31,
              regular: false),
            running("com.openai.codex", "/Applications/ChatGPT.app", pid: 10),
            running("com.tinyspeck.slackmacgap", "/Applications/Slack.app", pid: 40),
            running("com.loom.desktop", "/Applications/Loom.app", pid: 50),
          ],
          consumers: [
            row("Docker", cpu: 400, pids: [30, 31]), row("ChatGPT", cpu: 490, pids: [10, 11]),
            row("Slack", cpu: 200, pids: [40]),
          ],
          processes: .init(
            records: [
              10: record(10, parent: 1, cpu: 5), 11: record(11, parent: 10, cpu: 485),
              40: record(40, parent: 1, cpu: 200),
            ], serving: [], keptDirectories: []),
          frontmost: "com.tinyspeck.slackmacgap",
          usesMicOrCamera: { $0 == "com.loom.desktop" ? true : false },
          optedOut: AppSlowOptOut(), selfBundleID: "com.tamebar.Tamebar", selfProcessID: 99))
      // Docker has no regular app; Loom has no row.
      #expect(apps.map(\.group) == ["app:ChatGPT", "app:Slack"])
      #expect(apps[0].bundleID == "com.openai.codex" && apps[0].processIDs == [11])
      #expect(apps[0].cpuPercent == 490 && !apps[0].excluded)
      #expect(apps[1].isFrontmost)
    }

    /// macOS's own apps are never slowed: Music, Finder, Safari (in its cryptex).
    @Test func macOSsOwnAppsAreExcluded() {
      let safari =
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"
      let apps = AppSlow.apps(
        .init(
          running: [
            running("com.apple.Music", "/System/Applications/Music.app", pid: 60),
            running("com.apple.finder", "/System/Library/CoreServices/Finder.app", pid: 61),
            running("com.apple.Safari", safari, pid: 62),
            running("com.openai.codex", "/Applications/ChatGPT.app", pid: 10),
          ],
          consumers: [
            row("Music", cpu: 300, pids: [60]), row("Finder", cpu: 300, pids: [61]),
            row("Safari", cpu: 300, pids: [62]), row("ChatGPT", cpu: 300, pids: [10]),
          ],
          processes: .init(
            records: [
              60: record(60, parent: 1, cpu: 300), 61: record(61, parent: 1, cpu: 300),
              62: record(62, parent: 1, cpu: 300), 10: record(10, parent: 1, cpu: 300),
            ], serving: [], keptDirectories: []),
          frontmost: nil, usesMicOrCamera: { _ in false }, optedOut: AppSlowOptOut(),
          selfBundleID: "com.tamebar.Tamebar", selfProcessID: 99))
      #expect(apps.filter(\.excluded).map(\.group) == ["app:Finder", "app:Music", "app:Safari"])
      #expect(apps.filter { !$0.excluded }.map(\.group) == ["app:ChatGPT"])
    }

    @Test func theTreeCountsCodexWorkersTheRowDoesNot() {
      let readings = AppCPUWatch.readings(
        running: [running("com.openai.codex", "/Applications/ChatGPT.app", pid: 10)],
        consumers: [row("ChatGPT", cpu: 3, pids: [10, 11])],
        records: [
          10: record(10, parent: 1, cpu: 1), 11: record(11, parent: 10, cpu: 2),
          12: record(12, parent: 11, cpu: 1), 13: record(13, parent: 12, cpu: 300),
        ])
      #expect(readings["com.openai.codex"] == .init(row: 3, tree: 304))
    }

    @Test func topRowsAreNamedByTheirOutermostApp() {
      let ids = AppSuggestions.topBundleIDs(
        consumers: [
          row("Docker", cpu: 0, bytes: 9, pids: [31]), row("Chrome", cpu: 0, bytes: 4, pids: [20]),
          row("ChatGPT", cpu: 0, bytes: 6, pids: [10]), row("Loom", cpu: 0, bytes: 1, pids: [50]),
        ],
        running: [
          running(
            "com.docker.vm", "/Applications/Docker.app/Contents/MacOS/VM.app", pid: 31,
            regular: false),
          running("com.google.Chrome", "/Applications/Chrome.app", pid: 20),
          running("com.openai.codex", "/Applications/ChatGPT.app", pid: 10),
        ], bundleID: { $0.bundleID == "com.docker.vm" ? "com.docker.docker" : nil })
      #expect(ids == ["com.docker.docker", "com.openai.codex", "com.google.Chrome"])
    }
  }
}

extension AppSlowTests {
  struct Surfaces {
    /// N11: the card says what Tamebar did today, from the usage record, a count of zero left
    /// out, then the memory it freed.
    @Test func theCardSaysWhatTamebarDidToday() {
      #expect(UsageCardContent.today(nil) == "Today: nothing yet")
      #expect(UsageCardContent.today(UsageActions()) == "Today: nothing yet")
      var actions = UsageActions()
      actions.ended = 3
      actions.slowed = 2
      actions.freedBytes = 4_000_000_000
      #expect(UsageCardContent.today(actions) == "Today: ended 3 · slowed 2 · 4 GB back")
      actions.paused = 1
      actions.quit = 1
      #expect(
        UsageCardContent.today(actions)
          == "Today: ended 3 · quit 1 · paused 1 · slowed 2 · 4 GB back")
    }

    /// N11: the memory line ends on the strain (Q19), with its signals when the Mac struggles.
    @Test func theMemoryLineEndsOnTheStrain() {
      let snapshot = SystemSnapshot(
        .init(
          diskAvailable: 1, diskTotal: 2, ramAvailable: 2_000_000_000, ramTotal: 16_000_000_000,
          memoryPressure: .normal, cpuUsage: 0.1, thermalStatus: .nominal, updatedAt: .now))
      #expect(UsageCardContent(snapshot: snapshot, now: .now).memory == "Memory 2 GB free")
      let calm = CardStrain(struggling: false, signals: [])
      #expect(
        UsageCardContent(snapshot: snapshot, now: .now, strain: calm).memory
          == "Memory 2 GB free · Strain none")
      let hot = CardStrain(struggling: true, signals: ["fan 78%"])
      #expect(
        UsageCardContent(snapshot: snapshot, now: .now, strain: hot).memory
          == "Memory 2 GB free · Struggling: fan 78%")
      #expect(CardStrain(struggling: true, signals: []).text == "Struggling")
    }

    @Test func untickingSlowInBackgroundIsAMarker() {
      let old = UsageSettings(
        autoEnd: "ask", autoEndDays: 7, quitApps: [], autoPauseProjects: [], slowOptOut: [])
      var new = old
      new.slowOptOut = ["com.google.Chrome"]
      let name = { (id: String) in id == "com.google.Chrome" ? "Chrome" : id }
      #expect(
        UsageSettings.changes(from: old, to: new, name: name) == ["Slow in background: − Chrome"])
      #expect(
        UsageSettings.changes(from: new, to: old, name: name) == ["Slow in background: + Chrome"])
      // A record from before Q17 reads as nothing unticked.
      let json = #"{"autoEnd":"ask","autoEndDays":7,"quitApps":[],"autoPauseProjects":[]}"#
      let decoded = try? JSONDecoder().decode(UsageSettings.self, from: Data(json.utf8))
      #expect(decoded == old)
    }
  }
}
