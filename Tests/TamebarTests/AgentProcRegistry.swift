import Darwin
import Foundation
import Testing

/// `~/.claude/agent-procs.jsonl`: one JSON line per server an agent starts, so cleanup finds it
/// by this registry, never by a port scan.
enum AgentProcRegistry {
  static let session = "tamebar-e2e"

  struct Entry: Encodable, Equatable {
    let pid: Int32
    let port: UInt16
    let session: String
    let purpose: String
    let started: String

    init(
      pid: Int32, port: UInt16, purpose: String, session: String = AgentProcRegistry.session,
      at: Date = .now
    ) {
      self.pid = pid
      self.port = port
      self.session = session
      self.purpose = purpose
      self.started = ISO8601DateFormatter().string(from: at)
    }
  }

  enum Failure: Error, Equatable {
    case open(Int32)
    case shortWrite(Int)
    case rename(Int32)
    /// The file changed under every one of the rewrite's tries.
    case busy
  }

  static var file: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      ".claude/agent-procs.jsonl")
  }

  /// Appends one line with a single `write(2)` on an `O_APPEND` descriptor. A file whose last line
  /// has no newline gets one first, so lines never merge.
  static func append(_ entry: Entry, to file: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var line = try encoder.encode(entry)
    line.append(0x0A)
    if let reader = try? FileHandle(forReadingFrom: file) {
      defer { try? reader.close() }
      let end = try reader.seekToEnd()
      if end > 0 {
        try reader.seek(toOffset: end - 1)
        if try reader.read(upToCount: 1) != Data([0x0A]) { line.insert(0x0A, at: 0) }
      }
    } else {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard descriptor >= 0 else { throw Failure.open(errno) }
    defer { close(descriptor) }
    let written = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    guard written == line.count else { throw Failure.shortWrite(written) }
  }

  /// Drops this session's lines for `pid`. Every other line, including any that doesn't parse,
  /// stays byte for byte.
  static func remove(
    pid: Int32, session: String = AgentProcRegistry.session, from file: URL,
    beforeReplace: () -> Void = {}
  ) throws {
    try rewrite(file, beforeReplace: beforeReplace) { row in
      !((row["pid"] as? NSNumber)?.int32Value == pid && row["session"] as? String == session)
    }
  }

  /// Drops this session's lines whose pid no longer runs: what an earlier, interrupted run left.
  static func pruneDead(session: String = AgentProcRegistry.session, from file: URL) throws {
    guard FileManager.default.fileExists(atPath: file.path) else { return }
    try rewrite(file) { row in
      guard row["session"] as? String == session, let pid = (row["pid"] as? NSNumber)?.int32Value
      else { return true }
      return pid > 1 && (kill(pid, 0) == 0 || errno == EPERM)
    }
  }

  /// Keeps the lines `keep` accepts (unparseable lines always stay) and swaps the result in with
  /// `rename(2)`, so the file is never truncated. If the file changed after it was read, the
  /// rewrite is rebuilt from the new contents, up to 3 tries.
  static func rewrite(
    _ file: URL, beforeReplace: () -> Void = {}, keep: ([String: Any]) -> Bool
  ) throws {
    let target = file.resolvingSymlinksInPath()
    for _ in 0..<3 {
      let data = try Data(contentsOf: target)
      let rewritten = Data(
        lines(data).filter { line in
          guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
          else { return true }
          return keep(row)
        }.joined())
      guard rewritten != data else { return }
      beforeReplace()
      let temporary = target.deletingLastPathComponent().appendingPathComponent(
        ".\(target.lastPathComponent).\(UUID().uuidString).tmp")
      do {
        try rewritten.write(to: temporary, options: .withoutOverwriting)
        if let mode = try? FileManager.default.attributesOfItem(atPath: target.path)[
          .posixPermissions]
        {
          try? FileManager.default.setAttributes(
            [.posixPermissions: mode], ofItemAtPath: temporary.path)
        }
        guard try Data(contentsOf: target) == data else {
          try? FileManager.default.removeItem(at: temporary)
          continue
        }
        guard Darwin.rename(temporary.path, target.path) == 0 else {
          throw Failure.rename(errno)
        }
        return
      } catch {
        try? FileManager.default.removeItem(at: temporary)
        throw error
      }
    }
    throw Failure.busy
  }

  /// Every `port` the file lists, whatever the session.
  static func ports(in file: URL) -> Set<UInt16> {
    guard let data = try? Data(contentsOf: file) else { return [] }
    return Set(
      lines(data).compactMap { line in
        (try? JSONSerialization.jsonObject(with: line) as? [String: Any])
          .flatMap { ($0["port"] as? NSNumber)?.uint16Value }
      })
  }

  /// The file's lines, each with its own trailing newline when it has one.
  static func lines(_ data: Data) -> [Data] {
    var result: [Data] = []
    var start = data.startIndex
    for index in data.indices where data[index] == 0x0A {
      result.append(data[start...index])
      start = index + 1
    }
    if start < data.endIndex { result.append(data[start...]) }
    return result
  }
}

@Suite struct AgentProcRegistryTests {
  func scratch() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tamebar-registry-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent("agent-procs.jsonl")
  }

  let others =
    "{\"pid\":42,\"port\":5175,\"session\":\"lead\",\"purpose\":\"vite\"}\n"
    + "not json at all\n"
    + "{\"pid\":7,\"session\":\"other\",\"stopped\":\"2026-10-20T08:57:56Z\"}\r\n"
    + "{\"pid\":7,\"session\":\"lead\",\"purpose\":\"same pid, other session\"}\n"
    + "  {\"pid\":  99 , \"note\": \"odd spacing\"}"

  @Test func removeLeavesEveryOtherLineByteForByte() throws {
    let file = try scratch()
    let folder = file.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data(others.utf8).write(to: file)
    try AgentProcRegistry.append(.init(pid: 7, port: 3101, purpose: "e2e"), to: file)

    let appended = try String(contentsOf: file, encoding: .utf8)
    #expect(
      appended.hasPrefix(
        others + "\n{\"pid\":7,\"port\":3101,\"purpose\":\"e2e\",\"session\":\"tamebar-e2e\""))

    try AgentProcRegistry.remove(pid: 7, from: file)
    #expect(try Data(contentsOf: file) == Data((others + "\n").utf8))
    // No temp file left beside it.
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: folder.path) == [file.lastPathComponent])
  }

  @Test func removeWithoutAMatchDoesNotRewrite() throws {
    let file = try scratch()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let text = "{\"pid\":1,\"session\":\"tamebar-e2e\"}\nbroken {\n"
    try Data(text.utf8).write(to: file)
    try AgentProcRegistry.remove(pid: 2, from: file)
    #expect(try String(contentsOf: file, encoding: .utf8) == text)
  }

  @Test func appendCreatesTheFile() throws {
    let file = try scratch()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    try AgentProcRegistry.append(.init(pid: 5, port: 3102, purpose: "p"), to: file)
    try AgentProcRegistry.remove(pid: 5, from: file)
    #expect(try Data(contentsOf: file).isEmpty)
  }

  /// A line another agent appends between the read and the swap survives: the rewrite retries.
  @Test func removeRetriesWhenTheFileChangesBeforeTheSwap() throws {
    let file = try scratch()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    try Data(others.utf8).write(to: file)
    try AgentProcRegistry.append(.init(pid: 7, port: 3101, purpose: "e2e"), to: file)
    let late = "{\"pid\":8,\"session\":\"late\"}\n"
    var calls = 0
    try AgentProcRegistry.remove(pid: 7, from: file) {
      calls += 1
      if calls == 1, let handle = try? FileHandle(forWritingTo: file) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(late.utf8))
        try? handle.close()
      }
    }
    #expect(calls == 2)
    #expect(try String(contentsOf: file, encoding: .utf8) == others + "\n" + late)
  }

  @Test func pruneDropsOnlyThisSessionsDeadLines() throws {
    let file = try scratch()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    // macOS pids stop at 99999, so 999999 never runs.
    let alive = "{\"pid\":\(getpid()),\"session\":\"tamebar-e2e\"}\n"
    let otherSession = "{\"pid\":999999,\"session\":\"lead\"}\n"
    try Data(
      (others + "\n" + alive + "{\"pid\":999999,\"session\":\"tamebar-e2e\"}\n" + otherSession)
        .utf8
    ).write(to: file)
    try AgentProcRegistry.pruneDead(from: file)
    #expect(
      try String(contentsOf: file, encoding: .utf8) == others + "\n" + alive + otherSession)
  }

  @Test func portsListsEverySession() throws {
    let file = try scratch()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    try Data(others.utf8).write(to: file)
    try AgentProcRegistry.append(.init(pid: 7, port: 3101, purpose: "e2e"), to: file)
    #expect(AgentProcRegistry.ports(in: file) == [5175, 3101])
  }
}
