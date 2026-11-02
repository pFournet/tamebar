import Foundation
import Testing

@testable import Tamebar

private let day: TimeInterval = 86_400
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func idle(_ id: String, days: Double, bytes: UInt64, protected: Bool = false)
  -> AutoEndScheduler.Candidate
{
  .init(id: id, reason: .idle(days * day), memoryBytes: bytes, protected: protected)
}

private func tick(
  _ seconds: TimeInterval, away: Bool, mode: AutoEndSettings.Mode = .auto, days: Int = 7,
  _ candidates: [AutoEndScheduler.Candidate]
) -> AutoEndScheduler.Tick {
  .init(
    now: t0.addingTimeInterval(seconds), away: away,
    settings: .init(mode: mode, days: days), candidates: candidates)
}

/// Q10, Amendment B: unused AI sessions, Ask me or End after N days.
enum AutoEndTests {}

extension AutoEndTests {
  struct Settings {
    @Test func defaultIsAskAfterSevenDays() {
      let defaults = TestDefaults("auto-end-default").defaults
      let settings = AutoEndSettings.load(defaults)
      #expect(settings == AutoEndSettings())
      #expect(settings.mode == .ask)
      #expect(settings.days == 7)
    }

    @Test func savesAsJSONUnderItsKeyAndLoadsBack() throws {
      let defaults = TestDefaults("auto-end-round-trip").defaults
      AutoEndSettings(mode: .auto, days: 12).save(defaults)
      let data = try #require(defaults.data(forKey: "sessions.autoEnd.v1"))
      let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(json["mode"] as? String == "auto")
      #expect(json["days"] as? Int == 12)
      #expect(AutoEndSettings.load(defaults) == .init(mode: .auto, days: 12))
    }

    @Test func decodesFieldByFieldAndClampsDays() {
      func decoded(_ json: String) -> AutoEndSettings {
        let defaults = TestDefaults("auto-end-decode").defaults
        defaults.set(Data(json.utf8), forKey: AutoEndSettings.key)
        return AutoEndSettings.load(defaults)
      }
      #expect(decoded(#"{"mode":"auto"}"#) == .init(mode: .auto, days: 7))
      #expect(decoded(#"{"mode":"never","days":3}"#) == .init(mode: .ask, days: 3))
      #expect(decoded(#"{"mode":"auto","days":99}"#) == .init(mode: .auto, days: 30))
      #expect(decoded(#"{"mode":"auto","days":0}"#) == .init(mode: .auto, days: 1))
      #expect(decoded(#"{"mode":"auto","days":"x"}"#) == .init(mode: .auto, days: 7))
      #expect(decoded("not json") == AutoEndSettings())
      #expect(decoded("[1,2]") == AutoEndSettings())
    }

    @Test func daysStayBetweenOneAndThirty() {
      #expect(AutoEndSettings(mode: .auto, days: 50).days == 30)
      #expect(AutoEndSettings(mode: .auto, days: -2).days == 1)
      var settings = AutoEndSettings()
      settings.days = 31
      #expect(settings.days == 30)
    }

    /// In auto mode, sessions idle past N days count as unused even when N is under the usual
    /// 7-day cutoff, so the setting means what it says.
    @Test func autoDaysLowerTheUnusedCutoff() {
      #expect(UnusedPolicy.cutoff(risk: .normal, inMeeting: false) == 7 * day)
      #expect(UnusedPolicy.cutoff(risk: .normal, inMeeting: false, autoEndDays: 3) == 3 * day)
      #expect(UnusedPolicy.cutoff(risk: .normal, inMeeting: false, autoEndDays: 12) == 7 * day)
      #expect(UnusedPolicy.cutoff(risk: .warning, inMeeting: false, autoEndDays: 3) == day)
      #expect(AutoEndSettings(mode: .auto, days: 3).unusedCutoffDays == 3)
      #expect(AutoEndSettings(mode: .ask, days: 3).unusedCutoffDays == nil)
    }
  }
}

extension AutoEndTests {
  struct Scheduler {
    let candidates = [
      idle("small", days: 8, bytes: 300), idle("large", days: 9, bytes: 500),
      idle("young", days: 6.9, bytes: 900),
    ]

    @Test func askModeNeverEnds() {
      var scheduler = AutoEndScheduler()
      for second in stride(from: 0.0, through: 600, by: 15) {
        #expect(scheduler.step(tick(second, away: true, mode: .ask, candidates)) == .init())
      }
      #expect(scheduler.step(tick(660, away: false, mode: .ask, candidates)) == .init())
    }

    @Test func autoWhilePresentNeverEnds() {
      var scheduler = AutoEndScheduler()
      for second in stride(from: 0.0, through: 600, by: 15) {
        #expect(scheduler.step(tick(second, away: false, candidates)) == .init())
      }
    }

    @Test func autoWhileAwayEndsLargestFirstOnePerThirtySecondsNeverUnderDays() {
      var scheduler = AutoEndScheduler()
      #expect(scheduler.step(tick(0, away: true, candidates)).end == "large")
      scheduler.landed("large", ended: true)
      let rest = candidates.filter { $0.id != "large" }
      #expect(scheduler.step(tick(10, away: true, rest)).end == nil)
      #expect(scheduler.step(tick(29.9, away: true, rest)).end == nil)
      #expect(scheduler.step(tick(30, away: true, rest)).end == "small")
      scheduler.landed("small", ended: true)
      // "young" is the largest, but idle under 7 days.
      let young = candidates.filter { $0.id == "young" }
      for second in stride(from: 60.0, through: 600, by: 30) {
        #expect(scheduler.step(tick(second, away: true, young)).end == nil)
      }
      // Its own threshold: at 6 days it goes.
      #expect(scheduler.step(tick(630, away: true, days: 6, young)).end == "young")
    }

    @Test func oneAtATimeWhileAnEndIsInFlight() {
      var scheduler = AutoEndScheduler()
      #expect(scheduler.step(tick(0, away: true, candidates)).end == "large")
      let rest = candidates.filter { $0.id != "large" }
      #expect(scheduler.step(tick(45, away: true, rest)).end == nil)
      scheduler.landed("large", ended: true)
      #expect(scheduler.step(tick(46, away: true, rest)).end == "small")
    }

    @Test func detachedAndProtectedAreNeverEnded() {
      var scheduler = AutoEndScheduler()
      let never: [AutoEndScheduler.Candidate] = [
        .init(id: "detached", reason: .detached, memoryBytes: 9_000),
        idle("kept", days: 20, bytes: 8_000, protected: true),
      ]
      for second in stride(from: 0.0, through: 600, by: 30) {
        #expect(scheduler.step(tick(second, away: true, days: 1, never)).end == nil)
      }
    }

    @Test func oneNoteOnReturnWithCountAndSmallestIdleAge() {
      var scheduler = AutoEndScheduler()
      #expect(scheduler.step(tick(0, away: true, candidates)) == .init(end: "large"))
      scheduler.landed("large", ended: true)
      // An ended session is gone from the next scan.
      let rest = candidates.filter { $0.id != "large" }
      #expect(scheduler.step(tick(30, away: true, rest)).end == "small")
      scheduler.landed("small", ended: true)
      #expect(scheduler.step(tick(60, away: true, [])).note == nil)
      #expect(
        scheduler.step(tick(90, away: false, [])).note == "Ended 2 sessions idle 8+ days · 800 B")
      #expect(scheduler.step(tick(91, away: false, [])).note == nil)
      // A later spell with nothing ended says nothing.
      #expect(scheduler.step(tick(200, away: true, [])) == .init())
      #expect(scheduler.step(tick(300, away: false, [])) == .init())
    }

    @Test func singularNote() {
      var scheduler = AutoEndScheduler()
      let one = [idle("one", days: 1.5, bytes: 10)]
      #expect(scheduler.step(tick(0, away: true, days: 1, one)).end == "one")
      scheduler.landed("one", ended: true)
      #expect(scheduler.step(tick(5, away: false, [])).note == "Ended 1 session idle 1+ day · 10 B")
    }

    @Test func anEndThatDidNotLandIsNeitherCountedNorRetriedThisSpell() {
      var scheduler = AutoEndScheduler()
      #expect(scheduler.step(tick(0, away: true, candidates)).end == "large")
      scheduler.landed("large", ended: false)
      #expect(scheduler.step(tick(30, away: true, candidates)).end == "small")
      scheduler.landed("small", ended: true)
      // "large" still runs, and is still a candidate in the scan.
      let left = candidates.filter { $0.id != "small" }
      #expect(scheduler.step(tick(60, away: true, left)).end == nil)
      #expect(scheduler.step(tick(90, away: true, left)).end == nil)
      #expect(
        scheduler.step(tick(100, away: false, [])).note == "Ended 1 session idle 8+ days · 300 B")
      // Away again: a new spell may try it once more.
      #expect(scheduler.step(tick(130, away: true, left)).end == "large")
    }

    @Test func theNoteWaitsForAnEndStillInFlight() {
      var scheduler = AutoEndScheduler()
      #expect(scheduler.step(tick(0, away: true, candidates)).end == "large")
      #expect(scheduler.step(tick(1, away: false, candidates)) == .init())
      scheduler.landed("large", ended: true)
      #expect(
        scheduler.step(tick(2, away: false, candidates)).note
          == "Ended 1 session idle 9+ days · 500 B")
    }

    /// One end landed, a second still in flight at the return: a single note once both have,
    /// counting both, never one note per landing.
    @Test func oneNoteCoversAnEndThatLandsAfterTheReturn() {
      var scheduler = AutoEndScheduler()
      #expect(scheduler.step(tick(0, away: true, candidates)).end == "large")
      scheduler.landed("large", ended: true)
      let rest = candidates.filter { $0.id != "large" }
      #expect(scheduler.step(tick(30, away: true, rest)).end == "small")
      #expect(scheduler.step(tick(31, away: false, rest)) == .init())
      scheduler.landed("small", ended: true)
      #expect(
        scheduler.step(tick(32, away: false, [])).note == "Ended 2 sessions idle 8+ days · 800 B")
      #expect(scheduler.step(tick(33, away: false, [])).note == nil)
    }

    @Test func noLandingForAnIDItNeverStarted() {
      var scheduler = AutoEndScheduler()
      scheduler.landed("ghost", ended: true)
      #expect(scheduler.step(tick(0, away: false, [])) == .init())
    }
  }
}

extension AutoEndTests {
  @MainActor
  struct Wiring {
    private func thread(
      _ id: String, root: Int32, bytes: UInt64 = 10, paused: Bool = false, pids: [Int32]? = nil
    ) -> AIThread {
      var thread = AIThread(
        id: id, tool: .claudeCode, name: "Claude Code", directory: "/code/\(id)", terminal: nil,
        startedAt: nil, processIDs: pids ?? [root], memoryBytes: bytes, cpuPercent: 0,
        isPaused: paused,
        isDetached: false)
      thread.rootProcessID = root
      thread.agentStatus = .idle
      thread.sessionID = "00000000-0000-4000-8000-000000000010"
      return thread
    }

    /// Q10: an automatic end must leave a way back. Only a session that gets an Ended sessions
    /// entry with a resume command is a candidate; the others stay manual offers in the panel.
    @Test func onlySessionsWithAResumeCommandAreCandidates() {
      var noID = thread("no-id", root: 10)
      noID.sessionID = nil
      // A Codex session in ~, /tmp or a dot folder: the panel shows no folder, and Codex has no
      // session-file one.
      let codexHidden = AIThread(
        id: "codex-hidden", tool: .codexCLI, name: "Codex", directory: nil, terminal: nil,
        startedAt: nil, processIDs: [20], memoryBytes: 10, cpuPercent: 0, isPaused: false,
        isDetached: false, rootProcessID: 20,
        sessionID: "00000000-0000-4000-8000-000000000020")
      var notUUID = thread("not-uuid", root: 30)
      notUUID.sessionID = "abc"
      // Claude in /tmp: its session file's cwd gives the folder.
      var claudeTmp = AIThread(
        id: "claude-tmp", tool: .claudeCode, name: "Claude Code", directory: nil, terminal: nil,
        startedAt: nil, processIDs: [40], memoryBytes: 10, cpuPercent: 0, isPaused: false,
        isDetached: false, rootProcessID: 40,
        sessionID: "00000000-0000-4000-8000-000000000040")
      claudeTmp.sessionDirectory = "/tmp"
      let resumable = thread("resumable", root: 50)
      let threads = [noID, codexHidden, notUUID, claudeTmp, resumable]
      let candidates = SessionEligibility.autoEndCandidates(
        .init(
          threads: threads,
          unused: Dictionary(uniqueKeysWithValues: threads.map { ($0.id, .idle(8 * day)) }),
          protections: [:], scope: nil, inFlight: []))
      #expect(candidates.map(\.id) == ["claude-tmp", "resumable"])
    }

    /// "Do not touch a session who is already working" (the user): an idle session with something it
    /// started still running is never ended automatically. The agent's own helpers don't count.
    @Test func aSessionWithABackgroundJobIsNotACandidate() {
      func record(_ pid: Int32, _ parent: Int32, _ arguments: String) -> RawProcessRecord {
        StubWorld.record(pid, parent: parent, arguments)
      }
      let helpers: [RawProcessRecord] = [
        record(10, 1, "claude"),
        record(11, 10, "/Users/me/.local/bin/chat mcp"),
        record(12, 10, "npm exec @modelcontextprotocol/server-slack"),
        record(13, 12, "node /Users/me/.npm/_npx/71b7/node_modules/.bin/mcp-server-slack"),
        record(14, 10, "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl"),
        record(15, 14, "/Applications/ChatGPT.app/cua_node/bin/node /var/folders/T/.tmp/kernel.js"),
        record(16, 10, "caffeinate -i -t 300"),
        record(17, 10, "/Applications/Xcode.app/Contents/Developer/usr/bin/sourcekit-lsp"),
        record(18, 10, "typescript-language-server --stdio"),
      ]
      let records = Dictionary(uniqueKeysWithValues: helpers.map { ($0.processID, $0) })
      let helped = thread("helped", root: 10, pids: helpers.map(\.processID))
      #expect(BackgroundJobs.job(helped, records: records) == nil)

      let jobs: [(String, String)] = [
        ("sleep", "sleep 3600"),
        (
          "shell",
          "/bin/zsh -c source /Users/me/.claude/shell-snapshots/snapshot-zsh-1.sh && eval 'npm run dev'"
        ),
        ("tests", "node /code/x/node_modules/.bin/vitest run"),
        ("nested", "claude -p review"),
      ]
      for (name, arguments) in jobs {
        var all = records
        all[30] = record(30, 10, arguments)
        all[31] = record(31, 30, "node worker.js")
        let busy = thread(name, root: 10, pids: helpers.map(\.processID) + [30, 31])
        #expect(BackgroundJobs.job(busy, records: all) == 30, "\(name)")
      }

      // A Codex CLI under its npm `node` wrapper: the native codex is the agent, not a job.
      var codex = thread("codex", root: 40, pids: [40, 41])
      codex.nativeProcessID = 41
      let codexRecords: [Int32: RawProcessRecord] = [
        40: record(40, 1, "node /usr/local/bin/codex"),
        41: record(41, 40, "/usr/local/lib/node_modules/@openai/codex/vendor/codex"),
      ]
      #expect(BackgroundJobs.job(codex, records: codexRecords) == nil)

      var withJob = records
      withJob[30] = record(30, 10, "sleep 3600")
      let threads = [
        thread("job", root: 10, pids: [10, 30]), thread("quiet", root: 50),
      ]
      let candidates = SessionEligibility.autoEndCandidates(
        .init(
          threads: threads, unused: ["job": .idle(8 * day), "quiet": .idle(8 * day)],
          protections: [:], scope: nil, inFlight: [], records: withJob))
      #expect(candidates.map(\.id) == ["quiet"])
    }

    @Test func candidatesAreUnusedInScopeRunningAndNotInFlight() {
      let threads = [
        thread("idle", root: 10, bytes: 300), thread("detached", root: 20),
        thread("paused", root: 30, paused: true), thread("acting", root: 40),
        thread("outside", root: 50), thread("used", root: 60), thread("kept", root: 70),
      ]
      let unused: [String: UnusedPolicy.Reason] = [
        "idle": .idle(8 * day), "detached": .detached, "paused": .idle(8 * day),
        "acting": .idle(8 * day), "outside": .idle(8 * day), "kept": .idle(8 * day),
      ]
      let candidates = SessionEligibility.autoEndCandidates(
        .init(
          threads: threads + [threads[0]], unused: unused, protections: ["kept": .kept],
          scope: [10, 20, 30, 40, 60, 70], inFlight: ["acting"]))
      #expect(
        candidates == [
          .init(id: "idle", reason: .idle(8 * day), memoryBytes: 300),
          .init(id: "detached", reason: .detached, memoryBytes: 10),
          .init(id: "kept", reason: .idle(8 * day), memoryBytes: 10, protected: true),
        ])
    }

    @MainActor final class Calls { var ids: [String] = [] }

    private func controller(acts: Bool, ended: @escaping @MainActor (AIThread) -> Bool)
      -> (AutoEndController, () -> [String])
    {
      let calls = Calls()
      let controller = AutoEndController(acts: acts) { thread in
        calls.ids.append(thread.id)
        return ended(thread)
      }
      return (controller, { calls.ids })
    }

    private func run(
      _ controller: AutoEndController, _ seconds: TimeInterval, away: Bool,
      mode: AutoEndSettings.Mode = .auto, threads: [AIThread], busy: Bool = false
    ) -> AutoEndController.Outcome {
      controller.run(
        .init(
          now: t0.addingTimeInterval(seconds), away: away, settings: .init(mode: mode, days: 7),
          scan: .init(
            threads: threads,
            unused: Dictionary(uniqueKeysWithValues: threads.map { ($0.id, .idle(8 * day)) }),
            protections: [:], scope: nil, inFlight: []),
          busy: busy))
    }

    @Test func endsThroughTheModelAndNotesOnReturn() async {
      let (controller, calls) = controller(acts: true) { _ in true }
      let threads = [thread("a", root: 10, bytes: 100), thread("b", root: 20, bytes: 200)]
      let first = run(controller, 0, away: true, threads: threads)
      #expect(await first.ending?.value == true)
      #expect(calls() == ["b"])
      #expect(run(controller, 10, away: true, threads: [threads[0]]).ending == nil)
      _ = await run(controller, 30, away: true, threads: [threads[0]]).ending?.value
      #expect(calls() == ["b", "a"])
      let back = run(controller, 40, away: false, threads: [])
      #expect(back.note == "Ended 2 sessions idle 8+ days · 300 B")
      #expect(back.ending == nil)
    }

    @Test func onlyTheInstanceThatActsEnds() {
      let (controller, calls) = controller(acts: false) { _ in true }
      let threads = [thread("a", root: 10)]
      for second in stride(from: 0.0, through: 300, by: 30) {
        let outcome = run(controller, second, away: true, threads: threads)
        #expect(outcome.ending == nil && outcome.note == nil)
      }
      #expect(calls().isEmpty)
    }

    @Test func askShowsNothingAndEndsNothing() {
      let (controller, calls) = controller(acts: true) { _ in true }
      let threads = [thread("a", root: 10)]
      for second in stride(from: 0.0, through: 300, by: 30) {
        let outcome = run(controller, second, away: true, mode: .ask, threads: threads)
        #expect(outcome.ending == nil && outcome.note == nil)
      }
      let back = run(controller, 330, away: false, mode: .ask, threads: threads)
      #expect(back.ending == nil && back.note == nil)
      #expect(calls().isEmpty)
    }

    @Test func nothingWhileTheUserIsEndingSessions() {
      let (controller, calls) = controller(acts: true) { _ in true }
      let outcome = run(controller, 0, away: true, threads: [thread("a", root: 10)], busy: true)
      #expect(outcome.ending == nil)
      #expect(calls().isEmpty)
    }
  }
}

extension AutoEndTests {
  @MainActor
  struct Model {
    /// The setting is written to the injected defaults only, never to the real domain.
    @Test func aChangeIsSavedToTheInjectedDefaults() {
      let defaults = TestDefaults("auto-end-model").defaults
      let model = DevProcessModel()
      model.autoEndDefaults = defaults
      model.setAutoEnd(.init(mode: .auto, days: 3))
      #expect(model.autoEnd == .init(mode: .auto, days: 3))
      #expect(AutoEndSettings.load(defaults) == .init(mode: .auto, days: 3))
    }

    @Test func theStateDumpReportsPresenceAndTheSetting() {
      func state(_ settings: AutoEndSettings, away: Bool) -> E2EState {
        var input = E2EState.Input(
          at: t0, risk: .normal, meeting: false, threads: [], unused: [:], protections: [:],
          ended: [], targets: [])
        input.away = away
        input.autoEnd = settings
        return E2EState.build(input)
      }
      #expect(state(.init(), away: false).autoEnd == "ask")
      #expect(!state(.init(), away: false).away)
      #expect(state(.init(mode: .auto, days: 9), away: true).autoEnd == "auto:9")
      #expect(state(.init(mode: .auto, days: 9), away: true).away)
    }

    /// What the scan saw before the target filter, so a run that misses its fakes says why.
    @Test func theStateDumpReportsWhatTheScanSaw() {
      var outer = AIThread(
        id: "outer", tool: .claudeCode, name: "Claude Code", directory: nil, terminal: nil,
        startedAt: nil, processIDs: [30], memoryBytes: 1, cpuPercent: 0, isPaused: false,
        isDetached: false)
      outer.rootProcessID = 30
      var input = E2EState.Input(
        at: t0, risk: .normal, meeting: false, threads: [outer], unused: [:], protections: [:],
        ended: [], targets: [12, 11])
      input.scanComplete = false
      let state = E2EState.build(input)
      #expect(state.threads.isEmpty)
      #expect(state.scanRoots == [30])
      #expect(state.validTargets == [11, 12])
      #expect(!state.scanComplete)
    }
  }
}

/// Which processes of an idle session are background jobs (Q10 amendment). The trees are copied
/// from `ps -axo pid,ppid,command` on the development Mac (2026-10-21); the jobs are what a Claude or Codex
/// tool call leaves running. When in doubt it is a job: failing safe means not ending.
struct BackgroundJobsTests {
  /// One session: the first line is the agent's root, each later line `(pid, parent, argv)`.
  private func session(
    _ tool: AITool, _ lines: [(Int32, Int32, String)], native: Int32? = nil
  ) -> (AIThread, [Int32: RawProcessRecord]) {
    var thread = AIThread(
      id: "t", tool: tool, name: tool.title, directory: "/code/t", terminal: nil, startedAt: nil,
      processIDs: lines.map(\.0), memoryBytes: 1, cpuPercent: 0, isPaused: false,
      isDetached: false)
    thread.rootProcessID = lines.first?.0
    thread.nativeProcessID = native
    let records = Dictionary(
      uniqueKeysWithValues: lines.map { ($0.0, StubWorld.record($0.0, parent: $0.1, $0.2)) })
    return (thread, records)
  }

  private func jobs(_ tool: AITool, _ lines: [(Int32, Int32, String)], native: Int32? = nil)
    -> [Int32]
  {
    let (thread, records) = session(tool, lines, native: native)
    return BackgroundJobs.jobs(thread, records: records)
  }

  private let claude: (Int32, Int32, String) = (
    100, 1, "/Users/me/.local/bin/claude --dangerously-skip-permissions --resume 5cbed286"
  )
  private let codex: (Int32, Int32, String) = (
    200, 1,
    "/Users/me/.local/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex --no-daemon"
  )

  /// An idle Claude session on this Mac: its MCP servers, the keep-awake of its last turn, and
  /// language servers. No job.
  @Test func claudeHelpersAreNotJobs() {
    #expect(
      jobs(
        .claudeCode,
        [
          claude,
          (101, 100, "npm exec @modelcontextprotocol/server-slack"),
          (
            102, 101, "node /Users/me/.npm/_npx/71b7d53511ff2b57/node_modules/.bin/mcp-server-slack"
          ),
          (103, 100, "/Users/me/.local/bin/chat mcp"),
          (104, 100, "/Users/me/.local/bin/chat mcp --ext"),
          (105, 100, "caffeinate -i -t 300"),
          (106, 100, "/Applications/Xcode.app/Contents/Developer/usr/bin/sourcekit-lsp"),
          (107, 100, "typescript-language-server --stdio"),
          (108, 100, "/usr/local/bin/vscode-json-language-server"),
          (109, 100, "npm exec @upstash/context7-mcp"),
          (110, 109, "node /Users/me/.npm/_npx/eea2bd7412d4593b/node_modules/.bin/context7-mcp"),
          // A helper only by its `--stdio` token.
          (111, 100, "/usr/local/bin/pyright-langserver --stdio"),
        ]
      ).isEmpty)
  }

  /// Codex runs a command as `zsh -lc '<cmd>'`, and zsh execs a single command in place, so a
  /// job is a direct child judged on its own argv. "mcp", "server-" or a caffeinate in it doesn't
  /// make it the agent's.
  @Test func codexCommandsThatLookLikeHelpersAreJobs() {
    for command in [
      "caffeinate -i swift test", "caffeinate -t 300 make", "pnpm --filter mcp dev",
      "pnpm --filter mcp-server dev", "node scripts/server-dev.mjs", "node scripts/mcp-dev.mjs",
      "python3 -m http.server 8000", "sleep 3600",
    ] {
      #expect(jobs(.codexCLI, [codex, (201, 200, command)]) == [201], "\(command)")
    }
  }

  /// A Claude Bash tool call is a shell; one whose argv mentions mcp or `--stdio` is still a job.
  @Test func aShellIsAlwaysAJob() {
    for command in [
      "/bin/zsh -c source /Users/me/.claude/shell-snapshots/snapshot-zsh-1.sh && eval 'pnpm --filter mcp dev'",
      "/bin/zsh -c source /Users/me/.claude/shell-snapshots/snapshot-zsh-1.sh && eval 'node server.js --stdio --port 4000'",
      "/bin/bash -c npx @modelcontextprotocol/inspector",
    ] {
      #expect(jobs(.claudeCode, [claude, (101, 100, command)]) == [101], "\(command)")
    }
  }

  /// Only a direct child of the agent can be a helper; what a job starts is the job's, however
  /// it looks.
  @Test func onlyADirectChildOfTheAgentIsAHelper() {
    let lines: [(Int32, Int32, String)] = [
      claude,
      (101, 100, "/bin/zsh -c source snap.sh && eval 'pnpm dev'"),
      (102, 101, "node /code/x/node_modules/.bin/mcp-server-everything"),
      (103, 101, "typescript-language-server --stdio"),
      (104, 101, "caffeinate -i -t 300"),
    ]
    #expect(jobs(.claudeCode, lines) == [101, 102, 103, 104])
    // Under a Codex npm wrapper, the native codex is the agent too: its MCP child is a helper.
    #expect(
      jobs(
        .codexCLI,
        [
          (300, 1, "node /usr/local/bin/codex"),
          (301, 300, "/usr/local/lib/node_modules/@openai/codex/vendor/codex"),
          (302, 301, "/Users/me/.local/bin/chat mcp"), (303, 301, "pnpm test"),
        ], native: 301) == [303])
  }

  /// An idle Codex session on this Mac (2026-10-21): code mode's `@oai/cua-repl` with its
  /// `node_repl` kernel and app-server, a bare `node_repl`, the code-mode host, and MCP servers,
  /// remote ones through `mcp-remote`. No job, so End after N days can end Codex too.
  @Test func codexHelpersAreNotJobs() {
    let cua = "/Applications/ChatGPT.app/Contents/Resources/cua_node"
    #expect(
      jobs(
        .codexCLI,
        [
          codex,
          (201, 200, "/Users/me/.local/bin/chat mcp --ext"),
          (202, 200, "\(cua)/bin/node_repl"),
          (203, 200, "\(cua)/bin/node \(cua)/lib/node_modules/@oai/cua-repl/bin/cua-repl.mjs"),
          (204, 203, "\(cua)/bin/node_repl"),
          (
            205, 204,
            "\(cua)/bin/node --experimental-vm-modules /var/folders/T/.tmpPfDUKj/kernel.js"
          ),
          (206, 204, "\(cua)/bin/node /var/folders/T/.tmpPfDUKj/trusted-worker.js /Users/me/x"),
          (
            207, 204,
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex app-server --listen stdio://"
          ),
          (208, 200, "npm exec @upstash/context7-mcp"),
          (209, 208, "node /Users/me/.npm/_npx/eea2bd7412d4593b/node_modules/.bin/context7-mcp"),
          (210, 200, "npm exec @modelcontextprotocol/server-slack"),
          (211, 200, "npm exec mcp-remote https://mcp.sentry.dev/sse --transport sse"),
          (212, 200, "npm exec mcp-remote https://api.example.com/mcp"),
          (
            213, 200,
            "/Users/me/.local/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex-code-mode-host"
          ),
        ]
      ).isEmpty)
  }

  /// Code mode on this Mac runs no shell under itself (only its kernel, worker and app-server),
  /// but if a helper ever does, that shell and what it runs are a job.
  @Test func aShellUnderAHelperIsAJob() {
    let cua = "/Applications/ChatGPT.app/Contents/Resources/cua_node"
    #expect(
      jobs(
        .codexCLI,
        [
          codex, (201, 200, "\(cua)/bin/node_repl"), (202, 201, "/bin/zsh -lc cargo build"),
          (203, 202, "cargo build"), (204, 201, "\(cua)/bin/node /tmp/kernel.js"),
        ]) == [202, 203])
  }

  /// A direct child whose first argument is exactly `mcp` is an MCP server the agent started:
  /// `<tool> mcp` is how CLIs ship their server (courier and chat on this Mac, 2026-10-29, under
  /// almost every Claude session).
  @Test func aToolsMcpSubcommandIsAHelper() {
    for helper in [
      "/Users/me/.local/bin/courier mcp", "/Users/me/.local/bin/courier mcp --ext",
      "/Users/me/.local/bin/chat mcp --ext", "courier mcp",
    ] {
      #expect(jobs(.claudeCode, [claude, (101, 100, helper)]).isEmpty, "\(helper)")
      #expect(jobs(.codexCLI, [codex, (201, 200, helper)]).isEmpty, "\(helper)")
    }
  }

  /// The `mcp` rule reads the tool's own subcommand only. A shell running it is a job, as every
  /// shell is; a script or task a runner starts (`node mcp.js`, `pnpm mcp`, `make mcp`) is the
  /// project's code, not an MCP server the agent started, so it stays a job; and `mcp` further
  /// along the argv doesn't count.
  @Test func mcpElsewhereIsStillAJob() {
    for job in [
      "/bin/zsh -c courier mcp", "/bin/zsh -c source snap.sh && eval 'courier mcp'",
      "node mcp.js", "node mcp", "pnpm mcp", "npm run mcp", "make mcp", "python3 mcp",
      "courier serve mcp", "courier mcp-dev", "courier --verbose mcp",
    ] {
      #expect(jobs(.claudeCode, [claude, (101, 100, job)]) == [101], "\(job)")
    }
    // What a shell under the `mcp` helper runs is a job.
    #expect(
      jobs(
        .claudeCode,
        [claude, (101, 100, "/Users/me/.local/bin/courier mcp"), (102, 101, "/bin/zsh -c ls")])
        == [102])
  }

  /// Codex's bundled meetings plugin on this Mac (2026-10-29): its own runtime's node runs the
  /// plugin's MCP script, which starts a python server. A helper, with what it starts. The same
  /// script on the PATH's node, or another script on Codex's node, stays a job.
  @Test func codexsBundledMcpPluginIsAHelper() {
    let runtime = "/Users/me/.cache/codex-runtimes/codex-primary-runtime/dependencies"
    #expect(
      jobs(
        .codexCLI,
        [
          codex,
          (
            201, 200,
            "\(runtime)/node/bin/node ./scripts/start_bundled_meetings_mcp.mjs --profile production"
          ),
          (
            202, 201,
            "\(runtime)/python/bin/python3.12 -u /Users/me/.codex/plugins/cache/m/server.py"
          ),
        ]
      ).isEmpty)
    for job in [
      "/usr/local/bin/node ./scripts/start_bundled_meetings_mcp.mjs",
      "\(runtime)/node/bin/node ./scripts/dev.mjs",
      "\(runtime)/node/bin/node ./scripts/mcp-dev.mjs",
      "\(runtime)/python/bin/python3.12 ./scripts/start_mcp.py",
    ] {
      #expect(jobs(.codexCLI, [codex, (201, 200, job)]) == [201], "\(job)")
    }
  }

  @Test func caffeinateIsAHelperOnlyWithoutAUtility() {
    for helper in ["caffeinate -i -t 300", "caffeinate -dis", "caffeinate -w 4242", "caffeinate"] {
      #expect(jobs(.claudeCode, [claude, (101, 100, helper)]).isEmpty, "\(helper)")
    }
    for job in ["caffeinate -i swift test", "caffeinate swift build", "caffeinate -w 4242 make"] {
      #expect(jobs(.claudeCode, [claude, (101, 100, job)]) == [101], "\(job)")
    }
  }
}

/// A fixed process world for a model: what each scan returns, and every signal recorded instead of
/// sent. Nothing real is scanned or signalled.
final class StubWorld: @unchecked Sendable {
  private let lock = NSLock()
  private var threads: [AIThread]
  private var records: [Int32: RawProcessRecord]
  private var duringScan: (@Sendable () -> Void)?
  private var sent = 0
  private var _remaining = 0
  private var _locked = true

  init(_ threads: [AIThread], records: [Int32: RawProcessRecord] = [:]) {
    self.threads = threads
    self.records = records
  }

  /// Processes the stub reports still alive after a Quit.
  var remaining: Int {
    get { lock.withLock { _remaining } }
    set { lock.withLock { _remaining = newValue } }
  }

  /// The screen lock, as the session dictionary reports it.
  var locked: Bool {
    get { lock.withLock { _locked } }
    set { lock.withLock { _locked = newValue } }
  }

  /// Signals the model asked for.
  var signals: Int { lock.withLock { sent } }

  func set(_ threads: [AIThread]) { lock.withLock { self.threads = threads } }

  /// Runs once, on the scan's own thread, during the next scan.
  func duringNextScan(_ action: @escaping @Sendable () -> Void) {
    lock.withLock { duringScan = action }
  }

  func snapshot() -> DevProcessSnapshot {
    let (threads, records, action) = lock.withLock {
      defer { duringScan = nil }
      return (self.threads, self.records, duringScan)
    }
    action?()
    return DevProcessSnapshot(
      processes: [], identities: [:], threads: threads, resources: [],
      portsComplete: true, records: records)
  }

  func execute(_ request: WorkloadControl.Request) -> WorkloadControl.Result {
    lock.withLock {
      sent += 1
      return .init(affected: 1, remaining: _remaining, retainedBytes: 0, identities: [])
    }
  }

  /// A detached Claude session with a resume command: unused at any idle age, with no agent
  /// status to re-read.
  static func session(_ id: String = "s", root: Int32 = 40_000, children: [Int32] = [])
    -> AIThread
  {
    var thread = AIThread(
      id: id, tool: .claudeCode, name: "Claude Code", directory: "/code/\(id)", terminal: nil,
      startedAt: nil, processIDs: [root] + children, memoryBytes: 10, cpuPercent: 0,
      isPaused: false, isDetached: true)
    thread.rootProcessID = root
    thread.sessionID = "00000000-0000-4000-8000-000000000042"
    return thread
  }

  static func record(_ pid: Int32, parent: Int32, _ arguments: String) -> RawProcessRecord {
    .init(
      processID: pid, parentProcessID: parent, userID: Int(getuid()), cpuPercent: 0,
      residentKilobytes: 1, elapsed: "1-00:00:00", terminal: nil, arguments: arguments)
  }
}

extension AutoEndTests {
  /// The model's own end path, with a stubbed scan and signal and End after 7 days on.
  @MainActor
  struct ModelEnds {
    private func model(_ world: StubWorld) async -> DevProcessModel {
      let model = DevProcessModel(
        meetingMonitor: MeetingMonitor(sources: .none),
        effects: .init(snapshot: { world.snapshot() }, execute: { world.execute($0) }))
      model.autoEndDefaults = TestDefaults("auto-end-model-ends").defaults
      model.endedDefaults = TestDefaults("auto-end-model-ended").defaults
      model.presence = PresenceMonitor(
        session: { ["CGSSessionScreenIsLocked": world.locked] }, idle: { 0 })
      model.setAutoEnd(.init(mode: .auto, days: 7))
      await model.refreshNow()
      return model
    }

    @Test func endsWhileAwayInAutoMode() async {
      let world = StubWorld([StubWorld.session()])
      let model = await model(world)
      #expect(await model.endAutomatically(StubWorld.session()))
      #expect(world.signals == 1)
    }

    /// Q10: the end waits for a fresh scan; the user back at the Mac meanwhile means no signal.
    @Test func nothingIsSignalledWhenTheUserReturnsDuringTheRefresh() async {
      let world = StubWorld([StubWorld.session()])
      let model = await model(world)
      world.duringNextScan { world.locked = false }
      #expect(await !model.endAutomatically(StubWorld.session()))
      #expect(world.signals == 0)
    }

    /// Ask me chosen while the fresh scan runs: no signal either.
    @Test func nothingIsSignalledWhenAskMeIsChosenDuringTheRefresh() async {
      let world = StubWorld([StubWorld.session()])
      let model = await model(world)
      world.duringNextScan {
        DispatchQueue.main.sync {
          MainActor.assumeIsolated { model.setAutoEnd(.init(mode: .ask, days: 7)) }
        }
      }
      #expect(await !model.endAutomatically(StubWorld.session()))
      #expect(world.signals == 0)
    }

    /// An automatic end is an automatic action: no row message, whatever its outcome. The same
    /// end from the user's review does post one.
    @Test func anAutomaticEndPostsNoRowMessage() async {
      let world = StubWorld([StubWorld.session()])
      let model = await model(world)
      #expect(await model.endAutomatically(StubWorld.session()))
      #expect(model.threadMessage == nil)
      world.remaining = 1
      #expect(await !model.endAutomatically(StubWorld.session()))
      #expect(world.signals == 2)
      #expect(model.threadMessage == nil)
      _ = await model.endUnused([StubWorld.session()])
      #expect(model.threadMessage?.contains("still running") == true)
    }

    /// The end the scheduler waits on: only a confirmed quit lands as ended. A session that
    /// became active by the fresh scan, or that still runs after the Quit, lands as not ended,
    /// so it is neither counted in the note nor retried in this away spell.
    @Test func becameActiveOrStillRunningLandsAsNotEnded() async {
      let world = StubWorld([StubWorld.session()])
      let model = await model(world)
      let controller = AutoEndController(acts: true) { await model.endAutomatically($0) }
      func run(_ seconds: TimeInterval) async -> Bool? {
        await controller.run(
          .init(
            now: t0.addingTimeInterval(seconds), away: true, settings: model.autoEnd,
            scan: .init(
              threads: [StubWorld.session()], unused: ["s": .idle(8 * day)], protections: [:],
              scope: nil, inFlight: []))
        ).ending?.value
      }

      var busy = StubWorld.session()
      busy.agentStatus = .busy
      world.set([busy])
      #expect(await run(0) == false)
      #expect(world.signals == 0, "a session that became active was signalled")
      #expect(controller.scheduler.refused == ["s"])

      // A new away spell: back, then away again.
      _ = controller.run(
        .init(
          now: t0.addingTimeInterval(10), away: false, settings: model.autoEnd,
          scan: .init(threads: [], unused: [:], protections: [:], scope: nil, inFlight: [])))
      world.set([StubWorld.session()])
      world.remaining = 1
      #expect(await run(40) == false)
      #expect(world.signals == 1)
      #expect(controller.scheduler.refused == ["s"])
      #expect(controller.scheduler.ended.isEmpty)

      _ = controller.run(
        .init(
          now: t0.addingTimeInterval(50), away: false, settings: model.autoEnd,
          scan: .init(threads: [], unused: [:], protections: [:], scope: nil, inFlight: [])))
      world.remaining = 0
      #expect(await run(80) == true)
      #expect(controller.scheduler.ended == [8 * day])
    }

    /// A background job seen by the fresh scan holds an automatic end, with no signal sent. The
    /// same session ended from the user's review still ends: the rule is for automatic ends only.
    @Test func aBackgroundJobOnTheFreshScanHoldsTheAutomaticEndOnly() async {
      let session = StubWorld.session(children: [40_001])
      let world = StubWorld(
        [session],
        records: [
          40_000: StubWorld.record(40_000, parent: 1, "claude"),
          40_001: StubWorld.record(40_001, parent: 40_000, "sleep 3600"),
        ])
      let model = await model(world)
      #expect(await !model.endAutomatically(session))
      #expect(world.signals == 0)
      #expect(await model.endUnused([session]).confirmed == 1)
      #expect(world.signals == 1)
    }
  }
}
