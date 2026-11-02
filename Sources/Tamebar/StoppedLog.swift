import AppKit
import Foundation

/// One log of what Tamebar stopped and how to bring it back (decisions Q15, amends Q4). It is
/// derived from the stores that already record each kind, and holds nothing of its own but the
/// apps quit from the panel, which nothing recorded before:
/// - sessions and projects paused for memory, a call or heat: the auto-pause ledger
///   (`autopause.json`, `AutoPausePlanner.State.ledger`);
/// - sessions ended, automatically (Q10 after N idle days, Q18 under memory pressure) or from the
///   panel: `EndedSessionLog`;
/// - apps quit under memory pressure (Q11): the app ledger in `autopause.json`;
/// - apps quit from the panel: `QuitAppLog`;
/// - dev servers ended with their session once both were unused 24 h (Q20): `EndedServerLog`;
/// - Codex plugins turned off after 30 days without a call (Q21): `codex-plugins.json`.
///
/// Only what went through Tamebar is in it. An entry leaves when the thing is back (a paused one
/// resumed, an ended session running again, an app relaunched) or after 30 days. Pure: the app
/// and `tamebar stopped` build it from the same readings.
struct StoppedEntry: Equatable, Identifiable, Sendable {
  enum Kind: String, Sendable {
    case session, project, app, server
    case codexPlugin = "codex plugin"
  }

  /// Where it is now.
  enum State: String, Sendable {
    case paused, ended, quit
    /// A Codex plugin turned off in Codex's config (Q21).
    case off
  }

  enum Reason: Equatable, Sendable {
    case memory, call, heat
    /// Ended automatically after the agent had said idle this many whole days.
    case idle(days: Int)
    /// Unused this many whole days: a session and its dev server with no interaction and no
    /// connection (Q20), a Codex plugin with no call (Q21).
    case unused(days: Int)
    /// The user did it from Tamebar's panel.
    case byYou

    /// The JSON value: `memory`, `call`, `heat`, `idle` or `by_you`.
    var key: String {
      switch self {
      case .memory: "memory"
      case .call: "call"
      case .heat: "heat"
      case .idle: "idle"
      case .unused: "unused"
      case .byYou: "by_you"
      }
    }
  }

  /// What the app acts on to bring it back.
  enum Target: Equatable, Sendable {
    /// A ledger entry (a session's thread ID, or `project:<directory>`): Resume, or Run now.
    case ledger(String)
    /// An ended session, by its session id: Resume opens Terminal on `command`.
    case ended(String)
    /// An app: Reopen, in the background.
    case app(bundleID: String, bundleURL: URL)
    /// A dev server Q20 ended, by its entry's id: Resume opens Terminal on `command`.
    case server(String)
    /// A Codex plugin Q21 turned off, by its key (`server:<name>`, `plugin:<id>`): Undo.
    case codexPlugin(String)
  }

  let id: String
  let kind: Kind
  /// The project for a session or a project, the app's name for an app.
  let name: String
  var tool: AITool?
  var directory: String?
  var sessionID: String?
  var bundleID: String?
  let stoppedAt: Date
  let state: State
  let reason: Reason
  /// What it held when it was stopped (a paused session: what it holds now); nil when unknown.
  var memoryBytes: UInt64?
  /// The command that brings it back from a terminal; nil for what comes back on its own.
  var command: String?
  let target: Target
}

enum StoppedLog {
  /// Ended sessions' retention, for every kind.
  static let retention = EndedSessionLog.retention

  struct Input {
    var ledger: [AutoPausePlanner.Entry] = []
    /// The live sessions, for a paused session's project and memory, and to tell an ended
    /// session that runs again.
    var threads: [AIThread] = []
    /// A paused session's project when the scan doesn't list it (the CLI reads its process).
    var label: (String) -> String? = { _ in nil }
    /// A paused project's memory, by directory.
    var projectBytes: [String: UInt64] = [:]
    var ended: [EndedSession] = []
    /// Q11's ledger.
    var appLedger: [AppPressurePlanner.Entry] = []
    /// Apps quit from the panel.
    var quitApps: [QuitApp] = []
    /// Running apps by bundle id, with their launch date when known.
    var running: [String: Date?] = [:]
    /// Dev servers Q20 ended.
    var servers: [EndedServer] = []
    /// Codex plugins Q21 turned off and still off.
    var codexPlugins: [CodexTrimState.Entry] = []
    let now: Date
  }

  /// Everything stopped and not back, in the list's order: paused, ended, quit, the
  /// newest first in each (Q15's mock).
  static func entries(_ input: Input) -> [StoppedEntry] {
    let threads = Dictionary(
      input.threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var entries = input.ledger.map { paused($0, thread: threads[$0.threadID], input: input) }
    let live = Set(input.threads.compactMap { $0.sessionID?.lowercased() })
    var seenSessions: Set<String> = []
    for session in input.ended.sorted(by: { $0.endedAt > $1.endedAt })
    where !live.contains(session.id.lowercased())
      && seenSessions.insert(session.id.lowercased()).inserted
    {
      entries.append(ended(session))
    }
    entries += apps(input)
    entries += input.servers.map(server)
    entries += input.codexPlugins.map(codexPlugin)
    return
      entries
      // A Codex plugin stays while it is off: the file says so, not a date.
      .filter { $0.state == .off || input.now.timeIntervalSince($0.stoppedAt) <= retention }
      .sorted(by: trayOrder)
  }

  /// The CLI's order (Q15's terminal mock): what needs your command first (apps, then ended
  /// sessions), then what comes back on its own (paused), the newest first in each.
  static func commandOrder(_ entries: [StoppedEntry]) -> [StoppedEntry] {
    let rank: [StoppedEntry.State: Int] = [.quit: 0, .ended: 1, .off: 2, .paused: 3]
    return entries.sorted {
      rank[$0.state, default: 9] == rank[$1.state, default: 9]
        ? $0.stoppedAt > $1.stoppedAt : rank[$0.state, default: 9] < rank[$1.state, default: 9]
    }
  }

  private static func trayOrder(_ left: StoppedEntry, _ right: StoppedEntry) -> Bool {
    let rank: [StoppedEntry.State: Int] = [.paused: 0, .ended: 1, .quit: 2, .off: 3]
    let (a, b) = (rank[left.state, default: 9], rank[right.state, default: 9])
    return a == b ? left.stoppedAt > right.stoppedAt : a < b
  }

  /// A ledger entry: a pause. One an older build queued (Q14, the `queue` reason) reads as paused
  /// for memory until the first tick resumes it (Q19).
  private static func paused(_ entry: AutoPausePlanner.Entry, thread: AIThread?, input: Input)
    -> StoppedEntry
  {
    let reason: StoppedEntry.Reason =
      switch entry.reason {
      case .pressure, .queue: .memory
      case .meeting: .call
      case .heat: .heat
      }
    let state = StoppedEntry.State.paused
    if let directory = AutoPauseWiring.projectDirectory(entry.threadID) {
      return StoppedEntry(
        id: "paused:" + entry.threadID, kind: .project,
        name: URL(fileURLWithPath: directory).lastPathComponent, directory: directory,
        stoppedAt: entry.since, state: .paused, reason: reason,
        memoryBytes: input.projectBytes[directory], target: .ledger(entry.threadID))
    }
    let tool = thread?.tool ?? CLIReport.threadParts(entry.threadID)?.tool
    let name = thread?.project ?? input.label(entry.threadID) ?? tool?.title ?? "AI session"
    return StoppedEntry(
      id: "paused:" + entry.threadID, kind: .session, name: name, tool: tool,
      directory: thread?.directory, sessionID: thread?.sessionID, stoppedAt: entry.since,
      state: state, reason: reason, memoryBytes: thread?.memoryBytes,
      target: .ledger(entry.threadID))
  }

  private static func ended(_ session: EndedSession) -> StoppedEntry {
    let idleDays = session.idleSince.map {
      max(0, Int(session.endedAt.timeIntervalSince($0) / UnusedPolicy.day))
    }
    // Before the flag was kept, an entry with an idle time may have been either; it says how long
    // the session had been idle, which is true both ways.
    let reason: StoppedEntry.Reason =
      switch (session.automatic, session.pressure) {
      case _ where session.unusedServer == true: .unused(days: idleDays ?? 1)
      case (_, true?): .memory
      case (true?, _): .idle(days: idleDays ?? 0)
      case (false?, _): .byYou
      case (nil, _): idleDays.map { .idle(days: $0) } ?? .byYou
      }
    return StoppedEntry(
      id: "ended:" + session.id, kind: .session, name: session.folderName ?? session.rowTitle,
      tool: session.tool, directory: session.directory, sessionID: session.id,
      stoppedAt: session.endedAt, state: .ended, reason: reason,
      memoryBytes: session.memoryBytes, command: session.resumeCommand,
      target: .ended(session.id))
  }

  /// A dev server Q20 ended: "web-frontend :5180", Resume opens Terminal on its command.
  private static func server(_ server: EndedServer) -> StoppedEntry {
    StoppedEntry(
      id: "server:" + server.id, kind: .server, name: server.title,
      directory: server.directory, sessionID: server.sessionID, stoppedAt: server.endedAt,
      state: .ended, reason: .unused(days: max(1, Int(server.unusedFor / UnusedPolicy.day))),
      memoryBytes: server.memoryBytes, command: server.command, target: .server(server.id))
  }

  /// A Codex MCP server or plugin Q21 turned off: Undo turns it back on.
  private static func codexPlugin(_ entry: CodexTrimState.Entry) -> StoppedEntry {
    StoppedEntry(
      id: "codex:" + entry.key, kind: .codexPlugin, name: entry.name, stoppedAt: entry.offAt,
      state: .off, reason: .unused(days: Int(CodexTrim.window / UnusedPolicy.day)),
      target: .codexPlugin(entry.key))
  }

  /// Q11's quits once they landed, then the panel's, one entry per app (the latest quit), none
  /// for an app running again since.
  private static func apps(_ input: Input) -> [StoppedEntry] {
    var latest: [String: StoppedEntry] = [:]
    let pressure = input.appLedger.filter(\.confirmed).map {
      app(
        bundleID: $0.bundleID, name: $0.name, url: $0.bundleURL, bytes: $0.memoryBytes,
        at: $0.quitAt, reason: .memory)
    }
    let panel = input.quitApps.map {
      app(
        bundleID: $0.bundleID, name: $0.name, url: $0.bundleURL, bytes: $0.memoryBytes,
        at: $0.quitAt, reason: .byYou)
    }
    for entry in pressure + panel {
      guard let bundleID = entry.bundleID,
        !isBack(bundleID, quitAt: entry.stoppedAt, running: input.running)
      else { continue }
      if let other = latest[bundleID], other.stoppedAt >= entry.stoppedAt { continue }
      latest[bundleID] = entry
    }
    return Array(latest.values)
  }

  private static func app(
    bundleID: String, name: String, url: URL, bytes: UInt64, at: Date,
    reason: StoppedEntry.Reason
  ) -> StoppedEntry {
    StoppedEntry(
      id: "app:" + bundleID, kind: .app, name: name, bundleID: bundleID, stoppedAt: at,
      state: .quit, reason: reason, memoryBytes: bytes,
      command: openCommand(bundleURL: url, bundleID: bundleID),
      target: .app(bundleID: bundleID, bundleURL: url))
  }

  /// Running apps by bundle id, the latest launch of each (nil when macOS doesn't say).
  static func runningApps() -> [String: Date?] {
    var running: [String: Date?] = [:]
    for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
      guard let bundleID = app.bundleIdentifier else { continue }
      if let known = running[bundleID], let launched = known,
        let other = app.launchDate, other <= launched
      {
        continue
      }
      running[bundleID] = app.launchDate
    }
    return running
  }

  /// The app runs again: launched after the quit, or at an unknown time.
  static func isBack(_ bundleID: String, quitAt: Date, running: [String: Date?]) -> Bool {
    guard let launched = running[bundleID] else { return false }
    return launched.map { $0 > quitAt } ?? true
  }

  /// `open -a Docker` by the bundle's own name, `open -b <bundle id>` without one. A name that
  /// isn't plain is single-quoted, as Ended sessions quotes a folder.
  static func openCommand(bundleURL: URL, bundleID: String) -> String {
    let name = bundleURL.deletingPathExtension().lastPathComponent
    guard !name.isEmpty, name != "/",
      !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    else { return "open -b " + quote(bundleID) }
    return "open -a " + quote(name)
  }

  /// Plain words stay bare; anything else is single-quoted.
  static func quote(_ text: String) -> String {
    let plain = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+@")
    if !text.isEmpty, text.unicodeScalars.allSatisfy(plain.contains) { return text }
    return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

// MARK: Words

extension StoppedEntry {
  /// The row's state and reason: "paused · memory", "paused · call", "ended · idle 3d",
  /// "quit · memory". What the user did shows when: "quit 11:24", "ended Oct 27".
  func trayDetail(now: Date, timeZone: TimeZone = .current) -> String {
    switch reason {
    case .memory: "\(state.rawValue) · memory"
    case .call: "\(state.rawValue) · call"
    case .heat: "\(state.rawValue) · heat"
    case .idle(let days): "\(state.rawValue) · idle \(days)d"
    case .unused(let days): "\(state.rawValue) · unused \(days)d"
    case .byYou: "\(state.rawValue) \(Self.when(stoppedAt, now: now, timeZone: timeZone))"
    }
  }

  /// The CLI's state, reason and how it comes back: "paused · call · comes back when the call
  /// ends", "ended · idle 3 days", "quit by you, from Tamebar".
  var commandDetail: String {
    switch (state, reason) {
    case (.ended, .memory): "ended · memory"
    case (_, .idle(let days)): "\(state.rawValue) · idle \(days) \(days == 1 ? "day" : "days")"
    case (.off, .unused(let days)): "off · no call in \(days) days · new Codex sessions only"
    case (_, .unused(let days)):
      "\(state.rawValue) · unused \(days) \(days == 1 ? "day" : "days")"
    case (_, .byYou): "\(state.rawValue) by you, from Tamebar"
    case (.quit, _): "quit · \(reasonWord) · reopens when memory recovers"
    case (_, .call): "\(state.rawValue) · call · comes back when the call ends"
    case (_, .heat): "\(state.rawValue) · heat · comes back when the Mac cools"
    default: "\(state.rawValue) · memory · comes back when memory recovers"
    }
  }

  private var reasonWord: String {
    switch reason {
    case .memory: "memory"
    case .call: "call"
    case .heat: "heat"
    case .idle: "idle"
    case .unused: "unused"
    case .byYou: "by you"
    }
  }

  /// The row's one button: Resume (paused, or ended with a command), Reopen (an app); nil for an
  /// ended session with no command.
  var actionTitle: String? {
    switch state {
    case .paused: "Resume"
    case .ended: command == nil ? nil : "Resume"
    case .quit: "Reopen"
    case .off: "Turn on"
    }
  }

  /// `11:24` today, `Oct 27` before.
  static func when(_ date: Date, now: Date, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "MMM d"
    return formatter.string(from: date)
  }
}

// MARK: Apps quit from the panel

extension Notification.Name {
}

/// An app the user quit from Tamebar's panel. Q11's own quits are in `autopause.json`.
struct QuitApp: Codable, Equatable, Sendable {
  let bundleID: String
  let name: String
  let bundleURL: URL
  let memoryBytes: UInt64
  let quitAt: Date
}

/// The apps quit from the panel, for the Stopped list (Q15): 30 days, one entry per app, newest
/// first, in UserDefaults `apps.quitByYou.v1`. An app leaves once it runs again.
struct QuitAppLog: Equatable, Sendable {
  static let defaultsKey = "apps.quitByYou.v1"
  static let retention = EndedSessionLog.retention
  static let limit = 100
  private(set) var apps: [QuitApp] = []

  mutating func record(_ app: QuitApp, now: Date) {
    apps.removeAll { $0.bundleID == app.bundleID }
    apps.insert(app, at: 0)
    prune(now: now)
    if apps.count > Self.limit { apps.removeLast(apps.count - Self.limit) }
  }

  /// Drops the apps running again since their quit. True when one went.
  @discardableResult
  mutating func dropBack(running: [String: Date?]) -> Bool {
    let before = apps.count
    apps.removeAll { StoppedLog.isBack($0.bundleID, quitAt: $0.quitAt, running: running) }
    return apps.count != before
  }

  mutating func prune(now: Date) {
    apps.removeAll { now.timeIntervalSince($0.quitAt) > Self.retention }
  }

  /// Read entry by entry, as Ended sessions is: one this build can't read is skipped, the rest
  /// stay (`SavedSettings.list` keeps the unreadable value aside).
  static func load(_ defaults: UserDefaults = .standard, now: Date = .now) -> Self {
    var log = Self(
      apps: SavedSettings.list(.init(key: defaultsKey, defaults: defaults)) ?? [])
    log.prune(now: now)
    return log
  }

  func save(_ defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(apps) { defaults.set(data, forKey: Self.defaultsKey) }
  }
}
