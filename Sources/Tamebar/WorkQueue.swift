import Darwin
import Foundation

/// A session's terminal: which ttys its keys reach it through, when they last read input (Q18: a
/// keystroke resets the 12 h idle clock), and the title restore owed to a session Q14's work
/// queue stopped. Q19 removed the queue itself: running sessions are never held for memory. The
/// rules are pure, from the scan's `ps` records; reading a tty's last input and writing the
/// restore are the only effects (`TTY`).
enum WorkQueue {
  static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh"]

  /// The name a process runs as: its executable, without the `-` a login shell's argv[0] has.
  static func name(_ record: RawProcessRecord) -> String {
    let name = AIThreadGrouping.executableName(record.arguments)
    return name.hasPrefix("-") ? String(name.dropFirst()) : name
  }

  /// The terminals a session's keys reach it through: the agent's own tty, and, up its parents
  /// while each has a terminal, the first shell's (the pane's, above a wrapper such as agentrun,
  /// which gives the agent a pty of its own). Nil when the agent has no terminal.
  static func ttys(_ thread: AIThread, records: [Int32: RawProcessRecord]) -> (
    agent: String, pane: String
  )? {
    guard let root = thread.rootProcessID, let own = records[root]?.terminal, isTTYName(own)
    else { return nil }
    var pid = records[root]?.parentProcessID ?? 0
    var visited: Set<Int32> = [root]
    while pid > 1, visited.insert(pid).inserted, let record = records[pid],
      let tty = record.terminal, isTTYName(tty)
    {
      if shells.contains(name(record)) { return (own, tty) }
      pid = record.parentProcessID
    }
    return (own, own)
  }

  /// `ttys012`: letters and digits only, so `/dev/<name>` can't point anywhere else.
  static func isTTYName(_ name: String) -> Bool {
    name.hasPrefix("tty") && name.count <= 16
      && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
  }

  /// Each session's last input: the later of its own tty's and its pane's (`ttys`). A session
  /// with no terminal has none.
  static func lastInput(
    _ threads: [AIThread], records: [Int32: RawProcessRecord],
    read: (String) -> Date? = TTY.lastInput
  ) -> [String: Date] {
    var inputs: [String: Date] = [:]
    for thread in threads {
      guard let ttys = ttys(thread, records: records) else { continue }
      let reads = Set([ttys.agent, ttys.pane]).compactMap(read)
      if let latest = reads.max() { inputs[thread.id] = latest }
    }
    return inputs
  }

  // MARK: The terminal notice (S4)

  /// Written after the resume of a session an older build queued, whose notice pushed the title
  /// (XTWINOPS 22) and set "⏸ Queued by Tamebar · memory": an empty title, then the pop
  /// (XTWINOPS 23). A terminal with a
  /// title stack gets its own title back; one without keeps the empty one, never a stale
  /// "Queued". No line: each TUI redraws its live area, and a line would land inside it.
  static let resumedNotice = "\u{1B}]2;\u{07}" + "\u{1B}[23;0t"

  /// Reads and writes the session's terminal. Never blocks: the device is opened non-blocking,
  /// a write the terminal can't take at once is dropped, and only a character device owned by
  /// this user is written to.
  enum TTY {
    /// When the terminal last read input (keys, a paste): its access time, as `w` reads idle.
    static func lastInput(_ name: String) -> Date? {
      guard isTTYName(name) else { return nil }
      var info = stat()
      guard stat("/dev/" + name, &info) == 0, info.st_mode & S_IFMT == S_IFCHR,
        info.st_uid == getuid()
      else { return nil }
      return Date(
        timeIntervalSince1970: Double(info.st_atimespec.tv_sec)
          + Double(info.st_atimespec.tv_nsec) / 1e9)
    }

    /// True when every byte was written.
    @discardableResult
    static func write(_ name: String, _ text: String) -> Bool {
      guard isTTYName(name) else { return false }
      let descriptor = open("/dev/" + name, O_WRONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
      guard descriptor >= 0 else { return false }
      defer { close(descriptor) }
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFCHR,
        info.st_uid == getuid()
      else { return false }
      let bytes = Array(text.utf8)
      let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
      return written == bytes.count
    }
  }
}
