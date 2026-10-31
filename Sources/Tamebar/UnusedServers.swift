import Foundation
import os

/// Q20: end a session and its dev server once both have been unused 24 h (amends Q7, Q18).
///
/// Q7's "serving" protection kept every session with a listening child away from Q10 and Q18, so
/// a Codex session up for ten days with a dev server nobody opened kept its gigabytes. Q20 lifts
/// that one protection when the session has had no interaction for 24 h (Q18's meaning: no turn,
/// no keystroke) and no port it serves has had an established TCP connection for 24 h. Then the
/// dev server is ended first (Quit: SIGTERM to its tree), then the session (Q4's Quit, with Q18's
/// re-checks right before the signal). Never a protected port, never a kept session or project,
/// never during a call, and never a session running something else besides its server.

/// The ports Q20 never ends, whatever their idle time: the ones listed in Settings
/// (`AutomaticSafety.protectedPorts`, empty by default), the portless proxy's own ports
/// (`portless proxy start -p 1355`, its HTTP redirect on 80, HTTPS on 443), and every port the
/// portless routes file maps a name to.
enum ProtectedPorts {
  /// The portless proxy: 1355, and 443 and 80 for its HTTPS and redirect.
  static let proxy: Set<Int> = [1355, 443, 80]

  /// `<home>/.portless/routes.json`, a list of `{"hostname", "port", "pid"}`.
  static func routes(home: URL) -> Set<Int> {
    let url = home.appendingPathComponent(".portless/routes.json")
    guard let data = try? Data(contentsOf: url),
      let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return Set(list.compactMap { ($0["port"] as? NSNumber)?.intValue })
  }

  static func current(home: URL, listed: [Int]) -> Set<Int> {
    proxy.union(listed).union(routes(home: home))
  }

  /// A process run through portless (`portless <name> <cmd>`, `portless run …`, the proxy): an
  /// argument token that is the `portless` executable or its package.
  static func isPortless(_ arguments: String) -> Bool {
    arguments.split(separator: " ").prefix(3).contains { token in
      let name = token.split(separator: "/").last.map(String.init) ?? String(token)
      return name == "portless"
    }
  }
}

/// The last time each port a session serves had an established TCP connection (Q20), saved in
/// `served-ports.json` so a restart of Tamebar doesn't reset the clock. A port seen for the first
/// time starts at that scan: nothing is judged unused retroactively.
struct ServedPortClock: Codable, Equatable, Sendable {
  static let fileName = "served-ports.json"
  /// By port.
  private(set) var lastUsed: [Int: Date] = [:]

  /// One scan: every served port with a connection now, or seen for the first time, is used now.
  /// A port no longer served is forgotten, unless the port scan was partial.
  mutating func observe(served: Set<Int>, connected: Set<Int>, now: Date, complete: Bool) {
    for port in served where connected.contains(port) || lastUsed[port] == nil {
      lastUsed[port] = now
    }
    if complete { lastUsed = lastUsed.filter { served.contains($0.key) } }
  }

  /// How long the port has had no connection; nil for a port never seen.
  func unused(_ port: Int, now: Date) -> TimeInterval? {
    lastUsed[port].map { max(0, now.timeIntervalSince($0)) }
  }

  static func load(_ directory: URL) -> Self {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else {
      return Self()
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode(Self.self, from: data)) ?? Self()
  }

  func save(_ directory: URL) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(self) else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
  }
}

/// A dev server a session started: the agent's direct child whose tree holds a listener, and
/// that tree. Pure.
struct SessionServer: Equatable, Sendable {
  /// The agent's direct child the server's tree starts from (a shell, `npm run dev`…).
  let head: Int32
  /// The head and every member of the session under it, the head first.
  let processIDs: [Int32]
  let ports: [Int]
  /// The process the command line is taken from: the first one down from the head that isn't a
  /// shell, on the way to the listener.
  let commandProcess: Int32
  /// Its arguments, as `ps` printed them, and its working directory.
  let commandLine: String
  let directory: String?
  /// What its processes held (`ps`'s resident size).
  let memoryBytes: UInt64

  /// `cd '<dir>' && <command line>`, or nil without a folder, or with a control character (a
  /// newline in a shell script, an escape) that would act on the terminal it is pasted into.
  var command: String? { EndedServer.command(directory: directory, commandLine: commandLine) }
}

enum UnusedServers {
  static let unusedFor: TimeInterval = 24 * 3_600

  /// The agent itself: its root, native process and first process.
  static func agent(_ thread: AIThread) -> Set<Int32> {
    Set([thread.processIDs.first, thread.rootProcessID, thread.nativeProcessID].compactMap { $0 })
  }

  /// Every listening port of the session that isn't the agent's own (a Codex CLI's loopback
  /// listener), as `UnusedPolicy.serving` counts them.
  static func servedPorts(_ thread: AIThread, listening: [Int32: [Int]]) -> Set<Int> {
    let agent = thread.tool == .codexDesktop ? [] : agent(thread)
    return Set(
      thread.processIDs.filter { !agent.contains($0) }.flatMap { listening[$0] ?? [] })
  }

  /// The session's dev servers, one per direct child of the agent holding a listener in its
  /// tree, in pid order. A helper the agent runs (an MCP server, Q10's `BackgroundJobs.isHelper`)
  /// that listens is not a dev server: it ends with the session.
  static func servers(
    _ thread: AIThread, records: [Int32: RawProcessRecord], listening: [Int32: [Int]],
    directories: [Int32: String]
  ) -> [SessionServer] {
    let agent = agent(thread)
    let members = Set(thread.processIDs)
    var heads: [Int32: [Int32]] = [:]
    for pid in thread.processIDs where !agent.contains(pid) && !(listening[pid] ?? []).isEmpty {
      guard let chain = chain(pid, agent: agent, members: members, records: records) else {
        continue
      }
      heads[chain.last ?? pid, default: []].append(pid)
    }
    return heads.keys.sorted().compactMap { head -> SessionServer? in
      guard let headRecord = records[head], !BackgroundJobs.isHelper(headRecord) else {
        return nil
      }
      let tree = thread.processIDs.filter {
        chain($0, agent: agent, members: members, records: records)?.last == head
      }
      let listeners = (heads[head] ?? []).sorted()
      let ports = Array(Set(listeners.flatMap { listening[$0] ?? [] })).sorted()
      let path = (chain(listeners[0], agent: agent, members: members, records: records) ?? [])
        .reversed()
      let commandProcess =
        path.first {
          guard let record = records[$0] else { return false }
          return !AgentSignals.toolShells.contains(
            AIThreadGrouping.executableName(record.arguments))
        } ?? listeners[0]
      let memory = tree.reduce(UInt64(0)) { $0 + (records[$1]?.residentKilobytes ?? 0) * 1_024 }
      return SessionServer(
        head: head, processIDs: tree, ports: ports, commandProcess: commandProcess,
        commandLine: commandLine(records[commandProcess]?.arguments ?? ""),
        directory: directories[commandProcess] ?? directories[head] ?? thread.directory,
        memoryBytes: memory)
    }
  }

  /// The members from `pid` up to the agent's direct child, `pid` first; nil when the walk
  /// leaves the session or loops before it reaches the agent.
  static func chain(
    _ pid: Int32, agent: Set<Int32>, members: Set<Int32>, records: [Int32: RawProcessRecord]
  ) -> [Int32]? {
    var chain: [Int32] = []
    var current = pid
    var visited: Set<Int32> = []
    while !agent.contains(current) {
      guard members.contains(current), visited.insert(current).inserted,
        let record = records[current]
      else { return nil }
      chain.append(current)
      current = record.parentProcessID
    }
    return chain.isEmpty ? nil : chain
  }

  /// `npm run <script> <flags>` as `ps` shows it lost the `--` npm needs to pass the flags on
  /// (npm sets its title from the parsed arguments): it is put back.
  static func commandLine(_ arguments: String) -> String {
    let tokens = arguments.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard tokens.count > 3, tokens[0] == "npm", ["run", "run-script"].contains(tokens[1]),
      !tokens.contains("--"), tokens[3].hasPrefix("-")
    else { return tokens.joined(separator: " ") }
    return (tokens[..<3] + ["--"] + tokens[3...]).joined(separator: " ")
  }

  /// What a session runs that is neither the agent, a helper nor part of a dev server: Q10's
  /// background jobs, less the servers' trees. Such a session stays protected.
  static func otherJobs(
    _ thread: AIThread, servers: [SessionServer], records: [Int32: RawProcessRecord]
  ) -> [Int32] {
    let server = Set(servers.flatMap(\.processIDs))
    return BackgroundJobs.jobs(thread, records: records).filter { !server.contains($0) }
  }

  struct Scan {
    let now: Date
    let threads: [AIThread]
    let protections: [String: UnusedPolicy.Protection]
    /// The root PIDs Tamebar may act on: the e2e targets. Nil outside e2e mode.
    let scope: Set<Int32>?
    /// Threads with a signal in flight.
    let inFlight: Set<String>
    var records: [Int32: RawProcessRecord] = [:]
    /// Each listening process's ports.
    var listening: [Int32: [Int]] = [:]
    var directories: [Int32: String] = [:]
    /// Each session's terminal's last input: a keystroke resets idle (Q18).
    var lastInput: [String: Date] = [:]
    var clock = ServedPortClock()
    /// The protected ports, never ended.
    var protectedPorts: Set<Int> = ProtectedPorts.proxy
  }

  struct Candidate: Equatable, Sendable {
    let id: String
    let idle: TimeInterval
    let memoryBytes: UInt64
    let servers: [SessionServer]
    /// The longest any served port has been without a connection is at least this.
    let unused: TimeInterval
  }

  /// Why a serving session isn't a Q20 candidate, for a test and the log; nil when it is.
  enum Hold: Equatable, Sendable {
    case notServing, protected, idleUnder24h, portUsed, protectedPort, portless, otherJob,
      notResumable, out
  }

  /// Every session Q20 may end now, with its servers.
  static func candidates(_ scan: Scan) -> [Candidate] {
    var seen: Set<String> = []
    return scan.threads.compactMap { thread in
      guard seen.insert(thread.id).inserted else { return nil }
      if case .success(let candidate) = judge(thread, scan) { return candidate }
      return nil
    }
  }

  static func judge(_ thread: AIThread, _ scan: Scan) -> Result<Candidate, HoldError> {
    func hold(_ reason: Hold) -> Result<Candidate, HoldError> { .failure(HoldError(reason)) }
    guard thread.tool != .codexDesktop, !thread.isPaused, !scan.inFlight.contains(thread.id),
      AutoPauseWiring.inScope(thread, scope: scan.scope)
    else { return hold(.out) }
    // Q20 lifts serving and nothing else: busy, Keep and a kept project still hold.
    if let protection = scan.protections[thread.id], protection != .serving {
      return hold(.protected)
    }
    let ports = servedPorts(thread, listening: scan.listening)
    let servers = servers(
      thread, records: scan.records, listening: scan.listening, directories: scan.directories)
    guard !ports.isEmpty, !servers.isEmpty else { return hold(.notServing) }
    guard AutoEndWiring.resumable(thread) else { return hold(.notResumable) }
    guard let idle = PressureEndWiring.idle(thread, now: scan.now, lastInput: scan.lastInput),
      idle >= unusedFor
    else { return hold(.idleUnder24h) }
    guard ports.isDisjoint(with: scan.protectedPorts) else { return hold(.protectedPort) }
    guard
      !thread.processIDs.contains(where: {
        scan.records[$0].map { ProtectedPorts.isPortless($0.arguments) } ?? false
      })
    else { return hold(.portless) }
    let unused = ports.map { scan.clock.unused($0, now: scan.now) ?? 0 }
    guard let least = unused.min(), least >= unusedFor else { return hold(.portUsed) }
    guard otherJobs(thread, servers: servers, records: scan.records).isEmpty else {
      return hold(.otherJob)
    }
    return .success(
      Candidate(
        id: thread.id, idle: idle, memoryBytes: thread.memoryBytes, servers: servers,
        unused: least))
  }

  struct HoldError: Error, Equatable {
    let hold: Hold
    init(_ hold: Hold) { self.hold = hold }
  }

  /// The sessions the fresh scan still shows with no interaction for 24 h, as the "unused" map
  /// the click-time plan checks (`EndPlan.decide`). Never Codex desktop.
  static func eligible(_ threads: [AIThread], now: Date, lastInput: [String: Date])
    -> [String: UnusedPolicy.Reason]
  {
    var eligible: [String: UnusedPolicy.Reason] = [:]
    for thread in threads where thread.tool != .codexDesktop {
      guard let idle = PressureEndWiring.idle(thread, now: now, lastInput: lastInput),
        idle >= unusedFor
      else { continue }
      eligible[thread.id] = .idle(idle)
    }
    return eligible
  }

  /// The 4 s note: "Ended web-frontend and its server :5180 · 2 GB back". When the session
  /// itself didn't end: "Ended web-frontend's server :5180 · 300 MB back".
  static func note(name: String, ports: [Int], sessionEnded: Bool, freed: UInt64) -> String {
    let list = ports.sorted().map { ":\($0)" }.joined(separator: ", ")
    let server = ports.count == 1 ? "server" : "servers"
    let what =
      sessionEnded ? "Ended \(name) and its \(server) \(list)" : "Ended \(name)'s \(server) \(list)"
    return what + (freed > 0 ? " · \(ByteText.full(freed)) back" : "")
  }
}

/// Picks one session at a time. A session whose end didn't land is left alone for an hour.
struct UnusedServerScheduler: Equatable, Sendable {
  static let retryAfter: TimeInterval = 3_600
  private(set) var pending: Set<String> = []
  private(set) var refused: [String: Date] = [:]

  mutating func step(now: Date, inCall: Bool, candidates: [UnusedServers.Candidate]) -> String? {
    refused = refused.filter { now.timeIntervalSince($0.value) < Self.retryAfter }
    guard !inCall, pending.isEmpty else { return nil }
    let next = candidates.filter { refused[$0.id] == nil }
      .max { a, b in (a.memoryBytes, b.id) < (b.memoryBytes, a.id) }
    guard let next else { return nil }
    pending.insert(next.id)
    return next.id
  }

  mutating func landed(_ id: String, ended: Bool, now: Date) {
    guard pending.remove(id) != nil else { return }
    if !ended { refused[id] = now }
  }
}

/// Runs the scheduler on each scan and ends what it picks through the model, which waits for a
/// fresh scan and re-checks before each signal. It acts only in the instance whose automatic
/// pause acts.
@MainActor
final class UnusedServerController {
  let acts: Bool
  private(set) var scheduler = UnusedServerScheduler()
  private let end: @MainActor (AIThread) async -> UnusedServerOutcome
  private static let log = Logger(subsystem: AppBrand.bundleIdentifier, category: "unusedserver")

  init(acts: Bool, end: @escaping @MainActor (AIThread) async -> UnusedServerOutcome) {
    self.acts = acts
    self.end = end
  }

  func run(_ scan: UnusedServers.Scan, inCall: Bool, busy: Bool) -> Task<
    UnusedServerOutcome, Never
  >? {
    guard acts else { return nil }
    let candidates = busy ? [] : UnusedServers.candidates(scan)
    guard let id = scheduler.step(now: scan.now, inCall: inCall, candidates: candidates),
      let thread = scan.threads.first(where: { $0.id == id })
    else { return nil }
    let end = end
    return Task { [weak self] in
      let outcome = await end(thread)
      self?.scheduler.landed(id, ended: outcome.sessionEnded, now: .now)
      if !outcome.sessionEnded {
        Self.log.notice(
          "Q20 didn't end \(thread.displayName, privacy: .public): \(outcome.servers.count) servers ended, changed or still running"
        )
      }
      return outcome
    }
  }
}

struct UnusedServerOutcome: Equatable, Sendable {
  /// The servers that were ended, with their entries.
  var servers: [EndedServer] = []
  var sessionEnded = false
  var name = ""
  var freed: UInt64 = 0
}

/// A dev server Tamebar ended with its session (Q20), for the Stopped list: Resume opens Terminal
/// on `cd '<dir>' && <command line>`.
struct EndedServer: Codable, Equatable, Identifiable, Sendable {
  let id: String
  /// The session's folder name, as the note names it.
  let session: String
  var sessionID: String?
  let ports: [Int]
  let directory: String?
  let commandLine: String
  let endedAt: Date
  let memoryBytes: UInt64
  /// How long its ports had been without a connection, and the session without interaction.
  var unusedFor: TimeInterval = 0

  var command: String? { Self.command(directory: directory, commandLine: commandLine) }

  /// "web-frontend :5180".
  var title: String { ([session] + ports.map { ":\($0)" }).joined(separator: " ") }

  static func command(directory: String?, commandLine: String) -> String? {
    let line = commandLine.trimmingCharacters(in: .whitespaces)
    guard let directory, !line.isEmpty,
      !(directory + line).unicodeScalars.contains(where: {
        $0.properties.generalCategory == .control
      })
    else { return nil }
    return "cd '" + directory.replacingOccurrences(of: "'", with: "'\\''") + "' && " + line
  }
}

/// The servers Q20 ended: 30 days, newest first, in UserDefaults `servers.ended.v1`. One leaves
/// once something listens on one of its ports again from its folder.
struct EndedServerLog: Equatable, Sendable {
  static let defaultsKey = "servers.ended.v1"
  static let retention = EndedSessionLog.retention
  static let limit = 100
  private(set) var servers: [EndedServer] = []

  mutating func record(_ server: EndedServer, now: Date) {
    servers.removeAll { $0.id == server.id }
    servers.insert(server, at: 0)
    prune(now: now)
    if servers.count > Self.limit { servers.removeLast(servers.count - Self.limit) }
  }

  mutating func prune(now: Date) {
    servers.removeAll { now.timeIntervalSince($0.endedAt) > Self.retention }
  }

  /// Drops the servers running again: a listener on one of their ports whose folder is theirs,
  /// or inside or above it. True when one went.
  @discardableResult
  mutating func dropBack(listeners: [(port: Int, directory: String?)]) -> Bool {
    let before = servers.count
    servers.removeAll { server in
      listeners.contains { listener in
        guard server.ports.contains(listener.port) else { return false }
        guard let mine = server.directory, let theirs = listener.directory else { return true }
        return mine == theirs || mine.hasPrefix(theirs + "/") || theirs.hasPrefix(mine + "/")
      }
    }
    return servers.count != before
  }

  static func load(_ defaults: UserDefaults = .standard, now: Date = .now) -> Self {
    var log = Self(servers: SavedSettings.list(.init(key: defaultsKey, defaults: defaults)) ?? [])
    log.prune(now: now)
    return log
  }

  func save(_ defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(servers) {
      defaults.set(data, forKey: Self.defaultsKey)
    }
  }
}

/// `lsof -nP -iTCP -sTCP:ESTABLISHED -Fpn`: the local port of each connection
/// (`n127.0.0.1:5180->127.0.0.1:61234`, `n[::1]:5180->[::1]:61234`). A server's accepted
/// connection has its listening port as the local one. Tamebar's own connections (its port
/// probes) don't count: a connection whose peer is one of `selfID`'s sockets is left out. Pure.
enum ConnectedPorts {
  static func local(_ output: String, selfID: Int32? = nil) -> Set<Int> {
    var connections: [(pid: Int32?, local: Int, remote: Int)] = []
    var pid: Int32?
    for line in output.split(separator: "\n") {
      if line.first == "p" {
        pid = Int32(line.dropFirst())
        continue
      }
      guard line.first == "n", let arrow = line.range(of: "->"),
        let local = port(line[line.index(after: line.startIndex)..<arrow.lowerBound]),
        let remote = port(line[arrow.upperBound...])
      else { continue }
      connections.append((pid, local, remote))
    }
    let own = Set(connections.filter { $0.pid != nil && $0.pid == selfID }.map(\.local))
    return Set(
      connections.filter { $0.pid == nil || $0.pid != selfID }
        .filter { !own.contains($0.remote) }.map(\.local))
  }

  private static func port(_ address: Substring) -> Int? {
    guard let colon = address.lastIndex(of: ":") else { return nil }
    return Int(address[address.index(after: colon)...])
  }
}
