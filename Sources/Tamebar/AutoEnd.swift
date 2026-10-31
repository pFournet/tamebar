import Foundation
import os

/// "Unused AI sessions" in Settings (Q10, Amendment B): Ask me, the default, which is quiet, or End
/// after N days, 1 to 30, which ends sessions idle that long while the user is away. UserDefaults
/// `sessions.autoEnd.v1`, as JSON.
struct AutoEndSettings: Codable, Equatable, Sendable {
  static let key = "sessions.autoEnd.v1"
  static let dayRange = 1...30
  static let defaultDays = 7

  enum Mode: String, Codable, CaseIterable, Sendable {
    /// Nothing is ended, and nothing is said: unused sessions wait in the panel.
    case ask
    /// Sessions idle `days` or more are ended while the user is away, one note on return.
    case auto
  }

  var mode: Mode
  var days: Int {
    didSet { days = Self.clamp(days) }
  }

  init(mode: Mode = .ask, days: Int = defaultDays) {
    self.mode = mode
    self.days = Self.clamp(days)
  }

  static func clamp(_ days: Int) -> Int {
    min(max(days, dayRange.lowerBound), dayRange.upperBound)
  }

  /// Field by field: an unknown mode is Ask me, a missing or unreadable day count is 7, and any
  /// count is brought back into 1…30.
  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    mode = (try? values.decodeIfPresent(Mode.self, forKey: .mode)) ?? .ask
    days = Self.clamp((try? values.decodeIfPresent(Int.self, forKey: .days)) ?? Self.defaultDays)
  }

  /// In auto mode, the unused cutoff the setting implies: a session idle `days` counts as unused
  /// even under the usual 7 days, so it can be ended. Nil in Ask me.
  var unusedCutoffDays: Int? { mode == .auto ? days : nil }

  /// The saved setting, or the default when there is none or it can't be read.
  static func load(_ defaults: UserDefaults) -> AutoEndSettings {
    guard let data = defaults.data(forKey: key),
      let settings = try? JSONDecoder().decode(AutoEndSettings.self, from: data)
    else { return AutoEndSettings() }
    return settings
  }

  func save(_ defaults: UserDefaults) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(self) else { return }
    defaults.set(data, forKey: Self.key)
  }
}

/// Decides which unused session to end next while the user is away (Q10, Amendment B). Pure.
///
/// Nothing happens unless the mode is auto and the user is away. A candidate is a session whose unused
/// reason is `.idle(t)` with `t` at least `days`: never a detached one, which has no idle age, and
/// never a protected one. One session per 30 s, largest first, and never while one is still being
/// ended. It counts the sessions that did end during the away spell; on the first tick back with
/// none still in flight it returns one note, "Ended N sessions idle D+ days · 1.1 GB", D being the
/// smallest idle age in whole days and the amount the memory they held when picked.
struct AutoEndScheduler: Equatable, Sendable {
  static let spacing: TimeInterval = 30

  struct Candidate: Equatable, Sendable {
    let id: String
    let reason: UnusedPolicy.Reason
    let memoryBytes: UInt64
    var protected = false
  }

  struct Tick {
    let now: Date
    let away: Bool
    let settings: AutoEndSettings
    let candidates: [Candidate]
  }

  struct Step: Equatable {
    /// The session to end now.
    var end: String?
    /// The note for the user's return.
    var note: String?
  }

  private(set) var lastStartedAt: Date?
  /// Ends started and not landed yet, with the idle age each was chosen at.
  private(set) var pending: [String: TimeInterval] = [:]
  /// The idle ages of the sessions ended in this away spell.
  private(set) var ended: [TimeInterval] = []
  /// The memory of each end started and not landed yet, then of those ended this spell.
  private var pendingBytes: [String: UInt64] = [:]
  private var freed: UInt64 = 0
  /// Sessions whose end didn't land in this away spell: not tried again before the user returns.
  private(set) var refused: Set<String> = []

  mutating func step(_ tick: Tick) -> Step {
    guard tick.away else {
      // Back: once nothing is in flight, the spell is over.
      guard pending.isEmpty else { return Step() }
      let note = Self.note(ended, freed: freed)
      ended = []
      freed = 0
      refused = []
      return Step(note: note)
    }
    guard tick.settings.mode == .auto, pending.isEmpty,
      lastStartedAt.map({ tick.now.timeIntervalSince($0) >= Self.spacing }) ?? true
    else { return Step() }
    let threshold = TimeInterval(tick.settings.days) * UnusedPolicy.day
    let next =
      tick.candidates
      .compactMap { candidate -> (Candidate, TimeInterval)? in
        guard !candidate.protected, !refused.contains(candidate.id),
          case .idle(let idle) = candidate.reason, idle >= threshold
        else { return nil }
        return (candidate, idle)
      }
      .max { a, b in
        (a.0.memoryBytes, b.0.id) < (b.0.memoryBytes, a.0.id)
      }
    guard let (candidate, idle) = next else { return Step() }
    pending[candidate.id] = idle
    pendingBytes[candidate.id] = candidate.memoryBytes
    lastStartedAt = tick.now
    return Step(end: candidate.id)
  }

  /// An end started by `step` finished: `ended` when every process of the session exited.
  mutating func landed(_ id: String, ended didEnd: Bool) {
    guard let idle = pending.removeValue(forKey: id) else { return }
    let bytes = pendingBytes.removeValue(forKey: id) ?? 0
    if didEnd {
      ended.append(idle)
      freed += bytes
    } else {
      refused.insert(id)
    }
  }

  /// The note on return; `freed`, when known, says what the ends gave back.
  static func note(_ idleAges: [TimeInterval], freed: UInt64 = 0) -> String? {
    guard let smallest = idleAges.min() else { return nil }
    let count = idleAges.count
    let days = Int(smallest / UnusedPolicy.day)
    return "Ended \(count) \(count == 1 ? "session" : "sessions") idle \(days)+ "
      + (days == 1 ? "day" : "days") + (freed > 0 ? " · \(ByteText.full(freed))" : "")
  }
}

/// Something an idle session started is still running (Q10 amendment, 2026-10-21): "do not touch a
/// session who is already working". The agent can say idle while a `run_in_background` shell, a
/// dev server with no port, a test runner or a `sleep` it started still runs. Such a session is
/// never ended automatically; ending it from the panel is unchanged. Pure.
enum BackgroundJobs {
  /// Helpers known by their executable name: Codex's code-mode REPL and host.
  static let helperNames: Set<String> = ["node_repl", "codex-code-mode-host"]

  /// A direct child of the agent that belongs to the agent, not to its work. It is judged on its
  /// executable name and its own arguments as tokens, never on a substring of the whole argv: a
  /// Codex command (`zsh -lc` execs it in place) can mention mcp, server- or caffeinate and still
  /// be a job. When in doubt, it is a job.
  /// - A shell never is: shells are how tool calls and background jobs run.
  /// - `node_repl`, `codex-code-mode-host`; a language server (`…-lsp`, `…language-server…`).
  /// - An MCP server: `mcp-server-…` or `…-mcp` by name, `--stdio` as a token, a package a runner
  ///   starts that is one, or a known helper package (`isServerPackage`).
  /// - A tool's own `mcp` subcommand: the first argument is exactly `mcp` (`chat mcp`, `courier
  ///   mcp --ext`), the way a CLI ships its MCP server. Not for a runner (`isRunner`): there the
  ///   first argument is the project's script or task (`node mcp.js`, `pnpm mcp`, `make mcp`).
  /// - Codex's bundled MCP plugins: Codex's own node runtime running a script named like an MCP
  ///   server (`isCodexBundledServer`).
  /// - `caffeinate` with no utility to run: Claude's own keep-awake, `caffeinate -i -t 300`.
  static func isHelper(_ record: RawProcessRecord) -> Bool {
    let name = AIThreadGrouping.executableName(record.arguments)
    if AgentSignals.toolShells.contains(name) { return false }
    let rest = tokens(after: name, in: record.arguments)
    if name == "caffeinate" { return !caffeinateRunsUtility(rest) }
    if helperNames.contains(name) || name.hasSuffix("-lsp") || name.contains("language-server")
      || isServerName(name) || (rest.first == "mcp" && !isRunner(name)) || rest.contains("--stdio")
      || isCodexBundledServer(record.arguments)
    {
      return true
    }
    return package(name, rest).map(isServerPackage) ?? false
  }

  /// Codex starts its plugins' MCP servers with the node of its own runtime, from the plugin's
  /// folder: `~/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node
  /// ./scripts/start_bundled_meetings_mcp.mjs` (seen under every Codex session here, 2026-10-29).
  /// Both must hold: the executable is under `/.cache/codex-runtimes/`, and the script's name,
  /// its extension dropped, is an MCP server's (`…-mcp`, `…_mcp`, `mcp-server-…`). A project's
  /// script run with the PATH's node, or another script on Codex's node, stays a job.
  static func isCodexBundledServer(_ arguments: String) -> Bool {
    let tokens = arguments.split(separator: " ").map(String.init)
    guard let executable = tokens.first, executable.contains("/.cache/codex-runtimes/"),
      executable.hasSuffix("/node"),
      let script = package("node", Array(tokens.dropFirst()))
    else { return false }
    let file = (script as NSString).lastPathComponent
    let base = (file as NSString).deletingPathExtension
    return isServerName(base) || base.hasSuffix("_mcp")
  }

  /// Executables whose first argument is the project's script or task, not a subcommand of the
  /// tool: package managers, script runners, interpreters and build tools.
  static func isRunner(_ name: String) -> Bool {
    if runnerNames.contains(name) { return true }
    // Versioned interpreters: python3, python3.12, ruby3.3, node22.
    return ["python", "ruby", "node", "perl", "php"].contains { name.hasPrefix($0) }
  }

  static let runnerNames: Set<String> = [
    "npm", "pnpm", "yarn", "npx", "pnpx", "bun", "bunx", "deno", "uv", "uvx", "pip", "pipx",
    "poetry", "make", "gmake", "just", "task", "cargo", "go", "swift", "java", "dotnet",
    "env", "nohup", "time", "watch", "xargs", "exec", "sudo", "nice", "timeout",
  ]

  /// An MCP server's executable or package name.
  static func isServerName(_ name: String) -> Bool {
    name.hasPrefix("mcp-server-") || name.hasSuffix("-mcp")
  }

  /// Package names of helpers that aren't named like an MCP server: `mcp-remote`, the bridge to a
  /// remote MCP server, and Codex code mode's `@oai/cua-repl` (seen on this Mac, 2026-10-21).
  static let helperPackages: Set<String> = ["mcp-remote", "@oai/cua-repl"]

  /// A package that is an MCP server or a known helper: under `@modelcontextprotocol/`, in
  /// `helperPackages`, or one whose name (version dropped) is a server name. A script path counts
  /// by the package folder it sits in (`…/node_modules/@oai/cua-repl/bin/cua-repl.mjs`).
  static func isServerPackage(_ package: String) -> Bool {
    if package.contains("@modelcontextprotocol/") { return true }
    if helperPackages.contains(where: { package == $0 || package.contains("/\($0)/") }) {
      return true
    }
    var name = package.split(separator: "/").last.map(String.init) ?? package
    if let at = name.dropFirst().firstIndex(of: "@") { name = String(name[..<at]) }
    return isServerName(name) || helperPackages.contains(name)
  }

  /// The package a runner starts (`npx`, `npm exec`, `pnpm dlx`, `uvx`…), or the script `node`
  /// runs; nil for anything else.
  static func package(_ name: String, _ rest: [String]) -> String? {
    var arguments = rest[...]
    switch name {
    case "npm":
      guard let command = arguments.first, ["exec", "x"].contains(command) else { return nil }
      arguments = arguments.dropFirst()
    case "pnpm", "yarn":
      guard arguments.first == "dlx" else { return nil }
      arguments = arguments.dropFirst()
    case "npx", "pnpx", "bunx", "uvx", "node", "bun":
      break
    default:
      return nil
    }
    return arguments.first { !$0.hasPrefix("-") }
  }

  /// `caffeinate`'s arguments name a utility to run: anything that isn't a flag or the value of
  /// `-t` or `-w`.
  static func caffeinateRunsUtility(_ rest: [String]) -> Bool {
    var index = rest.startIndex
    while index < rest.endIndex {
      let argument = rest[index]
      guard argument.hasPrefix("-") else { return true }
      index += argument == "-t" || argument == "-w" ? 2 : 1
    }
    return false
  }

  /// The arguments after the executable, split on spaces. An absolute executable path may hold
  /// spaces, so they start after the token that ends with its name.
  static func tokens(after name: String, in arguments: String) -> [String] {
    let tokens = arguments.split(separator: " ").map(String.init)
    guard let index = tokens.firstIndex(where: { $0 == name || $0.hasSuffix("/" + name) }) else {
      return Array(tokens.dropFirst())
    }
    return Array(tokens[(index + 1)...])
  }

  /// The first process of the session that is a background job; nil when there is none.
  static func job(_ thread: AIThread, records: [Int32: RawProcessRecord]) -> Int32? {
    jobs(thread, records: records).first
  }

  /// Every process of the session that is neither the agent (its root, its native process, its
  /// first process) nor a helper or something a helper started. Only a direct child of the agent
  /// can be a helper: whatever a job starts is the job's, however it looks. A process off the
  /// agent's tree in the scan counts as a job.
  static func jobs(_ thread: AIThread, records: [Int32: RawProcessRecord]) -> [Int32] {
    let agent = Set(
      [thread.processIDs.first, thread.rootProcessID, thread.nativeProcessID].compactMap { $0 })
    let members = Set(thread.processIDs)
    return thread.processIDs.filter { pid in
      guard !agent.contains(pid), records[pid] != nil else { return false }
      // Up the parents to the agent's direct child.
      var chain: [RawProcessRecord] = []
      var current = pid
      var visited: Set<Int32> = []
      while !agent.contains(current) {
        guard members.contains(current), visited.insert(current).inserted,
          let record = records[current]
        else { return true }
        chain.append(record)
        current = record.parentProcessID
      }
      guard let direct = chain.last, isHelper(direct) else { return true }
      // A shell a helper runs is a command, not the helper: it and what it runs are a job.
      return chain.dropLast().contains {
        AgentSignals.toolShells.contains(AIThreadGrouping.executableName($0.arguments))
      }
    }
  }
}

/// The model-side glue between a scan and `AutoEndScheduler`.
enum AutoEndWiring {
  struct Scan {
    let threads: [AIThread]
    let unused: [String: UnusedPolicy.Reason]
    let protections: [String: UnusedPolicy.Protection]
    /// The root PIDs Tamebar may act on: the e2e targets. Nil outside e2e mode.
    let scope: Set<Int32>?
    /// Threads with a signal in flight.
    let inFlight: Set<String>
    /// The scan's `ps` records by PID, for `BackgroundJobs`.
    var records: [Int32: RawProcessRecord] = [:]
  }

  /// Every unused session Tamebar may act on, with its reason and protection: in scope, not
  /// paused (a stopped process can't take a Quit), with no signal in flight, and `endable`. The
  /// scheduler picks among them.
  static func candidates(_ scan: Scan) -> [AutoEndScheduler.Candidate] {
    var seen: Set<String> = []
    return scan.threads.compactMap { thread in
      guard seen.insert(thread.id).inserted, let reason = scan.unused[thread.id],
        !thread.isPaused, !scan.inFlight.contains(thread.id),
        AutoPauseWiring.inScope(thread, scope: scan.scope),
        endable(thread, records: scan.records)
      else { return nil }
      return .init(
        id: thread.id, reason: reason, memoryBytes: thread.memoryBytes,
        protected: scan.protections[thread.id] != nil)
    }
  }

  /// Ending it automatically leaves a way back: it gets an Ended sessions entry with a resume
  /// command (Q10). A session without one (no session id, or a Codex session in ~, /tmp or a dot
  /// folder, which has no folder to resume in) is only ever a manual offer in the panel.
  static func resumable(_ thread: AIThread) -> Bool {
    EndPlan.entry(thread, now: .distantPast)?.resumeCommand != nil
  }

  /// What only an automatic end requires, beyond the unused and protection rules every end has:
  /// the session is resumable and has no background job running.
  static func endable(_ thread: AIThread, records: [Int32: RawProcessRecord]) -> Bool {
    resumable(thread) && BackgroundJobs.job(thread, records: records) == nil
  }

  /// The click-time plan (`EndPlan.plan`) for an automatic end, against the fresh scan's records:
  /// a session that is no longer `endable` counts as became active, and gets no signal.
  static func recheck(_ plan: EndPlan.Decision, records: [Int32: RawProcessRecord])
    -> EndPlan.Decision
  {
    var plan = plan
    let kept = plan.end.filter { endable($0, records: records) }
    plan.becameActive += plan.end.count - kept.count
    plan.end = kept
    return plan
  }
}

/// Runs the scheduler on each scan and ends what it picks through the model's `endUnused`, which
/// waits for a fresh scan, re-checks the session (Q7) and records it in Ended sessions. It acts
/// only in the instance whose automatic pause acts: the installed build holding `autopause.lock`.
@MainActor
final class AutoEndController {
  let acts: Bool
  private(set) var scheduler = AutoEndScheduler()
  /// Ends one session; true when every process of it exited.
  private let end: @MainActor (AIThread) async -> Bool

  private static let log = Logger(subsystem: AppBrand.bundleIdentifier, category: "autoend")

  init(acts: Bool, end: @escaping @MainActor (AIThread) async -> Bool) {
    self.acts = acts
    self.end = end
  }

  struct Tick {
    let now: Date
    let away: Bool
    let settings: AutoEndSettings
    let scan: AutoEndWiring.Scan
    /// The user is ending sessions from a review: nothing new starts meanwhile.
    var busy = false
  }

  struct Outcome {
    var note: String?
    /// The end started this tick, true once it landed with the session gone.
    var ending: Task<Bool, Never>?
    /// The memory of the session being ended, for the usage record (Q16).
    var endingBytes: UInt64 = 0
  }

  func run(_ tick: Tick) -> Outcome {
    guard acts else { return Outcome() }
    let candidates = tick.busy ? [] : AutoEndWiring.candidates(tick.scan)
    let step = scheduler.step(
      .init(now: tick.now, away: tick.away, settings: tick.settings, candidates: candidates))
    var outcome = Outcome(note: step.note)
    guard let id = step.end else { return outcome }
    guard let thread = tick.scan.threads.first(where: { $0.id == id }) else {
      scheduler.landed(id, ended: false)
      return outcome
    }
    let end = end
    outcome.endingBytes = thread.memoryBytes
    outcome.ending = Task { [weak self] in
      let ended = await end(thread)
      self?.scheduler.landed(id, ended: ended)
      if !ended {
        Self.log.notice(
          "Didn't end \(thread.displayName, privacy: .public): changed or still running")
      }
      return ended
    }
    return outcome
  }
}
