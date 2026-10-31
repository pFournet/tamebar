import Darwin
import Foundation

/// Q19: new AI sessions wait at start while the Mac is really struggling. A `SessionStart` hook
/// (Claude Code and Codex) runs `tamebar wait`: it returns at once unless the running Tamebar's
/// `strain.json` says the Mac is struggling, and only for a fresh start (`source` "startup", never
/// a resume, clear, compact or fork). Otherwise it registers itself in `waiting/` and blocks,
/// event-driven, until Tamebar writes its release file (the strain cleared, or Start now), Tamebar
/// or the agent exits, or 10 minutes pass. Then it removes its registration and exits 0, printing
/// nothing, so nothing is ever injected into the session.
///
/// The files, in Tamebar's data folder:
/// - `waiting/<pid>.json`: one waiting `tamebar wait` (`Registration`), written by it;
/// - `waiting/<pid>.go`: its release (`Release`), written by Tamebar, its card or `tamebar start`.
enum StartWait {
  static let folderName = "waiting"
  /// The longest a session waits; the hook's own timeout (660 s) is set above it.
  static let maximumWait: TimeInterval = 600
  /// Once the strain clears, waiting sessions start one per minute, oldest first.
  static let releaseSpacing: TimeInterval = 60

  // MARK: The hook's input

  /// What `tamebar wait` reads of the hook's JSON on stdin: Claude Code's and Codex's
  /// `SessionStart` share these fields (Codex 0.165's `session-start.command.input`: `source` is
  /// `startup`, `resume`, `clear`, `compact` or `fork`).
  struct HookInput: Equatable, Sendable {
    var event: String?
    var source: String?
    var sessionID: String?
    var cwd: String?
    var transcriptPath: String?

    /// Nil without a JSON object.
    static func parse(_ data: Data?) -> HookInput? {
      guard let data, !data.isEmpty,
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      return HookInput(
        event: object["hook_event_name"] as? String, source: object["source"] as? String,
        sessionID: object["session_id"] as? String, cwd: object["cwd"] as? String,
        transcriptPath: object["transcript_path"] as? String)
    }

    /// Only a fresh session waits. No input (run by hand) or no `source` counts as one.
    var isFreshStart: Bool { source == nil || source == "startup" }
  }

  enum Decision: Equatable, Sendable {
    case wait
    /// A resume, clear, compact or fork: the session isn't new.
    case notNew
    /// No Tamebar wrote `strain.json`, or the one that did no longer runs.
    case noTamebar
    case notStruggling
  }

  /// Whether `tamebar wait` waits. Pure.
  static func decide(input: HookInput?, strain: StrainFile?, writerRuns: Bool) -> Decision {
    if let input, !input.isFreshStart { return .notNew }
    guard let strain, writerRuns else { return .noTamebar }
    return strain.struggling ? .wait : .notStruggling
  }

  // MARK: Registration and release

  /// One waiting `tamebar wait`.
  struct Registration: Codable, Equatable, Sendable, Identifiable {
    /// The `tamebar wait` process, with its start time so a reused pid never matches.
    let waitPID: Int32
    var waitStart: Double?
    /// The agent it holds: the nearest `claude` or `codex` up its parents.
    var agentPID: Int32?
    /// `claude` or `codex`; nil when neither was found.
    var tool: String?
    /// The session's folder (the hook's `cwd`).
    var directory: String?
    /// The folder's name, as `tamebar sessions` names a session's project.
    let project: String
    var sessionID: String?
    let started: Date

    var id: Int32 { waitPID }

    /// "Claude", "Codex", or "Agent".
    var toolName: String {
      switch tool {
      case "claude": "Claude"
      case "codex": "Codex"
      default: "Agent"
      }
    }

    /// "dashboard-app · Claude".
    var label: String { "\(project) · \(toolName)" }
  }

  /// Why a waiting session was released.
  struct Release: Codable, Equatable, Sendable {
    /// `strain_cleared`, `start_now` (the card) or `tamebar_start`.
    let by: String
    let at: Date
  }

  static func folder(_ directory: URL) -> URL {
    directory.appendingPathComponent(folderName, isDirectory: true)
  }

  static func registrationURL(_ directory: URL, _ pid: Int32) -> URL {
    folder(directory).appendingPathComponent("\(pid).json")
  }

  static func releaseURL(_ directory: URL, _ pid: Int32) -> URL {
    folder(directory).appendingPathComponent("\(pid).go")
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  /// Writes the registration, atomically, in a folder only this user reads.
  static func register(_ registration: Registration, directory: URL) throws {
    let folder = folder(directory)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try encoder.encode(registration).write(
      to: registrationURL(directory, registration.waitPID), options: .atomic)
  }

  /// Every registration that reads, oldest first.
  static func list(_ directory: URL) -> [Registration] {
    let folder = folder(directory)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.compactMap { name in
      guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
        data.count < 65_536
      else { return nil }
      return try? decoder.decode(Registration.self, from: data)
    }.sorted { ($0.started, $0.waitPID) < ($1.started, $1.waitPID) }
  }

  static func isReleased(_ pid: Int32, directory: URL) -> Bool {
    FileManager.default.fileExists(atPath: releaseURL(directory, pid).path)
  }

  /// Writes the release file the waiting process watches for. False when it couldn't be written.
  @discardableResult
  static func release(_ pid: Int32, by: String, at date: Date, directory: URL) -> Bool {
    guard let data = try? encoder.encode(Release(by: by, at: date)) else { return false }
    return (try? data.write(to: releaseURL(directory, pid), options: .atomic)) != nil
  }

  /// Removes a registration and its release.
  static func remove(_ pid: Int32, directory: URL) {
    try? FileManager.default.removeItem(at: registrationURL(directory, pid))
    try? FileManager.default.removeItem(at: releaseURL(directory, pid))
  }

  /// The registration's process is still that `tamebar wait`.
  static func isLive(_ registration: Registration, startTime: (Int32) -> Double?) -> Bool {
    guard registration.waitPID > 1, let started = startTime(registration.waitPID) else {
      return false
    }
    guard let expected = registration.waitStart else { return true }
    return abs(started - expected) < 0.001
  }

  /// The live registrations, oldest first; the files of the others (a `tamebar wait` killed
  /// before it could clean up) are removed, and so are release files left without one.
  static func prune(_ directory: URL, startTime: (Int32) -> Double?) -> [Registration] {
    let all = list(directory)
    var live: [Registration] = []
    for registration in all {
      if isLive(registration, startTime: startTime) {
        live.append(registration)
      } else {
        remove(registration.waitPID, directory: directory)
      }
    }
    let kept = Set(live.map(\.waitPID))
    let folder = folder(directory)
    for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    where name.hasSuffix(".go") {
      if let pid = Int32(name.dropLast(3)), !kept.contains(pid) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
      }
    }
    return live
  }

  // MARK: Release order

  /// Once the strain clears, the oldest waiting session is released, then one more each
  /// `releaseSpacing`, so ten sessions don't all start at once; while the strain holds, nothing
  /// is. `last` is when the clock last released one. Pure.
  static func due(
    _ waiting: [Registration], released: Set<Int32>, struggling: Bool, last: Date?, now: Date
  ) -> Registration? {
    guard !struggling else { return nil }
    if let last, now.timeIntervalSince(last) < releaseSpacing, now >= last { return nil }
    return waiting.first { !released.contains($0.waitPID) }
  }

  // MARK: `tamebar start`

  /// The waiting sessions `tamebar start <target>` starts: every one for `all`, else those whose
  /// project is `target` (the folder's name, any case).
  static func matching(_ target: String, in waiting: [Registration]) -> [Registration] {
    let wanted = target.trimmingCharacters(in: .whitespaces)
    if wanted.lowercased() == "all" { return waiting }
    return waiting.filter { $0.project.caseInsensitiveCompare(wanted) == .orderedSame }
  }

  // MARK: Words

  /// The session's project: its folder's name, else "session".
  static func project(_ directory: String?) -> String {
    guard let directory, !directory.isEmpty, directory != "/" else { return "session" }
    return URL(fileURLWithPath: directory).lastPathComponent
  }

  /// `claude` or `codex`, from the agent found up the parents, else from the transcript's path.
  static func tool(agent: String?, transcriptPath: String?) -> String? {
    if let agent, ["claude", "codex"].contains(agent) { return agent }
    if let path = transcriptPath {
      if path.contains("/.codex/") { return "codex" }
      if path.contains("/.claude/") { return "claude" }
    }
    return nil
  }

  /// How long it has waited: "40s", "1m", "12m", "1h 5m".
  static func waited(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    guard total >= 60 else { return "\(total)s" }
    let minutes = total / 60
    guard minutes >= 60 else { return "\(minutes)m" }
    return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
  }
}

// MARK: - The waiting process

/// `tamebar wait` on this Mac: the hook's stdin, the agent up the parents, and the wait itself
/// on kqueue (dispatch sources), never a sleep loop.
enum StartWaitLive {
  enum Outcome: Equatable, Sendable {
    case released
    /// Tamebar or the agent exited.
    case exited(Int32)
    case timedOut
    case signalled
    /// The waiting folder went away.
    case folderGone
  }

  /// Runs `tamebar wait`; always 0, so a hook never fails a session.
  static func run(directory: URL, input: Data?, now: Date = .now) -> Int32 {
    let hook = StartWait.HookInput.parse(input)
    let strain = StrainFile.read(directory)
    let runs = strain?.writerRuns(startTime: E2EMode.startTime) ?? false
    guard StartWait.decide(input: hook, strain: strain, writerRuns: runs) == .wait, let strain
    else { return 0 }
    let pid = getpid()
    let agent = agentUpTheParents()
    let registration = StartWait.Registration(
      waitPID: pid, waitStart: E2EMode.startTime(pid), agentPID: agent?.pid,
      tool: StartWait.tool(agent: agent?.name, transcriptPath: hook?.transcriptPath),
      directory: hook?.cwd ?? FileManager.default.currentDirectoryPath,
      project: StartWait.project(hook?.cwd ?? FileManager.default.currentDirectoryPath),
      sessionID: hook?.sessionID, started: now)
    guard (try? StartWait.register(registration, directory: directory)) != nil else { return 0 }
    defer { StartWait.remove(pid, directory: directory) }
    _ = block(
      folder: StartWait.folder(directory), release: StartWait.releaseURL(directory, pid),
      watch: [strain.pid] + (agent.map { [$0.pid] } ?? []), timeout: StartWait.maximumWait)
    return 0
  }

  /// The hook's JSON on stdin, when stdin isn't a terminal: read until it parses, ends, or 2 s
  /// pass, so a stdin left open never holds the session.
  static func readHookInput() -> Data? {
    guard isatty(STDIN_FILENO) == 0 else { return nil }
    var data = Data()
    let deadline = Date.now.addingTimeInterval(2)
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while data.count < 1_048_576 {
      let left = deadline.timeIntervalSinceNow
      guard left > 0 else { break }
      var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
      let ready = poll(&descriptor, 1, Int32(left * 1000))
      if ready < 0, errno == EINTR { continue }
      guard ready > 0 else { break }
      let count = read(STDIN_FILENO, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { break }
      data.append(contentsOf: buffer[0..<count])
      if (try? JSONSerialization.jsonObject(with: data)) != nil { break }
    }
    return data.isEmpty ? nil : data
  }

  /// The nearest `claude` or `codex` up this process's parents (argv[0]'s name), at most 12 up,
  /// and never past it: a `claude -p` run from another session's tool must not name that one.
  static func agentUpTheParents() -> (pid: Int32, name: String)? {
    var pid = getppid()
    for _ in 0..<12 {
      guard pid > 1 else { return nil }
      if let first = AIThreadNames.processArguments(pid).first {
        let name = URL(fileURLWithPath: first).lastPathComponent
        if name == "claude" || name == "codex" { return (pid, name) }
      }
      guard let parent = parentPID(pid), parent != pid else { return nil }
      pid = parent
    }
    return nil
  }

  static func parentPID(_ pid: Int32) -> Int32? {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.stride
    let read = withUnsafeMutablePointer(to: &info) {
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(size))
    }
    return read == size ? Int32(info.pbi_ppid) : nil
  }

  /// Blocks until `release` exists, a process in `watch` exits, the folder goes away, SIGTERM,
  /// SIGINT or SIGHUP arrives (with `signals`, which ignores their default action), or `timeout`
  /// passes. Dispatch sources (kqueue): the process sleeps
  /// in between.
  static func block(
    folder: URL, release: URL, watch: [Int32], timeout: TimeInterval, signals: Bool = true
  ) -> Outcome {
    let queue = DispatchQueue(label: "com.tamebar.wait")
    let done = DispatchSemaphore(value: 0)
    let box = OutcomeBox()
    var sources: [any DispatchSourceProtocol] = []
    @Sendable func finish(_ outcome: Outcome) {
      if box.set(outcome) { done.signal() }
    }
    let descriptor = open(folder.path, O_EVTONLY)
    if descriptor >= 0 {
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: queue)
      source.setEventHandler {
        if FileManager.default.fileExists(atPath: release.path) {
          finish(.released)
        } else if !FileManager.default.fileExists(atPath: folder.path) {
          finish(.folderGone)
        }
      }
      source.setCancelHandler { close(descriptor) }
      sources.append(source)
    }
    for pid in Set(watch) where pid > 1 {
      let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
      source.setEventHandler { finish(.exited(pid)) }
      sources.append(source)
    }
    for number in signals ? [SIGTERM, SIGINT, SIGHUP] : [] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
      source.setEventHandler { finish(.signalled) }
      sources.append(source)
    }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler { finish(.timedOut) }
    sources.append(timer)
    for source in sources { source.resume() }
    // What happened before the sources were armed: a release already written, a process gone.
    queue.async {
      if FileManager.default.fileExists(atPath: release.path) { finish(.released) }
      for pid in Set(watch) where pid > 1 && kill(pid, 0) != 0 && errno == ESRCH {
        finish(.exited(pid))
      }
      if descriptor < 0 { finish(.folderGone) }
    }
    done.wait()
    for source in sources { source.cancel() }
    return box.value ?? .timedOut
  }

  private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Outcome?

    var value: Outcome? { lock.withLock { outcome } }

    /// True for the first outcome only.
    func set(_ next: Outcome) -> Bool {
      lock.withLock {
        guard outcome == nil else { return false }
        outcome = next
        return true
      }
    }
  }
}
