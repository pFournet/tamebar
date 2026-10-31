import Darwin
import Foundation

/// `tamebar hooks install|remove|status` (decisions P2): the start-wait hook (Q19), a
/// `SessionStart` command `<tamebar> wait` with a 660 s timeout, in Claude Code's
/// `~/.claude/settings.json` and Codex's `~/.codex/hooks.json`. Each edit keeps every other key in
/// its order, writes a timestamped backup beside the file first, checks the result is valid JSON,
/// and changes nothing when there is nothing to change. A tool whose folder doesn't exist is
/// skipped; a missing file or key is created.
enum StartHooks {
  static let timeout = 660

  enum Tool: String, CaseIterable, Sendable {
    case claude, codex

    var name: String { self == .claude ? "Claude Code" : "Codex" }

    /// The tool's folder, which must exist, and its file under it.
    func folder(home: URL) -> URL {
      home.appendingPathComponent(self == .claude ? ".claude" : ".codex", isDirectory: true)
    }

    func file(home: URL) -> URL {
      folder(home: home).appendingPathComponent(self == .claude ? "settings.json" : "hooks.json")
    }
  }

  enum Action: String, Equatable, Sendable { case install, remove, status }

  /// One tool's outcome.
  enum Outcome: Equatable, Sendable {
    /// No folder for the tool: it isn't used on this Mac.
    case noTool
    /// `status`: the hook's commands found (empty: none).
    case found([String])
    case unchanged
    /// Written, with the backup's path (nil when the file didn't exist before).
    case changed(backup: String?)
    case failed(String)
  }

  /// The command the hook runs: the path quoted when it holds a space or a quote.
  static func command(executable: String) -> String {
    let safe = executable.allSatisfy { !$0.isWhitespace && $0 != "'" && $0 != "\"" && $0 != "\\" }
    return (safe ? executable : "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'")
      + " wait"
  }

  /// Whether a hook command is Tamebar's start wait: a program named `tamebar` (the link) or
  /// `Tamebar` (the app's executable), quoted or not, then exactly `wait`.
  static func isTamebarWait(_ command: String) -> Bool {
    let text = command.trimmingCharacters(in: .whitespaces)
    let program: Substring
    let rest: Substring
    if let quote = text.first, quote == "'" || quote == "\"" {
      let body = text.dropFirst()
      guard let end = body.firstIndex(of: quote) else { return false }
      program = body[..<end]
      rest = body[body.index(after: end)...]
    } else {
      guard let space = text.firstIndex(where: \.isWhitespace) else { return false }
      program = text[..<space]
      rest = text[space...]
    }
    let name = program.split(separator: "/").last.map(String.init) ?? ""
    return (name == "tamebar" || name == "Tamebar")
      && rest.trimmingCharacters(in: .whitespaces) == "wait"
  }

  /// Runs the action for one tool on its file under `home`.
  static func run(_ action: Action, tool: Tool, home: URL, command: String, now: Date) -> Outcome {
    var isFolder: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: tool.folder(home: home).path, isDirectory: &isFolder),
      isFolder.boolValue
    else { return .noTool }
    return run(action, file: tool.file(home: home), command: command, now: now)
  }

  static func run(_ action: Action, file: URL, command: String, now: Date) -> Outcome {
    let original: Data?
    if FileManager.default.fileExists(atPath: file.path) {
      guard let data = FileManager.default.contents(atPath: file.path) else {
        return .failed("\(file.path) can't be read")
      }
      original = data
    } else {
      original = nil
    }
    var root: JSONNode
    if let original, !original.allSatisfy({ [9, 10, 13, 32].contains($0) }) {
      guard (try? JSONSerialization.jsonObject(with: original)) is [String: Any],
        let parsed = JSONNode.parse(original), case .object = parsed
      else { return .failed("\(file.path) isn't a JSON object; left as it is") }
      root = parsed
    } else {
      root = .object([])
    }
    switch action {
    case .status:
      return .found(commands(in: root))
    case .install:
      guard let edited = install(root, command: command) else {
        return .failed(
          "\(file.path) has a \"hooks\" or \"SessionStart\" that isn't the expected shape")
      }
      if original != nil, edited == root { return .unchanged }
      root = edited
    case .remove:
      guard original != nil, let edited = remove(root), edited != root else { return .unchanged }
      root = edited
    }
    let trailing = original.map { $0.last == 10 } ?? true
    let text = root.render() + (trailing ? "\n" : "")
    return write(Data(text.utf8), to: file, original: original, now: now)
  }

  /// The `SessionStart` commands that are Tamebar's wait.
  static func commands(in root: JSONNode) -> [String] {
    guard let groups = root["hooks"]?["SessionStart"], case .array(let list) = groups else {
      return []
    }
    return list.flatMap { group -> [String] in
      guard let hooks = group["hooks"], case .array(let entries) = hooks else { return [] }
      return entries.compactMap { $0["command"]?.stringValue }.filter(isTamebarWait)
    }
  }

  /// One Tamebar wait with this command and the timeout: the first one found is updated in
  /// place and any other removed; with none, a new group is added at the end. Nil when `hooks`
  /// or `SessionStart` isn't an object or array.
  static func install(_ root: JSONNode, command: String) -> JSONNode? {
    let entry = JSONNode.object([
      .init("type", .string("command")), .init("command", .string(command)),
      .init("timeout", .number(String(timeout))),
    ])
    var hooks = root["hooks"] ?? .object([])
    guard case .object = hooks else { return nil }
    var groups = hooks["SessionStart"] ?? .array([])
    guard case .array(var list) = groups else { return nil }
    var placed = false
    // Groups that held only a duplicate Tamebar wait, removed with it.
    var emptied: Set<Int> = []
    for index in list.indices {
      guard case .array(let entries)? = list[index]["hooks"] else { continue }
      var kept: [JSONNode] = []
      for hook in entries {
        guard let text = hook["command"]?.stringValue, isTamebarWait(text) else {
          kept.append(hook)
          continue
        }
        guard !placed else { continue }
        placed = true
        if text == command, hook["timeout"]?.intValue == timeout, hook["type"] != nil {
          kept.append(hook)
        } else {
          var updated = hook
          updated["command"] = .string(command)
          updated["timeout"] = .number(String(timeout))
          if updated["type"] == nil { updated["type"] = .string("command") }
          kept.append(updated)
        }
      }
      guard kept != entries else { continue }
      if kept.isEmpty { emptied.insert(index) }
      list[index]["hooks"] = .array(kept)
    }
    list = list.enumerated().filter { !emptied.contains($0.offset) }.map(\.element)
    if !placed { list.append(.object([.init("hooks", .array([entry]))])) }
    groups = .array(list)
    hooks["SessionStart"] = groups
    var root = root
    root["hooks"] = hooks
    return root
  }

  /// Every Tamebar wait removed, with a group, `SessionStart` or `hooks` that held only them.
  /// Nil when there was none.
  static func remove(_ root: JSONNode) -> JSONNode? {
    guard case .object? = root["hooks"], case .array(var list)? = root["hooks"]?["SessionStart"]
    else { return nil }
    var removed = false
    list = list.compactMap { group in
      guard case .array(let entries)? = group["hooks"] else { return group }
      let kept = entries.filter { !($0["command"]?.stringValue.map(isTamebarWait) ?? false) }
      guard kept.count != entries.count else { return group }
      removed = true
      if kept.isEmpty { return nil }
      var group = group
      group["hooks"] = .array(kept)
      return group
    }
    guard removed else { return nil }
    var root = root
    var hooks = root["hooks"] ?? .object([])
    hooks["SessionStart"] = list.isEmpty ? nil : .array(list)
    if case .object(let members) = hooks, members.isEmpty {
      root["hooks"] = nil
    } else {
      root["hooks"] = hooks
    }
    return root
  }

  /// `<file>.tamebar-backup-YYYYMMDD-HHMMSS` beside the file, then the new text written beside
  /// the real file (a link is followed and kept) and renamed over it with its permissions, then
  /// read back and parsed.
  private static func write(_ data: Data, to file: URL, original: Data?, now: Date) -> Outcome {
    guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
      return .failed("the edited \(file.lastPathComponent) wouldn't be valid JSON; nothing written")
    }
    let manager = FileManager.default
    var backupPath: String?
    if let original {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyyMMdd-HHmmss"
      var backup = file.deletingLastPathComponent().appendingPathComponent(
        "\(file.lastPathComponent).tamebar-backup-\(formatter.string(from: now))")
      var suffix = 1
      while manager.fileExists(atPath: backup.path) {
        suffix += 1
        backup = file.deletingLastPathComponent().appendingPathComponent(
          "\(file.lastPathComponent).tamebar-backup-\(formatter.string(from: now))-\(suffix)")
      }
      guard
        manager.createFile(
          atPath: backup.path, contents: original, attributes: [.posixPermissions: 0o600])
      else { return .failed("couldn't write a backup beside \(file.path); nothing changed") }
      backupPath = backup.path
    }
    let target = file.resolvingSymlinksInPath()
    let permissions =
      (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber
    let temporary = target.deletingLastPathComponent()
      .appendingPathComponent(".\(target.lastPathComponent).tamebar-\(getpid())")
    guard
      manager.createFile(
        atPath: temporary.path, contents: data,
        attributes: [.posixPermissions: permissions?.intValue ?? 0o644])
    else { return .failed("couldn't write beside \(target.path); nothing changed") }
    guard rename(temporary.path, target.path) == 0 else {
      try? manager.removeItem(at: temporary)
      return .failed("couldn't replace \(target.path); nothing changed")
    }
    guard let back = manager.contents(atPath: target.path),
      (try? JSONSerialization.jsonObject(with: back)) is [String: Any]
    else {
      return .failed(
        "\(target.path) doesn't read back as JSON; the backup is \(backupPath ?? "none")")
    }
    return .changed(backup: backupPath)
  }

  /// The lines `tamebar hooks` prints, one per tool, and whether all went well.
  static func report(
    _ action: Action, outcomes: [(Tool, Outcome)], home: URL, command: String
  ) -> (text: String, ok: Bool) {
    var lines: [String] = []
    var ok = true
    for (tool, outcome) in outcomes {
      let path = tool.file(home: home).path.replacingOccurrences(
        of: home.path, with: "~", options: .anchored)
      let head = "\(tool.name) (\(path)): "
      switch outcome {
      case .noTool:
        lines.append(head + "no \(tool.folder(home: home).lastPathComponent) folder, skipped")
      case .found(let commands):
        lines.append(
          head
            + (commands.isEmpty
              ? "not installed" : "installed: " + commands.joined(separator: "; ")))
      case .unchanged:
        lines.append(head + (action == .install ? "already installed" : "not installed"))
      case .changed(let backup):
        lines.append(
          head + (action == .install ? "installed \(command)" : "removed")
            + (backup.map { " (backup: \($0))" } ?? ""))
      case .failed(let reason):
        ok = false
        lines.append(head + reason)
      }
    }
    return (lines.joined(separator: "\n") + "\n", ok)
  }
}

/// A JSON value that keeps its objects' key order and its numbers' and strings' literal text, so
/// an edit rewrites only what changed; written back the way `JSON.stringify(value, null, 2)`
/// does, which is how Claude Code and Codex write theirs. Pure.
indirect enum JSONNode: Equatable, Sendable {
  struct Member: Equatable, Sendable {
    /// The key's literal text between its quotes.
    var key: String
    var value: JSONNode

    init(raw key: String, _ value: JSONNode) {
      self.key = key
      self.value = value
    }

    init(_ key: String, _ value: JSONNode) {
      self.init(raw: JSONNode.literal(key), value)
    }
  }

  case object([Member])
  case array([JSONNode])
  /// The literal text between the quotes, escapes as written.
  case raw(String)
  case number(String)
  case bool(Bool)
  case null

  static func string(_ value: String) -> JSONNode { .raw(literal(value)) }

  /// A string's literal text, without its quotes: `/` is left alone.
  static func literal(_ value: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let text = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    return String(text.dropFirst().dropLast())
  }

  var stringValue: String? {
    guard case .raw(let text) = self else { return nil }
    return
      (try? JSONSerialization.jsonObject(
        with: Data("\"\(text)\"".utf8), options: .fragmentsAllowed)) as? String
  }

  var intValue: Int? {
    guard case .number(let text) = self else { return nil }
    return Int(text)
  }

  subscript(key: String) -> JSONNode? {
    get {
      guard case .object(let members) = self else { return nil }
      return members.first { $0.key == JSONNode.literal(key) }?.value
    }
    set {
      guard case .object(var members) = self else { return }
      let raw = JSONNode.literal(key)
      if let index = members.firstIndex(where: { $0.key == raw }) {
        if let newValue {
          members[index].value = newValue
        } else {
          members.remove(at: index)
        }
      } else if let newValue {
        members.append(.init(raw: raw, newValue))
      }
      self = .object(members)
    }
  }

  // MARK: Reading

  /// Parses JSON the system parser already accepted; nil on anything it can't read.
  static func parse(_ data: Data) -> JSONNode? {
    var parser = Parser(bytes: Array(data))
    guard let value = parser.value() else { return nil }
    parser.skipSpace()
    return parser.index == parser.bytes.count ? value : nil
  }

  private struct Parser {
    let bytes: [UInt8]
    var index = 0

    mutating func skipSpace() {
      while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    mutating func value() -> JSONNode? {
      skipSpace()
      guard index < bytes.count else { return nil }
      switch bytes[index] {
      case UInt8(ascii: "{"): return object()
      case UInt8(ascii: "["): return array()
      case UInt8(ascii: "\""): return string().map(JSONNode.raw)
      case UInt8(ascii: "t"): return word("true", .bool(true))
      case UInt8(ascii: "f"): return word("false", .bool(false))
      case UInt8(ascii: "n"): return word("null", .null)
      default: return number()
      }
    }

    mutating func word(_ text: String, _ value: JSONNode) -> JSONNode? {
      let expected = Array(text.utf8)
      guard index + expected.count <= bytes.count,
        Array(bytes[index..<index + expected.count]) == expected
      else { return nil }
      index += expected.count
      return value
    }

    mutating func number() -> JSONNode? {
      let start = index
      while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
      guard index > start else { return nil }
      return .number(String(decoding: bytes[start..<index], as: UTF8.self))
    }

    /// The literal text between the quotes.
    mutating func string() -> String? {
      guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
      index += 1
      let start = index
      while index < bytes.count {
        switch bytes[index] {
        case UInt8(ascii: "\\"): index += 2
        case UInt8(ascii: "\""):
          let text = String(decoding: bytes[start..<index], as: UTF8.self)
          index += 1
          return text
        default: index += 1
        }
      }
      return nil
    }

    mutating func object() -> JSONNode? {
      index += 1
      var members: [Member] = []
      skipSpace()
      if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
        index += 1
        return .object(members)
      }
      while true {
        skipSpace()
        guard let key = string() else { return nil }
        skipSpace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
        index += 1
        guard let value = value() else { return nil }
        members.append(.init(raw: key, value))
        skipSpace()
        guard index < bytes.count else { return nil }
        if bytes[index] == UInt8(ascii: ",") {
          index += 1
          continue
        }
        guard bytes[index] == UInt8(ascii: "}") else { return nil }
        index += 1
        return .object(members)
      }
    }

    mutating func array() -> JSONNode? {
      index += 1
      var items: [JSONNode] = []
      skipSpace()
      if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
        index += 1
        return .array(items)
      }
      while true {
        guard let value = value() else { return nil }
        items.append(value)
        skipSpace()
        guard index < bytes.count else { return nil }
        if bytes[index] == UInt8(ascii: ",") {
          index += 1
          continue
        }
        guard bytes[index] == UInt8(ascii: "]") else { return nil }
        index += 1
        return .array(items)
      }
    }
  }

  // MARK: Writing

  /// Two spaces per level, `"key": value`, `{}` and `[]` when empty, no trailing newline.
  func render(_ depth: Int = 0) -> String {
    let inner = String(repeating: "  ", count: depth + 1)
    let outer = String(repeating: "  ", count: depth)
    switch self {
    case .object(let members):
      guard !members.isEmpty else { return "{}" }
      return "{\n"
        + members.map { "\(inner)\"\($0.key)\": \($0.value.render(depth + 1))" }
        .joined(separator: ",\n") + "\n\(outer)}"
    case .array(let items):
      guard !items.isEmpty else { return "[]" }
      return "[\n" + items.map { inner + $0.render(depth + 1) }.joined(separator: ",\n")
        + "\n\(outer)]"
    case .raw(let text): return "\"\(text)\""
    case .number(let text): return text
    case .bool(let value): return value ? "true" : "false"
    case .null: return "null"
    }
  }
}
