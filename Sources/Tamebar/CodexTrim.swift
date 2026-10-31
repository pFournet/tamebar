import Darwin
import Foundation

/// Q21: turn off the Codex plugins nobody uses. Each Codex session starts its own copy of every
/// MCP server in `~/.codex/config.toml`, again for each sub-agent: 40–53 helper processes and
/// 1–2 GB per session. An `[mcp_servers.<name>]` no Codex session called in the last 30 days gets
/// `enabled = false`; so does a bundled `[plugins."<id>"]` whose own MCP servers had no call.
/// Affects new sessions only. A plugin without MCP servers (skills only) starts nothing and its
/// use can't be read from the rollouts, so it is left alone.
///
/// Per plugin, Auto (the rule, the default), On (never touched) or Off (always off), set by a hand
/// edit of the file. The servers listed in Settings (`AutomaticSafety.keptCodexServers`) are
/// always On. It runs only once "Turn off unused Codex plugins" is switched on (decisions P2).

// MARK: The file

/// A minimal, format-preserving view of a TOML file, line by line: it finds `[table]` headers
/// (never inside a multi-line string or array) and reads or writes one key, `enabled`, in one
/// table. Everything else stays byte for byte. Pure.
enum CodexTOML {
  struct Table: Equatable {
    /// The header's dotted key, unquoted: `[mcp_servers."context7"]` is `["mcp_servers", "context7"]`.
    let path: [String]
    /// `[[array.of.tables]]`.
    let isArray: Bool
    /// The header's line, and the body's lines after it up to the next header.
    let header: Int
    let body: Range<Int>
  }

  static func lines(_ text: String) -> [String] {
    // By UTF-16 unit, so a CRLF line keeps its `\r` (Swift reads `\r\n` as one character).
    text.components(separatedBy: "\n")
  }

  /// Every table header, in order.
  static func tables(_ lines: [String]) -> [Table] {
    var headers: [(path: [String], isArray: Bool, line: Int)] = []
    var scanner = Scanner()
    for (index, line) in lines.enumerated() {
      if scanner.atTopLevel, let header = header(line) {
        headers.append((header.path, header.isArray, index))
        continue
      }
      scanner.scan(line)
    }
    return headers.enumerated().map { offset, header in
      let end = offset + 1 < headers.count ? headers[offset + 1].line : lines.count
      return Table(
        path: header.path, isArray: header.isArray, header: header.line,
        body: (header.line + 1)..<end)
    }
  }

  /// Tracks multi-line strings and open arrays or inline tables across lines.
  struct Scanner {
    private var multiline: String?
    private var depth = 0

    var atTopLevel: Bool { multiline == nil && depth == 0 }

    mutating func scan(_ line: String) {
      let characters = Array(line)
      var index = 0
      func starts(_ token: String) -> Bool {
        let token = Array(token)
        return index + token.count <= characters.count
          && Array(characters[index..<(index + token.count)]) == token
      }
      while index < characters.count {
        if let delimiter = multiline {
          if delimiter == "\"\"\"", characters[index] == "\\" {
            index += 2
            continue
          }
          if starts(delimiter) {
            index += 3
            // A closing delimiter may be followed by up to two more quotes of its kind.
            while index < characters.count, characters[index] == Array(delimiter)[0] { index += 1 }
            multiline = nil
          } else {
            index += 1
          }
          continue
        }
        let character = characters[index]
        if character == "#" { return }
        if starts("\"\"\"") || starts("'''") {
          multiline = String(characters[index..<(index + 3)])
          index += 3
          continue
        }
        if character == "\"" || character == "'" {
          index += 1
          while index < characters.count, characters[index] != character {
            if character == "\"", characters[index] == "\\" { index += 1 }
            index += 1
          }
          index += 1
          continue
        }
        if character == "[" || character == "{" { depth += 1 }
        if character == "]" || character == "}" { depth = max(0, depth - 1) }
        index += 1
      }
    }
  }

  /// A header line's dotted key, or nil when the line isn't one.
  static func header(_ line: String) -> (path: [String], isArray: Bool)? {
    var text = Substring(line.trimmingCharacters(in: .whitespacesAndNewlines))
    guard text.hasPrefix("[") else { return nil }
    let isArray = text.hasPrefix("[[")
    text = text.dropFirst(isArray ? 2 : 1)
    var path: [String] = []
    var current = ""
    var index = text.startIndex
    var expectingKey = true
    while index < text.endIndex {
      let character = text[index]
      if character == " " || character == "\t" {
        index = text.index(after: index)
        continue
      }
      if character == "]" {
        guard !expectingKey else { return nil }
        path.append(current)
        let rest = text[text.index(after: index)...]
        let close = isArray ? rest.dropFirst() : rest
        if isArray, rest.first != "]" { return nil }
        let trailing = close.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trailing.isEmpty || trailing.hasPrefix("#") else { return nil }
        return (path, isArray)
      }
      if character == "." {
        guard !expectingKey else { return nil }
        path.append(current)
        current = ""
        expectingKey = true
        index = text.index(after: index)
        continue
      }
      guard expectingKey else { return nil }
      if character == "\"" || character == "'" {
        var value = ""
        index = text.index(after: index)
        while index < text.endIndex, text[index] != character {
          if character == "\"", text[index] == "\\" {
            index = text.index(after: index)
            guard index < text.endIndex else { return nil }
          }
          value.append(text[index])
          index = text.index(after: index)
        }
        guard index < text.endIndex else { return nil }
        current = value
        index = text.index(after: index)
      } else {
        var value = ""
        while index < text.endIndex,
          text[index].isLetter || text[index].isNumber || text[index] == "_" || text[index] == "-"
        {
          value.append(text[index])
          index = text.index(after: index)
        }
        guard !value.isEmpty else { return nil }
        current = value
      }
      expectingKey = false
    }
    return nil
  }

  /// `enabled = true|false` as a line of a table's body (bare or quoted key, an optional comment).
  static func enabledLine(_ line: String) -> (value: Bool, range: Range<String.Index>)? {
    let pattern = #"^\s*(?:enabled|"enabled"|'enabled')\s*=\s*(true|false)\s*(?:#.*)?\r?$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
      let range = Range(match.range(at: 1), in: line)
    else { return nil }
    return (line[range] == "true", range)
  }

  /// The one plain table at `path`; nil when there is none or more than one.
  static func table(_ path: [String], in lines: [String]) -> Table? {
    let matches = tables(lines).filter { !$0.isArray && $0.path == path }
    return matches.count == 1 ? matches[0] : nil
  }

  /// The table's `enabled` line in its body, at the top level of the body.
  static func enabledIndex(_ table: Table, in lines: [String]) -> Int? {
    var scanner = Scanner()
    for index in table.body {
      if scanner.atTopLevel, enabledLine(lines[index]) != nil { return index }
      scanner.scan(lines[index])
    }
    return nil
  }

  /// The table's `enabled`: nil when the key is missing (Codex's default, on).
  static func enabled(_ path: [String], in text: String) -> Bool? {
    let lines = lines(text)
    guard let table = table(path, in: lines), let index = enabledIndex(table, in: lines) else {
      return nil
    }
    return enabledLine(lines[index])?.value
  }

  /// The text with `enabled = <value>` in that table only: the existing line's value replaced
  /// in place, or a new line right under the header. Nil when the table isn't there exactly once.
  static func setEnabled(_ path: [String], _ value: Bool, in text: String) -> String? {
    var lines = lines(text)
    guard let table = table(path, in: lines) else { return nil }
    let word = value ? "true" : "false"
    if let index = enabledIndex(table, in: lines), let found = enabledLine(lines[index]) {
      lines[index].replaceSubrange(found.range, with: word)
    } else {
      let ending = lines[table.header].hasSuffix("\r") ? "\r" : ""
      lines.insert("enabled = \(word)" + ending, at: table.header + 1)
    }
    return lines.joined(separator: "\n")
  }

  /// The `[mcp_servers.<name>]` and `[plugins."<id>"]` tables, with their `enabled`.
  static func entries(_ text: String) -> [CodexTrim.Item] {
    let lines = lines(text)
    var counts: [[String]: Int] = [:]
    let all = tables(lines).filter { !$0.isArray }
    for table in all { counts[table.path, default: 0] += 1 }
    return all.compactMap { table in
      guard table.path.count == 2, counts[table.path] == 1,
        let kind = CodexTrim.Kind(section: table.path[0])
      else { return nil }
      let enabled = enabledIndex(table, in: lines).flatMap { enabledLine(lines[$0])?.value }
      return .init(kind: kind, name: table.path[1], enabled: enabled)
    }
  }
}

// MARK: The rollouts

/// Which MCP servers Codex sessions called, from the rollouts under `~/.codex/sessions`.
/// A call is recorded as (seen in this Mac's rollouts, October 2026):
/// - `{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"McpToolCall",
///   "server":"mcp-server-github",…}}}`, for every MCP call, a code-mode one included;
/// - `{"type":"response_item","payload":{"type":"function_call","namespace":"mcp__cua_repl",…}}`
///   for a direct call (the server's name, `-` read as `_`);
/// - older builds: a `function_call` named `mcp__<server>__<tool>`, and `mcp_tool_call_begin` /
///   `mcp_tool_call_end` events with `invocation.server`.
/// Only lines holding one of those markers are parsed; nothing else is read.
enum CodexRollouts {
  struct Usage: Equatable, Sendable {
    /// Calls by server, its name normalized (`normalize`).
    var calls: [String: Int] = [:]
    var files = 0
    /// Rollouts in the window that couldn't be read in full.
    var unreadable: [String] = []
    /// The day of the oldest rollout on disk.
    var oldest: Date?
  }

  /// Lowercased, every character that isn't a letter or a digit read as `_`: how Codex names a
  /// server in a tool namespace.
  static func normalize(_ name: String) -> String {
    String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
  }

  static let markers = ["McpToolCall", "\"mcp__", "mcp_tool_call"].map { Data($0.utf8) }

  /// The servers one rollout line calls (none or one), normalized.
  static func servers(inLine line: Data) -> [String] {
    call(inLine: line).map { [$0.server] } ?? []
  }

  /// The server a rollout line calls, normalized, and whether the line is an `McpToolCall` item.
  static func call(inLine line: Data) -> (server: String, item: Bool)? {
    guard markers.contains(where: { line.range(of: $0) != nil }),
      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      let payload = object["payload"] as? [String: Any]
    else { return nil }
    let type = payload["type"] as? String
    if let item = payload["item"] as? [String: Any], item["type"] as? String == "McpToolCall",
      let server = item["server"] as? String
    {
      return (normalize(server), true)
    }
    if type == "function_call" || type == "custom_tool_call" {
      if let namespace = payload["namespace"] as? String, namespace.hasPrefix("mcp__") {
        return (normalize(String(namespace.dropFirst(5))), false)
      }
      if let name = payload["name"] as? String, name.hasPrefix("mcp__") {
        let parts = name.dropFirst(5).components(separatedBy: "__")
        if parts.count >= 2, !parts[0].isEmpty { return (normalize(parts[0]), false) }
      }
    }
    if type == "mcp_tool_call_end",
      let invocation = payload["invocation"] as? [String: Any],
      let server = invocation["server"] as? String
    {
      return (normalize(server), false)
    }
    return nil
  }

  /// The zstd tool, for the rollouts Codex compresses (`.jsonl.zst`); nil when none is installed.
  static func zstd() -> URL? {
    ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
      .first { FileManager.default.isExecutableFile(atPath: $0) }
      .map { URL(fileURLWithPath: $0) }
  }

  /// Every rollout written since `since`, read line by line in 1 MB chunks.
  static func scan(sessions: URL, since: Date, zstd: URL? = zstd()) -> Usage {
    var usage = Usage()
    usage.oldest = oldest(sessions)
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: sessions, includingPropertiesForKeys: keys)
    else { return usage }
    for case let url as URL in enumerator {
      let name = url.lastPathComponent
      guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst"),
        let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
        let modified = values.contentModificationDate, modified >= since
      else { continue }
      usage.files += 1
      // A call can show twice in one rollout (its `McpToolCall` item and its `function_call`):
      // a file with items is counted by its items alone.
      var items: [String: Int] = [:]
      var others: [String: Int] = [:]
      let ok = read(url, zstd: zstd) { line in
        guard let call = call(inLine: line) else { return }
        if call.item {
          items[call.server, default: 0] += 1
        } else {
          others[call.server, default: 0] += 1
        }
      }
      for (server, count) in items.isEmpty ? others : items {
        usage.calls[server, default: 0] += count
      }
      if !ok { usage.unreadable.append(url.path) }
    }
    return usage
  }

  /// The rollouts' first day: the oldest `YYYY/MM/DD` folder under `sessions`.
  static func oldest(_ sessions: URL) -> Date? {
    let manager = FileManager.default
    func sortedNumbers(_ url: URL) -> [String] {
      ((try? manager.contentsOfDirectory(atPath: url.path)) ?? [])
        .filter { Int($0) != nil }.sorted()
    }
    for year in sortedNumbers(sessions) {
      for month in sortedNumbers(sessions.appendingPathComponent(year)) {
        let monthURL = sessions.appendingPathComponent(year).appendingPathComponent(month)
        for day in sortedNumbers(monthURL) {
          let dayURL = monthURL.appendingPathComponent(day)
          guard !((try? manager.contentsOfDirectory(atPath: dayURL.path)) ?? []).isEmpty
          else { continue }
          var components = DateComponents()
          components.year = Int(year)
          components.month = Int(month)
          components.day = Int(day)
          return Calendar(identifier: .gregorian).date(from: components)
        }
      }
    }
    return nil
  }

  /// Calls `line` on each line; false when the file couldn't be read to its end.
  static func read(_ url: URL, zstd: URL?, line: (Data) -> Void) -> Bool {
    if url.pathExtension == "zst" {
      guard let zstd else { return false }
      let process = Process()
      process.executableURL = zstd
      process.arguments = ["-dcq", "--", url.path]
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      process.standardInput = FileHandle.nullDevice
      guard (try? process.run()) != nil else { return false }
      lines(pipe.fileHandleForReading, line)
      process.waitUntilExit()
      return process.terminationStatus == 0
    }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    lines(handle, line)
    return true
  }

  /// Hands over only the lines holding a marker: the chunk is searched with `memmem`, and only
  /// around a hit is the line cut out. Rollouts run to hundreds of megabytes.
  private static func lines(_ handle: FileHandle, _ line: (Data) -> Void) {
    var buffer = Data()
    while true {
      let chunk = autoreleasepool { handle.readData(ofLength: 4 << 20) }
      if chunk.isEmpty { break }
      buffer.append(chunk)
      guard let end = lastNewline(buffer) else { continue }
      marked(buffer.prefix(end + 1), line)
      buffer = Data(buffer.suffix(from: buffer.startIndex + end + 1))
    }
    if !buffer.isEmpty { marked(buffer, line) }
  }

  private static func lastNewline(_ data: Data) -> Int? {
    data.withUnsafeBytes { raw -> Int? in
      guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
      var index = raw.count - 1
      while index >= 0 {
        if base[index] == 0x0A { return index }
        index -= 1
      }
      return nil
    }
  }

  /// The lines of `region` holding a marker, each once, in order.
  private static func marked(_ region: Data, _ line: (Data) -> Void) {
    let region = Data(region)
    let ranges = region.withUnsafeBytes { raw -> [Range<Int>] in
      guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return [] }
      let count = raw.count
      var found: [Int: Int] = [:]
      for marker in markers {
        marker.withUnsafeBytes { needle in
          var offset = 0
          while offset < count,
            let hit = memmem(base + offset, count - offset, needle.baseAddress, needle.count)
          {
            let position = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
            var start = position
            while start > 0, base[start - 1] != 0x0A { start -= 1 }
            let newline = memchr(base + position, 0x0A, count - position)
            let end =
              newline.map { UnsafeRawPointer(base).distance(to: UnsafeRawPointer($0)) } ?? count
            found[start] = end
            offset = end + 1
          }
        }
      }
      return found.sorted { $0.key < $1.key }.map { $0.key..<$0.value }
    }
    for range in ranges { line(region.subdata(in: range)) }
  }
}

// MARK: Bundled plugins

/// A plugin's own MCP servers, from Codex's plugin cache:
/// `<cache>/<marketplace>/<name>/<version>/.codex-plugin/plugin.json`, whose `mcpServers` is a
/// path (`./.mcp.json`) or the servers themselves; `.mcp.json` holds `{"mcpServers": {name: …}}`.
enum CodexPluginCatalog {
  /// The servers of `name@marketplace` across its cached versions; nil when it isn't cached.
  static func servers(_ id: String, cache: URL) -> Set<String>? {
    let parts = id.split(separator: "@", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return nil }
    let folder = cache.appendingPathComponent(parts[1]).appendingPathComponent(parts[0])
    guard let versions = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
      !versions.isEmpty
    else { return nil }
    var servers: Set<String> = []
    for version in versions where !version.hasPrefix(".") {
      let root = folder.appendingPathComponent(version)
      var declared: Any? = json(root.appendingPathComponent(".codex-plugin/plugin.json"))
        .flatMap { ($0 as? [String: Any])?["mcpServers"] }
      if let path = declared as? String {
        declared = json(root.appendingPathComponent(path)).flatMap {
          ($0 as? [String: Any])?["mcpServers"]
        }
      }
      if declared == nil {
        declared = json(root.appendingPathComponent(".mcp.json")).flatMap {
          ($0 as? [String: Any])?["mcpServers"]
        }
      }
      if let table = declared as? [String: Any] { servers.formUnion(table.keys) }
    }
    return servers
  }

  private static func json(_ url: URL) -> Any? {
    (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
  }
}

// MARK: The plan

enum CodexTrim {
  static let window: TimeInterval = 30 * 86_400
  static let interval: TimeInterval = 86_400
  /// A config written this recently may be a Codex session starting: no edit now.
  static let settle: TimeInterval = 60

  enum Kind: String, Codable, Sendable {
    case server, plugin

    init?(section: String) {
      switch section {
      case "mcp_servers": self = .server
      case "plugins": self = .plugin
      default: return nil
      }
    }

    var section: String { self == .server ? "mcp_servers" : "plugins" }
  }

  struct Item: Equatable, Sendable {
    let kind: Kind
    let name: String
    /// nil: the key is missing (on).
    let enabled: Bool?

    var key: String { "\(kind.rawValue):\(name)" }
    var path: [String] { [kind.section, name] }
    var isOn: Bool { enabled != false }
  }

  /// Per server or plugin (2026-10-30). There is no Settings screen: Auto is the default,
  /// and a hand edit of the file sets the other two (`handEdits`), as does Undo (On).
  enum Mode: String, Codable, CaseIterable, Sendable {
    /// Q21's rule: off once no Codex session called it in 30 days.
    case auto
    /// Never touched; turned back on if Tamebar had turned it off.
    case on
    /// Always `enabled = false`.
    case off
  }

  /// The modes hand edits and Undo set, in UserDefaults `codexPlugins.modes.v1` as `{key: mode}`.
  enum Modes {
    static let key = "codexPlugins.modes.v1"
    /// `alwaysOn`: the servers listed in Settings (messaging servers receive messages, which
    /// call counts don't show), as `server:<name>` keys: always On, never touched.
    static func mode(_ key: String, in modes: [String: Mode], alwaysOn: Set<String> = []) -> Mode {
      alwaysOn.contains(key) ? .on : modes[key] ?? .auto
    }

    static func load(_ defaults: UserDefaults) -> [String: Mode] {
      guard let data = defaults.data(forKey: key),
        let raw = try? JSONDecoder().decode([String: String].self, from: data)
      else { return [:] }
      return raw.compactMapValues(Mode.init(rawValue:))
    }

    static func save(_ modes: [String: Mode], _ defaults: UserDefaults) {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      guard let data = try? encoder.encode(modes.mapValues(\.rawValue)) else { return }
      defaults.set(data, forKey: key)
    }
  }

  /// Whether Auto may judge now: the rollouts go back 30 days and every one in the window was
  /// read. Nil when it may; the reason otherwise.
  static func held(_ usage: CodexRollouts.Usage, now: Date) -> String? {
    if !usage.unreadable.isEmpty {
      return "\(usage.unreadable.count) Codex rollouts couldn't be read"
    }
    guard let oldest = usage.oldest else { return "no Codex rollouts" }
    return now.timeIntervalSince(oldest) < window ? "Codex rollouts go back less than 30 days" : nil
  }

  /// A server's calls, or a plugin's (the sum of its MCP servers'); nil for a plugin with no MCP
  /// server or not in the cache, which isn't listed or touched.
  static func calls(_ item: Item, calls: [String: Int], pluginServers: (String) -> Set<String>?)
    -> Int?
  {
    func count(_ server: String) -> Int { calls[CodexRollouts.normalize(server)] ?? 0 }
    switch item.kind {
    case .server: return count(item.name)
    case .plugin:
      guard let servers = pluginServers(item.name), !servers.isEmpty else { return nil }
      return servers.reduce(0) { $0 + count($1) }
    }
  }

  struct Change: Equatable, Sendable {
    let item: Item
    let on: Bool
    /// Auto's rule turned it off: a Stopped entry with Undo, and the note.
    let automatic: Bool
  }

  /// What the file should change, per row's mode: Off turns off; On turns back on only what
  /// Tamebar turned off; Auto turns off what had no call in 30 days, unless `held` (no calls
  /// known yet, or not enough rollouts). A plugin without MCP servers is never touched.
  /// `turnsOff` false (the Settings switch is off): only On's turning back on, which Undo asks for.
  static func plan(
    items: [Item], modes: [String: Mode], calls: [String: Int]?, held: Bool,
    turnedOffByTamebar: Set<String>, pluginServers: (String) -> Set<String>?,
    alwaysOn: Set<String> = [], turnsOff: Bool = true
  ) -> [Change] {
    items.compactMap { item in
      guard let count = Self.calls(item, calls: calls ?? [:], pluginServers: pluginServers)
      else { return nil }
      let mode = Modes.mode(item.key, in: modes, alwaysOn: alwaysOn)
      guard turnsOff || mode == .on else { return nil }
      switch mode {
      case .off:
        return item.isOn ? Change(item: item, on: false, automatic: false) : nil
      case .on:
        return !item.isOn && turnedOffByTamebar.contains(item.key)
          ? Change(item: item, on: true, automatic: false) : nil
      case .auto:
        guard item.isOn, !held, calls != nil, count == 0 else { return nil }
        return Change(item: item, on: false, automatic: true)
      }
    }
  }

  /// A hand edit of the file wins (2026-10-30): a row whose state in the file changed since
  /// Tamebar last saw it is set to On or Off to match. A row seen for the first time already off
  /// by hand is Off. Returns the modes to set.
  static func handEdits(items: [Item], known: [String: Bool], turnedOffByTamebar: Set<String>)
    -> [String: Mode]
  {
    var changes: [String: Mode] = [:]
    for item in items {
      if let was = known[item.key] {
        if was != item.isOn { changes[item.key] = item.isOn ? .on : .off }
      } else if !item.isOn, !turnedOffByTamebar.contains(item.key) {
        changes[item.key] = .off
      }
    }
    return changes
  }
}

// MARK: What Tamebar did

/// `codex-plugins.json` in Tamebar's folder: what Q21's Auto turned off and is still off, each
/// row's state as Tamebar last saw it in the file (to tell a hand edit), and the latest run.
struct CodexTrimState: Codable, Equatable, Sendable {
  static let fileName = "codex-plugins.json"

  struct Entry: Codable, Equatable, Sendable {
    let kind: CodexTrim.Kind
    let name: String
    let offAt: Date
    /// The backup taken before the change.
    var backup: String?

    var key: String { "\(kind.rawValue):\(name)" }
  }

  struct Run: Codable, Equatable, Sendable {
    let at: Date
    /// Something was written to the file.
    var applied: Bool
    /// What Auto turned off at this run: server names, plugins as `plugin <id>`.
    var turnOff: [String]
    /// Calls in the last 30 days by server, normalized (`CodexRollouts.normalize`).
    let calls: [String: Int]
    var held: String?
    var files = 0
  }

  var off: [Entry] = []
  /// Each row's on/off as Tamebar last saw or wrote it.
  var known: [String: Bool] = [:]
  var lastRun: Run?

  static func read(_ directory: URL) -> Self? {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else {
      return nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(Self.self, from: data)
  }

  func save(_ directory: URL) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    guard let data = try? encoder.encode(self) else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
  }
}

/// Runs Q21 against files it is given: the real ones in the app, copies in tests.
struct CodexTrimRunner: Sendable {
  struct Paths: Sendable {
    let config: URL
    let sessions: URL
    let pluginCache: URL
    /// Tamebar's folder: the state file and `codex-config-backups/`.
    let directory: URL

    static func live(home: URL, directory: URL) -> Paths {
      let codex = home.appendingPathComponent(".codex")
      return .init(
        config: codex.appendingPathComponent("config.toml"),
        sessions: codex.appendingPathComponent("sessions"),
        pluginCache: codex.appendingPathComponent("plugins/cache"), directory: directory)
    }
  }

  let paths: Paths
  var zstd: URL? = CodexRollouts.zstd()
  static let backupsKept = 20

  struct Outcome: Equatable, Sendable {
    /// False: the file was just written (a Codex session may be starting) or unreadable.
    var ran = false
    var turnedOff: [CodexTrimState.Entry] = []
    var turnedOn: [String] = []
    /// Rows a hand edit set to On or Off.
    var modes: [String: CodexTrim.Mode] = [:]
    var state = CodexTrimState()
  }

  /// Once a day: true when the last count is a day old or more, or there is none.
  static func due(_ state: CodexTrimState?, now: Date) -> Bool {
    guard let last = state?.lastRun?.at else { return true }
    return now.timeIntervalSince(last) >= CodexTrim.interval || now < last
  }

  /// What a run applies: the rows' modes, the servers always On, and whether it may turn
  /// anything off (the Settings switch; off, only Undo's turning back on is done).
  struct Rules: Sendable {
    var modes: [String: CodexTrim.Mode] = [:]
    var alwaysOn: Set<String> = []
    var turnsOff = true
  }

  /// The daily run: counts the calls in the rollouts, then applies the modes.
  func run(now: Date, rules: Rules) -> Outcome {
    guard let first = readConfig(), now.timeIntervalSince(first.modified) >= CodexTrim.settle
    else { return Outcome(state: CodexTrimState.read(paths.directory) ?? CodexTrimState()) }
    let usage = CodexRollouts.scan(
      sessions: paths.sessions, since: now.addingTimeInterval(-CodexTrim.window), zstd: zstd)
    var state = CodexTrimState.read(paths.directory) ?? CodexTrimState()
    state.lastRun = .init(
      at: now, applied: false, turnOff: [], calls: usage.calls,
      held: CodexTrim.held(usage, now: now), files: usage.files)
    state.save(paths.directory)
    return apply(now: now, rules: rules)
  }

  /// Matches the file to the modes, with the latest run's counts: a hand edit first sets its
  /// row, then Off and Auto turn off and On turns back on, in one write after a backup. Cheap: a
  /// Settings change or Undo runs it at once.
  func apply(now: Date, rules: Rules) -> Outcome {
    var state = CodexTrimState.read(paths.directory) ?? CodexTrimState()
    var outcome = Outcome(state: state)
    guard let read = readConfig(), now.timeIntervalSince(read.modified) >= CodexTrim.settle
    else { return outcome }
    let items = CodexTOML.entries(read.text)
    // What Auto turned off and is on again, by hand, leaves `off`; the hand edit sets its row.
    let edits = CodexTrim.handEdits(
      items: items, known: state.known, turnedOffByTamebar: Set(state.off.map(\.key)))
    outcome.modes = edits
    let byKey = Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    state.off.removeAll { byKey[$0.key]?.isOn ?? true }
    var effective = rules.modes
    for (key, mode) in edits { effective[key] = mode }
    let pluginServers = { (id: String) in CodexPluginCatalog.servers(id, cache: paths.pluginCache) }
    let changes = CodexTrim.plan(
      items: items, modes: effective, calls: state.lastRun?.calls,
      held: state.lastRun?.held != nil, turnedOffByTamebar: Set(state.off.map(\.key)),
      pluginServers: pluginServers, alwaysOn: rules.alwaysOn, turnsOff: rules.turnsOff)
    var written = read.text
    if !changes.isEmpty,
      let edited = changes.reduce(
        Optional(read.text),
        { text, change in
          text.flatMap { CodexTOML.setEnabled(change.item.path, change.on, in: $0) }
        }), let backup = backup(read.text, now: now), write(edited, expecting: read.text)
    {
      written = edited
      for change in changes {
        let key = change.item.key
        if change.on {
          state.off.removeAll { $0.key == key }
          outcome.turnedOn.append(change.item.name)
        } else if change.automatic {
          let entry = CodexTrimState.Entry(
            kind: change.item.kind, name: change.item.name, offAt: now, backup: backup.path)
          state.off.removeAll { $0.key == key }
          state.off.append(entry)
          outcome.turnedOff.append(entry)
        }
      }
      if !outcome.turnedOff.isEmpty, var run = state.lastRun {
        run.applied = true
        run.turnOff += outcome.turnedOff.map { $0.kind == .server ? $0.name : "plugin \($0.name)" }
        state.lastRun = run
      }
    }
    let final = CodexTOML.entries(written)
    state.known = Dictionary(
      final.map { ($0.key, $0.isOn) }, uniquingKeysWith: { first, _ in first })
    state.save(paths.directory)
    outcome.ran = true
    outcome.state = state
    return outcome
  }

  private func readConfig() -> (text: String, modified: Date)? {
    let url = paths.config.resolvingSymlinksInPath()
    guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
      let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
        .modificationDate] as? Date
    else { return nil }
    return (text, modified)
  }

  /// `codex-config-backups/config-YYYYMMDD-HHMMSS.toml`, readable by this user only (the file
  /// holds tokens); the newest 20 are kept.
  private func backup(_ text: String, now: Date) -> URL? {
    let folder = paths.directory.appendingPathComponent("codex-config-backups", isDirectory: true)
    let manager = FileManager.default
    try? manager.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let stamp = formatter.string(from: now)
    var url = folder.appendingPathComponent("config-\(stamp).toml")
    var suffix = 1
    while manager.fileExists(atPath: url.path) {
      suffix += 1
      url = folder.appendingPathComponent("config-\(stamp)-\(suffix).toml")
    }
    guard
      manager.createFile(
        atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
    else { return nil }
    let backups = ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? [])
      .filter { $0.hasPrefix("config-") }.sorted()
    for old in backups.dropLast(Self.backupsKept) {
      try? manager.removeItem(at: folder.appendingPathComponent(old))
    }
    return url
  }

  /// Writes beside the file and renames over it, keeping its permissions; a symbolic link is
  /// followed, so the link stays. Nothing is written when the file changed since it was read.
  private func write(_ text: String, expecting: String) -> Bool {
    let url = paths.config.resolvingSymlinksInPath()
    guard (try? String(contentsOf: url, encoding: .utf8)) == expecting else { return false }
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).tamebar-\(getpid())")
    let permissions =
      (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
      as? NSNumber
    guard
      FileManager.default.createFile(
        atPath: temporary.path, contents: Data(text.utf8),
        attributes: [.posixPermissions: permissions?.intValue ?? 0o644])
    else { return false }
    guard rename(temporary.path, url.path) == 0 else {
      try? FileManager.default.removeItem(at: temporary)
      return false
    }
    return true
  }
}
