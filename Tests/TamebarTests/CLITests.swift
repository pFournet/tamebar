import Darwin
import Foundation
import Testing

@testable import Tamebar

/// The read-only `tamebar` command line: arguments, the JSON shape and the text, from fixtures.
enum CLITests {}

// MARK: Fixtures

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let fixtureNow = now
private let gb: UInt64 = 1_000_000_000

private func session(
  _ id: String, tool: AITool = .claudeCode, root: Int32, children: [Int32] = [],
  directory: String? = "/code/app", bytes: UInt64, status: AgentStatus? = .idle,
  since: Date? = now.addingTimeInterval(-2 * 86_400), paused: Bool = false
) -> AIThread {
  var thread = AIThread(
    id: id, tool: tool, name: tool.title, directory: directory, terminal: "ttys001",
    startedAt: nil, processIDs: [root] + children, memoryBytes: bytes, cpuPercent: 1.5,
    isPaused: paused, isDetached: false)
  thread.rootProcessID = root
  thread.agentStatus = status
  thread.agentStatusSince = since
  return thread
}

private func record(_ pid: Int32, parent: Int32, _ arguments: String) -> RawProcessRecord {
  RawProcessRecord(
    processID: pid, parentProcessID: parent, userID: 501, cpuPercent: 0,
    residentKilobytes: 1, elapsed: "01:00", terminal: nil, arguments: arguments)
}

private func reading(pressure: MemoryPressureLevel = .warning) -> CLISystemReading {
  CLISystemReading(
    memory: MemoryGuardSample(
      date: now, pressure: pressure, available: 2 * gb, total: 16 * gb, compressed: 3 * gb,
      swapUsed: 9 * gb, swapOutBytes: 0),
    cpu: 0.234, diskFree: 40 * gb, diskTotal: 500 * gb,
    leads: ResourceLeads(
      cpu: ResourceLead(name: "Notion", value: 51.7),
      memory: ResourceLead(name: "Google Chrome", value: Double(7 * gb))),
    call: CallReading(inputs: [], camera: false))
}

private func autopause() -> AutoPauseWiring.Record {
  var record = AutoPauseWiring.Record()
  record.state.ledger = [
    .init(
      threadID: "claudeCode-4242-1799990000", reason: .pressure,
      since: now.addingTimeInterval(-180)),
    .init(threadID: "project:/code/web", reason: .meeting, since: now.addingTimeInterval(-60)),
  ]
  record.state.elevatedSince = now.addingTimeInterval(-300)
  record.state.lastTick = now.addingTimeInterval(-2)
  record.apps.ledger = [
    .init(
      bundleID: "com.tinyspeck.slackmacgap", name: "Slack",
      bundleURL: URL(fileURLWithPath: "/Applications/Slack.app"), memoryBytes: gb,
      quitAt: now.addingTimeInterval(-120), confirmed: true)
  ]
  return record
}

private func background() -> BackgroundPriority.Record {
  var record = BackgroundPriority.Record()
  record.slowed = [
    .init(
      identity: DevProcessIdentity(
        process: RecoveryProcess(
          processID: 777, owner: 501, startSeconds: 1, startMicroseconds: 0,
          state: UInt32(SRUN)),
        executable: "/usr/local/bin/node"),
      group: "ai:claudeCode-4242-1799990000", slowedAt: now.addingTimeInterval(-30)),
    .init(
      identity: DevProcessIdentity(
        process: RecoveryProcess(
          processID: 888, owner: 501, startSeconds: 1, startMicroseconds: 0,
          state: UInt32(SRUN)),
        executable: "/Applications/ChatGPT.app/Contents/Frameworks/Helper"),
      group: "app:ChatGPT", slowedAt: now.addingTimeInterval(-60)),
  ]
  record.apps = [
    .init(
      group: "app:ChatGPT", bundleID: "com.openai.codex", name: "ChatGPT", cpuPercent: 489.6,
      slowedAt: now.addingTimeInterval(-60))
  ]
  return record
}

private func json(_ value: some Encodable) throws -> [String: Any] {
  let data = try CLIReport.encoder.encode(value)
  return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let utc = TimeZone(identifier: "UTC")!

extension CLIEnvironment {
  /// Fixture readings, a data folder that doesn't exist unless given, and in-memory defaults.
  static func fixture(
    directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "TamebarTests-CLI-missing-\(UUID().uuidString)"),
    defaults: UserDefaults = TestDefaults("CLI").defaults,
    out: @escaping (String) -> Void = { _ in }, err: @escaping (String) -> Void = { _ in }
  ) -> CLIEnvironment {
    CLIEnvironment(
      directory: directory, defaults: defaults, now: { fixtureNow }, timeZone: utc,
      system: { reading() },
      sessions: {
        CLISessionScan(threads: [], records: [:], listening: [], ports: [:], incomplete: false)
      },
      tamebarPID: { nil }, label: { _ in nil }, out: out, err: err)
  }
}

// MARK: Arguments

extension CLITests {
  struct Arguments {
    @Test func aBareWordOrHelpIsTheCommandLineAndAppFlagsAreNot() {
      #expect(CLI.wants(["status"]))
      #expect(CLI.wants(["bogus"]))
      #expect(CLI.wants(["--help"]))
      #expect(CLI.wants(["-h"]))
      #expect(!CLI.wants([]))
      #expect(!CLI.wants(["--background"]))
      #expect(!CLI.wants(["--e2e", "/tmp/x"]))
      #expect(!CLI.wants(["-psn_0_12345"]))
      #expect(!CLI.wants(["--purge-memory"]))
    }

    @Test func parsesEachCommandAndItsFlags() throws {
      #expect(try CLI.parse(["status"]).get() == .status(json: false))
      #expect(try CLI.parse(["status", "--json"]).get() == .status(json: true))
      #expect(try CLI.parse(["sessions"]).get() == .sessions(json: false, all: false))
      #expect(
        try CLI.parse(["sessions", "--all", "--json"]).get() == .sessions(json: true, all: true))
      #expect(try CLI.parse(["stopped"]).get() == .stopped(json: false))
      #expect(try CLI.parse(["stopped", "--json"]).get() == .stopped(json: true))
      #expect(try CLI.parse(["help", "stopped"]).get() == .help("stopped"))
      #expect(try CLI.parse(["history"]).get() == .history(json: false, since: 86_400))
      #expect(
        try CLI.parse(["history", "--since", "7d", "--json"]).get()
          == .history(json: true, since: 7 * 86_400))
      #expect(
        try CLI.parse(["history", "--since=1h"]).get() == .history(json: false, since: 3_600))
      #expect(try CLI.parse(["--help"]).get() == .help(nil))
      #expect(try CLI.parse(["help"]).get() == .help(nil))
      #expect(try CLI.parse(["help", "sessions"]).get() == .help("sessions"))
      #expect(try CLI.parse(["status", "--help"]).get() == .help("status"))
    }

    @Test func badUsageIsAnError() {
      for arguments in [
        ["bogus"], ["status", "--all"], ["status", "extra"], ["history", "--since"],
        ["history", "--since", "soon"], ["sessions", "--since", "1h"], ["help", "nope"],
        ["stopped", "--all"],
      ] {
        #expect(throws: CLI.UsageError.self) { try CLI.parse(arguments).get() }
      }
    }

    @Test func sinceTakesMinutesHoursDaysAndWeeks() {
      #expect(CLI.parseSince("30m") == 1_800)
      #expect(CLI.parseSince("1h") == 3_600)
      #expect(CLI.parseSince("24h") == 86_400)
      #expect(CLI.parseSince("7d") == 604_800)
      #expect(CLI.parseSince("2w") == 1_209_600)
      for bad in ["", "h", "0h", "-1h", "1.5h", "1y", "10", "1 h", "abc"] {
        #expect(CLI.parseSince(bad) == nil, "\(bad)")
      }
    }

    @Test func helpNamesEveryCommandAndExitsZero() {
      var out = ""
      let code = CLI.run(["--help"], .fixture(out: { out += $0 }))
      #expect(code == 0)
      for word in [
        "status", "sessions", "stopped", "history", "trend", "mark", "--json", "--all", "--since",
        "read-only",
      ] {
        #expect(out.contains(word), "\(word)")
      }
      var topic = ""
      #expect(CLI.run(["help", "history"], .fixture(out: { topic += $0 })) == 0)
      #expect(topic.contains("--since"))
    }

    @Test func badUsageExitsTwoWithTheUsageOnStandardError() {
      var out = ""
      var err = ""
      let code = CLI.run(["bogus"], .fixture(out: { out += $0 }, err: { err += $0 }))
      #expect(code == 2)
      #expect(out.isEmpty)
      #expect(err.contains("bogus"))
      #expect(err.contains("tamebar --help"))
    }
  }
}

// MARK: status

extension CLITests {
  struct Status {
    private func report(running: Int32? = 99) -> CLIStatus {
      CLIReport.status(
        .init(
          reading: reading(), state: CLIState(autopause: autopause(), background: background()),
          tamebarPID: running, directory: URL(fileURLWithPath: "/data/Tamebar"), now: now,
          label: { id in id == "claudeCode-4242-1799990000" ? "notes" : nil }))
    }

    @Test func jsonIsVersionedSnakeCaseWithIntegerBytesAndISODates() throws {
      let object = try json(report())
      #expect(object["schema"] as? Int == 1)
      #expect(object["command"] as? String == "status")
      #expect(object["generated_at"] as? String == "2027-01-15T08:00:00Z")
      #expect(
        Set(object.keys)
          == [
            "schema", "command", "generated_at", "tamebar", "memory", "assessment", "cpu", "disk",
            "top", "call", "thermal", "strain", "codex_plugins", "automatic",
          ])
      let memory = try #require(object["memory"] as? [String: Any])
      #expect(memory["available_bytes"] as? Int == 2_000_000_000)
      #expect(memory["total_bytes"] as? Int == 16_000_000_000)
      #expect(memory["swap_used_bytes"] as? Int == 9_000_000_000)
      #expect(memory["pressure"] as? String == "warning")
      let cpu = try #require(object["cpu"] as? [String: Any])
      #expect(cpu["percent"] as? Double == 23.4)
      let disk = try #require(object["disk"] as? [String: Any])
      #expect(disk["free_bytes"] as? Int == 40_000_000_000)
      let top = try #require(object["top"] as? [String: Any])
      let ram = try #require(top["memory"] as? [String: Any])
      #expect(ram["name"] as? String == "Google Chrome")
      #expect(ram["bytes"] as? Int == 7_000_000_000)
      let busiest = try #require(top["cpu"] as? [String: Any])
      #expect(busiest["percent"] as? Double == 51.7)
      let call = try #require(object["call"] as? [String: Any])
      #expect(call["active"] as? Bool == false)
      let assessment = try #require(object["assessment"] as? [String: Any])
      #expect(assessment["risk"] as? String == "warning")
      #expect(assessment["limit"] as? String == "memory")
    }

    @Test func tamebarStateNamesWhatItPausedQuitAndSlowed() throws {
      let object = try json(report())
      let tamebar = try #require(object["tamebar"] as? [String: Any])
      #expect(tamebar["running"] as? Bool == true)
      #expect(tamebar["pid"] as? Int == 99)
      #expect(tamebar["pressure_since"] as? String == "2027-01-15T07:55:00Z")
      let paused = try #require(tamebar["auto_paused"] as? [[String: Any]])
      #expect(paused.count == 2)
      #expect(paused[0]["kind"] as? String == "session")
      #expect(paused[0]["tool"] as? String == "claude_code")
      #expect(paused[0]["pid"] as? Int == 4242)
      #expect(paused[0]["project"] as? String == "notes")
      #expect(paused[0]["reason"] as? String == "pressure")
      #expect(paused[0]["since"] as? String == "2027-01-15T07:57:00Z")
      #expect(paused[1]["kind"] as? String == "project")
      #expect(paused[1]["directory"] as? String == "/code/web")
      #expect(paused[1]["project"] as? String == "web")
      #expect(paused[1]["reason"] as? String == "meeting")
      #expect(paused[1]["tool"] is NSNull)
      let quit = try #require(tamebar["quit_apps"] as? [[String: Any]])
      #expect(quit.first?["name"] as? String == "Slack")
      #expect(quit.first?["bundle_id"] as? String == "com.tinyspeck.slackmacgap")
      #expect(quit.first?["memory_bytes"] as? Int == 1_000_000_000)
      let slowed = try #require(tamebar["slowed"] as? [[String: Any]])
      #expect(slowed.first?["process_ids"] as? [Int] == [777])
      #expect(slowed.first?["executables"] as? [String] == ["node"])
      #expect(slowed.first?["label"] as? String == "Claude Code · notes")
      #expect(slowed.first?["kind"] as? String == "session")
      #expect(slowed.first?["cpu_percent"] is NSNull)
      // Q17.1: an app slowed in the background, with its bundle id and CPU.
      #expect(slowed.count == 2)
      #expect(slowed.last?["kind"] as? String == "app")
      #expect(slowed.last?["label"] as? String == "ChatGPT")
      #expect(slowed.last?["bundle_id"] as? String == "com.openai.codex")
      #expect(slowed.last?["cpu_percent"] as? Double == 490)
      #expect(slowed.last?["process_ids"] as? [Int] == [888])
      #expect(tamebar["in_call"] as? Bool == true)
    }

    @Test func notRunningIsSaidPlainlyAndUnknownsAreNull() throws {
      var empty = reading()
      empty = CLISystemReading(
        memory: empty.memory, cpu: nil, diskFree: empty.diskFree, diskTotal: empty.diskTotal,
        leads: ResourceLeads(cpu: nil, memory: nil), call: nil)
      let status = CLIReport.status(
        .init(
          reading: empty, state: CLIState(), tamebarPID: nil,
          directory: URL(fileURLWithPath: "/data/Tamebar"), now: now, label: { _ in nil }))
      let object = try json(status)
      let tamebar = try #require(object["tamebar"] as? [String: Any])
      #expect(tamebar["running"] as? Bool == false)
      #expect(tamebar["pid"] is NSNull)
      #expect(object["call"] is NSNull)
      #expect((object["cpu"] as? [String: Any])?["percent"] is NSNull)
      #expect((object["top"] as? [String: Any])?["cpu"] is NSNull)
      let text = CLIText.status(status, timeZone: utc)
      #expect(text.contains("Tamebar isn't running"))
      #expect(text.contains("CPU      measuring"))
    }

    @Test func textLeadsWithTheVerdictAndListsTamebarsActions() {
      let text = CLIText.status(report(), timeZone: utc)
      let lines = text.split(separator: "\n").map(String.init)
      #expect(
        lines.first?.hasPrefix("Memory is the bottleneck. Avoid starting new threads or builds.")
          == true)
      #expect(text.contains("Memory   2 GB available of 16 GB · swap 9 GB · pressure warning"))
      #expect(text.contains("CPU      23%"))
      #expect(text.contains("Disk     40 GB free"))
      #expect(text.contains("Top RAM  Google Chrome 7 GB"))
      #expect(text.contains("Top CPU  Notion 52%"))
      #expect(text.contains("Call     none"))
      #expect(text.contains("Tamebar is running (pid 99)"))
      #expect(text.contains("Paused   Claude Code · notes (memory pressure, 3 min)"))
      #expect(text.contains("Paused   web (call, 1 min)"))
      #expect(text.contains("Quit     Slack, 1 GB, reopens when memory recovers"))
      #expect(text.contains("Slowed   Claude Code · notes: node"))
      #expect(text.contains("Slowed   ChatGPT, in the background (490% CPU)"))
    }
  }
}

// MARK: sessions

extension CLITests {
  struct Sessions {
    private func scan() -> CLISessionScan {
      var big = session("claudeCode-10-1", root: 10, children: [11, 12], bytes: 3 * gb)
      big.sessionID = "6f1c1e0a-1111-4222-8333-944455556666"
      big.sessionDirectory = "/code/app"
      let busy = session(
        "codexCLI-20-1", tool: .codexCLI, root: 20, directory: "/code/api", bytes: 2 * gb,
        status: .busy)
      let pausedByTamebar = session(
        "claudeCode-30-1", root: 30, directory: "/code/notes", bytes: gb, paused: true)
      let pausedByUser = session(
        "claudeCode-40-1", root: 40, directory: "/code/web", bytes: 900_000_000, paused: true)
      let small = session("claudeCode-50-1", root: 50, directory: "/code/tiny", bytes: 20_000_000)
      return CLISessionScan(
        threads: [small, pausedByUser, busy, big, pausedByTamebar],
        records: [
          10: record(10, parent: 1, "claude"),
          11: record(11, parent: 10, "node /code/app/node_modules/.bin/vite"),
          12: record(12, parent: 10, "zsh -c sleep 100"),
        ],
        listening: [11], ports: [11: [5175]], incomplete: false)
    }

    private func report(all: Bool = false, reason: AutoPausePlanner.Reason = .pressure)
      -> CLISessions
    {
      var paused = AutoPauseWiring.Record()
      var keeps = SessionKeeps()
      keeps.toggle("codexCLI-20-1")
      paused.state.ledger = [
        .init(threadID: "claudeCode-30-1", reason: reason, since: now.addingTimeInterval(-600))
      ]
      return CLIReport.sessions(
        .init(
          scan: scan(), autopause: paused,
          keeps: keeps, preferences: [], tamebarRunning: true,
          now: now, all: all))
    }

    @Test func sortedByRAMWithSmallOnesHiddenUnlessAll() {
      let shown = report()
      #expect(
        shown.sessions.map(\.id) == [
          "claudeCode-10-1", "codexCLI-20-1", "claudeCode-30-1", "claudeCode-40-1",
        ])
      #expect(shown.hidden == 1)
      #expect(shown.total == 5)
      let all = report(all: true)
      #expect(all.sessions.count == 5)
      #expect(all.hidden == 0)
    }

    @Test func stateProtectionAndResumeCommand() throws {
      let rows = Dictionary(uniqueKeysWithValues: report().sessions.map { ($0.id, $0) })
      let big = try #require(rows["claudeCode-10-1"])
      #expect(big.state == "idle")
      #expect(big.idleSeconds == 2 * 86_400)
      #expect(big.protections == ["serving", "background_job"])
      #expect(big.ports == [5175])
      #expect(big.protected)
      #expect(
        big.resumeCommand
          == "cd '/code/app' && claude --resume 6f1c1e0a-1111-4222-8333-944455556666")
      let busy = try #require(rows["codexCLI-20-1"])
      #expect(busy.state == "busy")
      #expect(busy.protections == ["kept"])
      #expect(busy.resumeCommand == nil)
      let byTamebar = try #require(rows["claudeCode-30-1"])
      #expect(byTamebar.state == "paused")
      #expect(byTamebar.pausedBy == "tamebar")
      #expect(byTamebar.pauseReason == "pressure")
      let byUser = try #require(rows["claudeCode-40-1"])
      #expect(byUser.pausedBy == "user")
      #expect(byUser.pauseReason == nil)
      #expect(!byUser.protected)
    }

    /// Q19: nothing reads `queued` any more. A session an older build queued (Q14) reads paused
    /// for memory until Tamebar resumes it at its first scan.
    @Test func aSessionAnOlderBuildQueuedReadsPaused() throws {
      let report = report(reason: .queue)
      let row = try #require(report.sessions.first { $0.id == "claudeCode-30-1" })
      #expect(row.state == "paused")
      #expect(row.pausedBy == "tamebar")
      let text = CLIText.sessions(report, timeZone: utc)
      #expect(text.contains("paused by Tamebar (memory pressure)"))
      #expect(!text.contains("queued"))
    }

    @Test func jsonShape() throws {
      let object = try json(report())
      #expect(object["schema"] as? Int == 1)
      #expect(object["command"] as? String == "sessions")
      let rows = try #require(object["sessions"] as? [[String: Any]])
      let first = try #require(rows.first)
      #expect(
        Set(first.keys)
          == [
            "id", "tool", "tool_name", "project", "directory", "title", "pid", "memory_bytes",
            "cpu_percent", "state", "agent_status", "idle_seconds", "idle_since", "paused_by",
            "pause_reason", "paused_since", "protected", "protections", "ports", "detached",
            "session_id", "resume_command",
          ])
      #expect(first["tool"] as? String == "claude_code")
      #expect(first["memory_bytes"] as? Int == 3_000_000_000)
      #expect(first["idle_since"] as? String == "2027-01-13T08:00:00Z")
      #expect(rows[1]["idle_seconds"] is NSNull)
    }

    @Test func textOneLinePerSessionThenItsResumeCommand() {
      let text = CLIText.sessions(report(), timeZone: utc)
      #expect(text.contains("4 AI sessions · 7 GB"))
      #expect(text.contains("1 under 100 MB hidden (--all shows them)"))
      #expect(
        text.contains("Claude Code  app    3 GB    idle 2d      serving :5175, background job"))
      #expect(text.contains("Codex CLI    api    2 GB    busy         kept"))
      #expect(text.contains("Claude Code  notes  1 GB    paused by Tamebar (memory pressure)"))
      #expect(text.contains("Claude Code  web    900 MB  paused by you"))
      #expect(
        text.contains(
          "    resume: cd '/code/app' && claude --resume 6f1c1e0a-1111-4222-8333-944455556666"))
    }
  }
}

// MARK: stopped

extension CLITests {
  struct Stopped {
    private let atlasID = "601f93df-0000-4000-8000-000000000001"

    private func report(running: Bool = true) -> CLIStopped {
      let agent = session(
        "claudeCode-4242-1799990000", root: 4242, directory: "/code/Agent", bytes: 600_000_000,
        paused: true)
      var stores = CLIStoppedStores()
      stores.ended = [
        EndedSession(
          id: atlasID, tool: .claudeCode, directory: "/Users/me/code/Atlas", name: nil,
          idleSince: now.addingTimeInterval(-4 * 86_400 - 600),
          endedAt: now.addingTimeInterval(-86_400 - 600), memoryBytes: 2 * gb, automatic: true)
      ]
      stores.quitApps = [
        QuitApp(
          bundleID: "com.docker.docker", name: "Docker Desktop",
          bundleURL: URL(fileURLWithPath: "/Applications/Docker.app"), memoryBytes: 9 * gb,
          quitAt: now.addingTimeInterval(-60))
      ]
      return CLIReport.stopped(
        .init(
          scan: CLISessionScan(
            threads: [agent], records: [:], listening: [], ports: [:], incomplete: false),
          state: CLIState(autopause: autopause()), stores: stores,
          running: ["com.tinyspeck.slackmacgap": nil], tamebarRunning: running, now: now,
          label: { _ in nil }))
    }

    /// Slack, which Tamebar quit, is running again (launched at an unknown time): it is back.
    @Test func whatNeedsACommandFirstThenWhatComesBackOnItsOwn() {
      let stopped = report().stopped
      #expect(
        stopped.map(\.id) == [
          "app:com.docker.docker", "ended:\(atlasID)", "paused:project:/code/web",
          "paused:claudeCode-4242-1799990000",
        ])
      #expect(stopped.map(\.state) == ["quit", "ended", "paused", "paused"])
      #expect(stopped.map(\.reason) == ["by_you", "idle", "call", "memory"])
      #expect(stopped[1].idleDays == 3)
      #expect(stopped[3].name == "Agent")
      #expect(stopped[3].memoryBytes == 600_000_000)
      #expect(stopped[0].resumeCommand == "open -a Docker")
      #expect(stopped[2].resumeCommand == nil)
    }

    @Test func jsonShape() throws {
      let object = try json(report())
      #expect(object["schema"] as? Int == 1)
      #expect(object["command"] as? String == "stopped")
      #expect(object["total"] as? Int == 4)
      #expect(object["tamebar_running"] as? Bool == true)
      let rows = try #require(object["stopped"] as? [[String: Any]])
      let first = try #require(rows.first)
      #expect(
        Set(first.keys)
          == [
            "id", "kind", "name", "tool", "tool_name", "directory", "session_id", "bundle_id",
            "stopped_at", "state", "reason", "idle_days", "memory_bytes", "resume_command",
          ])
      #expect(first["kind"] as? String == "app")
      #expect(first["bundle_id"] as? String == "com.docker.docker")
      #expect(first["memory_bytes"] as? Int == 9_000_000_000)
      #expect(first["tool"] is NSNull)
      #expect(first["stopped_at"] as? String == "2027-01-15T07:59:00Z")
      #expect(rows[1]["tool"] as? String == "claude_code")
      #expect(rows[2]["resume_command"] is NSNull)
    }

    /// Q15's terminal mock.
    @Test func textFollowsTheMock() {
      let text = CLIText.stopped(report(), timeZone: utc)
      let expected = """
        4 stopped · bring back with the command under each

        Jan 15 07:59  Docker Desktop  app      9 GB    quit by you, from Tamebar
                      open -a Docker
        Jan 14 07:50  Atlas           session  2 GB    ended · idle 3 days
                      cd '/Users/me/code/Atlas' && claude --resume \(atlasID)
        Jan 15 07:59  web             project  —       paused · call · comes back when the call ends
        Jan 15 07:57  Agent           session  600 MB  paused · memory · comes back when memory recovers

        """
      #expect(text == expected)
      #expect(
        CLIText.stopped(report(running: false), timeZone: utc).contains("Tamebar isn't running"))
    }

    @Test func nothingStopped() {
      let empty = CLIReport.stopped(
        .init(
          scan: CLISessionScan(
            threads: [], records: [:], listening: [], ports: [:], incomplete: false),
          state: CLIState(), stores: CLIStoppedStores(), running: [:], tamebarRunning: true,
          now: now, label: { _ in nil }))
      #expect(empty.total == 0)
      #expect(CLIText.stopped(empty, timeZone: utc) == "Nothing stopped by Tamebar.\n")
    }

    @Test func unreadableStoresAreNotedNotBackedUp() {
      let defaults = TestDefaults("CLI").defaults
      defaults.set(Data("not a list".utf8), forKey: EndedSessionLog.defaultsKey)
      var out = ""
      #expect(CLI.run(["stopped"], .fixture(defaults: defaults, out: { out += $0 })) == 0)
      #expect(out.contains("Note: Ended sessions are unreadable"))
      #expect(Set(defaults.dictionaryRepresentation().keys) == [EndedSessionLog.defaultsKey])
    }
  }
}

// MARK: history

extension CLITests {
  struct History {
    private func files() -> CLIHistoryFiles {
      func incident(_ kind: String, _ detail: String, minutesAgo: Double) -> MemoryIncident {
        MemoryIncident(
          id: UUID(), date: now.addingTimeInterval(-minutesAgo * 60), kind: kind, detail: detail,
          sample: MemoryGuardSample(
            date: now, pressure: .warning, available: 2 * gb, total: 16 * gb, compressed: 0,
            swapUsed: 8 * gb, swapOutBytes: 0),
          apps: [
            .init(name: "Google Chrome", bytes: 5 * gb, protected: false),
            .init(name: "Slack", bytes: gb, protected: true),
          ],
          resources: [
            ResourceGroup(
              id: "a", name: "node", owner: "Terminal", project: "web-frontend", processCount: 4,
              memoryBytes: 2 * gb, unknownMemoryCount: 0)
          ])
      }
      // Through the file's own format: `append` keeps a single day.
      struct Saved: Encodable { let events: [MemoryIncident] }
      let memory = try? JSONDecoder().decode(
        MemoryIncidentHistory.self,
        from: JSONEncoder().encode(
          Saved(events: [
            incident("pressure", "Memory running low", minutesAgo: 30 * 60),
            incident("pressure", "Memory almost full", minutesAgo: 90),
            incident("sample", "Memory running low", minutesAgo: 89),
            incident("disk-alert", "19 GB free", minutesAgo: 30),
          ])))
      let samples = [
        ResourceSample(
          date: now.addingTimeInterval(-3 * 86_400), cpu: 0.99, memory: 0.99,
          cpuLead: .init(name: "Old", value: 99), memoryLead: .init(name: "Old", value: 1)),
        ResourceSample(
          date: now.addingTimeInterval(-7_200), cpu: 0.4, memory: 0.91,
          cpuLead: .init(name: "Notion", value: 52), memoryLead: .init(name: "Chrome", value: 7e9)),
        ResourceSample(date: now.addingTimeInterval(-60), cpu: 0.8, memory: 0.85),
      ]
      let pressure: [[String: String]] = [
        [
          "at": "2027-01-15T07:30:00Z", "risk": "Memory is the bottleneck",
          "detail": "2 GB RAM available · 9 GB swap · 40 GB disk free", "action": "",
          "projects": "web-frontend: 6 GB; dashboard-app: 2 GB",
        ],
        [
          "at": "2026-12-01T07:30:00Z", "risk": "Memory is the bottleneck", "detail": "",
          "action": "", "projects": "",
        ],
      ]
      return CLIHistoryFiles(memory: memory, resources: samples, pressure: pressure)
    }

    private func report(since: TimeInterval = 86_400) -> CLIHistory {
      CLIReport.history(.init(files: files(), since: since, now: now, tamebarRunning: false))
    }

    @Test func keepsOnlyTheWindowAndSplitsEventsFromSamples() {
      let day = report()
      #expect(day.events.map(\.kind) == ["pressure", "disk-alert"])
      #expect(day.samples.count == 2)
      #expect(day.pressureLog.count == 1)
      let hour = report(since: 3_600)
      #expect(hour.events.map(\.kind) == ["disk-alert"])
      #expect(hour.samples.count == 1)
      let week = report(since: 7 * 86_400)
      #expect(week.events.count == 3)
      #expect(week.samples.count == 3)
    }

    @Test func eachEventCarriesItsTopAppsAndProjects() throws {
      let object = try json(report())
      #expect(object["schema"] as? Int == 1)
      #expect(object["since"] as? String == "2027-01-14T08:00:00Z")
      let events = try #require(object["events"] as? [[String: Any]])
      let first = try #require(events.first)
      #expect(first["date"] as? String == "2027-01-15T06:30:00Z")
      #expect(first["available_bytes"] as? Int == 2_000_000_000)
      let apps = try #require(first["top_apps"] as? [[String: Any]])
      #expect(apps.first?["name"] as? String == "Google Chrome")
      #expect(apps.first?["bytes"] as? Int == 5_000_000_000)
      let projects = try #require(first["top_projects"] as? [[String: Any]])
      #expect(projects.first?["name"] as? String == "web-frontend")
      let log = try #require(object["pressure_log"] as? [[String: Any]])
      let logged = try #require(log.first?["top_projects"] as? [[String: Any]])
      #expect(logged.map { $0["name"] as? String } == ["web-frontend", "dashboard-app"])
      #expect(logged.first?["memory"] as? String == "6 GB")
      let samples = try #require(object["samples"] as? [[String: Any]])
      #expect(samples.first?["memory_percent"] as? Double == 91)
      #expect((samples.first?["cpu_lead"] as? [String: Any])?["percent"] as? Double == 52)
      #expect((samples.first?["memory_lead"] as? [String: Any])?["bytes"] as? Int == 7_000_000_000)
    }

    @Test func textSummarisesPressurePeaksAndOtherEvents() {
      let text = CLIText.history(report(), timeZone: utc)
      #expect(text.contains("Tamebar history · last 24h"))
      #expect(text.contains("Tamebar isn't running"))
      #expect(text.contains("Pressure events: 1"))
      #expect(text.contains("06:30  Memory almost full · 2 GB available · 8 GB swap"))
      #expect(text.contains("Google Chrome 5 GB, Slack 1 GB · web-frontend 2 GB"))
      #expect(text.contains("Peak RAM 91% at Jan 15 06:00 (Chrome 7 GB)"))
      #expect(text.contains("Peak CPU 80% at Jan 15 07:59"))
      #expect(text.contains("Other events: 1 disk-alert"))
    }
  }
}

// MARK: Read-only

extension CLITests {
  /// Every command against a data folder whose files the app would move aside or rewrite (unreadable
  /// JSON), and defaults whose saved projects the app would back up: nothing changes, and no lock.
  struct ReadOnly {
    private func tree(_ root: URL) -> [String: Data] {
      var files: [String: Data] = [:]
      let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
      while let url = enumerator?.nextObject() as? URL {
        files[url.path] = (try? Data(contentsOf: url)) ?? Data()
      }
      return files
    }

    @Test func noCommandWritesTheDataFolderTheDefaultsOrTakesTheLock() throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TamebarTests-CLI-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      for name in ["autopause.json", "background.json", "resource-history.json"] {
        try Data("{not json".utf8).write(to: root.appendingPathComponent(name))
      }
      try Data("[1,2".utf8).write(to: root.appendingPathComponent("pressure-latest.json"))
      try Data("{}".utf8).write(to: root.appendingPathComponent("memory-history.json"))
      let defaults = TestDefaults("CLI").defaults
      defaults.set(Data("not a list".utf8), forKey: WorkspacePreferences.key)
      defaults.set(["session:abc"], forKey: SessionKeeps.defaultsKey)
      // A list with an entry the app can't read: the app would keep it aside, the CLI doesn't.
      defaults.set(Data("[{\"id\": 3}]".utf8), forKey: EndedSessionLog.defaultsKey)
      defaults.set(Data("not a list".utf8), forKey: QuitAppLog.defaultsKey)
      let before = tree(root)
      let keysBefore = Set(defaults.dictionaryRepresentation().keys)

      for arguments in [
        ["status"], ["status", "--json"], ["sessions", "--all"], ["sessions", "--json"],
        ["history", "--since", "7d"], ["history", "--json"], ["stopped"], ["stopped", "--json"],
        ["trend"], ["trend", "--days", "30", "--json"], ["--help"], ["help", "mark"],
      ] {
        var out = ""
        let code = CLI.run(
          arguments, .fixture(directory: root, defaults: defaults, out: { out += $0 }))
        #expect(code == 0, "\(arguments)")
        #expect(!out.isEmpty)
      }
      #expect(tree(root) == before)
      #expect(
        !FileManager.default.fileExists(atPath: root.appendingPathComponent("autopause.lock").path))
      #expect(Set(defaults.dictionaryRepresentation().keys) == keysBefore)
    }

    @Test func unreadableFilesAreReportedNotMovedAside() throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TamebarTests-CLI-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      try Data("{not json".utf8).write(to: root.appendingPathComponent("autopause.json"))
      let state = CLIState.read(root)
      #expect(state.autopause == nil)
      #expect(state.notes == ["autopause.json is unreadable"])
    }

    /// The command-line sources call nothing that writes, locks or signals. `mark` appends its
    /// line through `UsageMarkers.append`, outside these files (UsageTrendTests covers it).
    @Test func cliSourcesHoldNoWriteLockOrSignal() throws {
      let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Tamebar")
      let names = try FileManager.default.contentsOfDirectory(atPath: sources.path)
        .filter { $0.hasPrefix("CLI") && $0.hasSuffix(".swift") }
      #expect(names.count >= 3)
      let forbidden = [
        "Lock.acquire", "flock(", ".write(", "save(", "moveItem", "removeItem", "createDirectory",
        ".set(", "kill(", "ProcessSignal", "setpriority", "AutoPauseWiring.load",
        "BackgroundPriority.load", "ResourceHistoryStore.application", "store.load",
        "WorkspacePreferences.read",
        "WorkspacePreferences.load", "SavedSettings", "NSApplication", "TamebarApp",
      ]
      for name in names {
        let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
        for word in forbidden {
          #expect(!text.contains(word), "\(name) contains \(word)")
        }
      }
    }
  }
}

// MARK: The built binary

extension CLITests {
  struct Binary {
    /// `swift test` builds the app's executable next to the test bundle.
    private var executable: URL? {
      let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      let url = root.appendingPathComponent(".build/debug/Tamebar")
      return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private func run(_ arguments: [String], directory: URL) throws -> (Int32, Data) {
      let process = Process()
      let executable = try #require(executable)
      process.executableURL = executable
      process.arguments = arguments
      var environment = ProcessInfo.processInfo.environment
      environment["TAMEBAR_STATE_DIR"] = directory.path
      // Outside the app bundle, Sparkle.framework sits next to the executable, off its rpath.
      environment["DYLD_FRAMEWORK_PATH"] =
        executable.resolvingSymlinksInPath().deletingLastPathComponent().path
      process.environment = environment
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      try process.run()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (process.terminationStatus, data)
    }

    @Test func statusJSONParsesAndBadUsageExitsTwo() throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TamebarTests-CLI-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let started = Date()
      let (code, data) = try run(["status", "--json"], directory: root)
      let elapsed = Date().timeIntervalSince(started)
      #expect(code == 0)
      let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(object["schema"] as? Int == 1)
      #expect((object["memory"] as? [String: Any])?["total_bytes"] as? Int ?? 0 > 0)
      #expect(elapsed < 5, "status took \(elapsed) s")
      #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
      #expect(try run(["bogus"], directory: root).0 == 2)
    }
  }
}
