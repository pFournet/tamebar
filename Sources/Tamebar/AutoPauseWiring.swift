import Darwin
import Foundation
import os

/// The model-side glue between a scan and `AutoPausePlanner` (Task 5.3a). Pure, except `load`
/// and `save`, which read and write one file.
enum AutoPauseWiring {
  struct Scan {
    let threads: [AIThread]
    let unused: [String: UnusedPolicy.Reason]
    let protections: [String: UnusedPolicy.Protection]
    /// The root PIDs Tamebar may act on: the e2e targets. Nil outside e2e mode.
    let scope: Set<Int32>?
    /// PIDs the scan saw stopped.
    let stopped: Set<Int32>
    /// Threads with a signal in flight, or one that settled after the scan began reading
    /// processes: the scan can't show its effect yet.
    let inFlight: Set<String>
    /// False when the planner can't pause a session this tick (no call: idle sessions are no
    /// longer paused for memory, Q18), so the live status re-reads are skipped.
    let wantsCandidates: Bool
  }

  struct Sets: Equatable {
    var candidates: [AutoPausePlanner.Candidate] = []
    var pausedNow: Set<String> = []
    var runningNow: Set<String> = []
  }

  /// The threads Tamebar may act on: rooted at an e2e target in e2e mode, all otherwise.
  static func inScope(_ thread: AIThread, scope: Set<Int32>?) -> Bool {
    guard let scope else { return true }
    return E2ECommand.root(thread).map(scope.contains) == true
  }

  /// The planner's view of a scan. A thread with a signal in flight is in no set. A candidate
  /// is unused, unprotected, with no process stopped (by Tamebar or by hand), not busy or shell
  /// in this scan, and still idle when `stillIdle` re-reads what its agent writes now (Q7): every
  /// candidate must be pausable now.
  static func sets(_ scan: Scan, stillIdle: (AIThread) -> Bool) -> Sets {
    var seen: Set<String> = []
    var sets = Sets()
    for thread in scan.threads
    where seen.insert(thread.id).inserted && inScope(thread, scope: scan.scope)
      && !scan.inFlight.contains(thread.id)
    {
      if thread.isPaused { sets.pausedNow.insert(thread.id) }
      // Any process stopped, by Tamebar or by hand (Ctrl-Z on a child): never a candidate, as
      // for projects. A pause would record it and every resume would send it SIGCONT.
      let anyStopped = thread.processIDs.contains(where: scan.stopped.contains)
      if !anyStopped { sets.runningNow.insert(thread.id) }
      guard scan.wantsCandidates, !thread.isPaused, !anyStopped, scan.unused[thread.id] != nil,
        scan.protections[thread.id] == nil, thread.agentStatus != .busy,
        thread.agentStatus != .shell, stillIdle(thread)
      else { continue }
      sets.candidates.append(
        .init(threadID: thread.id, memoryBytes: thread.memoryBytes, isPaused: false))
    }
    return sets
  }

  // MARK: Heat (Q13)

  /// What a scan brings for choosing the idle sessions heat may pause.
  struct HeatScan {
    let threads: [AIThread]
    let protections: [String: UnusedPolicy.Protection]
    let scope: Set<Int32>?
    let stopped: Set<Int32>
    /// Threads with a signal in flight or a resume owed.
    let inFlight: Set<String>
    /// CPU in percent of one core, averaged over `Heat.cpuWindow`, by thread ID: only threads
    /// seen for the whole window (`CPUWindow`).
    let cpu: [String: Double]
    /// Threads with a background job (`BackgroundJobs`, Q10 amendment): still working.
    let jobs: Set<String>
    /// The front app's pid.
    let frontApp: Int32?
  }

  /// The idle sessions heat may pause: the agent says idle (never busy, shell or no state), every
  /// Q7 protection clear (kept, kept project, serving), no background job, not the front app,
  /// nothing stopped, and above `Heat.cpuThreshold` over the last 30 s. `stillIdle` re-reads what
  /// the agent writes now, last.
  static func heatCandidates(_ scan: HeatScan, stillIdle: (AIThread) -> Bool) -> [AutoPausePlanner
    .Candidate]
  {
    var seen: Set<String> = []
    var candidates: [AutoPausePlanner.Candidate] = []
    for thread in scan.threads
    where seen.insert(thread.id).inserted && inScope(thread, scope: scan.scope)
      && !scan.inFlight.contains(thread.id) && !thread.isPaused
      && !thread.processIDs.contains(where: scan.stopped.contains)
      && thread.agentStatus == .idle && thread.tool != .codexDesktop
      && scan.protections[thread.id] == nil && !scan.jobs.contains(thread.id)
      && scan.frontApp.map({ !thread.processIDs.contains($0) }) ?? true
      && (scan.cpu[thread.id] ?? 0) > Heat.cpuThreshold && stillIdle(thread)
    {
      candidates.append(
        .init(threadID: thread.id, memoryBytes: thread.memoryBytes, isPaused: false))
    }
    return candidates
  }

  // MARK: Dev-server projects (D6.4, Task 5.4)

  /// Opted-in dev-server projects plan in the same run as sessions, under this prefix and their
  /// directory. A thread ID starts with a tool's raw value and a dash (`claudeCode-…`,
  /// `codex-…`), so the two never collide.
  static let projectPrefix = "project:"

  static func projectID(_ directory: String) -> String { projectPrefix + directory }

  /// The directory behind a project ID; nil for a thread ID.
  static func projectDirectory(_ id: String) -> String? {
    id.hasPrefix(projectPrefix) ? String(id.dropFirst(projectPrefix.count)) : nil
  }

  /// The dev-server projects a scan saw.
  struct Projects {
    /// Projects with pausable processes (`ProjectPausePolicy.target`), session processes left
    /// out.
    var targets: [ProjectPauseTarget] = []
    /// Directories opted in to automatic pause (`ProjectPausePolicy.key`).
    var optedIn: Set<String> = []
    /// Directories set to Keep running, or inside a kept project.
    var kept: Set<String> = []
    /// Parent by PID, for the e2e scope.
    var parents: [Int32: Int32] = [:]
  }

  struct ProjectScan {
    let projects: Projects
    let scope: Set<Int32>?
    /// Project IDs with a signal in flight, the user's included, or a resume owed.
    let inFlight: Set<String>
    let now: Date
    let wantsCandidates: Bool
  }

  /// A project Tamebar may act on: every process in an e2e target's tree in e2e mode.
  static func inScope(_ target: ProjectPauseTarget, scope: Set<Int32>?, parents: [Int32: Int32])
    -> Bool
  {
    guard let scope else { return true }
    return !target.identities.isEmpty
      && target.identities.allSatisfy {
        E2EMode.allows(.init(processID: $0.process.processID, targets: scope, parents: parents))
      }
  }

  /// The planner's view of the projects, as `sets` gives it for threads. A candidate is opted in,
  /// not Keep running, captured under 20 s ago, and has no process stopped. It ranks by the
  /// memory of the processes a pause would stop, never tools or sessions in the same folder.
  static func projectSets(_ scan: ProjectScan) -> Sets {
    var seen: Set<String> = []
    var sets = Sets()
    let projects = scan.projects
    for target in projects.targets where seen.insert(target.directory).inserted {
      let id = projectID(target.directory)
      guard !scan.inFlight.contains(id),
        inScope(target, scope: scan.scope, parents: projects.parents)
      else { continue }
      let anyStopped = target.identities.contains(where: \.process.stopped)
      if target.isPaused { sets.pausedNow.insert(id) }
      if !anyStopped { sets.runningNow.insert(id) }
      guard scan.wantsCandidates, !anyStopped, projects.optedIn.contains(target.directory),
        !target.keepRunning, !projects.kept.contains(target.directory),
        scan.now.timeIntervalSince(target.capturedAt) < 20
      else { continue }
      sets.candidates.append(
        .init(threadID: id, memoryBytes: target.pausableBytes, isPaused: false))
    }
    return sets
  }

  /// What `autopause.json` holds: the planner's state, the processes behind each ledger entry,
  /// and the resumes still to retry.
  struct Record: Codable, Equatable {
    var state = AutoPausePlanner.State()
    /// The identities of the processes Tamebar paused, by thread ID, so a thread the scan no
    /// longer lists can still be resumed. Kept while the thread is in the ledger or pending.
    var identities: [String: [DevProcessIdentity]] = [:]
    /// Resumes owed: started and not yet confirmed, refused (a signal in flight), or one that
    /// left a process stopped. Retried on every refresh until one goes through.
    var pendingResumes: Set<String> = []
    /// Set once Tamebar has resumed the opted-in projects an older build paused and never
    /// resumed (before Task 5.4), so that happens a single time.
    var projectsMigrated = false
    /// The apps Tamebar quit under memory pressure, to reopen (Q11, Task 5.5). Kept on quit, so
    /// the next launch reopens them.
    var apps = AppPressurePlanner.State()
    /// The tty each queued session's notice went to (Q14), by thread ID: its title is restored
    /// there after the resume. Kept while the thread is in the ledger or owed a resume. Nothing is
    /// queued any more (Q19); this is read so a session an older build queued gets its title back.
    var notices: [String: String] = [:]

    init() {}

    /// Field by field: an unreadable field takes its default and never drops the others.
    init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      state = (try? values.decodeIfPresent(AutoPausePlanner.State.self, forKey: .state)) ?? .init()
      identities =
        (try? values.decodeIfPresent([String: [DevProcessIdentity]].self, forKey: .identities))
        ?? [:]
      pendingResumes =
        (try? values.decodeIfPresent(Set<String>.self, forKey: .pendingResumes)) ?? []
      projectsMigrated =
        (try? values.decodeIfPresent(Bool.self, forKey: .projectsMigrated)) ?? false
      apps =
        (try? values.decodeIfPresent(AppPressurePlanner.State.self, forKey: .apps)) ?? .init()
      notices = (try? values.decodeIfPresent([String: String].self, forKey: .notices)) ?? [:]
    }

    /// Tamebar paused this thread: remember its processes, and drop any older resume to retry.
    mutating func paused(_ threadID: String, identities: [DevProcessIdentity]) {
      self.identities[threadID] = identities
      pendingResumes.remove(threadID)
    }

    /// A pause started `at` stopped nothing: its entry goes, without counting as the user's
    /// resume, and the spacing slot it took is handed back so the next candidate goes at once.
    /// This one waits `pressureSpacing` before it is tried again (`pauseFailedAt`).
    mutating func pauseFailed(_ id: String, at: Date, previousLastPause: Date?) {
      guard let index = state.ledger.firstIndex(where: { $0.threadID == id && $0.since == at })
      else { return }
      state.ledger.remove(at: index)
      state.pauseFailedAt[id] = at
      if state.lastPause == at { state.lastPause = previousLastPause }
      prune()
    }

    /// A resume is owed from now until one leaves none of the thread's processes stopped, even
    /// when this one is refused (a signal in flight) or fails. Keeps its identities meanwhile.
    mutating func resuming(_ threadID: String) {
      pendingResumes.insert(threadID)
    }

    /// A resume finished. Done when no process it covered is still stopped; otherwise it stays
    /// owed, as `resuming` left it, and is retried.
    mutating func resumed(_ threadID: String, stillStopped: Int) {
      if stillStopped == 0 { pendingResumes.remove(threadID) }
      prune()
    }

    /// The user paused or resumed this thread from its row: it is theirs now. Tamebar owes it
    /// no resume, and a user resume also keeps it from being paused again this episode.
    mutating func userSignalled(_ threadID: String, _ signal: AIThreadSignal) {
      guard signal == .pause || signal == .resume else { return }
      pendingResumes.remove(threadID)
      if signal == .resume, state.ledger.contains(where: { $0.threadID == threadID }) {
        state.userResumed.insert(threadID)
      }
      state.ledger.removeAll { $0.threadID == threadID }
      prune()
    }

    /// The pending resumes to start now: none the planner owns again (back in the ledger), none
    /// in flight.
    func retries(inFlight: Set<String>) -> [String] {
      let ledger = Set(state.ledger.map(\.threadID))
      return pendingResumes.subtracting(ledger).subtracting(inFlight).sorted()
    }

    /// Identities go once their thread is neither in the ledger nor owed a resume.
    mutating func prune() {
      let keep = Set(state.ledger.map(\.threadID)).union(pendingResumes)
      identities = identities.filter { keep.contains($0.key) }
      notices = notices.filter { keep.contains($0.key) }
    }
  }

  /// Where the record lives. Nil, so nothing is read or written, when the e2e build's data
  /// folder isn't its own `Tamebar-e2e`: the real app's file is never touched from a test.
  static func storeURL(directory: URL, e2e: Bool) -> URL? {
    guard !e2e || directory.lastPathComponent == "Tamebar-e2e"
    else { return nil }
    return directory.appendingPathComponent("autopause.json")
  }

  private static let log = Logger(subsystem: AppBrand.bundleIdentifier, category: "autopause")

  /// The saved record, or an empty one when there is none. An unreadable file is logged, kept
  /// aside as `autopause.unreadable-<seconds>.json`, and the launch goes on empty.
  static func load(_ url: URL, now: Date = .now) -> Record {
    guard let data = try? Data(contentsOf: url) else { return Record() }
    do {
      return try JSONDecoder().decode(Record.self, from: data)
    } catch {
      let aside = url.deletingLastPathComponent().appendingPathComponent(
        "autopause.unreadable-\(Int(now.timeIntervalSince1970)).json")
      try? FileManager.default.moveItem(at: url, to: aside)
      log.error(
        "autopause.json unreadable, kept as \(aside.lastPathComponent, privacy: .public), starting empty: \(error, privacy: .public)"
      )
      let apps = AppPressureWiring.ledgerBundleIDs(data)
      if !apps.isEmpty {
        log.error(
          "Apps Tamebar quit and won't reopen: \(apps.joined(separator: ", "), privacy: .public)")
      }
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
      log.error("autopause.json not saved: \(error, privacy: .public)")
    }
  }

  struct PausedProject: Equatable {
    let directory: String
    let name: String
    let reason: AutoPausePlanner.Reason
    /// The memory of the processes the pause stopped, for the note.
    var memoryBytes: UInt64 = 0
  }

  /// A pause that stopped something, for the note, the log and the banner. A session carries
  /// its memory at the scan the pause was planned from.
  enum LandedPause: Equatable {
    case session(AutoPausePlanner.Reason, memoryBytes: UInt64)
    case project(PausedProject)
  }

  /// What a project signal did: how many processes it changed, and how many of them are still
  /// stopped afterwards.
  struct ProjectSignal: Equatable, Sendable {
    let changed: Int
    let stillStopped: Int
  }

  /// The brief line an automatic pause leaves for the island: sessions by count, a project by
  /// name, several projects by count, then under pressure the memory it `freed` when known
  /// ("Paused 3 idle sessions · 2.4 GB · resumes when memory recovers"). A call's line keeps
  /// its words: the call state covers the notch while it lasts. Nil when nothing was paused.
  /// Heat's pauses have their own note (`Heat.note`) and are left out.
  static func note(
    paused: [AutoPausePlanner.Reason], projects: [PausedProject] = [], freed: UInt64 = 0
  ) -> String? {
    let paused = paused.filter { $0 != .heat }
    var what: [String] = []
    if !paused.isEmpty {
      what.append(paused.count == 1 ? "1 idle session" : "\(paused.count) idle sessions")
    }
    if let only = projects.first, projects.count == 1 {
      what.append(only.name)
    } else if projects.count > 1 {
      what.append("\(projects.count) projects")
    }
    guard !what.isEmpty else { return nil }
    let subject = what.joined(separator: " and ")
    if paused.contains(.meeting) || projects.contains(where: { $0.reason == .meeting }) {
      return "Paused \(subject) for your call"
    }
    let amount = freed > 0 ? " · \(ByteText.full(freed))" : ""
    return "Paused \(subject)\(amount) · resumes when memory recovers"
  }

  /// What quitting needs to resume everything: a live read of the process table and a signaller.
  struct QuitResume {
    let parents: [Int32: Int32]
    let read: (Int32) -> DevProcessIdentity?
    /// Sends SIGCONT to the process if it is still this instance (`ProcessSignal.send`).
    let send: (DevProcessIdentity) -> Bool
  }

  /// SIGCONT for every process Tamebar paused or owes a resume, and for each one's live tree:
  /// a recorded process that is still the same instance, then each descendant whose parent was
  /// walked. Synchronous, for quit. Returns how many processes were sent SIGCONT.
  @discardableResult
  static func resumeAll(_ record: Record, _ env: QuitResume) -> Int {
    let owed = Set(record.state.ledger.map(\.threadID)).union(record.pendingResumes)
    var roots: [Int32: DevProcessIdentity] = [:]
    for id in owed.sorted() {
      for expected in record.identities[id] ?? [] {
        let pid = expected.process.processID
        guard roots[pid] == nil, let current = env.read(pid), expected.matches(current) else {
          continue
        }
        roots[pid] = expected
      }
    }
    var walked: Set<Int32> = []
    var sent = 0
    for pid in LiveProcessTree(parents: env.parents).descendants(Set(roots.keys)) {
      let identity: DevProcessIdentity?
      if let root = roots[pid] {
        identity = root
      } else if let parent = env.parents[pid], walked.contains(parent) {
        identity = env.read(pid)
      } else {
        identity = nil
      }
      guard let identity else { continue }
      walked.insert(pid)
      if env.send(identity) { sent += 1 }
    }
    return sent
  }

  /// Only one Tamebar acts on its own: the one holding this lock (`flock`), until it exits.
  enum Lock {
    /// The descriptor holding an exclusive lock on `url`, or nil when another holds it.
    static func acquire(_ url: URL) -> Int32? {
      try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else { return nil }
      guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        close(descriptor)
        return nil
      }
      return descriptor
    }

    static func release(_ descriptor: Int32) {
      flock(descriptor, LOCK_UN)
      close(descriptor)
    }
  }

  /// How the controller signals: the model's own paths in the app, a recorder in tests.
  struct Signaller {
    /// The model's `beginSignal`: marks the thread acting and captures its scanned identities.
    /// Nil when a signal is already in flight for it.
    var begin: @MainActor (AIThread, AIThreadSignal) -> AIThreadStopRequest?
    /// The model's `finishSignal`: sends, waits, then refreshes. The row message only when the
    /// flag is set: a user's signal, never an automatic one. True when it signalled something.
    var finish: @MainActor (AIThread, AIThreadSignal, AIThreadStopRequest, Bool) async -> Bool
    /// Resumes, by its recorded identities, a thread the scan doesn't list. Nil when a signal is
    /// in flight for it; the task returns how many processes are still stopped.
    var resumeByIdentity: @MainActor (String, [DevProcessIdentity]) -> Task<Int, Never>?
    /// How many of these processes are still the same instance and stopped.
    var stillStopped: @MainActor ([DevProcessIdentity]) -> Int
    /// Pauses or resumes a project by its identities (`ProjectPausePolicy.signal`), marking it
    /// acting meanwhile. Nil when an action is in flight for it.
    var project: @MainActor (ProjectPauseTarget, AIThreadSignal) -> Task<ProjectSignal, Never>?
    /// Writes text to a session's tty (`WorkQueue.TTY.write`): the title restore of a session an
    /// older build queued (Q14). Nothing
    /// by default, so a test never writes to a real terminal.
    var notice: @MainActor (_ tty: String, _ text: String) -> Void = { _, _ in }
  }

  /// One scan, as the controller plans from it.
  struct Tick {
    let now: Date
    /// The scan's number. Scans are numbered as they start.
    let scan: Int
    let threads: [AIThread]
    let unused: [String: UnusedPolicy.Reason]
    let protections: [String: UnusedPolicy.Protection]
    let scope: Set<Int32>?
    let stopped: Set<Int32>
    let risk: MemoryRisk
    let inMeeting: Bool
    /// Threads with a signal in flight (`stoppingThreads`).
    let stopping: Set<String>
    /// The scan read every process, so a thread it doesn't list is gone.
    let complete: Bool
    var projects = Projects()
    /// The running apps, for Q11's quits and reopens. Nil skips the app planner.
    var apps: AppPressureWiring.Scan? = nil
    /// macOS's thermal state (Q13).
    var thermal: ThermalStatus = .nominal
    /// Threads with a background job, read only while heat is or may be acting.
    var jobs: Set<String> = []
    var frontApp: Int32? = nil
    /// The scan's `ps` records by PID: the tty a queued session's title is restored on.
    var records: [Int32: RawProcessRecord] = [:]
    /// Re-reads what the agent writes now (Q7).
    let stillIdle: (AIThread) -> Bool
  }

  struct Outcome {
    /// Resumes started this tick, retries included.
    var resumed = 0
    /// Resume now only: the ledger entries it took, started or still owed.
    var taken = 0
    /// Why each session pause started this tick was asked for.
    var paused: [AutoPausePlanner.Reason] = []
    /// The project pauses started this tick.
    var pausedProjects: [PausedProject] = []
    /// The projects whose resume started this tick: name by directory.
    var resumedProjects: [String: String] = [:]
    /// The pauses started this tick, each nil once it lands having stopped nothing.
    var pauses: [Task<LandedPause?, Never>] = []
    /// The app quits started this tick, each nil once it lands without ending the app.
    var quits: [Task<AppPressureWiring.QuitApp?, Never>] = []
    /// The apps reopened this tick, by bundle id.
    var reopened: [String] = []
    /// The reopens started this tick, each with the note to show when it failed for good.
    var reopens: [Task<String?, Never>] = []
    /// The signals started, for a test to wait on.
    var tasks: [Task<Void, Never>] = []

    /// How many heat pauses stopped something, once all have landed.
    func landedHeat() async -> Int {
      await landed().sessions.filter { $0 == .heat }.count
    }

    /// The pauses that stopped something, once all have landed: what the note may report, with
    /// the memory of what they stopped.
    func landed() async -> (
      sessions: [AutoPausePlanner.Reason], projects: [PausedProject], freed: UInt64
    ) {
      var sessions: [AutoPausePlanner.Reason] = []
      var projects: [PausedProject] = []
      var freed: UInt64 = 0
      for pause in pauses {
        switch await pause.value {
        case .session(let reason, let bytes):
          sessions.append(reason)
          freed += bytes
        case .project(let project):
          projects.append(project)
          freed += project.memoryBytes
        case nil: continue
        }
      }
      return (sessions, projects, freed)
    }
  }
}

/// Runs the planner on each scan and applies its steps, resumes first (Q9, Task 5.3). Holds the
/// saved record; everything a scan brings comes in as a `Tick`. Every thread signal, the user's
/// included, goes through it, so it knows which scans began before a signal landed. Opted-in
/// dev-server projects plan in the same run under `project:<directory>` IDs (D6.4, Task 5.4), so
/// both kinds share the ledger, the pacing and the resume rules.
@MainActor
final class AutoPauseController {
  private(set) var record: AutoPauseWiring.Record
  /// False in `swift run` and test hosts, which would act on this Mac's real sessions, and in a
  /// second running Tamebar: it then plans nothing and saves nothing.
  let acts: Bool
  private let url: URL?
  private let lock: Int32?
  private let signaller: AutoPauseWiring.Signaller
  /// The number of the latest scan started.
  private let scans: @MainActor () -> Int
  private var saved: (record: AutoPauseWiring.Record, at: Date)?
  /// For each thread with a signal, the number of the latest scan started when it landed, or
  /// `Int.max` while it is in flight. A scan numbered at or below it can't show the effect.
  private var settled: [String: Int] = [:]
  private var lastTick: Date?
  /// The largest gap between two ticks since launch, in seconds.
  private(set) var maxTickGap: TimeInterval = 0
  /// The latest tick's candidates, by thread ID.
  private(set) var candidates: [String] = []
  /// The latest tick's `ps` records, to tie a queued session's tty to it at the resume.
  private var records: [Int32: RawProcessRecord] = [:]
  /// Each session's CPU over the last 30 s, for heat (Q13).
  private(set) var cpuWindow = CPUWindow()

  /// Tamebar is acting on heat (Q13): hot held 30 s, and cool hasn't held 60 s yet.
  var heat: Bool { AutoPausePlanner.isHeat(record.state) }
  private let apps: AppPressureWiring.Actions
  /// Bundle ids whose quit is in flight.
  private(set) var quittingApps: Set<String> = []

  init(
    record: AutoPauseWiring.Record, acts: Bool, url: URL?, lock: Int32? = nil,
    signaller: AutoPauseWiring.Signaller, apps: AppPressureWiring.Actions = .inert,
    scans: @escaping @MainActor () -> Int
  ) {
    self.record = record
    self.acts = acts
    self.url = url
    self.lock = lock
    self.signaller = signaller
    self.apps = apps
    self.scans = scans
  }

  deinit {
    if let lock { AutoPauseWiring.Lock.release(lock) }
  }

  private static let log = Logger(subsystem: AppBrand.bundleIdentifier, category: "autopause")

  /// The controller the model starts with. It acts only in an installed build (the shipped app
  /// or the e2e build) whose data folder is its own, and only while it holds `autopause.lock`;
  /// it then loads `autopause.json`. `directory` has no default: a caller that forgets it fails
  /// to compile instead of reaching the real app's folder.
  static func launch(
    signaller: AutoPauseWiring.Signaller, apps: AppPressureWiring.Actions = .inert,
    scans: @escaping @MainActor () -> Int, installed: Bool = AppBrand.isInstalledBuild,
    directory: URL, e2e: Bool = E2EMode.current != nil
  ) -> AutoPauseController {
    func idle() -> AutoPauseController {
      .init(record: .init(), acts: false, url: nil, signaller: signaller, scans: scans)
    }
    guard installed, let url = AutoPauseWiring.storeURL(directory: directory, e2e: e2e) else {
      return idle()
    }
    let lockURL = url.deletingLastPathComponent().appendingPathComponent("autopause.lock")
    guard let lock = AutoPauseWiring.Lock.acquire(lockURL) else {
      log.notice("Another Tamebar holds autopause.lock; this one won't pause on its own.")
      return idle()
    }
    let controller = AutoPauseController(
      record: AutoPauseWiring.load(url), acts: true, url: url, lock: lock,
      signaller: signaller, apps: apps, scans: scans)
    controller.dropStaleApps(now: .now)
    return controller
  }

  /// At launch: the apps an earlier run quit and never reopened (a crash, SIGKILL) are reopened on
  /// the normal rules only when it ticked less than 2 h ago. Older ones are forgotten, by name in
  /// the log: the user may have opened and quit them since.
  func dropStaleApps(now: Date) {
    let dropped = record.apps.dropStale(lastTick: record.state.lastTick, now: now)
    guard !dropped.isEmpty else { return }
    let names = dropped.map(\.name).joined(separator: ", ")
    Self.log.notice("Not reopening \(names, privacy: .public): Tamebar was down 2 h or more")
    save(now: now, force: true)
  }

  func pausedBy(_ threadID: String) -> AutoPausePlanner.Entry? {
    record.state.ledger.first { $0.threadID == threadID }
  }

  private func signalling(_ id: String) { settled[id] = .max }
  private func landed(_ id: String) { settled[id] = scans() }

  /// The island's Resume now (N3): every ledger entry, session or project, listed by the scan or
  /// not. Each counts as the user's resume (`userSignalled`), so it isn't paused again this
  /// episode, and is resumed as an automatic resume is: a project by exactly the identities
  /// recorded at its pause, so a process stopped by hand in the same folder is never touched; a
  /// session through its row's path with those identities added, or by them alone when the scan
  /// lost it. A resume refused (a signal in flight), or one that leaves a process stopped, stays
  /// owed and is retried on the next ticks. `projects` (by directory) only gives names. `only`
  /// resumes just those ledger entries: the Stopped list's Resume on one row (Q15).
  @discardableResult
  func resumeNow(
    threads: [AIThread], projects: [String: ProjectPauseTarget], only: Set<String>? = nil,
    now: Date = .now
  ) -> AutoPauseWiring.Outcome {
    var outcome = AutoPauseWiring.Outcome()
    guard acts else { return outcome }
    let byID = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for id in record.state.ledger.map(\.threadID) where only?.contains(id) ?? true {
      outcome.taken += 1
      let recorded = record.identities[id]
      let notice = record.notices[id]
      record.userSignalled(id, .resume)
      // `userSignalled` forgets the identities of what left the ledger; the resume needs them,
      // and a queued session's title is restored after it.
      if let recorded { record.identities[id] = recorded }
      if let notice { record.notices[id] = notice }
      let task: Task<Void, Never>?
      if let directory = AutoPauseWiring.projectDirectory(id) {
        let name = projects[directory]?.name
        task = resumeProject(id, directory: directory, name: name, complete: false, now: now)
        if task != nil {
          outcome.resumedProjects[directory] =
            name ?? URL(fileURLWithPath: directory).lastPathComponent
        }
      } else {
        task = resume(id, thread: byID[id], complete: false)
      }
      guard let task else { continue }
      outcome.resumed += 1
      outcome.tasks.append(task)
    }
    record.prune()
    save(now: now)
    return outcome
  }

  @discardableResult
  func run(_ tick: AutoPauseWiring.Tick) -> AutoPauseWiring.Outcome {
    guard acts else { return .init() }
    if let lastTick { maxTickGap = max(maxTickGap, tick.now.timeIntervalSince(lastTick)) }
    lastTick = tick.now
    settled = settled.filter { $0.value >= tick.scan }
    let inFlight = tick.stopping.union(settled.keys)
    let wants = tick.risk >= .warning || tick.inMeeting
    // Idle sessions are paused only for a call (Q9) and heat (Q13), never for memory: pausing one
    // frees nothing, so memory pressure ends long-idle ones instead (Q18, `PressureEndController`).
    // Opted-in dev-server projects still pause under memory pressure.
    var sets = AutoPauseWiring.sets(
      .init(
        threads: tick.threads, unused: tick.unused, protections: tick.protections,
        scope: tick.scope, stopped: tick.stopped,
        inFlight: inFlight.union(record.pendingResumes), wantsCandidates: tick.inMeeting),
      stillIdle: tick.stillIdle)
    let projectSets = AutoPauseWiring.projectSets(
      .init(
        projects: tick.projects, scope: tick.scope,
        inFlight: inFlight.union(record.pendingResumes), now: tick.now, wantsCandidates: wants))
    sets.candidates += projectSets.candidates
    sets.pausedNow.formUnion(projectSets.pausedNow)
    sets.runningNow.formUnion(projectSets.runningNow)
    let projects = Dictionary(
      tick.projects.targets.map { (AutoPauseWiring.projectID($0.directory), $0) },
      uniquingKeysWith: { first, _ in first })
    migrateProjects(tick, inFlight: inFlight.union(record.pendingResumes))
    candidates = sets.candidates.map(\.threadID)
    cpuWindow.record(
      Dictionary(tick.threads.map { ($0.id, $0.cpuPercent) }, uniquingKeysWith: { a, _ in a }),
      at: tick.now)
    let heatCandidates =
      (tick.thermal.isHot || heat) && !tick.inMeeting
      ? AutoPauseWiring.heatCandidates(
        .init(
          threads: tick.threads, protections: tick.protections, scope: tick.scope,
          stopped: tick.stopped, inFlight: inFlight.union(record.pendingResumes),
          cpu: cpuWindow.averages(now: tick.now), jobs: tick.jobs, frontApp: tick.frontApp),
        stillIdle: tick.stillIdle) : []
    records = tick.records
    let previousLastPause = record.state.lastPause
    // Busy running sessions are never candidates for memory (Q19): the planner gets none, and it
    // resumes at once any session an older build queued (Q14).
    let output = AutoPausePlanner.plan(
      .init(
        now: tick.now, risk: tick.risk, inMeeting: tick.inMeeting, candidates: sets.candidates,
        pausedNow: sets.pausedNow, runningNow: sets.runningNow, state: record.state,
        thermal: tick.thermal, heatCandidates: heatCandidates))
    record.state = output.state
    let threads = Dictionary(
      tick.threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var outcome = AutoPauseWiring.Outcome()
    let resumes =
      record.retries(inFlight: inFlight)
      + output.steps.compactMap { step -> String? in
        if case .resume(let id) = step { id } else { nil }
      }
    for id in resumes {
      let task: Task<Void, Never>?
      if let directory = AutoPauseWiring.projectDirectory(id) {
        task = resumeProject(
          id, directory: directory, name: projects[id]?.name, complete: tick.complete,
          now: tick.now)
        // Only a resume that started: none for one refused, or settled with nothing to resume.
        if task != nil {
          outcome.resumedProjects[directory] =
            projects[id]?.name ?? URL(fileURLWithPath: directory).lastPathComponent
        }
      } else {
        task = resume(id, thread: threads[id], complete: tick.complete)
      }
      guard let task else { continue }
      outcome.resumed += 1
      outcome.tasks.append(task)
    }
    let at = tick.now
    for step in output.steps {
      guard case .pause(let id, let reason) = step else { continue }
      let pause: Task<AutoPauseWiring.LandedPause?, Never>
      if let target = projects[id] {
        guard let task = signaller.project(target, .pause) else { continue }
        record.paused(id, identities: target.identities)
        let paused = AutoPauseWiring.PausedProject(
          directory: target.directory, name: target.name, reason: reason,
          memoryBytes: target.pausableBytes)
        outcome.pausedProjects.append(paused)
        signalling(id)
        pause = Task { [weak self] in
          let result = await task.value
          self?.landed(id)
          guard result.changed > 0 else {
            self?.pauseFailed(id, at: at, previousLastPause: previousLastPause)
            return nil
          }
          return .project(paused)
        }
      } else {
        // Every candidate is pausable now, so the step is applied without a second check.
        guard let thread = threads[id], let request = signaller.begin(thread, .pause)
        else { continue }
        record.paused(id, identities: Array(request.expected.values))
        outcome.paused.append(reason)
        signalling(id)
        let finish = signaller.finish
        pause = Task { [weak self] in
          let sent = await finish(thread, .pause, request, false)
          self?.landed(id)
          guard sent else {
            self?.pauseFailed(id, at: at, previousLastPause: previousLastPause)
            return nil
          }
          return .session(reason, memoryBytes: thread.memoryBytes)
        }
      }
      outcome.pauses.append(pause)
      outcome.tasks.append(Task { _ = await pause.value })
    }
    // A queued session resumed outside Tamebar (`fg`, `kill -CONT`) left the ledger running:
    // its title comes back too. One being resumed now restores it as its resume lands.
    let owed = Set(record.state.ledger.map(\.threadID)).union(record.pendingResumes)
      .union(settled.keys).union(tick.stopping)
    for id in record.notices.keys.sorted() where !owed.contains(id) {
      restoreTitle(id, thread: threads[id])
    }
    if let scan = tick.apps { runApps(scan, tick: tick, sets: sets, outcome: &outcome) }
    record.prune()
    save(now: tick.now)
    return outcome
  }

  /// Q11's last rung, after this tick's session and project steps: quits a listed app once no
  /// candidate is left to pause, reopens what it quit once memory is calm (Task 5.5).
  private func runApps(
    _ scan: AppPressureWiring.Scan, tick: AutoPauseWiring.Tick, sets: AutoPauseWiring.Sets,
    outcome: inout AutoPauseWiring.Outcome
  ) {
    let state = record.state
    let now = tick.now
    let pending = AutoPausePlanner.stillPausable(
      sets.candidates, pausedNow: sets.pausedNow, state: state)
    let output = AppPressurePlanner.plan(
      .init(
        now: now, pressure: AutoPausePlanner.isPressure(state, now),
        calm: AutoPausePlanner.isCalm(state, now), othersPending: !pending.isEmpty,
        lastPause: state.lastPause, apps: scan.apps, running: scan.running,
        quitting: quittingApps, list: scan.list, selfBundleID: scan.selfBundleID,
        state: record.apps, inMeeting: tick.inMeeting))
    record.apps = output.state
    for step in output.steps {
      switch step {
      case .reopen(let entry):
        let task = apps.reopen(entry)
        outcome.reopened.append(entry.bundleID)
        let reopen = Task { [weak self] () -> String? in
          let result = await task.value
          guard let dropped = self?.reopenLanded(entry, result) else { return nil }
          return AppPressureWiring.reopenFailedNote(dropped)
        }
        outcome.reopens.append(reopen)
        outcome.tasks.append(Task { _ = await reopen.value })
      case .quit(let app):
        guard let task = apps.quit(app) else {
          record.apps.quitLanded(app.bundleID, at: now, ended: false)
          continue
        }
        quittingApps.insert(app.bundleID)
        let quit = Task { [weak self] () -> AppPressureWiring.QuitApp? in
          let ended = await task.value
          self?.appQuitLanded(app.bundleID, at: now, ended: ended)
          return ended ? .init(name: app.name, memoryBytes: app.memoryBytes) : nil
        }
        outcome.quits.append(quit)
        outcome.tasks.append(Task { _ = await quit.value })
      }
    }
  }

  private func reopenLanded(
    _ entry: AppPressurePlanner.Entry, _ result: AppPressurePlanner.ReopenResult
  ) -> AppPressurePlanner.Entry? {
    let dropped = record.apps.reopenLanded(entry, result)
    save(now: .now)
    return dropped
  }

  private func appQuitLanded(_ bundleID: String, at: Date, ended: Bool) {
    quittingApps.remove(bundleID)
    record.apps.quitLanded(bundleID, at: at, ended: ended)
    save(now: .now)
  }

  /// Through the row's resume path when the scan lists the thread, with the identities recorded
  /// at the pause added; else by those identities alone. Owed until a resume leaves none of its
  /// processes stopped. Nil when nothing was started.
  private func resume(_ id: String, thread: AIThread?, complete: Bool) -> Task<Void, Never>? {
    record.resuming(id)
    let recorded = record.identities[id] ?? []
    if let thread {
      guard let begun = signaller.begin(thread, .resume) else { return nil }
      var expected = begun.expected
      for identity in recorded where expected[identity.process.processID] == nil {
        expected[identity.process.processID] = identity
      }
      let request = AIThreadStopRequest(thread: thread, expected: expected, force: false)
      let signaller = signaller
      signalling(id)
      return Task { [weak self] in
        _ = await signaller.finish(thread, .resume, request, false)
        self?.landed(id)
        self?.restoreTitle(id, thread: thread)
        self?.settle(id, stillStopped: signaller.stillStopped(Array(expected.values)))
      }
    }
    guard !recorded.isEmpty else {
      // Nothing to resume by. A complete scan that doesn't list it means it is gone.
      if complete { settle(id, stillStopped: 0) }
      return nil
    }
    guard let task = signaller.resumeByIdentity(id, recorded) else { return nil }
    signalling(id)
    return Task { [weak self] in
      let left = await task.value
      self?.landed(id)
      // The scan lost it: its tty can't be tied to it any more, so nothing is written.
      self?.restoreTitle(id, thread: nil)
      self?.settle(id, stillStopped: left)
    }
  }

  /// By exactly the identities recorded at the pause, so a project the scan misses is still
  /// resumed and a job stopped by hand in the same folder is never touched. Owed until none of
  /// them is left stopped.
  private func resumeProject(
    _ id: String, directory: String, name: String?, complete: Bool, now: Date
  ) -> Task<Void, Never>? {
    record.resuming(id)
    let identities = record.identities[id] ?? []
    guard !identities.isEmpty else {
      if complete { settle(id, stillStopped: 0) }
      return nil
    }
    let resuming = ProjectPauseTarget(
      directory: directory, name: name ?? URL(fileURLWithPath: directory).lastPathComponent,
      cpuPercent: 0, memoryBytes: 0, identities: identities, capturedAt: now)
    guard let task = signaller.project(resuming, .resume) else { return nil }
    signalling(id)
    return Task { [weak self] in
      let result = await task.value
      self?.landed(id)
      self?.settle(id, stillStopped: result.stillStopped)
    }
  }

  private func pauseFailed(_ id: String, at: Date, previousLastPause: Date?) {
    record.pauseFailed(id, at: at, previousLastPause: previousLastPause)
    save(now: .now)
  }

  /// After a queued session's resume (one an older build queued, Q14): an empty title, then the
  /// pop, to the tty its notice went
  /// to, only while that tty is still the session's own (this scan's parents). Forgotten either
  /// way.
  private func restoreTitle(_ id: String, thread: AIThread?) {
    guard let tty = record.notices.removeValue(forKey: id) else { return }
    save(now: .now)
    guard let thread, WorkQueue.ttys(thread, records: records)?.pane == tty else { return }
    signaller.notice(tty, WorkQueue.resumedNotice)
  }

  /// Before Task 5.4 the sentinel paused opted-in projects and never resumed them. Once, on the
  /// first complete scan, each opted-in project with a process stopped and no ledger entry is
  /// owed a resume, by its identities; only stopped processes whose identity still matches get
  /// SIGCONT. A project the user suspended by hand before this version is resumed too: the two
  /// can't be told apart, and resuming only hands back the CPU.
  private func migrateProjects(_ tick: AutoPauseWiring.Tick, inFlight: Set<String>) {
    guard !record.projectsMigrated, tick.complete else { return }
    record.projectsMigrated = true
    let ledger = Set(record.state.ledger.map(\.threadID))
    let projects = tick.projects
    for target in projects.targets where projects.optedIn.contains(target.directory) {
      let id = AutoPauseWiring.projectID(target.directory)
      guard !ledger.contains(id), !inFlight.contains(id),
        target.identities.contains(where: \.process.stopped),
        AutoPauseWiring.inScope(target, scope: tick.scope, parents: projects.parents)
      else { continue }
      record.identities[id] = target.identities
      record.resuming(id)
    }
  }

  private func settle(_ id: String, stillStopped: Int) {
    record.resumed(id, stillStopped: stillStopped)
    save(now: .now)
  }

  /// Sleep and wake: pressure and calm are timed afresh, as after a long gap between ticks.
  func resetClocks() {
    record.state.resetClocks()
    save(now: .now)
  }

  /// Quitting: resumes everything Tamebar paused or owes, and reopens every app it quit, whatever
  /// the pressure (it is no longer managing anything, and the note promised a reopen), through a
  /// detached `open` that outlives it; then forgets them. SIGKILL skips this; the next launch then
  /// resumes the saved ledger on its normal rules, and reopens the apps if it was down < 2 h.
  /// `reopenApps` is false when the Mac is logging out, restarting or shutting down: the ledger is
  /// kept, and the 2 h rule decides at the next login.
  func resumeAllForQuit(_ env: AutoPauseWiring.QuitResume, reopenApps: Bool = true) {
    guard acts else { return }
    AutoPauseWiring.resumeAll(record, env)
    // A queued session's title, where a process it was queued with is still that process.
    for (id, tty) in record.notices.sorted(by: { $0.key < $1.key })
    where (record.identities[id] ?? []).contains(where: { expected in
      env.read(expected.process.processID).map(expected.matches) ?? false
    }) {
      signaller.notice(tty, WorkQueue.resumedNotice)
    }
    record.notices = [:]
    if reopenApps {
      for entry in record.apps.takeAllForQuit() where !apps.openOnQuit(entry) {
        Self.log.error("Couldn't reopen \(entry.bundleID, privacy: .public) on quit")
      }
    }
    record.state.ledger = []
    record.pendingResumes = []
    record.prune()
    save(now: .now, force: true)
  }

  /// Writes when something other than the tick time changed, or once a minute.
  private func save(now: Date, force: Bool = false) {
    guard acts, let url else { return }
    var comparable = record
    comparable.state.lastTick = nil
    if !force, let saved, saved.record == comparable, now.timeIntervalSince(saved.at) < 60 {
      return
    }
    AutoPauseWiring.save(record, to: url)
    saved = (comparable, now)
  }
}
