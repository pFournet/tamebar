import Foundation

/// The `tamebar` command line: `status`, `sessions`, `stopped`, `history` and `trend`, read-only;
/// `mark`, which only appends a line to `usage-markers.jsonl` (Q16); and Q19's `wait` (the
/// `SessionStart` hook: a new session waits while the Mac is struggling) and `start` (starts the
/// sessions waiting); and `hooks`, which adds or removes that hook in Claude Code's and Codex's
/// settings (P2). The app's own executable runs it from `TamebarEntry`, before anything of the
/// app starts, so it never shows a window or a Dock icon. It reads the app's files and settings
/// and scans the Mac; apart from `mark`'s marker, `wait`/`start`'s files in `waiting/` and
/// `hooks install|remove`'s edit of the agents' hook files it never writes a file or a setting,
/// takes `autopause.lock`, or sends a signal. Schema: docs/CLI.md.
enum CLI {
  enum Command: Equatable {
    case status(json: Bool)
    case sessions(json: Bool, all: Bool)
    case stopped(json: Bool)
    case history(json: Bool, since: TimeInterval)
    case trend(json: Bool, days: Int, compare: String?)
    case mark(String)
    /// Q19's start hook: waits while the Mac is struggling, then returns 0.
    case wait
    /// Starts the sessions of a project (or `all`) waiting for memory.
    case start(String)
    /// Adds, removes or reports the start hook in the agents' settings (P2).
    case hooks(StartHooks.Action)
    case help(String?)
  }

  struct UsageError: Error, Equatable {
    let message: String
  }

  static let commands = [
    "status", "sessions", "stopped", "history", "trend", "mark", "wait", "start", "hooks",
  ]
  static let defaultSince: TimeInterval = 86_400

  /// The command line, not the app: a bare word first (the app's own flags all start with a
  /// dash, and LaunchServices adds `-psn_…`), or a request for help.
  static func wants(_ arguments: [String]) -> Bool {
    guard let first = arguments.first else { return false }
    return !first.hasPrefix("-") || first == "--help" || first == "-h"
  }

  static func parse(_ arguments: [String]) -> Result<Command, UsageError> {
    guard let first = arguments.first, first != "--help", first != "-h" else {
      return .success(.help(nil))
    }
    if first == "help" {
      guard let topic = arguments.dropFirst().first else { return .success(.help(nil)) }
      guard commands.contains(topic), arguments.count == 2 else {
        return .failure(
          .init(message: "No help for \(arguments.dropFirst().joined(separator: " "))."))
      }
      return .success(.help(topic))
    }
    guard commands.contains(first) else {
      return .failure(.init(message: "Unknown command: \(first)."))
    }
    if first == "mark" { return parseMark(Array(arguments.dropFirst())) }
    if first == "start" { return parseStart(Array(arguments.dropFirst())) }
    if first == "hooks" { return parseHooks(Array(arguments.dropFirst())) }
    if first == "wait" {
      let rest = Array(arguments.dropFirst())
      if rest == ["--help"] || rest == ["-h"] { return .success(.help("wait")) }
      guard let extra = rest.first else { return .success(.wait) }
      return .failure(.init(message: "wait doesn't take \(extra)."))
    }
    var json = false
    var days: Int?
    var compare: String?
    var all = false
    var since: TimeInterval?
    var rest = Array(arguments.dropFirst())[...]
    while let argument = rest.popFirst() {
      switch argument {
      case "--help", "-h":
        return .success(.help(first))
      case "--json":
        json = true
      case "--all" where first == "sessions":
        all = true
      case "--since" where first == "history":
        guard let value = rest.popFirst() else {
          return .failure(.init(message: "--since needs a value, such as 1h, 24h or 7d."))
        }
        guard let seconds = parseSince(value) else {
          return .failure(.init(message: "--since \(value): use a number and m, h, d or w."))
        }
        since = seconds
      case let flag where first == "history" && flag.hasPrefix("--since="):
        let value = String(flag.dropFirst("--since=".count))
        guard let seconds = parseSince(value) else {
          return .failure(.init(message: "--since \(value): use a number and m, h, d or w."))
        }
        since = seconds
      case "--days" where first == "trend":
        guard let value = rest.popFirst() else {
          return .failure(.init(message: "--days needs a number from 1 to 366."))
        }
        guard let count = parseDays(value) else {
          return .failure(.init(message: "--days \(value): use a number from 1 to 366."))
        }
        days = count
      case let flag where first == "trend" && flag.hasPrefix("--days="):
        let value = String(flag.dropFirst("--days=".count))
        guard let count = parseDays(value) else {
          return .failure(.init(message: "--days \(value): use a number from 1 to 366."))
        }
        days = count
      case "--compare" where first == "trend":
        guard let value = rest.popFirst(), !value.isEmpty else {
          return .failure(
            .init(message: "--compare needs a marker, a version or a day (2026-10-29)."))
        }
        compare = value
      case let flag where first == "trend" && flag.hasPrefix("--compare="):
        let value = String(flag.dropFirst("--compare=".count))
        guard !value.isEmpty else {
          return .failure(
            .init(message: "--compare needs a marker, a version or a day (2026-10-29)."))
        }
        compare = value
      default:
        return .failure(.init(message: "\(first) doesn't take \(argument)."))
      }
    }
    switch first {
    case "status": return .success(.status(json: json))
    case "sessions": return .success(.sessions(json: json, all: all))
    case "stopped": return .success(.stopped(json: json))
    case "trend":
      return .success(
        .trend(json: json, days: days ?? CLITrendReport.defaultDays, compare: compare))
    default: return .success(.history(json: json, since: since ?? defaultSince))
    }
  }

  /// `mark <text>`: the words are the marker's text; `--help` alone asks for help.
  static func parseMark(_ words: [String]) -> Result<Command, UsageError> {
    if words == ["--help"] || words == ["-h"] { return .success(.help("mark")) }
    let text = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      return .failure(
        .init(message: "mark needs a text, such as tamebar mark \"Raised the swap limit\"."))
    }
    return .success(.mark(text))
  }

  /// `start <project|all>`: the project is a folder's name, as `tamebar sessions` shows it.
  static func parseStart(_ words: [String]) -> Result<Command, UsageError> {
    if words == ["--help"] || words == ["-h"] { return .success(.help("start")) }
    let target = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty, !target.hasPrefix("-") else {
      return .failure(
        .init(message: "start needs a project or all, such as tamebar start dashboard-app."))
    }
    return .success(.start(target))
  }

  /// `hooks install|remove|status`.
  static func parseHooks(_ words: [String]) -> Result<Command, UsageError> {
    if words == ["--help"] || words == ["-h"] { return .success(.help("hooks")) }
    guard words.count == 1, let action = StartHooks.Action(rawValue: words[0]) else {
      return .failure(.init(message: "hooks needs one of install, remove or status."))
    }
    return .success(.hooks(action))
  }

  /// 1 to 366 days.
  static func parseDays(_ text: String) -> Int? {
    guard text.allSatisfy(\.isASCII), let count = Int(text),
      (1...CLITrendReport.maximumDays).contains(count)
    else { return nil }
    return count
  }

  /// `30m`, `1h`, `24h`, `7d`, `2w`: a whole number above zero and a unit.
  static func parseSince(_ text: String) -> TimeInterval? {
    let units: [Character: TimeInterval] = ["m": 60, "h": 3_600, "d": 86_400, "w": 604_800]
    guard let unit = text.last, let scale = units[unit] else { return nil }
    let digits = text.dropLast()
    guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
      let count = Int(digits), count > 0
    else { return nil }
    return TimeInterval(count) * scale
  }

  static func usage(_ topic: String?) -> String {
    switch topic {
    case "status":
      return """
        tamebar status [--json]

        Memory (available RAM, swap, pressure), CPU, free disk, the apps using the most RAM and CPU,
        whether a call holds the mic or camera, and what Tamebar has paused, quit or slowed.
        The numbers are a fresh scan, so they are live even when Tamebar isn't running.
        """
    case "sessions":
      return """
        tamebar sessions [--all] [--json]

        The Claude and Codex sessions on this Mac, largest first: project, RAM, state (busy,
        idle for how long, or paused and by whom), what protects them (kept, serving a port,
        a background job) and the command that resumes them.
        Sessions under 100 MB are left out unless --all is given.
        """
    case "stopped":
      return """
        tamebar stopped [--json]

        What Tamebar stopped and isn't back yet: sessions it paused (memory, a call, heat), sessions
        it ended, dev servers it ended with their session, apps it quit, apps you quit from
        Tamebar, and Codex plugins it turned off. Each with when, why, the memory it held, and the
        command that brings it back. Entries leave once the thing is back, or after 30 days. Only
        what went through Tamebar is listed.
        """
    case "history":
      return """
        tamebar history [--since 1h|24h|7d] [--json]

        Memory pressure events, resource samples and Tamebar's pressure log, with the apps and
        projects using the most memory at each. --since takes a number and m, h, d or w
        (default 24h). Tamebar keeps a day of events and a week of samples.
        """
    case "trend":
      return """
        tamebar trend [--days 14] [--compare <marker|version|day>] [--json]

        One line per day: awake (in use) time, the time and share of it under memory pressure,
        critical time, the swap peak, AI sessions on average with their memory, and what
        Tamebar did. Markers (a new Tamebar build, an automatic setting switched, your own
        tamebar mark) show as a line after their day. --days takes 1 to 366 (default 14).
        --compare prints up to 7 days before a marker (or a day, 2026-10-29) against up to 7
        days after it. Tamebar keeps a year of days.
        """
    case "wait":
      return """
        tamebar wait

        For an AI session's start hook (Claude Code and Codex SessionStart). Returns at once
        unless Tamebar is running and the Mac is struggling (swap-ins, fan, heat or critical
        memory). Then a fresh session waits until the strain eases (one session a minute, oldest
        first), Start now in Tamebar's card or tamebar start, or 10 minutes. A resumed, cleared
        or compacted session never waits. Reads the hook's JSON on stdin, prints nothing, and
        always exits 0.
        """
    case "start":
      return """
        tamebar start <project|all>

        Starts the sessions waiting for memory at start (tamebar wait) in that project, a
        folder's name as tamebar sessions shows it, or all of them. Prints what it started; exits
        1 when nothing waiting matched.
        """
    case "hooks":
      return """
        tamebar hooks install|remove|status

        The start hook (tamebar wait, with a 660 s timeout) in Claude Code's
        ~/.claude/settings.json and Codex's ~/.codex/hooks.json, as a SessionStart command. install
        adds it, or updates its path; remove takes it out; status says where it is. install and
        remove keep every other setting, write a timestamped backup beside the file first, and
        change nothing when there is nothing to change. A tool whose folder doesn't exist is
        skipped. Exits 1 when a file couldn't be read or written.
        """
    case "mark":
      return """
        tamebar mark "<text>"

        Adds a marker with your text and the time, such as tamebar mark "Raised the swap limit",
        so tamebar trend --compare can show before and after. The only command that writes:
        one line in usage-markers.jsonl. Tamebar needn't be running.
        """
    default:
      return """
        tamebar: what is using this Mac's memory and CPU.

        Usage:
          tamebar status [--json]                 memory, CPU, disk, top apps, Tamebar's actions
          tamebar sessions [--all] [--json]       AI sessions by RAM, with state and resume command
          tamebar stopped [--json]                what Tamebar stopped, and the command to bring it back
          tamebar history [--since 24h] [--json]  pressure events and samples with top apps
          tamebar trend [--days 14] [--compare <marker>] [--json]
                                                  time under pressure per day, before and after
          tamebar mark "<text>"                   add a marker to the trend
          tamebar wait                            start hook: wait while the Mac is struggling
          tamebar start <project|all>             start the sessions waiting for memory
          tamebar hooks install|remove|status     the start hook in Claude Code and Codex
          tamebar help <command>                  more about one command

        status, sessions, stopped, history and trend are read-only: they never pause, quit or
        slow anything, and never change Tamebar's files or settings. mark only adds its marker;
        wait and start only write their files in waiting/; hooks install and remove only edit
        the agents' hook files. --json prints a versioned schema (docs/CLI.md). Exit codes: 0
        success, 1 the marker couldn't be written, start found nothing waiting or a hook file
        couldn't be changed, 2 bad usage.
        """
    }
  }

  /// Runs one command and returns its exit code: 0, 1 when `mark` couldn't write or `start`
  /// found nothing waiting, or 2 for bad usage. `wait` always returns 0.
  static func run(_ arguments: [String], _ env: CLIEnvironment) -> Int32 {
    let command: Command
    switch parse(arguments) {
    case .success(let parsed):
      command = parsed
    case .failure(let error):
      env.err("tamebar: \(error.message)\nRun tamebar --help for usage.\n")
      return 2
    }
    switch command {
    case .help(let topic):
      env.out(usage(topic) + "\n")
    case .status(let json):
      let report = CLIReport.status(
        .init(
          reading: env.system(), state: CLIState.read(env.directory),
          tamebarPID: env.tamebarPID(), directory: env.directory, now: env.now(),
          label: env.label, startTime: env.startTime, safety: AutomaticSafety.load(env.defaults)))
      env.out(json ? CLIReport.json(report) : CLIText.status(report, timeZone: env.timeZone))
    case .sessions(let json, let all):
      let report = CLIReport.sessions(
        .init(
          scan: env.sessions(), autopause: CLIState.read(env.directory).autopause,
          keeps: SessionKeeps.load(env.defaults),
          preferences: CLIReport.preferences(env.defaults),
          tamebarRunning: env.tamebarPID() != nil, now: env.now(), all: all))
      env.out(json ? CLIReport.json(report) : CLIText.sessions(report, timeZone: env.timeZone))
    case .stopped(let json):
      let report = CLIReport.stopped(
        .init(
          scan: env.sessions(), state: CLIState.read(env.directory),
          stores: CLIStoppedStores.read(env.defaults), running: env.runningApps(),
          tamebarRunning: env.tamebarPID() != nil, now: env.now(), label: env.label))
      env.out(json ? CLIReport.json(report) : CLIText.stopped(report, timeZone: env.timeZone))
    case .history(let json, let since):
      let report = CLIReport.history(
        .init(
          files: CLIHistoryFiles.read(env.directory), since: since, now: env.now(),
          tamebarRunning: env.tamebarPID() != nil))
      env.out(json ? CLIReport.json(report) : CLIText.history(report, timeZone: env.timeZone))
    case .trend(let json, let days, let compare):
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = env.timeZone
      let built = CLITrendReport.build(
        .init(
          files: CLITrendFiles.read(env.directory), days: days, compare: compare, now: env.now(),
          calendar: calendar, tamebarRunning: env.tamebarPID() != nil))
      switch built {
      case .success(let built):
        env.out(
          json
            ? CLIReport.json(built.report)
            : CLITrendText.render(built.report, comparison: built.comparison, calendar: calendar))
      case .failure(.noMatch(let query)):
        let labels = UsageMarkers.read(env.directory).suffix(5).map(\.label)
        var message = "No marker or day matches \(query)."
        if !labels.isEmpty { message += " Latest markers: " + labels.joined(separator: "; ") + "." }
        env.err("tamebar: \(message)\nRun tamebar help trend for usage.\n")
        return 2
      }
    case .mark(let text):
      switch UsageMarkers.append(
        .init(at: env.now(), kind: .note, text: text), directory: env.directory)
      {
      case .success(let marker):
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = env.timeZone
        formatter.dateFormat = "MMM d HH:mm"
        env.out("Marked “\(marker.text)” at \(formatter.string(from: marker.at)).\n")
      case .failure(.emptyText):
        env.err("tamebar: mark needs a text.\nRun tamebar help mark for usage.\n")
        return 2
      case .failure(.unwritable(let reason)):
        env.err("tamebar: couldn't add the marker: \(reason).\n")
        return 1
      }
    case .wait:
      return env.wait()
    case .hooks(let action):
      let command = StartHooks.command(executable: env.executable())
      let outcomes = StartHooks.Tool.allCases.map { tool in
        (tool, StartHooks.run(action, tool: tool, home: env.home, command: command, now: env.now()))
      }
      let report = StartHooks.report(action, outcomes: outcomes, home: env.home, command: command)
      env.out(report.text)
      return report.ok ? 0 : 1
    case .start(let target):
      let now = env.now()
      let waiting = StartWait.prune(env.directory, startTime: env.startTime).filter {
        !StartWait.isReleased($0.waitPID, directory: env.directory)
      }
      let started = StartWait.matching(target, in: waiting).filter {
        StartWait.release($0.waitPID, by: "tamebar_start", at: now, directory: env.directory)
      }
      guard !started.isEmpty else {
        let projects = Array(Set(waiting.map(\.project))).sorted()
        env.err(
          projects.isEmpty
            ? "tamebar: nothing is waiting for memory.\n"
            : "tamebar: nothing waiting for memory in \(target). Waiting: "
              + projects.joined(separator: ", ") + ".\n")
        return 1
      }
      for registration in started {
        env.out(
          "Started \(registration.label) (waited "
            + "\(StartWait.waited(now.timeIntervalSince(registration.started)))).\n")
      }
    }
    return 0
  }
}

/// Everything a command reads, so a test runs it on fixtures and the app on this Mac.
struct CLIEnvironment {
  /// Tamebar's data folder, read and never written but for `mark`'s line in
  /// `usage-markers.jsonl`.
  let directory: URL
  /// Tamebar's settings, read and never written.
  let defaults: UserDefaults
  let now: () -> Date
  let timeZone: TimeZone
  /// Memory, CPU, disk, the top apps and the call probe, read now.
  let system: () -> CLISystemReading
  /// The AI sessions, scanned now.
  let sessions: () -> CLISessionScan
  /// The running Tamebar app's pid, nil when it isn't running.
  let tamebarPID: () -> Int32?
  /// A paused session's project, by its thread ID, when its process is still that session.
  let label: (String) -> String?
  let out: (String) -> Void
  let err: (String) -> Void
  /// Running apps by bundle id, with their launch date: an app quit and relaunched since is back.
  var runningApps: () -> [String: Date?] = { [:] }
  /// A pid's start time while it runs, nil once it doesn't: `tamebar wait`'s and Tamebar's
  /// liveness (Q19).
  var startTime: (Int32) -> Double? = { _ in nil }
  /// Runs `tamebar wait` (Q19): reads the hook's stdin, waits if the Mac is struggling; 0.
  var wait: () -> Int32 = { 0 }
  /// The home folder whose `.claude` and `.codex` `tamebar hooks` edits.
  var home = FileManager.default.homeDirectoryForCurrentUser
  /// The absolute path the start hook runs: the `tamebar` link to this app when there is one,
  /// else this executable.
  var executable: () -> String = { "tamebar" }
}
