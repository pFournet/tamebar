import Darwin
import Foundation

/// Test-only mode. It needs `--e2e <dir>`, `TAMEBAR_E2E=1` AND a bundle id ending `.e2e`.
/// In this mode Tamebar acts only on processes listed in `<dir>/targets.json` and their
/// descendants; see `allowsSignal(to:mode:live:)`.
struct E2EMode: Equatable, Sendable {
  let directory: URL

  struct Launch {
    let arguments: [String]
    let environment: [String: String]
    let bundleID: String?
  }

  /// All three locks, or nil. The Emergency helper's id ends `.e2e.Emergency`, so it never
  /// resolves; a relative `--e2e` path never does either, so the folder can't depend on the cwd.
  static func resolve(_ launch: Launch) -> E2EMode? {
    guard launch.environment["TAMEBAR_E2E"] == "1",
      launch.bundleID?.hasSuffix(".e2e") == true,
      let index = launch.arguments.firstIndex(of: "--e2e"),
      launch.arguments.indices.contains(index + 1),
      launch.arguments[index + 1].hasPrefix("/")
    else { return nil }
    return E2EMode(directory: URL(fileURLWithPath: launch.arguments[index + 1], isDirectory: true))
  }

  static let current = resolve(
    .init(
      arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment,
      bundleID: Bundle.main.bundleIdentifier))

  /// The home the fake agents write their session files under, in place of the real one.
  var agentHome: URL { directory.appendingPathComponent("home", isDirectory: true) }

  /// A process the test started, pinned by its start time so a reused PID never matches.
  struct Target: Codable, Equatable, Hashable, Sendable {
    let pid: Int32
    /// Seconds since 1970, as `DevProcessIdentity` reads it: `startSeconds + µs / 1e6`.
    let start: Double
  }

  /// `<dir>/targets.json` as written: `[{"pid": N, "start": seconds}]`. Anything else is none.
  func declaredTargets() -> [Target] {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("targets.json")),
      let targets = try? JSONDecoder().decode([Target].self, from: data)
    else { return [] }
    return targets
  }

  /// The live process table, as the allowlist reads it.
  struct Live {
    let parents: [Int32: Int32]
    /// The start time of a live, non-exited process, in `Target.start`'s measure.
    let start: (Int32) -> Double?
    let selfID: Int32

    static func read() -> Live {
      Live(parents: LiveProcessTree.read().parents, start: E2EMode.startTime, selfID: getpid())
    }
  }

  static func startTime(_ processID: Int32) -> Double? {
    guard let process = RecoveryProcess.read(processID), !process.exited else {
      return nil
    }
    return Double(process.startSeconds) + Double(process.startMicroseconds) / 1_000_000
  }

  /// The target PIDs that are still the processes the test started: the live start time matches
  /// within a millisecond. Tamebar itself and its ancestors (the test runner) never count.
  static func validTargets(_ declared: [Target], live: Live) -> Set<Int32> {
    var protected: Set<Int32> = []
    var current: Int32? = live.selfID
    while let pid = current, protected.insert(pid).inserted { current = live.parents[pid] }
    return Set(
      declared.compactMap { target in
        guard target.pid > 1, !protected.contains(target.pid),
          let started = live.start(target.pid), abs(started - target.start) < 0.001
        else { return nil }
        return target.pid
      })
  }

  /// The root PIDs Tamebar may act on now. Missing, invalid or stale targets mean none.
  func targets(_ live: Live = .read()) -> Set<Int32> {
    Self.validTargets(declaredTargets(), live: live)
  }

  struct Control: Codable, Equatable, Sendable {
    var pressure: MemoryRisk?
    var meeting: Bool?
    var away: Bool?
    /// True forces the CPU to be the bottleneck at warning, unless `pressure` forces memory.
    var cpu: Bool?
    /// The bundle id in front, in place of the real one; "" for none (Q11).
    var frontmost: String?
    /// Bundle ids the mic/camera probe reports free; every other app counts as in use (Q11).
    var micCameraFree: [String]?
    /// macOS's thermal state, in place of the real one (Q13): "nominal", "fair", "serious" or
    /// "critical".
    var thermal: ThermalStatus?
    /// The Mac struggling (Q19), on or off at once, in place of the strain signals.
    var strain: Bool?
    /// Seconds added to Q20's clock, so a test sees a day pass in a minute (Q20 only: its port
    /// clock and the idle age it judges).
    var clockAdvance: Double?

    init(
      pressure: MemoryRisk? = nil, meeting: Bool? = nil, away: Bool? = nil, cpu: Bool? = nil,
      frontmost: String? = nil, micCameraFree: [String]? = nil, thermal: ThermalStatus? = nil,
      strain: Bool? = nil, clockAdvance: Double? = nil
    ) {
      self.pressure = pressure
      self.meeting = meeting
      self.away = away
      self.cpu = cpu
      self.frontmost = frontmost
      self.micCameraFree = micCameraFree
      self.thermal = thermal
      self.strain = strain
      self.clockAdvance = clockAdvance
    }

    /// Field by field, so one bad value never drops the others.
    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      pressure = try? values.decodeIfPresent(MemoryRisk.self, forKey: .pressure)
      meeting = try? values.decodeIfPresent(Bool.self, forKey: .meeting)
      away = try? values.decodeIfPresent(Bool.self, forKey: .away)
      cpu = try? values.decodeIfPresent(Bool.self, forKey: .cpu)
      frontmost = try? values.decodeIfPresent(String.self, forKey: .frontmost)
      micCameraFree = try? values.decodeIfPresent([String].self, forKey: .micCameraFree)
      thermal = try? values.decodeIfPresent(ThermalStatus.self, forKey: .thermal)
      strain = try? values.decodeIfPresent(Bool.self, forKey: .strain)
      clockAdvance = try? values.decodeIfPresent(Double.self, forKey: .clockAdvance)
    }
  }

  func control() -> Control {
    (try? Data(contentsOf: directory.appendingPathComponent("control.json")))
      .flatMap { try? JSONDecoder().decode(Control.self, from: $0) } ?? Control()
  }

  /// One-shot commands the test drops in `<dir>/commands/`, consumed in name order. Dotfiles
  /// (the rig's temp files before their rename) and anything but a regular file are left alone.
  func takeCommands() -> [String] {
    let folder = directory.appendingPathComponent("commands")
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
      .filter { !$0.hasPrefix(".") }.sorted()
    return names.compactMap { name in
      let url = folder.appendingPathComponent(name)
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
      else { return nil }
      defer { try? FileManager.default.removeItem(at: url) }
      return try? String(contentsOf: url, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  func write<T: Encodable>(_ state: T) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(state) else { return }
    try? data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
  }

  // MARK: Launch reset

  struct Reset {
    let bundleID: String?
    let dataDirectory: URL
    /// Removes the persistent defaults domain of this id: `UserDefaults.standard` at launch, a
    /// recorder in tests, so a test never makes cfprefsd write a plist it can't take back.
    let clearDomain: (String) -> Void
  }

  /// Clears what an earlier run left: this build's own defaults domain and its `Tamebar-e2e`
  /// data folder. Deletes nothing unless the id ends `.e2e` and the folder is exactly
  /// `Tamebar-e2e` and not a symbolic link. Returns whether it reset.
  @discardableResult
  static func reset(_ input: Reset) -> Bool {
    // `isDirectory: false` keeps a trailing slash off, so the link itself is checked, not its target.
    let folder = URL(fileURLWithPath: input.dataDirectory.path, isDirectory: false)
    guard let id = input.bundleID, id.hasSuffix(".e2e"),
      folder.lastPathComponent == "Tamebar-e2e",
      // A missing folder reads as nil: the defaults are still cleared, and there is nothing to empty.
      (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
    else { return false }
    input.clearDomain(id)
    let manager = FileManager.default
    for item
      in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
      ?? []
    {
      try? manager.removeItem(at: item)
    }
    return true
  }

  /// At launch, in e2e mode only: the triple lock has passed, so `current` is set.
  static func resetAtLaunch() {
    guard current != nil else { return }
    reset(
      .init(
        bundleID: Bundle.main.bundleIdentifier, dataDirectory: AppData.directory,
        clearDomain: { UserDefaults.standard.removePersistentDomain(forName: $0) }))
  }

  // MARK: Allowlist

  struct SignalCheck {
    let processID: Int32
    let targets: Set<Int32>
    /// Parent PID by PID, from a live read of the process table.
    let parents: [Int32: Int32]
  }

  /// True when the process is a target or descends from one. A process whose chain of parents
  /// reaches launchd, or loops, without meeting a target is refused.
  static func allows(_ check: SignalCheck) -> Bool {
    var current: Int32? = check.processID
    var visited: Set<Int32> = []
    while let pid = current, pid > 1, visited.insert(pid).inserted {
      if check.targets.contains(pid) { return true }
      current = check.parents[pid]
    }
    return false
  }

  /// Every process seen inside a live target's tree, by pid and start time, with the target it
  /// was seen under. Quit signals the root first; once the root exits, its children belong to
  /// launchd and leave the tree, yet they are the processes the test started and must still be
  /// signalled in that Quit. A pin counts only while its target is still declared, so a stale or
  /// emptied `targets.json` still refuses everything. E2E mode only.
  final class Pins: @unchecked Sendable {
    static let shared = Pins()
    private struct Pin {
      let start: Double
      let target: Target
    }
    private let lock = NSLock()
    private var pins: [Int32: Pin] = [:]

    /// Pins every live process in `target`'s tree, and forgets pins whose process is gone.
    func pin(_ target: Target, live: Live) {
      let fresh = LiveProcessTree(parents: live.parents).descendants([target.pid])
        .compactMap { pid in live.start(pid).map { (pid, Pin(start: $0, target: target)) } }
      lock.withLock {
        pins = pins.filter { live.parents[$0.key] != nil }
        for (pid, pin) in fresh { pins[pid] = pin }
      }
    }

    /// The process is the one pinned (same pid, start time within a millisecond), under a target
    /// that is still declared.
    func contains(_ pid: Int32, live: Live, declared: [Target]) -> Bool {
      guard let start = live.start(pid), let pin = lock.withLock({ pins[pid] }) else {
        return false
      }
      return abs(pin.start - start) < 0.001 && declared.contains(pin.target)
    }
  }

  /// The one check every signal, priority change or app quit Tamebar sends passes in e2e mode:
  /// outside a live, start-time-pinned target's tree, it is refused, unless the process was seen
  /// inside one (`Pins`), is still that process, and that target is still declared. Without a
  /// mode, everything is allowed but another e2e run's targets (`otherRuns`).
  static func allowsSignal(
    to processID: Int32, mode: E2EMode? = current, live: () -> Live = { .read() },
    pins: Pins = .shared, otherRuns: [URL] = OtherRuns.shared.directories
  ) -> Bool {
    guard let mode else { return !inOtherRun(processID, runs: otherRuns, live: live) }
    let live = live()
    let declared = mode.declaredTargets()
    let targets = validTargets(declared, live: live)
    // Pin each live target's tree now, while every parent still runs.
    for target in declared where targets.contains(target.pid) { pins.pin(target, live: live) }
    if !targets.isEmpty,
      allows(.init(processID: processID, targets: targets, parents: live.parents))
    {
      return true
    }
    return processID > 1 && processID != live.selfID
      && pins.contains(processID, live: live, declared: declared)
  }

  // MARK: Another Tamebar's e2e run

  /// The folders of the e2e builds running as `userID`, from a scan's records: a `Tamebar`
  /// binary with `--e2e /<folder>` among its arguments. The installed Tamebar leaves their
  /// targets alone: under the Mac's real CPU strain it would otherwise slow the run's heavy
  /// terminal job, which the e2e build then can't take (one already in background is someone
  /// else's), and the run fails (2026-10-29). Pure.
  static func runs(in records: [RawProcessRecord], userID: Int) -> [URL] {
    let folders = records.compactMap { record -> String? in
      guard record.userID == userID,
        AIThreadGrouping.executableName(record.arguments) == "Tamebar"
      else { return nil }
      let tokens = record.arguments.split(separator: " ").map(String.init)
      guard let index = tokens.firstIndex(of: "--e2e"), tokens.indices.contains(index + 1),
        tokens[index + 1].hasPrefix("/")
      else { return nil }
      return tokens[index + 1]
    }
    return Set(folders).sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
  }

  /// True when the process is a live target of one of these e2e runs, or descends from one.
  static func inOtherRun(_ processID: Int32, runs: [URL], live: () -> Live) -> Bool {
    guard !runs.isEmpty else { return false }
    let live = live()
    return runs.contains { folder in
      let targets = validTargets(E2EMode(directory: folder).declaredTargets(), live: live)
      return !targets.isEmpty
        && allows(.init(processID: processID, targets: targets, parents: live.parents))
    }
  }

  /// The other e2e runs the latest scan found, outside e2e mode.
  final class OtherRuns: @unchecked Sendable {
    static let shared = OtherRuns()
    private let lock = NSLock()
    private var folders: [URL] = []

    var directories: [URL] { lock.withLock { folders } }

    func update(_ directories: [URL]) { lock.withLock { folders = directories } }
  }
}

/// A one-shot command from `<dir>/commands/`. Unknown text is ignored.
enum E2ECommand: Equatable, Sendable {
  case endUnused
  case keep(Int32)
  /// The island's Resume now (N3), as the header's button runs it.
  case resumeNow
  /// The card's Start now on the sessions of this project waiting for memory (Q19).
  case startNow(String)

  init?(_ text: String) {
    if text == "endUnused" {
      self = .endUnused
    } else if text == "resumeNow" {
      self = .resumeNow
    } else if text.hasPrefix("startNow:"), text.count > "startNow:".count {
      self = .startNow(String(text.dropFirst("startNow:".count)))
    } else if text.hasPrefix("keep:"), let pid = Int32(text.dropFirst("keep:".count)), pid > 1 {
      self = .keep(pid)
    } else {
      return nil
    }
  }

  /// The root PID of a thread: the agent process its subtree starts from.
  static func root(_ thread: AIThread) -> Int32? { thread.rootProcessID }

  /// Unused threads rooted at a target: what `endUnused` may end.
  static func endable(
    _ threads: [AIThread], unused: [String: UnusedPolicy.Reason], targets: Set<Int32>
  ) -> [AIThread] {
    threads.filter { thread in
      unused[thread.id] != nil && root(thread).map(targets.contains) == true
    }
  }

  /// The thread rooted at `pid`, only when `pid` is a target.
  static func thread(rootedAt pid: Int32, in threads: [AIThread], targets: Set<Int32>)
    -> AIThread?
  {
    guard targets.contains(pid) else { return nil }
    return threads.first { root($0) == pid }
  }
}

/// What the e2e build reports after each scan, to `<dir>/state.json`.
struct E2EState: Encodable, Equatable {
  struct Thread: Encodable, Equatable {
    let id: String
    let pid: Int32
    let status: String?
    let unused: String?
    let protection: String?
    let pausedBy: String?
    let paused: Bool
  }

  let at: Date
  let risk: Int
  let meeting: Bool
  /// Only threads whose root PID is a target.
  let threads: [Thread]
  /// `IslandState.debugName`, resolved from the model whether or not a panel shows (Task 9.4).
  /// It is the menu bar's state, so pressure stays "pressure" while it lasts; the notch shows it
  /// only as a 4 s flash.
  let island: String
  /// The menu-bar item's text beside the icon (N7), "" for the icon alone.
  var menuBar = ""
  /// Resume commands of the visible Ended sessions.
  let ended: [String]
  /// The largest gap, in seconds, between two auto-pause ticks since launch. App Nap or a
  /// stalled main thread shows up here.
  var maxTickGap: Double = 0
  /// The thread IDs the latest tick could pause.
  var candidates: [String] = []
  /// The brief line of Tamebar's latest automatic action.
  var note: String?
  /// The PIDs Tamebar moved to background on its own.
  var slowed: [Int32] = []
  /// Dev-server projects wholly inside the targets' trees.
  var projects: [Project] = []
  /// Bundle ids in the ledger of apps Tamebar quit under memory pressure (Q11).
  var quitApps: [String] = []
  /// Bundle ids of the apps Tamebar slowed in the background (Q17.1).
  var slowedApps: [String] = []
  /// What Q17.1 saw of each app on the latest scan, for a failing test's state:
  /// "app:Name 200% pids=2 front=false mic=false out=false".
  var appsSeen: [String] = []
  /// Tamebar is acting on heat (Q13).
  var heat = false
  /// Presence as the latest scan read it (Q5).
  var away = false
  /// "Unused AI sessions": "ask", or "auto:<days>" (Q10).
  var autoEnd = "ask"
  /// What the scan saw before the target filter, to tell a scan that missed the fakes from
  /// targets that didn't validate: every thread's root PID, the valid targets, and whether the
  /// scan read every process.
  var scanRoots: [Int32] = []
  var validTargets: [Int32] = []
  var scanComplete = true
  /// What the user resumed this episode (the planner's `userResumed`), sorted. Empty once the
  /// episode ends, so a test can wait for a fresh episode.
  var userResumed: [String] = []
  /// The Mac struggling (Q19), and the projects waiting for memory, oldest first.
  var strain = false
  var waiting: [String] = []
  /// The commands of the dev servers Q20 ended, and each served port's seconds without a
  /// connection by Q20's clock.
  var endedServers: [String] = []
  var servedPorts: [String: Int] = [:]

  struct Project: Encodable, Equatable {
    let directory: String
    let paused: Bool
    /// Why Tamebar paused it ("pressure", "meeting"), while that pause holds.
    let pausedBy: String?
  }

  struct Input {
    let at: Date
    let risk: MemoryRisk
    let meeting: Bool
    let threads: [AIThread]
    let unused: [String: UnusedPolicy.Reason]
    let protections: [String: UnusedPolicy.Protection]
    let ended: [EndedSession]
    let targets: Set<Int32>
    /// Why Tamebar paused a thread ("pressure", "meeting"), by thread ID.
    var pausedBy: [String: String] = [:]
    var maxTickGap: Double = 0
    var candidates: [String] = []
    var note: String?
    var slowed: [Int32] = []
    var userResumed: [String] = []
    var projects: [Project] = []
    var quitApps: [String] = []
    var slowedApps: [String] = []
    var appsSeen: [String] = []
    var heat = false
    var away = false
    var autoEnd = AutoEndSettings()
    var scanComplete = true
    var island: IslandState = .hidden
    var strain = false
    var waiting: [String] = []
    var endedServers: [String] = []
    var servedPorts: [String: Int] = [:]
  }

  static func build(_ input: Input) -> E2EState {
    let threads = input.threads.compactMap { thread -> Thread? in
      guard let pid = E2ECommand.root(thread), input.targets.contains(pid) else { return nil }
      return Thread(
        id: thread.id, pid: pid, status: thread.agentStatus?.rawValue,
        unused: input.unused[thread.id].map(name),
        protection: input.protections[thread.id]
          .map { "\($0)" }, pausedBy: input.pausedBy[thread.id], paused: thread.isPaused)
    }.sorted { $0.pid < $1.pid }
    return E2EState(
      at: input.at, risk: input.risk.rawValue, meeting: input.meeting, threads: threads,
      island: input.island.debugName, menuBar: input.island.menuText?.text ?? "",
      ended: input.ended.compactMap(\.resumeCommand),
      maxTickGap: input.maxTickGap,
      candidates: input.candidates, note: input.note,
      slowed: input.slowed,
      projects: input.projects, quitApps: input.quitApps, slowedApps: input.slowedApps,
      appsSeen: input.appsSeen,
      heat: input.heat, away: input.away,
      autoEnd: input.autoEnd.mode == .auto ? "auto:\(input.autoEnd.days)" : "ask",
      scanRoots: input.threads.compactMap(\.rootProcessID).sorted(),
      validTargets: input.targets.sorted(), scanComplete: input.scanComplete,
      userResumed: input.userResumed.sorted(), strain: input.strain, waiting: input.waiting,
      endedServers: input.endedServers, servedPorts: input.servedPorts)
  }

  private static func name(_ reason: UnusedPolicy.Reason) -> String {
    switch reason {
    case .idle: "idle"
    case .detached: "detached"
    }
  }
}
