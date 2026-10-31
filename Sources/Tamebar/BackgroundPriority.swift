import Darwin
import Foundation
import os

/// Darwin background priority that Tamebar sets on its own while the CPU is the bottleneck, a
/// call is on (Q9, Q12), or the Mac is hot (Q13), and how it is undone. Pure, except `load`,
/// `save` and `System.live`.
enum BackgroundPriority {
  /// The trigger must hold this long before anything is slowed, as for memory.
  static let sustain = AutoPausePlanner.pressureSustain
  /// Calm this long ends the episode: everything slowed is restored.
  static let calmAfter = AutoPausePlanner.calmAfter
  /// `pti_priority` of a process in Darwin background (spike S3).
  static let backgroundPriority: Int32 = 4

  /// Slowing is wanted: the CPU is strained, whatever bottleneck the assessment shows (memory
  /// pressure can hide it), or a call is on.
  static func trigger(_ assessment: PressureAssessment, meeting: Bool) -> Bool {
    meeting || assessment.cpuStrained
  }

  /// Processes to slow, under the consumer row they belong to.
  struct Group: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case session, workload }
    /// The consumer row's ID: `ai:<thread>` for a session, the workload's own otherwise.
    let id: String
    let name: String
    let kind: Kind
    let processIDs: [Int32]
  }

  /// Everything a scan brings for choosing what to slow.
  struct Sources {
    let threads: [AIThread]
    let consumers: [ResourceConsumer]
    let scan: HeavyChildren.Scan
    let frontApp: Int32?
    /// The e2e targets, nil outside e2e mode: only their trees may be slowed.
    let scope: Set<Int32>?
    /// A complete port scan has landed since launch. Until then a server may look idle, so
    /// nothing is slowed.
    let portsScanned: Bool
  }

  /// What is heavy now: terminal jobs first, then busy sessions' children. Nothing before a
  /// complete port scan, which lsof is likeliest to miss under the very CPU pressure that slows.
  static func groups(_ sources: Sources) -> [Group] {
    guard sources.portsScanned else { return [] }
    let parents = HeavyChildren.parents(sources.scan.records)
    let workloads = HeavyChildren.workloads(
      .init(consumers: sources.consumers, scan: sources.scan, frontApp: sources.frontApp))
    let jobs = workloads.compactMap { workload -> Group? in
      let pids = workload.processIDs.filter { pid in
        sources.scope.map { E2EMode.allows(.init(processID: pid, targets: $0, parents: parents)) }
          ?? true
      }
      return pids.isEmpty
        ? nil : .init(id: workload.id, name: workload.name, kind: .workload, processIDs: pids)
    }
    let sessions = sources.threads.filter { AutoPauseWiring.inScope($0, scope: sources.scope) }
      .compactMap { thread -> Group? in
        let pids = HeavyChildren.select(.init(thread: thread, scan: sources.scan))
        return pids.isEmpty
          ? nil
          : .init(
            id: "ai:" + thread.id, name: thread.displayName, kind: .session, processIDs: pids)
      }
    return jobs + sessions
  }

  /// One process Tamebar moved to background, or a child that inherited it.
  struct Entry: Codable, Equatable, Sendable {
    let identity: DevProcessIdentity
    /// The consumer row it belongs to, whose Normal priority undoes it.
    let group: String
    /// When it was slowed. Its children started after this inherited the priority.
    let slowedAt: Date

    init(identity: DevProcessIdentity, group: String, slowedAt: Date) {
      self.identity = identity
      self.group = group
      self.slowedAt = slowedAt
    }

    /// Without a time, no child is taken as having inherited it; the entry is still restored.
    init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      identity = try values.decode(DevProcessIdentity.self, forKey: .identity)
      group = try values.decode(String.self, forKey: .group)
      slowedAt = (try? values.decodeIfPresent(Date.self, forKey: .slowedAt)) ?? .distantFuture
    }

    var processID: Int32 { identity.process.processID }
  }

  /// An app Tamebar slowed in the background (Q17.1); its processes are `Entry`s under `group`.
  struct AppEntry: Codable, Equatable, Sendable {
    /// The app's row, `app:<bundle name>`.
    let group: String
    let bundleID: String
    let name: String
    /// Its CPU when it was slowed, for the note, the card and `tamebar status`.
    let cpuPercent: Double
    let slowedAt: Date
  }

  /// An app slowed lately, for Settings' apps list (`AppSlow.recentFor`).
  struct RecentApp: Codable, Equatable, Sendable {
    let name: String
    let cpuPercent: Double
    let at: Date
  }

  /// What `background.json` holds.
  struct Record: Codable, Equatable, Sendable {
    /// `backgroundedByTamebar`: restored when the episode ends, on quit, or at the next launch.
    var slowed: [Entry] = []
    /// Apps slowed in the background now (Q17.1), restored each on its own rule.
    var apps: [AppEntry] = []
    /// Apps slowed in the last week, by bundle id.
    var recentApps: [String: RecentApp] = [:]

    init() {}

    /// An unreadable entry is dropped; the others are kept.
    init(from decoder: any Decoder) throws {
      struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
      }
      let values = try decoder.container(keyedBy: CodingKeys.self)
      slowed =
        ((try? values.decodeIfPresent([Lenient<Entry>].self, forKey: .slowed)) ?? nil)?
        .compactMap(\.value) ?? []
      apps =
        ((try? values.decodeIfPresent([Lenient<AppEntry>].self, forKey: .apps)) ?? nil)?
        .compactMap(\.value) ?? []
      recentApps =
        ((try? values.decodeIfPresent([String: Lenient<RecentApp>].self, forKey: .recentApps))
        ?? nil)?.compactMapValues(\.value) ?? [:]
    }

    /// The app slowed under this row, if one is.
    func app(_ group: String) -> AppEntry? { apps.first { $0.group == group } }
  }

  /// A row of an app slowed in the background (Q17.1), not one of Q12's.
  static func isApp(_ group: String) -> Bool { group.hasPrefix("app:") }

  /// The episode's clocks. In memory only: a relaunch restores what was slowed instead.
  struct Clock: Equatable, Sendable {
    var activeSince: Date?
    var calmSince: Date?
    var lastTick: Date?
    /// Slowing has started and the calm that ends it hasn't lasted `calmAfter` yet.
    var engaged = false
  }

  enum Phase: Equatable, Sendable {
    /// Slow what is heavy now.
    case slow
    /// Keep what is slowed; slow nothing new.
    case hold
    /// Restore everything slowed.
    case restore
  }

  /// Times the trigger and calm the way `AutoPausePlanner` times memory pressure: a sleep (a gap
  /// over `wakeGap`) starts both afresh, and a date in the future is brought back to now.
  /// `heat` is the planner's own heat (Q13), already timed there: it slows at once, and once it
  /// clears everything is restored unless the CPU or a call still holds the slow.
  static func advance(_ clock: inout Clock, now: Date, active: Bool, heat: Bool = false) -> Phase {
    clock.activeSince = clock.activeSince.map { min($0, now) }
    clock.calmSince = clock.calmSince.map { min($0, now) }
    if let last = clock.lastTick, now.timeIntervalSince(last) > AutoPausePlanner.wakeGap {
      clock.activeSince = nil
      clock.calmSince = nil
    }
    clock.lastTick = now
    if active {
      clock.activeSince = clock.activeSince ?? now
      clock.calmSince = nil
    } else {
      clock.activeSince = nil
      clock.calmSince = clock.calmSince ?? now
    }
    if heat || clock.activeSince.map({ now.timeIntervalSince($0) >= sustain }) == true {
      clock.engaged = true
      return .slow
    }
    let calm = clock.calmSince.map { now.timeIntervalSince($0) >= calmAfter } ?? false
    guard clock.engaged, !calm else {
      clock.engaged = false
      return .restore
    }
    return .hold
  }

  /// The brief line for what was just slowed. Builds win over a session's tasks.
  static func note(builds: Int, tasks: [(name: String, count: Int)]) -> String? {
    if builds > 0 { return builds == 1 ? "Slowed 1 build" : "Slowed \(builds) builds" }
    let count = tasks.reduce(0) { $0 + $1.count }
    guard count > 0 else { return nil }
    let noun = count == 1 ? "task" : "tasks"
    let of = tasks.count == 1 ? tasks[0].name : "\(tasks.count) sessions"
    return "Slowed \(count) \(noun) of \(of)"
  }

  /// Where the record lives, next to `autopause.json`. Nil, so nothing is read or written, when
  /// the e2e build's data folder isn't its own `Tamebar-e2e`.
  static func storeURL(directory: URL, e2e: Bool) -> URL? {
    guard !e2e || directory.lastPathComponent == "Tamebar-e2e" else { return nil }
    return directory.appendingPathComponent("background.json")
  }

  private static let log = Logger(subsystem: AppBrand.bundleIdentifier, category: "background")

  /// The saved record, or an empty one when there is none. An unreadable file is logged, kept
  /// aside as `background.unreadable-<seconds>.json`, and the launch goes on empty.
  static func load(_ url: URL, now: Date = .now) -> Record {
    guard let data = try? Data(contentsOf: url) else { return Record() }
    do {
      return try JSONDecoder().decode(Record.self, from: data)
    } catch {
      let aside = url.deletingLastPathComponent().appendingPathComponent(
        "background.unreadable-\(Int(now.timeIntervalSince1970)).json")
      try? FileManager.default.moveItem(at: url, to: aside)
      log.error(
        "background.json unreadable, kept as \(aside.lastPathComponent, privacy: .public), starting empty: \(error, privacy: .public)"
      )
      return Record()
    }
  }

  static func save(_ record: Record, to url: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(record) else { return }
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      log.error("background.json not saved: \(error, privacy: .public)")
    }
  }

  /// The process table and the priority calls: the real ones in the app, a fake in tests.
  struct System {
    /// Processes Tamebar may slow belong to this user.
    let uid: UInt32
    /// The live identity of a PID, nil once it exited.
    let read: (Int32) -> DevProcessIdentity?
    /// `proc_pidinfo(PROC_PIDTASKINFO).pti_priority`: 4 in Darwin background (S3). Never
    /// `getpriority`, which reads 0 for another process whatever its priority.
    let priority: (Int32) -> Int32?
    /// `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG or 0)`; true when it succeeded.
    let set: (Int32, Bool) -> Bool
    /// Not Tamebar itself and, in e2e mode, inside a pinned target's tree. Checked before
    /// slowing; a restore needs only the identity Tamebar recorded.
    let allows: (Int32) -> Bool
    /// A live read of the process table: parent by PID.
    let parents: () -> [Int32: Int32]
    /// An Apple platform binary (`CS_PLATFORM_BINARY`), which `SystemExecutable` reads with
    /// the path: macOS's own code is never slowed.
    var platform: (Int32) -> Bool = { _ in false }

    /// macOS's own code (`SystemExecutable`): never slowed, and a priority Tamebar never set.
    func isSystem(_ pid: Int32, _ identity: DevProcessIdentity) -> Bool {
      SystemExecutable.isSystem(identity.executable, platform: platform(pid))
    }

    static var live: System {
      .init(
        uid: getuid(), read: DevProcessIdentity.read, priority: taskPriority,
        set: { pid, background in
          setpriority(PRIO_DARWIN_PROCESS, id_t(pid), background ? PRIO_DARWIN_BG : 0) == 0
        },
        allows: { $0 != getpid() && $0 > 1 && E2EMode.allowsSignal(to: $0) },
        parents: { LiveProcessTree.read().parents }, platform: SystemExecutable.isPlatform)
    }
  }

  static func taskPriority(_ pid: Int32) -> Int32? {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size ? info.pti_priority : nil
  }

  static func started(_ identity: DevProcessIdentity) -> Date {
    Date(
      timeIntervalSince1970: Double(identity.process.startSeconds)
        + Double(identity.process.startMicroseconds) / 1_000_000)
  }

  /// One scan, as the controller acts on it.
  struct Tick {
    let now: Date
    /// `trigger`: the CPU is the bottleneck at warning, or a call is on.
    let active: Bool
    /// What is heavy now (`groups`).
    let groups: [Group]
    /// The scan's identities, which every process must still match.
    let identities: [Int32: DevProcessIdentity]
    /// Processes holding a listening port: anything slowed on their line is restored at once.
    let serving: Set<Int32>
    /// Tamebar is acting on heat (`AutoPausePlanner.isHeat`), outside a call.
    var heat = false
    /// The running apps with a regular activation policy, for Q17.1. Only those in the e2e
    /// scope in e2e mode.
    var apps: [AppSlow.App] = []
  }

  struct Outcome: Equatable {
    var slowed = 0
    var restored = 0
    var note: String?
    /// Processes of background apps slowed this tick (Q17.1).
    var appSlowed = 0
    /// "Slowed ChatGPT · 490% CPU" when an app started being slowed.
    var appNote: String?
  }
}

/// Applies `BackgroundPriority` on each scan (Q9, Q12). Like `AutoPauseController`, it acts
/// only in the instance holding `autopause.lock`, and everything it slowed, with the children
/// that inherited it, is restored when the episode ends, on quit, and at the next launch.
/// A process already in background is never taken, so what the user backgrounded stays theirs.
@MainActor
final class BackgroundPriorityController {
  private(set) var record: BackgroundPriority.Record
  let acts: Bool
  private let url: URL?
  private let system: BackgroundPriority.System
  private var clock = BackgroundPriority.Clock()
  /// Q17.1's per-app clocks.
  private(set) var appClock = AppSlow.Clock()
  /// When this episode's first slow happened. Only a listener started after it can have
  /// inherited background from Tamebar; an entry kept from an earlier episode doesn't count.
  private(set) var episodeStartedAt: Date?

  init(
    record: BackgroundPriority.Record, acts: Bool, url: URL?, system: BackgroundPriority.System
  ) {
    self.record = record
    self.acts = acts
    self.url = url
    self.system = system
  }

  /// The model's controller. `acts` is the auto-pause controller's: the installed build holding
  /// `autopause.lock`. `directory` has no default, so a caller can't reach the real app's folder
  /// by forgetting it. Leftovers from a run that ended without restoring are restored now.
  static func launch(
    acts: Bool, directory: URL, e2e: Bool = E2EMode.current != nil,
    system: BackgroundPriority.System = .live
  ) -> BackgroundPriorityController {
    guard acts, let url = BackgroundPriority.storeURL(directory: directory, e2e: e2e) else {
      return .init(record: .init(), acts: false, url: nil, system: system)
    }
    let controller = BackgroundPriorityController(
      record: BackgroundPriority.load(url), acts: true, url: url, system: system)
    if !controller.record.slowed.isEmpty { controller.restoreAll() }
    return controller
  }

  /// True when Tamebar slowed a process of this consumer row.
  func slows(_ consumerID: String) -> Bool {
    record.slowed.contains { $0.group == consumerID }
  }

  var slowedProcessIDs: [Int32] { record.slowed.map(\.processID) }

  @discardableResult
  func run(_ tick: BackgroundPriority.Tick) -> BackgroundPriority.Outcome {
    guard acts else { return .init() }
    let before = record
    var outcome = BackgroundPriority.Outcome()
    let phase = BackgroundPriority.advance(
      &clock, now: tick.now, active: tick.active, heat: tick.heat)
    if phase == .slow, episodeStartedAt == nil { episodeStartedAt = tick.now }
    // An app slowed in the background (Q17.1) is held whatever Q12's phase: its children are
    // taken in and its servers restored on every tick.
    if !record.slowed.isEmpty, phase != .restore || !record.apps.isEmpty {
      let parents = system.parents()
      adopt(parents)
      forgetExited()
      restoreServing(tick.serving, parents: parents)
    }
    switch phase {
    case .slow:
      var builds = 0
      var tasks: [(name: String, count: Int)] = []
      for group in tick.groups where !BackgroundPriority.isApp(group.id) {
        let count = group.processIDs.filter { slow($0, group: group.id, tick: tick) }.count
        guard count > 0 else { continue }
        outcome.slowed += count
        switch group.kind {
        case .workload: builds += 1
        case .session: tasks.append((group.name, count))
        }
      }
      outcome.note = BackgroundPriority.note(builds: builds, tasks: tasks)
    case .hold:
      break
    case .restore:
      if record.slowed.contains(where: { !BackgroundPriority.isApp($0.group) }) {
        outcome.restored = restoreAll { !BackgroundPriority.isApp($0) }
      }
      episodeStartedAt = nil
    }
    runApps(tick, &outcome)
    if record != before { save() }
    return outcome
  }

  /// Q17.1, each app on its own clock: an app busy in the background for two minutes is slowed,
  /// one in front, on a call, opted out, calm or gone is restored. Its processes go through the
  /// same `slow` and ledger as Q12's.
  private func runApps(_ tick: BackgroundPriority.Tick, _ outcome: inout BackgroundPriority.Outcome)
  {
    // An app whose processes have all exited, or were restored with Q12's, is no longer slowed.
    let live = Set(record.slowed.map(\.group))
    record.apps.removeAll { !live.contains($0.group) }
    let plan = AppSlow.plan(
      &appClock, now: tick.now, apps: tick.apps, slowed: Set(record.apps.map(\.group)))
    for group in plan.restore {
      outcome.restored += restoreAll { $0 == group }
      record.apps.removeAll { $0.group == group }
    }
    for app in plan.hold {
      outcome.appSlowed += slowApp(app, tick: tick)
    }
    var started: [(name: String, cpu: Double)] = []
    for app in plan.start {
      let count = slowApp(app, tick: tick)
      guard count > 0 else { continue }
      outcome.appSlowed += count
      started.append((app.name, app.cpuPercent))
      record.apps.append(
        .init(
          group: app.group, bundleID: app.bundleID, name: app.name, cpuPercent: app.cpuPercent,
          slowedAt: tick.now))
      record.recentApps[app.bundleID] = .init(
        name: app.name, cpuPercent: app.cpuPercent, at: tick.now)
    }
    record.recentApps = record.recentApps.filter {
      tick.now.timeIntervalSince($0.value.at) < AppSlow.recentFor
    }
    outcome.appNote = AppSlow.note(started)
  }

  private func slowApp(_ app: AppSlow.App, tick: BackgroundPriority.Tick) -> Int {
    app.processIDs.filter { slow($0, group: app.group, tick: tick) }.count
  }

  /// Background priority with the row action's checks: the scanned identity still matches, the
  /// process is the user's, and the allowlist lets it through. One already in background is
  /// someone else's (the user's Run in background among them) and is left alone. Recorded only
  /// once `pti_priority` confirms it. macOS's own code never is, whatever row it came in: every
  /// slow (Q12's, Q13's, Q17's) comes through here.
  private func slow(_ pid: Int32, group: String, tick: BackgroundPriority.Tick) -> Bool {
    guard !slowedProcessIDs.contains(pid),
      let expected = tick.identities[pid], let current = system.read(pid),
      expected.matches(current), current.process.owner == system.uid, system.allows(pid),
      !system.isSystem(pid, current),
      let priority = system.priority(pid), priority != BackgroundPriority.backgroundPriority,
      system.set(pid, true)
    else { return false }
    guard system.priority(pid) == BackgroundPriority.backgroundPriority else {
      _ = system.set(pid, false)
      return false
    }
    record.slowed.append(.init(identity: current, group: group, slowedAt: tick.now))
    return true
  }

  /// Children forked after their parent was slowed inherit its priority. Each live descendant of
  /// a recorded process, the user's, started after it was slowed and in background now, is
  /// recorded under the same row, so it is restored with it.
  private func adopt(_ parents: [Int32: Int32]) {
    let tree = LiveProcessTree(parents: parents)
    var recorded = Set(slowedProcessIDs)
    for entry in record.slowed {
      guard let live = system.read(entry.processID), entry.identity.matches(live) else {
        continue
      }
      for pid in tree.descendants([entry.processID])
      where !recorded.contains(pid) {
        guard let current = system.read(pid), current.process.owner == system.uid,
          BackgroundPriority.started(current) > entry.slowedAt,
          system.priority(pid) == BackgroundPriority.backgroundPriority
        else { continue }
        recorded.insert(pid)
        record.slowed.append(
          .init(identity: current, group: entry.group, slowedAt: entry.slowedAt))
      }
    }
  }

  /// Entries whose process exited or was replaced have nothing left to restore.
  private func forgetExited() {
    record.slowed.removeAll { entry in
      system.read(entry.processID).map { !entry.identity.matches($0) } ?? true
    }
  }

  /// A recorded process that now serves a port, or is an ancestor or descendant of a server, is
  /// restored at once: a server must never run slowed, nor restart slowed. So is a listener that
  /// inherited background without being adopted, a daemon that double-forked away from its
  /// slowed parent: one of this user's, in background, started during the episode, not the
  /// user's own, not macOS's (which runs some daemons in background itself), and let through
  /// by the allowlist since Tamebar never recorded it. Started during the episode means after
  /// its first slow, whatever older entries are still kept.
  private func restoreServing(_ serving: Set<Int32>, parents: [Int32: Int32]) {
    let line = HeavyChildren.ServingLine(serving: serving, parents: parents)
    record.slowed.removeAll { entry in
      line.touches(entry.processID) && restore(entry) != .failed
    }
    guard let earliest = episodeStartedAt else { return }
    let recorded = Set(slowedProcessIDs)
    for pid in serving.sorted()
    where !recorded.contains(pid) && system.allows(pid) {
      guard let current = system.read(pid), current.process.owner == system.uid,
        BackgroundPriority.started(current) > earliest, !system.isSystem(pid, current),
        system.priority(pid) == BackgroundPriority.backgroundPriority
      else { continue }
      _ = system.set(pid, false)
    }
  }

  private enum Restore { case restored, gone, failed }

  /// Priority 0 when the process is still the instance Tamebar recorded. Identity alone proves
  /// it is Tamebar's to restore, so the e2e allowlist isn't asked again: a refusal there would
  /// leave a process slowed for good.
  private func restore(_ entry: BackgroundPriority.Entry) -> Restore {
    guard let current = system.read(entry.processID), entry.identity.matches(current) else {
      return .gone
    }
    return system.set(entry.processID, false) ? .restored : .failed
  }

  /// Restores every recorded process that is still the same instance, with the children that
  /// inherited its priority, and keeps only those whose restore failed, to retry. A child forked
  /// between taking children in and restoring its parent inherits background too, so children
  /// are taken in again after each pass. Returns how many it restored.
  /// `groups` picks the rows to restore: every one on quit and at launch, Q12's alone when its
  /// episode ends, one app's when that app is restored (Q17.1).
  @discardableResult
  private func restoreAll(_ groups: (String) -> Bool = { _ in true }) -> Int {
    var restored = 0
    var handled: Set<Int32> = []
    var failed: Set<Int32> = []
    for _ in 0..<3 {
      adopt(system.parents())
      let pending = record.slowed.filter { !handled.contains($0.processID) && groups($0.group) }
      guard !pending.isEmpty else { break }
      for entry in pending {
        handled.insert(entry.processID)
        switch restore(entry) {
        case .restored: restored += 1
        case .gone: break
        case .failed: failed.insert(entry.processID)
        }
      }
    }
    record.slowed.removeAll { handled.contains($0.processID) && !failed.contains($0.processID) }
    let live = Set(record.slowed.map(\.group))
    record.apps.removeAll { !live.contains($0.group) }
    save()
    return restored
  }

  /// Quitting: restores everything recorded. SIGKILL skips this; the next launch restores it.
  @discardableResult
  func restoreAllForQuit() -> Int {
    guard acts else { return 0 }
    return restoreAll()
  }

  /// Sleep and wake: the trigger and calm are timed afresh.
  func resetClocks() {
    clock.activeSince = nil
    clock.calmSince = nil
  }

  private func save() {
    guard acts, let url else { return }
    BackgroundPriority.save(record, to: url)
  }
}
