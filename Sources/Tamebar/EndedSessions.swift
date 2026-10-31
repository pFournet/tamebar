import Foundation

/// A session Tamebar ended, at the user's click or automatically (Q4, Q10). No conversation
/// content is stored (Q8).
struct EndedSession: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let tool: AITool
  let directory: String
  /// The session file's `name`, or nil. Never a summary.
  let name: String?
  let idleSince: Date?
  let endedAt: Date
  let memoryBytes: UInt64
  /// Ended on its own after N idle days (Q10), or from the panel; nil in an entry saved before
  /// it was kept. The Stopped list says "idle N days" or "by you" from it (Q15).
  var automatic: Bool? = nil
  /// Ended on its own under memory pressure (Q18), not after N idle days; nil otherwise. The
  /// Stopped list says "ended · memory" from it.
  var pressure: Bool? = nil
  /// Ended with its unused dev server after 24 h with no interaction (Q20); nil otherwise. The
  /// Stopped list says "ended · unused 1d" from it.
  var unusedServer: Bool? = nil

  /// The command that reopens the session, for Copy resume command. It is pasted into a terminal,
  /// so it carries only a UUID id and a single-quoted folder. A control character in the folder
  /// (Ctrl-U, a carriage return, an end-of-paste escape) acts on the terminal's line editor even
  /// inside quotes, so such a folder gives no command; a folder with a newline in its name too.
  var resumeCommand: String? {
    guard UUID(uuidString: id) != nil,
      !directory.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    else { return nil }
    let folder = "'" + directory.replacingOccurrences(of: "'", with: "'\\''") + "'"
    switch tool {
    case .claudeCode: return "cd \(folder) && claude --resume \(id)"
    case .codexCLI: return "cd \(folder) && codex resume \(id)"
    case .codexDesktop, .cursorAgent, .otherAgent: return nil
    }
  }

  /// The session's title: the session file's name, else its folder's name, else the tool. Never
  /// a summary (Q8). The Stopped list names it by its folder, and falls back to this.
  var rowTitle: String {
    if let name, !name.isEmpty { return name }
    return folderName ?? tool.title
  }

  /// The folder's last path component, or nil for an empty or root folder.
  var folderName: String? {
    let folder = (directory as NSString).lastPathComponent
    return folder.isEmpty || folder == "/" ? nil : folder
  }
}

/// The Ended sessions list: 30 days, newest first, one entry per session id.
struct EndedSessionLog: Equatable, Sendable {
  static let defaultsKey = "sessions.ended.v1"
  static let retention: TimeInterval = 30 * 86_400
  /// Keeps the stored list small even when many sessions end inside 30 days.
  static let limit = 200
  private(set) var sessions: [EndedSession] = []

  mutating func record(_ session: EndedSession, now: Date) {
    sessions.removeAll { $0.id == session.id }
    sessions.insert(session, at: 0)
    prune(now: now)
    if sessions.count > Self.limit { sessions.removeLast(sessions.count - Self.limit) }
  }

  /// The sessions to show: one a live thread still runs is hidden, so its resume command can't
  /// put a second agent on the same session.
  func visible(liveSessionIDs: Set<String>) -> [EndedSession] {
    let live = Set(liveSessionIDs.map { $0.lowercased() })
    return sessions.filter { !live.contains($0.id.lowercased()) }
  }

  /// Drops sessions ended more than 30 days before `now`.
  mutating func prune(now: Date) {
    sessions.removeAll { now.timeIntervalSince($0.endedAt) > Self.retention }
  }

  /// Stored as a plain list read entry by entry, so an entry this build cannot read (a tool from a
  /// newer build) is skipped and the rest stay. When anything is skipped, the stored value is first
  /// copied to `<key>.unreadable`; the next save then drops the skipped entries from the list.
  /// Entries past 30 days are dropped.
  static func load(_ defaults: UserDefaults = .standard, now: Date = .now) -> Self {
    let request = SavedSettings.Request(key: defaultsKey, defaults: defaults)
    var log = Self(sessions: SavedSettings.list(request) ?? [])
    log.prune(now: now)
    return log
  }

  func save(_ defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(sessions) {
      defaults.set(data, forKey: Self.defaultsKey)
    }
  }
}
