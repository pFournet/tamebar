import AppKit
import Darwin
import Foundation
import os

@MainActor
final class DevProcessModel: ObservableObject {
  @Published private(set) var processes: [DevProcess] = []
  @Published private(set) var resources: [ResourceProcess] = []
  @Published private(set) var workspaceRoots: [Int32: String] = [:]
  @Published private(set) var threads: [AIThread] = []
  @Published private(set) var stoppingThreads: Set<String> = []
  @Published private(set) var threadMessage: String?
  @Published private(set) var consumers: [ResourceConsumer] = []
  @Published private(set) var consumerMessage: String?
  /// A confirmed review or suggested stop is ending things, so pages show it busy and offer no
  /// second one until it reports.
  @Published private(set) var isEnding = false
  /// Sessions pinned with Keep (Q7).
  @Published private(set) var keeps = SessionKeeps.load()
  /// Why each unused session is unused, by thread ID.
  @Published private(set) var unused: [String: UnusedPolicy.Reason] = [:]
  /// Why each protected session is never offered for ending, by thread ID.
  @Published private(set) var protections: [String: UnusedPolicy.Protection] = [:]
  /// Sessions Tamebar ended, with their resume commands (Q4, Q10).
  @Published private(set) var endedLog = EndedSessionLog.load()
  /// Apps quit from the panel before N11, for the Stopped list (Q15). Q11's own quits are in
  /// `autoPause`.
  @Published private(set) var quitApps = QuitAppLog.load()
  /// Where a panel quit writes that log; a test swaps in a `TestDefaults`.
  var quitAppsDefaults = UserDefaults.standard
  /// Running apps by bundle id with their launch date, read on each scan: an app launched after
  /// its quit is back, and leaves the Stopped list.
  @Published private(set) var runningApps: [String: Date?] = [:]
  /// Stopped entries whose Resume, Run now or Reopen was clicked, and when: the button waits
  /// until the entry leaves the list, for at most `bringBackHold`.
  @Published private(set) var bringingBack: [String: Date] = [:]
  static let bringBackHold: TimeInterval = 20
  /// A call is on (`MeetingMonitor`): it lowers the idle cutoff to a day, pauses every unused
  /// session and opted-in project, and slows heavy work. Each scan sets it before `updateUnused`
  /// and the automatic actions; the meeting timer asks for a scan when it changes. The e2e build
  /// reads it from the test's control file.
  private(set) var meetingActive = false
  /// The meeting sources: real only in the shipped app.
  private let meetingMonitor: MeetingMonitor
  /// The latest scan's mic and camera read, for Q11's app probe; nil without a probe or when
  /// the read failed, which holds every app.
  private(set) var callReading: CallReading?
  /// Polls the meeting sources between scans, so a call is caught within about 5 s even when
  /// the background refresh runs every 15 s. Only in the shipped app.
  private var meetingTimer: Timer?
  /// A read of the meeting sources is in flight. A probe stuck in a system call keeps it set,
  /// so neither the timer nor a scan starts a second read behind it.
  private(set) var meetingObserving = false
  /// How long a scan waits for the meeting read before it goes on without it.
  var meetingReadTimeout: Duration = .seconds(2)
  /// Sessions and projects Tamebar resumed on its own, for the island's "resumed" flash.
  @Published private(set) var lastResume: (at: Date, count: Int)?
  /// A brief line about what Tamebar just did on its own, for the island (amendment A).
  @Published private(set) var note: (text: String, at: Date)?
  /// Whether free disk space is in a low episode, for its one note.
  private var diskNote = DiskLowNote()
  /// Automatic pause and resume (Q9). Every thread signal goes through it; it acts on its own
  /// only in an installed build holding `autopause.lock` (see `AutoPauseController.launch`).
  private lazy var autoPause = AutoPauseController.launch(
    signaller: autoPauseSignaller(), apps: .live,
    scans: { [weak self] in self?.scansStarted ?? 0 }, directory: AppData.directory)
  /// "Unused AI sessions" (Q10): Ask me, or End after N days while away.
  @Published private(set) var autoEnd = AutoEndSettings.load(.standard)
  /// What may end or edit on its own (Q18, Q20, Q21), off on a new install, and the ports and
  /// Codex servers never touched (decisions P2).
  @Published private(set) var safety = AutomaticSafety.load(.standard)
  /// Where a change writes them; a test swaps in a `TestDefaults`.
  var safetyDefaults = UserDefaults.standard
  /// Where a change writes the setting; a test swaps in a `TestDefaults` so no plist is written.
  var autoEndDefaults = UserDefaults.standard
  /// Where an end writes the Ended sessions log; a test swaps in a `TestDefaults`.
  var endedDefaults = UserDefaults.standard
  /// The latest scan's presence (Q5): the screen locked, or 10 min with no input.
  private(set) var away = false
  /// Read on every scan; a test swaps in one with its own session dictionary and idle time.
  lazy var presence = PresenceMonitor()
  /// Q10, Q18 and Q20 share one authority, order, end slot, port clock and outcome path.
  private lazy var automaticActions = AutomaticActionCoordinator(
    acts: autoPause.acts, directory: AppData.directory,
    endAutomatically: { [weak self] thread in
      guard let self else { return false }
      return await self.endAutomatically(thread)
    },
    endUnderPressure: { [weak self] thread in
      guard let self else { return false }
      return await self.endUnderPressure(thread)
    },
    endUnusedServer: { [weak self] thread in
      guard let self else { return UnusedServerOutcome() }
      return await self.endUnusedServer(thread)
    },
    emit: { [weak self] event in self?.recordAutomatic(event) })
  /// The last connection on each served port (Q20); tests may replace the clock and its folder.
  var portClock: ServedPortClock {
    get { automaticActions.portClock }
    set { automaticActions.portClock = newValue }
  }
  var portClockDirectory: URL {
    get { automaticActions.portClockDirectory }
    set { automaticActions.portClockDirectory = newValue }
  }
  /// Dev servers Q20 ended, for the Stopped list.
  @Published private(set) var endedServers = EndedServerLog.load()
  /// Where that log is saved; a test swaps in a `TestDefaults`.
  var endedServersDefaults = UserDefaults.standard
  private var appliedProcessScan = AppliedProcessScan()
  private var latestApplied: AppliedProcessScan.Observation?
  private var listeningPorts: [Int32: [Int]] { latestApplied?.listeningPorts ?? [:] }
  private var directories: [Int32: String] { latestApplied?.directories ?? [:] }
  /// Q21's state: what it turned off, what the user turned back on, its last run.
  @Published private(set) var codexTrim = CodexTrimState.read(AppData.directory)
  /// Where the rows' modes are saved; a test swaps in a `TestDefaults`.
  var codexModesDefaults = UserDefaults.standard
  private var codexTrimRunning = false
  private var codexTrimAppliedAt: Date?
  /// Q21's files; a test points them at copies.
  var codexTrimPaths = CodexTrimRunner.Paths.live(
    home: FileManager.default.homeDirectoryForCurrentUser, directory: AppData.directory)
  /// Re-reads an agent's own status right before an end (Q7); a test swaps in its own.
  var statusProbe: (AgentStatusProbe.Input) -> Bool = AgentStatusProbe.stillIdle
  /// The memory risk Q18's last check reads in place of the sentinel's; a test sets it.
  var memoryRiskOverride: MemoryRisk?
  /// The daily usage record (Q16): only in the Tamebar that acts, never the e2e build.
  private var usage: UsageRecorder?
  /// The latest scan's presence, for the usage record's in-use time.
  private var usagePresent = true
  /// The days and markers the Trend card on Activity draws, and the card's Today line, refreshed
  /// at each flush (once a minute).
  @Published private(set) var usageTrend = UsageTrendData()
  /// Q19: the strain and the sessions waiting at start for it, only in the Tamebar that acts.
  private var startGate: StartGate?
  /// The sessions waiting for memory at start, oldest first, for the card's Start now (Q19).
  @Published private(set) var waitingStarts: [StartWait.Registration] = []
  /// The Mac is struggling (Q19), as the latest reading judged it.
  private(set) var struggling = false
  /// The strain for the card's memory line (N11): none, or struggling with its signals; nil in a
  /// Tamebar that doesn't act, which doesn't judge it.
  @Published private(set) var strain: CardStrain?
  /// Background priority under CPU pressure or a call (Q9, Q12). It acts only when `autoPause`
  /// does, so only the instance holding `autopause.lock` touches priorities.
  private lazy var background = BackgroundPriorityController.launch(
    acts: autoPause.acts, directory: AppData.directory)
  private var terminationSource: (any DispatchSourceSignal)?
  /// The Mac is logging out, restarting or shutting down: apps Tamebar quit aren't reopened now.
  private var poweringOff = false
  /// Scans are numbered as they start, to tell which ones began before a signal settled.
  private var scansStarted = 0
  /// Applied process facts keep the previous complete port observation through partial reads.
  private var listeningIDs: Set<Int32> { latestApplied?.servingIDs ?? [] }
  private var scanComplete: Bool { latestApplied?.scanComplete ?? false }
  /// Keep running per thread directory under `keptPreferences`. The check resolves symlinks, so
  /// it runs once per new directory or preference change, not on every refresh.
  private var keptPreferences: [WorkspacePreference]?
  private var keptByDirectory: [String: Bool] = [:]
  /// The latest scan's `ps` records, for the heavy children of busy sessions.
  private var records: [Int32: RawProcessRecord] = [:]
  private var portsScanned: Bool { latestApplied?.portsScanned ?? false }
  private var identities: [Int32: DevProcessIdentity] = [:]
  @Published private(set) var isRefreshing = false
  /// Set when an action asks for a refresh while one is running; that scan started before the
  /// action, so another runs right after it.
  private var refreshRequested = false
  /// The running scan loop, so `refreshNow()` can wait for it.
  private var refreshTask: Task<Void, Never>?
  @Published private(set) var scannedAt: Date?
  @Published private(set) var statusMessage: String?

  @Published private(set) var pressure = PressureAssessment.checking
  @Published private(set) var autoPauseDirectories = Set(
    UserDefaults.standard.stringArray(forKey: ProjectPausePolicy.key) ?? [])
  /// Apps the user lets Tamebar quit under memory pressure and reopen after (Q11).
  @Published private(set) var appQuitList = AppQuitList.load(.defaults(.standard))
  /// Where a toggle writes the list; a test swaps in memory so no defaults plist is written.
  var appQuitStore = AppQuitList.Store.defaults(.standard)
  /// Apps the user doesn't want slowed in the background (Q17.1): "Slow in background" unticked.
  @Published private(set) var appSlowOptOut = AppSlowOptOut.load(.defaults(.standard))
  /// Where a toggle writes it; a test swaps in memory so no defaults plist is written.
  var appSlowOptOutStore = AppSlowOptOut.Store.defaults(.standard)
  /// Each running app's CPU over the last scans: Settings' recent peak, Q17.3's quiet rule.
  private(set) var appWatch = AppCPUWatch()
  /// The latest scan's running apps (Q17).
  @Published private(set) var scannedApps: [ScannedApp] = []
  /// What Q17.1 planned from on the latest scan.
  private var appsSeen: [AppSlow.App] = []
  /// Apps Tamebar slowed in the background now (Q17.1), for the hover card.
  @Published private(set) var slowedApps: [BackgroundPriority.AppEntry] = []
  /// Live slowed sessions, workloads and apps for Activity and the hover card.
  @Published private(set) var slowedNow: [CurrentActivity.Slowed] = []
  /// Apps slowed in the last week, by bundle id, for Settings' apps list.
  @Published private(set) var recentlySlowedApps: [String: BackgroundPriority.RecentApp] = [:]
  @Published private(set) var projectTargets: [String: ProjectPauseTarget] = [:]
  @Published private(set) var actingProjects: Set<String> = []
  private let sentinel = PressureSentinel()
  /// What the model reads from and does to the Mac's processes.
  private let effects: Effects
  private var timer: Timer?

  /// The process scan, and the signal a session's pause, resume or quit sends. A test swaps in
  /// stubs, so its model scans a fixed world and signals nothing real.
  struct Effects: Sendable {
    var snapshot: @Sendable () -> DevProcessSnapshot
    var execute: @Sendable (WorkloadControl.Request) async -> WorkloadControl.Result

    static let live = Effects(
      snapshot: { DevProcessScanner().snapshot() },
      execute: { await WorkloadControl.execute($0) })
  }

  init(meetingMonitor: MeetingMonitor = .launch(), effects: Effects = .live) {
    self.meetingMonitor = meetingMonitor
    self.effects = effects
    if autoPause.acts {
      // Launching the background controller restores what an earlier run left slowed.
      _ = background
      observeSleepAndQuit()
    }
    if autoPause.acts, E2EMode.current == nil {
      startUsage()
    } else if AppBrand.isShippedApp || AppData.isE2E(Bundle.main.bundleIdentifier) {
      usageTrend = .read(AppData.directory)
    }
    if autoPause.acts { startGate = StartGate(directory: AppData.directory) }
    sentinel.start(strain: autoPause.acts) { [weak self] update in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.observeStrain(update)
        if self.pressure.publishes(.init(next: update.assessment, active: NSApp?.isActive == true))
        {
          self.pressure = update.assessment
        }
        ResourceSnapshotCache.pressure = update.assessment
        self.observeUsage(update)
        // Only the instance that acts speaks, and never the e2e build, which reads this Mac's
        // real disk and would leave a note no test asked for.
        if self.autoPause.acts, E2EMode.current == nil, let free = update.diskFree {
          self.noteDisk(free: free, now: .now)
        }
      }
    }
    startAutoRefresh()
    refresh()
  }

  func startAutoRefresh() {
    guard timer == nil else {
      return
    }

    let timer = Timer(timeInterval: E2EMode.current == nil ? 3 : 1, repeats: true) {
      [weak self] _ in
      Task { @MainActor in
        self?.refreshIfStale()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    startMeetingTimer()
  }

  private func startMeetingTimer() {
    guard meetingTimer == nil, meetingMonitor.isLive else { return }
    let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor in
        // Skipped while a read is in flight, or when this one doesn't come back in time.
        guard let self, let observation = await self.observeMeeting() else { return }
        if self.meetingMonitor.tick(now: .now, observation: observation) != self.meetingActive {
          self.refresh()
        }
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    meetingTimer = timer
  }

  func refreshIfStale() {
    guard !isRefreshing else { return }
    let interval: TimeInterval =
      E2EMode.current != nil
      ? 1 : pressure.risk >= .warning ? 12 : NSApp?.isActive == true ? 5 : 15
    if let scannedAt, Date().timeIntervalSince(scannedAt) < interval {
      return
    }

    refresh()
  }

  func refresh() {
    guard !isRefreshing else {
      refreshRequested = true
      return
    }

    isRefreshing = true
    refreshTask = Task { [weak self] in await self?.refreshLoop() }
  }

  /// Returns once a scan that started after this call has been applied. Shares `refresh()`'s
  /// loop: while a scan runs, it asks for one more and waits for both.
  func refreshNow() async {
    refresh()
    await refreshTask?.value
  }

  /// Scans until no refresh was asked for during the last scan.
  private func refreshLoop() async {
    repeat {
      refreshRequested = false
      await scanAndApply()
    } while refreshRequested
    isRefreshing = false
    refreshTask = nil
  }

  /// One read of the meeting sources, off the main thread, waited on for at most
  /// `meetingReadTimeout`. Nil when a read is still in flight or this one timed out; the read
  /// itself runs on, and clears `meetingObserving` when it ends.
  func observeMeeting() async -> MeetingMonitor.Observation? {
    guard !meetingObserving else { return nil }
    meetingObserving = true
    let sources = meetingMonitor.sources
    let read = Task.detached(priority: .utility) {
      await MeetingMonitor.observe(sources, now: .now)
    }
    Task { [weak self] in
      _ = await read.value
      self?.meetingObserving = false
    }
    return await MeetingMonitor.value(of: read, within: meetingReadTimeout)
  }

  private func scanAndApply() async {
    if let mode = E2EMode.current { runCommands(mode) }
    scansStarted += 1
    let scan = scansStarted
    let snapshot = effects.snapshot
    // The meeting sources, once per scan, off the main thread and for at most 2 s. Without a
    // read every app is held and the last meeting answer stands.
    let observation = await observeMeeting()
    let scanned = await Task.detached(priority: .utility) {
      snapshot()
    }.value
    let observed = appliedProcessScan.apply(scanned)
    latestApplied = observed
    // Before `updateUnused` and the automatic actions, which read it.
    callReading = observation?.calls
    meetingActive = meetingMonitor.tick(now: .now, observation: observation)

    if processes != scanned.processes { processes = scanned.processes }
    if resources != scanned.resources { resources = scanned.resources }
    if workspaceRoots != scanned.workspaceRoots { workspaceRoots = scanned.workspaceRoots }
    if threads != scanned.threads { threads = scanned.threads }
    ResourceSnapshotCache.groups = ResourceOwnership.groups(scanned.resources)
    ResourceSnapshotCache.scannedAt = .now
    identities = scanned.identities
    records = scanned.records
    if E2EMode.current == nil {
      E2EMode.OtherRuns.shared.update(
        E2EMode.runs(in: Array(scanned.records.values), userID: Int(getuid())))
    }
    let stopped = observed.stoppedIDs
    let built = observed.consumers
    if consumers != built { consumers = built }
    updateUnused()
    if usage != nil { usagePresent = !presence.reading().isAway }
    // The projects first: automatic pause plans from them, captured at this scan.
    scannedAt = .now
    updateRunningApps(StoppedLog.runningApps(), now: .now)
    observeApps(Self.scanApps(), consumers: built, records: scanned.records)
    updateProjectTargets()
    let targets = E2EMode.current?.targets()
    let paused = runAutoActions(scan: scan, stopped: stopped, targets: targets)
    let slowed = runBackgroundPriority(targets: targets)
    automaticActions.recordHeat(paused: paused, slowed: slowed, acting: heatActing)
    // A `defaults write` of a switch or list is read at the next scan.
    let safety = AutomaticSafety.load(safetyDefaults)
    if safety != self.safety { self.safety = safety }
    if autoPause.acts { away = presence.reading().isAway }
    automaticActions.run(
      .init(
        now: .now, serverNow: unusedServerNow(), observed: observed, records: records,
        unused: unused, protections: protections, scope: targets, inFlight: stoppingThreads,
        risk: pressure.memoryRisk, inMeeting: meetingActive, away: away,
        manuallyEnding: isEnding, autoEnd: autoEnd, safety: safety, home: AgentHome.current))
    runCodexTrim()
    statusMessage =
      scanned.incomplete
      ? "Process scan incomplete; some processes or ports could not be read." : nil
    if let mode = E2EMode.current {
      mode.write(
        E2EState.build(
          .init(
            at: .now, risk: pressure.risk, meeting: meetingActive, threads: threads,
            unused: unused, protections: protections, ended: visibleEndedSessions,
            targets: targets ?? mode.targets(),
            pausedBy: Dictionary(
              threads.compactMap { thread in
                pausedBy(thread).map { (thread.id, $0.reason.rawValue) }
              }, uniquingKeysWith: { first, _ in first }),
            maxTickGap: autoPause.maxTickGap, candidates: autoPause.candidates,
            note: note?.text, slowed: background.slowedProcessIDs.sorted(),
            userResumed: Array(autoPause.record.state.userResumed),
            projects: e2eProjects(targets ?? mode.targets()),
            quitApps: autoPause.record.apps.ledger.map(\.bundleID),
            slowedApps: background.record.apps.map(\.bundleID).sorted(),
            appsSeen: appsSeen.map { app in
              "\(app.group) \(Int(app.cpuPercent))% pids=\(app.processIDs.count)"
                + " front=\(app.isFrontmost) mic=\(String(describing: app.usesMicOrCamera))"
                + " out=\(app.optedOut) above=\(background.appClock.above[app.group].map { Int(Date.now.timeIntervalSince($0)) } ?? -1)s"
            }, heat: heatActing,
            away: away,
            autoEnd: autoEnd, scanComplete: scanComplete,
            // Without the panel or the screen: the same state on a Mac with no notch, and full
            // screen never read, so the dump doesn't depend on this Mac's windows.
            island: IslandState.resolve(islandFacts(now: .now, freeBytes: 0)) { false },
            strain: struggling, waiting: waitingStarts.map(\.project),
            endedServers: endedServers.servers.compactMap(\.command),
            servedPorts: Dictionary(
              portClock.lastUsed.map { port, _ in
                (String(port), Int(portClock.unused(port, now: unusedServerNow()) ?? 0))
              }, uniquingKeysWith: { first, _ in first }))))
    }
  }

  // MARK: The usage record (Q16)

  private func startUsage() {
    let directory = AppData.directory
    let recorder = UsageRecorder(
      .init(
        directory: directory, now: .now,
        build: UsageBuild.label(version: AppBrand.version, commit: AppBrand.commit),
        version: AppBrand.version, commit: AppBrand.commit,
        baseline: {
          (try? ResourceHistoryStore(
            url: directory.appendingPathComponent("resource-history.json")
          ).load()) ?? []
        },
        settings: { [weak self] in
          self?.usageSettings
            ?? .init(
              autoEnd: "ask", autoEndDays: AutoEndSettings.defaultDays, quitApps: [],
              autoPauseProjects: [])
        },
        appName: { QuitListApp.resolve($0).name }))
    recorder.importTops { Self.historyTops(directory: directory, apps: Self.scanApps()) }
    recorder.flushed = { [weak self] in self?.usageTrend = $0 }
    usage = recorder
    usageTrend = recorder.data
  }

  /// The automatic settings, for a marker when one is switched.
  var usageSettings: UsageSettings {
    .init(
      autoEnd: autoEnd.mode.rawValue, autoEndDays: autoEnd.days,
      quitApps: appQuitList.bundleIDs.sorted(), autoPauseProjects: autoPauseDirectories.sorted(),
      slowOptOut: appSlowOptOut.bundleIDs.sorted(), endIdleSessions: safety.endIdleSessions,
      trimCodexPlugins: safety.trimCodexPlugins)
  }

  // MARK: Waiting at start (Q19)

  /// One reading into the strain; releases the sessions waiting at start once it clears.
  private func observeStrain(_ update: PressureUpdate) {
    guard let startGate, let reading = update.strain else { return }
    startGate.observe(reading, forced: update.forcedStrain)
    struggling = startGate.struggling
    let strain = CardStrain(
      struggling: startGate.struggling, signals: startGate.planner.signals.map(\.text))
    if self.strain != strain { self.strain = strain }
    if waitingStarts != startGate.waiting { waitingStarts = startGate.waiting }
  }

  /// The card's Start now: that session starts at once.
  func startNow(_ registration: StartWait.Registration) {
    guard let startGate, startGate.startNow(registration.waitPID) else { return }
    waitingStarts = startGate.waiting
  }

  /// One pressure reading into the usage record, with the latest scan's presence and sessions.
  private func observeUsage(_ update: PressureUpdate) {
    guard let usage else { return }
    let assessment = update.assessment
    let memory = update.memory
    let scanned = scannedAt != nil
    usage.observe(
      .init(
        date: memory?.date ?? .now, present: usagePresent, risk: assessment.memoryRisk,
        cpuStrained: assessment.cpuStrained, hot: assessment.thermal.isHot,
        struggling: startGate == nil ? nil : struggling,
        swapBytes: memory?.swapUsed, availableBytes: memory?.available,
        memoryPercent: memory.flatMap { sample in
          sample.total > 0
            ? Double(sample.total - min(sample.total, sample.available)) / Double(sample.total)
              * 100 : nil
        },
        cpuPercent: update.cpu.map { $0 * 100 },
        sessions: scanned ? threads.count : nil,
        sessionBytes: scanned ? threads.reduce(0) { $0 + $1.memoryBytes } : nil))
  }

  // MARK: The island (Task 9.3)

  /// Low disk is a note, never a banner nor a deletion (2026-10-27): once when free space
  /// crosses into low, again only after it recovered (`DiskLowNote`).
  func noteDisk(free: UInt64, now: Date) {
    guard let text = diskNote.next(available: free) else { return }
    note = (text, now)
    sentinel.log(text)
  }

  /// What the model knows for the island; the free memory comes from the caller's monitor.
  func islandFacts(now: Date, freeBytes: UInt64) -> IslandState.Facts {
    .init(
      now: now, meeting: meetingActive, source: meetingMonitor.source,
      ledger: autoPause.record.state.ledger, risk: pressure.memoryRisk, freeBytes: freeBytes,
      lastResume: lastResume, note: note, struggling: strain?.struggling ?? false,
      strain: strain?.signals ?? [])
  }

  /// The island's Resume now (N3): every session and project Tamebar paused on its own, by the
  /// identities it recorded at the pause (`AutoPauseController.resumeNow`), whether the scan
  /// still lists it or not. Each counts as the user's resume, so it isn't paused again this
  /// episode, and it leaves the ledger at once. A pause of the user's own is never in the
  /// ledger, so it stays.
  func resumeAutoPaused() {
    resumeNowLanded(autoPause.resumeNow(threads: threads, projects: projectTargets), now: .now)
  }

  // MARK: Stopped (Q15)

  /// Everything Tamebar stopped that isn't back, for CLI recovery and current Activity's
  /// live subset: built from the ledgers on each read, so it never disagrees with them.
  var stopped: [StoppedEntry] {
    var input = StoppedLog.Input(now: .now)
    input.ledger = autoPause.record.state.ledger
    input.threads = threads
    input.projectBytes = projectTargets.mapValues(\.memoryBytes)
    input.ended = endedLog.sessions
    input.appLedger = autoPause.record.apps.ledger
    input.quitApps = quitApps.apps
    input.running = runningApps
    input.servers = endedServers.servers
    input.codexPlugins = codexTrim?.off ?? []
    return StoppedLog.entries(input)
  }

  /// Only work still affected now; ended sessions remain in `stopped` for CLI recovery.
  var currentActivity: CurrentActivity { .init(stopped: stopped, slowed: slowedNow) }

  /// The scan's running apps: a panel-quit app launched since its quit leaves the log.
  func updateRunningApps(_ running: [String: Date?], now: Date) {
    if running != runningApps { runningApps = running }
    var log = quitApps
    log.prune(now: now)
    log.dropBack(running: running)
    if log != quitApps {
      quitApps = log
      log.save(quitAppsDefaults)
    }
    var servers = endedServers
    servers.prune(now: now)
    servers.dropBack(
      listeners: latestApplied?.listenerLocations ?? [])
    if servers != endedServers {
      endedServers = servers
      servers.save(endedServersDefaults)
    }
    let shown = Set(stopped.map(\.id))
    let held = bringingBack.filter {
      shown.contains($0.key) && now.timeIntervalSince($0.value) < Self.bringBackHold
    }
    if held != bringingBack { bringingBack = held }
  }

  /// The Stopped row's one button (Q15). A paused session or project resumes in place through
  /// the user's Resume (`userSignalled`, so it stays out of automatic pauses for the episode),
  /// an ended session opens Terminal running its resume
  /// command; an app reopens in the background, as Q11's reopen does.
  func bringBack(_ entry: StoppedEntry) {
    guard bringingBack[entry.id] == nil else { return }
    switch entry.target {
    case .ledger(let id):
      resumeNowLanded(
        autoPause.resumeNow(threads: threads, projects: projectTargets, only: [id]), now: .now)
    case .ended, .server:
      guard let command = entry.command else { return }
      TerminalLauncher.run(command)
    case .codexPlugin(let key):
      undoCodexPlugin(key)
    case .app(let bundleID, let bundleURL):
      let reopen = AppPressureWiring.Actions.live.reopen(
        .init(
          bundleID: bundleID, name: entry.name, bundleURL: bundleURL,
          memoryBytes: entry.memoryBytes ?? 0, quitAt: entry.stoppedAt, confirmed: true))
      Task { [weak self] in
        _ = await reopen.value
        self?.refresh()
      }
    }
    bringingBack[entry.id] = .now
    refresh()
  }

  /// What Resume now leaves: the resumed flash, which confirms the click in the open panel's
  /// header, and the project banner and log as for an automatic resume.
  func resumeNowLanded(_ outcome: AutoPauseWiring.Outcome, now: Date) {
    if outcome.taken > 0 { lastResume = (now, outcome.taken) }
    guard !outcome.resumedProjects.isEmpty else { return }
    sentinel.log("Resumed \(outcome.resumedProjects.values.sorted().joined(separator: ", "))")
  }

  // MARK: Automatic pause and resume (Q9)

  /// Why Tamebar paused this session on its own, if it did and the pause still holds.
  func pausedBy(_ thread: AIThread) -> AutoPausePlanner.Entry? {
    autoPause.pausedBy(thread.id)
  }

  /// The projects inside the e2e targets' trees, for the state dump.
  private func e2eProjects(_ targets: Set<Int32>) -> [E2EState.Project] {
    let parents = records.mapValues(\.parentProcessID)
    return pausableProjects().filter {
      AutoPauseWiring.inScope($0, scope: targets, parents: parents)
    }.map { target in
      E2EState.Project(
        directory: target.directory, paused: target.isPaused,
        pausedBy: autoPause.pausedBy(AutoPauseWiring.projectID(target.directory))?.reason
          .rawValue)
    }.sorted { $0.directory < $1.directory }
  }

  /// Sleep and wake reset the planner's clocks; quit and SIGTERM resume everything it paused.
  private func observeSleepAndQuit() {
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
      _ = NSWorkspace.shared.notificationCenter.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.autoPause.resetClocks()
          self?.background.resetClocks()
          // The time asleep isn't awake time; the record is written before the Mac sleeps.
          self?.usage?.pause()
        }
      }
    }
    _ = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.poweringOff = true }
    }
    _ = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.resumeAllForQuit() }
    }
    // `pkill -x Tamebar` (install.sh) sends SIGTERM, which skips willTerminate: resume on the
    // main thread, then let the default action end the app. The source listens off the main
    // thread, so a stuck main thread still ends within 3 s. It is live before SIGTERM is
    // ignored, so no SIGTERM in between is lost.
    let source = DispatchSource.makeSignalSource(
      signal: SIGTERM, queue: .global(qos: .userInitiated))
    // @Sendable: the handler runs on the global queue, never on the main actor, so it must not
    // inherit the model's isolation; it only hops to main.
    source.setEventHandler { @Sendable [weak self] in
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) {
        Self.endOnSIGTERM()
      }
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.resumeAllForQuit() }
        Self.endOnSIGTERM()
      }
    }
    source.resume()
    Darwin.signal(SIGTERM, SIG_IGN)
    terminationSource = source
  }

  /// SIGTERM's default action: the app ends.
  private nonisolated static func endOnSIGTERM() {
    Darwin.signal(SIGTERM, SIG_DFL)
    raise(SIGTERM)
  }

  private func resumeAllForQuit() {
    usage?.pause()
    background.restoreAllForQuit()
    autoPause.resumeAllForQuit(
      .init(
        parents: LiveProcessTree.read().parents, read: DevProcessIdentity.read,
        send: { ProcessSignal.send(.init(expected: $0, signal: SIGCONT)).wasSent }),
      reopenApps: !poweringOff)
  }

  /// The model's own signal paths, with no message: an automatic action posts no toast.
  private func autoPauseSignaller() -> AutoPauseWiring.Signaller {
    .init(
      begin: { [weak self] thread, signal in self?.beginSignal(thread, signal) },
      finish: { [weak self] thread, signal, request, announce in
        await self?.finishSignal(thread, signal, request, announce: announce) != nil
      },
      resumeByIdentity: { [weak self] id, identities in
        guard let self, stoppingThreads.insert(id).inserted else { return nil }
        return Task { [weak self] in
          let result = await Task.detached(priority: .userInitiated) {
            await WorkloadControl.execute(.init(identities: identities, signal: .resume))
          }.value
          guard let self else { return result.remaining }
          stoppingThreads.remove(id)
          refresh()
          return result.remaining
        }
      },
      stillStopped: { WorkloadControl.stillStopped($0) },
      project: { [weak self] target, signal in
        guard let self, actingProjects.insert(target.directory).inserted else { return nil }
        return Task { [weak self] in
          let result = await Task.detached(priority: .userInitiated) {
            () async -> AutoPauseWiring.ProjectSignal in
            let changed = ProjectPausePolicy.signal(
              .init(target: target, resume: signal == .resume))
            var left = WorkloadControl.stillStopped(target.identities)
            for _ in 0..<8 where signal == .resume && left > 0 {
              try? await Task.sleep(for: .milliseconds(50))
              left = WorkloadControl.stillStopped(target.identities)
            }
            return .init(changed: changed, stillStopped: left)
          }.value
          guard let self else { return result }
          actingProjects.remove(target.directory)
          refresh()
          return result
        }
      },
      // The title restore of a session an older build queued (Q14): non-blocking, to the tty
      // the controller tied to it.
      notice: { tty, text in WorkQueue.TTY.write(tty, text) })
  }

  /// Plans from the scan just applied and starts its steps. Runs after `updateUnused`, on the
  /// threads rooted at an e2e target in e2e mode. Returns the outcome, for the heat note.
  @discardableResult
  private func runAutoActions(scan: Int, stopped: Set<Int32>, targets: Set<Int32>?)
    -> AutoPauseWiring.Outcome
  {
    let home = AgentHome.current
    let scanned = identities
    let now = Date.now
    let thermal = pressure.thermal
    // Background jobs are read only while heat acts or may start (Q13).
    let jobs =
      autoPause.acts && (thermal.isHot || autoPause.heat)
      ? Set(threads.filter { BackgroundJobs.job($0, records: records) != nil }.map(\.id)) : []
    let frontApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let outcome = autoPause.run(
      .init(
        now: now, scan: scan, threads: threads, unused: unused, protections: protections,
        scope: targets, stopped: stopped, risk: pressure.memoryRisk, inMeeting: meetingActive,
        stopping: stoppingThreads.union(actingProjects.map(AutoPauseWiring.projectID)),
        complete: scanComplete, projects: autoPauseProjects(scope: targets),
        apps: autoPause.acts ? appPressureScan(scope: targets) : nil, thermal: thermal,
        jobs: jobs, frontApp: frontApp, records: records
      ) { thread in
        // Q7 for an automatic pause: what the agent writes now, not only this scan's status.
        AgentStatusProbe.stillIdle(
          .init(
            thread: thread, home: home,
            startTime: EndPlan.startTime(thread, identities: scanned)))
      })
    automaticActions.recordPause(outcome)
    return outcome
  }

  // MARK: Heat (Q13)

  /// Tamebar is acting on heat: serious or critical held 30 s, not yet 60 s back to normal, and
  /// no call (a call has its own rules, and heat touches nothing during one).
  var heatActing: Bool { autoPause.heat && !meetingActive }

  /// The projects automatic pause plans from: opted-in ones are checked against Keep running,
  /// and, in e2e mode, their parents are read for the scope.
  private func autoPauseProjects(scope: Set<Int32>?) -> AutoPauseWiring.Projects {
    let targets = pausableProjects()
    let kept = targets.filter { target in
      autoPauseDirectories.contains(target.directory)
        && (target.keepRunning
          || keptByDirectory[target.directory]
            ?? WorkspacePreferences.isKeptRunning(target.directory, preferences: keptPreferences))
    }
    return .init(
      targets: targets, optedIn: autoPauseDirectories, kept: Set(kept.map(\.directory)),
      parents: scope == nil ? [:] : records.mapValues(\.parentProcessID))
  }

  /// Opts an app in or out of Q11's quit under memory pressure, by bundle id.
  func setQuitUnderPressure(_ bundleID: String, on: Bool) {
    var list = appQuitList
    list.set(bundleID, on: on)
    guard list != appQuitList else { return }
    appQuitList = list
    list.save(appQuitStore)
  }

  /// The policy keys of apps set to Keep running on the Memory page before N11 removed it.
  private static func keptApps() -> Set<String> {
    guard let data = UserDefaults.standard.data(forKey: MemoryAppPolicy.storageKey),
      let policies = try? JSONDecoder().decode([String: Lossy<MemoryAppPolicy>].self, from: data)
    else { return [] }
    return Set(policies.filter { $0.value.value == .keepRunning }.keys)
  }

  /// The running apps for Q11, each with its row's memory. The e2e control stands in for the
  /// front app and the mic/camera probe. The shipped app reads `CallSignals`: while any mic or
  /// camera is in use no app is quit, otherwise every app counts as free of them.
  /// `running` is the running apps, read from `NSWorkspace` unless a test passes its own.
  func appPressureScan(scope: Set<Int32>?, running: [AppPressureWiring.Running]? = nil)
    -> AppPressureWiring.Scan
  {
    let control = E2EMode.current?.control()
    var memory: [Int32: UInt64] = [:]
    for consumer in consumers where consumer.kind == .app {
      for pid in consumer.processIDs { memory[pid] = consumer.memoryBytes }
    }
    let running =
      running
      ?? NSWorkspace.shared.runningApplications.map { app in
        AppPressureWiring.Running(
          bundleID: app.bundleIdentifier, name: app.localizedName, processID: app.processIdentifier,
          launchDate: app.launchDate, bundleURL: app.bundleURL, isTerminated: app.isTerminated,
          prohibited: app.activationPolicy == .prohibited)
      }
    return AppPressureWiring.scan(
      .init(
        running: running, list: appQuitList, memory: memory,
        probes: .live(
          control: control,
          frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
          calls: callReading),
        keepRunning: Self.keptApps(),
        scope: scope, parents: records.mapValues(\.parentProcessID),
        selfBundleID: Bundle.main.bundleIdentifier, selfProcessID: getpid(),
        quietAIApps: AppSlow.aiApps.filter { appWatch.isQuiet($0, now: .now) }))
  }

  // MARK: What may act on its own (P2)

  /// Changes the switches or lists of Settings' automatic actions. Switching Codex plugins on
  /// runs Q21 at the next scan; switching it off stops it before its next run.
  func setSafety(_ settings: AutomaticSafety) {
    guard settings != safety else { return }
    safety = settings
    settings.save(safetyDefaults)
  }

  // MARK: Ending unused sessions while away (Q10)

  /// Changes "Unused AI sessions" and recomputes unused: End after N days lowers the cutoff.
  func setAutoEnd(_ settings: AutoEndSettings) {
    guard settings != autoEnd else { return }
    autoEnd = settings
    settings.save(autoEndDefaults)
    updateUnused()
  }

  private func recordAutomatic(_ event: AutomaticActionCoordinator.Event) {
    switch event {
    case .note(let text):
      note = (text, .now)
      sentinel.log(text)
    case .noteOnly(let text):
      note = (text, .now)
    case .ended(let bytes):
      usage?.add(.ended(freedBytes: bytes))
    case .paused(let count, let freed):
      usage?.add(.paused(count: count, freedBytes: freed))
    case .quit(let bytes):
      usage?.add(.quit(freedBytes: bytes))
    case .slowed(let count):
      usage?.add(.slowed(count: count))
    case .resumed(let count):
      lastResume = (.now, count)
    case .log(let text):
      sentinel.log(text)
    }
  }

  // MARK: Ending a session and its unused dev server (Q20)

  /// Q20's clock: now, moved forward by the e2e control's `clockAdvance` in the e2e build only.
  func unusedServerNow() -> Date {
    Date.now.addingTimeInterval(E2EMode.current?.control().clockAdvance ?? 0)
  }

  /// This scan, as Q20 reads it. The terminals' last input is read only for `lastInputFor`.
  private func unusedServerScan(now: Date, targets: Set<Int32>?, lastInputFor: [AIThread])
    -> UnusedServers.Scan
  {
    var scan = UnusedServers.Scan(
      now: now, threads: threads, protections: protections, scope: targets,
      inFlight: stoppingThreads, records: records)
    scan.listening = listeningPorts
    scan.directories = directories
    scan.lastInput =
      lastInputFor.isEmpty ? [:] : WorkQueue.lastInput(lastInputFor, records: records)
    scan.clock = portClock
    scan.protectedPorts = ProtectedPorts.current(
      home: AgentHome.current, listed: safety.protectedPorts)
    return scan
  }

  /// Q20's end of one session: after a fresh scan, the session is judged again (24 h with no
  /// interaction, every served port 24 h without a connection, none protected, no other job, no
  /// protection but serving, no call) and its agent's status re-read (Q7). Then its dev servers
  /// get Quit (SIGTERM to their trees, stopped ones continued to take it, as every Quit); once
  /// every one exited they are recorded, and the session is ended through `endUnused`, which
  /// re-checks it once more right before its own signal.
  func endUnusedServer(_ target: AIThread) async -> UnusedServerOutcome {
    await refreshNow()
    var outcome = UnusedServerOutcome(name: SessionEligibility.name(target))
    let now = unusedServerNow()
    guard !meetingActive, let thread = threadsByID[target.id] else { return outcome }
    let scan = unusedServerScan(
      now: now, targets: E2EMode.current?.targets(), lastInputFor: [thread])
    guard case .success(let candidate) = UnusedServers.judge(thread, scan),
      statusProbe(
        .init(
          thread: thread, home: AgentHome.current,
          startTime: EndPlan.startTime(thread, identities: identities))),
      stoppingThreads.insert(thread.id).inserted
    else { return outcome }
    let members = Set(candidate.servers.flatMap(\.processIDs))
    let expected = identities.filter { members.contains($0.key) }.map(\.value)
    let execute = effects.execute
    let gone = await Task.detached(priority: .userInitiated) { () async -> Bool in
      let result = await execute(.init(identities: expected, signal: .quit))
      guard result.affected > 0, result.remaining == 0 else { return false }
      for _ in 0..<12 {
        let alive = expected.contains { identity in
          DevProcessIdentity.read(identity.process.processID).map(identity.matches) ?? false
        }
        if !alive { return true }
        try? await Task.sleep(for: .milliseconds(250))
      }
      return false
    }.value
    stoppingThreads.remove(thread.id)
    guard gone else {
      refresh()
      return outcome
    }
    let endedAt = Date.now
    var log = endedServers
    for server in candidate.servers {
      let entry = EndedServer(
        id: UUID().uuidString, session: outcome.name, sessionID: thread.sessionID,
        ports: server.ports, directory: server.directory, commandLine: server.commandLine,
        endedAt: endedAt, memoryBytes: server.memoryBytes, unusedFor: candidate.unused)
      log.record(entry, now: endedAt)
      outcome.servers.append(entry)
    }
    endedServers = log
    log.save(endedServersDefaults)
    outcome.sessionEnded = await endUnused([thread], unusedServer: true).confirmed == 1
    outcome.freed =
      outcome.sessionEnded
      ? thread.memoryBytes : candidate.servers.reduce(0) { $0 + $1.memoryBytes }
    return outcome
  }

  // MARK: Turning off unused Codex plugins (Q21)

  /// Q21 in the Tamebar that acts, never the e2e build: once a day the calls are counted and the
  /// modes applied (Auto turns off what had none in 30 days); once a minute between, the modes
  /// are applied with the last counts, which is how a hand edit of the file reaches its row.
  private func runCodexTrim() {
    guard autoPause.acts, E2EMode.current == nil, safety.trimCodexPlugins, !codexTrimRunning
    else { return }
    let now = Date.now
    let due = CodexTrimRunner.due(codexTrim, now: now)
    guard due || codexTrimAppliedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else {
      return
    }
    startCodexTrim(daily: due)
  }

  private func startCodexTrim(daily: Bool) {
    codexTrimRunning = true
    codexTrimAppliedAt = .now
    let runner = CodexTrimRunner(paths: codexTrimPaths)
    let rules = CodexTrimRunner.Rules(
      modes: CodexTrim.Modes.load(codexModesDefaults), alwaysOn: safety.keptCodexKeys,
      turnsOff: safety.trimCodexPlugins)
    Task { [weak self] in
      let outcome = await Task.detached(priority: daily ? .background : .utility) {
        daily ? runner.run(now: .now, rules: rules) : runner.apply(now: .now, rules: rules)
      }.value
      self?.codexTrimLanded(outcome)
    }
  }

  private func codexTrimLanded(_ outcome: CodexTrimRunner.Outcome) {
    codexTrimRunning = false
    if outcome.state != codexTrim { codexTrim = outcome.state }
    if !outcome.modes.isEmpty {
      var modes = CodexTrim.Modes.load(codexModesDefaults)
      for (key, mode) in outcome.modes { modes[key] = mode }
      CodexTrim.Modes.save(modes, codexModesDefaults)
    }
    let count = outcome.turnedOff.count
    guard count > 0 else { return }
    let text = "Turned off \(count) unused Codex \(count == 1 ? "plugin" : "plugins")"
    note = (text, Date.now)
    sentinel.log(text)
  }

  /// The Stopped row's Undo on a Codex plugin: it is set On (never touched again) and turned
  /// back on, at once in the Tamebar that acts, else within a minute by the one that does.
  func undoCodexPlugin(_ key: String) {
    var modes = CodexTrim.Modes.load(codexModesDefaults)
    modes[key] = .on
    CodexTrim.Modes.save(modes, codexModesDefaults)
    if autoPause.acts, E2EMode.current == nil, !codexTrimRunning {
      startCodexTrim(daily: false)
    } else {
      codexTrimAppliedAt = nil
    }
  }

  // MARK: Background priority under CPU pressure (Q9, Q12)

  /// Slows what is heavy while the CPU is the bottleneck, a call is on or the Mac is hot, and
  /// restores it after 30 calm seconds (heat: once it clears). In e2e mode, only inside the
  /// targets' trees. Under heat the slow's line is returned for the heat note instead.
  private func runBackgroundPriority(targets: Set<Int32>?) -> String? {
    guard background.acts else { return nil }
    let now = Date.now
    appsSeen = portsScanned ? appSlowApps(scope: targets) : []
    let groups = BackgroundPriority.groups(
      .init(
        threads: threads, consumers: consumers,
        scan: .init(
          records: records, serving: listeningIDs,
          keptDirectories: Set(keptByDirectory.filter(\.value).keys)),
        frontApp: NSWorkspace.shared.frontmostApplication?.processIdentifier, scope: targets,
        portsScanned: portsScanned))
    let outcome = background.run(
      .init(
        now: now, active: BackgroundPriority.trigger(pressure, meeting: meetingActive),
        groups: groups, identities: identities, serving: listeningIDs, heat: heatActing,
        apps: appsSeen))
    updateSlowedRows()
    return automaticActions.recordPriority(outcome, heatActing: heatActing)
  }

  private func updateSlowedRows() {
    let current = CLIReport.slowed(
      background.record,
      label: { id in
        threads.first(where: { $0.id == id })?.project
      }
    ).map { row in
      CurrentActivity.Slowed(
        id: row.group, name: row.label,
        kind: CurrentActivity.Slowed.Kind(rawValue: row.kind) ?? .workload)
    }
    if current != slowedNow { slowedNow = current }
    if background.record.apps != slowedApps { slowedApps = background.record.apps }
    if background.record.recentApps != recentlySlowedApps {
      recentlySlowedApps = background.record.recentApps
    }
  }

  // MARK: Apps (Q17)

  /// The running apps, from `NSWorkspace`.
  static func scanApps() -> [ScannedApp] {
    NSWorkspace.shared.runningApplications.compactMap { app in
      guard !app.isTerminated, let id = app.bundleIdentifier, let url = app.bundleURL else {
        return nil
      }
      return ScannedApp(
        bundleID: id, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
        processID: app.processIdentifier, bundleURL: url,
        regular: app.activationPolicy == .regular)
    }
  }

  /// The bundle id of the app a helper app lives in: Docker's for its VM service.
  static func outermostBundleID(_ app: ScannedApp) -> String? {
    let path = app.bundleURL.path
    guard let range = path.range(of: ".app/") else { return app.bundleID }
    return Bundle(path: String(path[..<range.lowerBound]) + ".app")?.bundleIdentifier
  }

  /// One scan's apps: their CPU into the watch (Q17.3, Settings' peak), and under memory
  /// pressure the three largest into the usage record (Q17.2).
  private func observeApps(
    _ apps: [ScannedApp], consumers: [ResourceConsumer], records: [Int32: RawProcessRecord]
  ) {
    if apps != scannedApps { scannedApps = apps }
    appWatch.observe(
      now: .now,
      apps: AppCPUWatch.readings(running: apps, consumers: consumers, records: records))
    guard let usage, pressure.memoryRisk >= .warning else { return }
    usage.recordTops(
      AppSuggestions.topBundleIDs(
        consumers: consumers, running: apps, bundleID: Self.outermostBundleID))
  }

  /// Q17.1's view of the running apps: the front app and the mic and camera from the e2e
  /// control in e2e mode, the probes otherwise; in e2e mode only the targets' apps.
  private func appSlowApps(scope: Set<Int32>?) -> [AppSlow.App] {
    let probes = AppPressureWiring.Probes.live(
      control: E2EMode.current?.control(),
      frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, calls: callReading)
    let parents = records.mapValues(\.parentProcessID)
    let running = scannedApps.map { app in
      AppPressureWiring.Running(
        bundleID: app.bundleID, name: app.name, processID: app.processID, launchDate: nil,
        bundleURL: app.bundleURL, isTerminated: false, prohibited: false)
    }
    return AppSlow.apps(
      .init(
        running: scannedApps, consumers: consumers,
        processes: .init(records: records, serving: listeningIDs, keptDirectories: []),
        frontmost: probes.frontmost,
        usesMicOrCamera: probes.usesMicOrCamera(running: running, parents: parents),
        optedOut: appSlowOptOut, selfBundleID: Bundle.main.bundleIdentifier,
        selfProcessID: getpid(),
        allows: { pid in
          scope.map { E2EMode.allows(.init(processID: pid, targets: $0, parents: parents)) }
            ?? true
        }))
  }

  /// "Slow in background" for one app, by bundle id (Q17.1). Unticking it restores the app at
  /// the next scan.
  func setSlowInBackground(_ bundleID: String, on: Bool) {
    var list = appSlowOptOut
    list.set(bundleID, slow: on)
    guard list != appSlowOptOut else { return }
    appSlowOptOut = list
    list.save(appSlowOptOutStore)
  }

  /// Settings' apps list (Q17): the apps with a setting, the suggested ones, those slowed in
  /// the last week, and `added`.
  func appsUnderPressure(added: Set<String>, now: Date = .now) -> [AppsUnderPressure.Row] {
    let suggested = AppSuggestions.suggested(
      usageTrend.days, now: now, calendar: .autoupdatingCurrent
    ).filter(Self.suggestable)
    return AppsUnderPressure.rows(
      .init(
        quit: appQuitList.bundleIDs, optedOut: appSlowOptOut.bundleIDs, suggested: suggested,
        recent: Set(recentlySlowedApps.keys), added: added)
    ) { appInfo($0, now: now) }
  }

  /// Name, memory and recent peak CPU of one app: the running app's, else the installed one's.
  func appInfo(_ bundleID: String, now: Date = .now) -> AppsUnderPressure.Info {
    let running = scannedApps.first { $0.bundleID == bundleID }
    let row = running.flatMap { app in consumers.first { $0.id == app.group } }
    let slowedLately = recentlySlowedApps[bundleID].flatMap {
      now.timeIntervalSince($0.at) < 86_400 ? $0.cpuPercent : nil
    }
    // An app slowed lately that is gone keeps the name it had then, not its bundle id.
    let resolved = QuitListApp.resolve(bundleID).name
    return .init(
      name: running?.name
        ?? (resolved == bundleID ? recentlySlowedApps[bundleID]?.name ?? resolved : resolved),
      memoryBytes: running == nil ? nil : row?.memoryBytes ?? 0,
      peakCPU: [appWatch.peak(bundleID, now: now), slowedLately].compactMap { $0 }.max())
  }

  /// Never Tamebar, nor an app Memory keeps open (macOS's, terminals), but for ChatGPT and
  /// Claude, which Q17.3 quits once quiet.
  static func suggestable(_ bundleID: String) -> Bool {
    guard !AppBrand.isOwn(bundleID) else { return false }
    if AppSlow.isAIApp(bundleID) { return true }
    let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path ?? ""
    return MemoryAppProtection.reason(
      .init(
        processID: -1, bundleIdentifier: bundleID, bundlePath: path, currentProcessID: getpid(),
        currentBundleIdentifier: Bundle.main.bundleIdentifier)) == nil
  }

  /// `memory-history.json`'s pressure events (a day of them), each with the bundle ids of its
  /// three largest apps, for the first run's suggestions. Names resolve through the running apps.
  static func historyTops(directory: URL, apps: [ScannedApp]) -> [(
    date: Date, bundleIDs: [String]
  )] {
    guard
      let data = try? Data(contentsOf: directory.appendingPathComponent("memory-history.json")),
      let history = try? JSONDecoder().decode(MemoryIncidentHistory.self, from: data)
    else { return [] }
    var byName: [String: String] = [:]
    for app in apps {
      guard let id = outermostBundleID(app) else { continue }
      byName[app.name] = byName[app.name] ?? id
      byName[app.bundleName] = byName[app.bundleName] ?? id
    }
    let pressured = Set([MemoryRisk.warning.title, MemoryRisk.critical.title])
    return history.events.filter { $0.kind == "pressure" && pressured.contains($0.detail) }
      .map { event in
        var seen: Set<String> = []
        let ids = AppSuggestions.top(event.apps.map { ($0.name, $0.bytes) })
          .compactMap { byName[$0] }.filter { seen.insert($0).inserted }
        return (event.date, ids)
      }
  }

  /// Runs the e2e test's one-shot commands against target-rooted threads only. Ending runs in its
  /// own task: it waits for a fresh scan, which can't finish while this one is running.
  private func runCommands(_ mode: E2EMode) {
    let targets = mode.targets()
    for command in mode.takeCommands().compactMap(E2ECommand.init) {
      switch command {
      case .endUnused:
        let ending = E2ECommand.endable(threads, unused: unused, targets: targets)
        guard !ending.isEmpty, beginEnding() else { continue }
        Task { [weak self] in
          guard let self else { return }
          _ = await endUnused(ending)
          finishEnding(nil)
        }
      case .keep(let pid):
        if let thread = E2ECommand.thread(rootedAt: pid, in: threads, targets: targets) {
          toggleKeep(thread)
        }
      case .resumeNow:
        // The ledger only ever holds what Tamebar paused within the e2e scope.
        resumeAutoPaused()
      case .startNow(let project):
        // Only the e2e build's own folder holds these.
        for registration in StartWait.matching(project, in: waitingStarts) {
          startNow(registration)
        }
      }
    }
  }

  func toggleKeep(_ thread: AIThread) {
    keeps.toggle(thread)
    // An incomplete scan may have missed a live thread; its thread-ID pin must survive.
    if scanComplete { keeps.prune(liveThreadIDs: Set(threads.map(\.id)).union([thread.id])) }
    keeps.save()
    updateUnused()
  }

  /// Recomputes unused sessions and protections from the latest scan. No process syscalls: ports
  /// come from the scan, and Keep running is cached per directory.
  func updateUnused(now: Date = .now) {
    let preferences = WorkspacePreferences.read()
    if preferences != keptPreferences {
      keptPreferences = preferences
      keptByDirectory = [:]
    }
    var kept: [String: Bool] = [:]
    let directories =
      threads.compactMap(\.directory)
      + consumers.filter { $0.kind == .workload }.compactMap(\.directory)
    for directory in Set(directories) {
      kept[directory] =
        keptByDirectory[directory]
        ?? WorkspacePreferences.isKeptRunning(directory, preferences: preferences)
    }
    keptByDirectory = kept
    let result = UnusedPolicy.evaluate(
      .init(
        // Q2's day cutoff holds while memory is at warning, not under a CPU or disk bottleneck.
        threads: threads, now: now, risk: pressure.memoryRisk, inMeeting: meetingActive,
        keeps: keeps,
        keptDirectories: Set(kept.filter(\.value).keys), servingIDs: listeningIDs,
        autoEndDays: autoEnd.unusedCutoffDays))
    if unused != result.reasons { unused = result.reasons }
    if protections != result.protections { protections = result.protections }
  }

  private struct ProjectCacheKey: Equatable {
    let scannedAt: Date?
    let preferences: [WorkspacePreference]
  }

  private var projectCache: (key: ProjectCacheKey, projects: [WorkspaceProject])?

  /// Resolved projects for the latest scan, reused until a new scan or preference change.
  func projects(_ preferences: [WorkspacePreference]) -> [WorkspaceProject] {
    let key = ProjectCacheKey(scannedAt: scannedAt, preferences: preferences)
    if let projectCache, projectCache.key == key { return projectCache.projects }
    let projects = WorkspaceCatalog.resolvedProjects(
      .init(
        input: .init(resources: resources, processes: processes, preferences: preferences),
        roots: workspaceRoots))
    projectCache = (key, projects)
    return projects
  }

  func updateProjectTargets() {
    let projects = WorkspaceCatalog.resolvedProjects(
      .init(
        input: .init(
          resources: resources, processes: processes, preferences: WorkspacePreferences.load()),
        roots: workspaceRoots))
    projectTargets = Dictionary(
      projects.compactMap { project in
        ProjectPausePolicy.target(
          .init(
            project: project, identities: identities, excludedIDs: [],
            date: scannedAt ?? .distantPast)
        )
        .map { (project.directory, $0) }
      }, uniquingKeysWith: { first, _ in first })
    updateSentinelTargets()
  }

  /// The project targets without any session's processes, for automatic pause and the pressure
  /// log. Sessions pause on their own rules.
  private func pausableProjects() -> [ProjectPauseTarget] {
    let excluded = Set(threads.flatMap(\.processIDs))
    return projectTargets.values.compactMap { target in
      var value = target
      value.identities = target.identities.filter { !excluded.contains($0.process.processID) }
      return value.identities.isEmpty ? nil : value
    }
  }

  private func updateSentinelTargets() {
    sentinel.update(pausableProjects())
  }

  /// True for an AI session that must never be offered for ending: busy, kept, in a kept project,
  /// or serving (Q7).
  func isProtected(_ consumer: ResourceConsumer) -> Bool {
    UnusedPolicy.isProtected(threadID: consumer.threadID, protections: protections)
  }

  func isProtected(threadID: String) -> Bool {
    UnusedPolicy.isProtected(threadID: threadID, protections: protections)
  }

  /// AI threads by ID; the scanner can report one session twice, so the first wins instead of trapping.
  var threadsByID: [String: AIThread] {
    Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// Shows one message on the consumer line of every page, replacing any per-session one.
  func note(_ message: String?) {
    consumerMessage = message
    threadMessage = nil
  }

  /// False when an ending is already running, so nothing should start.
  func beginEnding() -> Bool {
    guard !isEnding else { return false }
    isEnding = true
    return true
  }

  func finishEnding(_ message: String?) {
    isEnding = false
    note(message)
  }

  struct EndResult: Equatable {
    /// Sessions sent Quit.
    var requested = 0
    /// Of those, the ones whose processes all exited. Only these go into Ended sessions.
    var confirmed = 0
    /// Of those, the ones with a process still alive after the wait.
    var stillRunning = 0
    /// Sessions no longer unused, now protected, or whose agent wrote a status since the scan.
    var becameActive = 0
    /// Sessions the fresh scan no longer lists, or that had exited before the Quit reached them.
    var gone = 0
    /// Sessions already being paused, resumed or quit, left alone.
    var inFlight = 0
    /// Automatic ends held back because the user came back or chose Ask me before the signal.
    var held = 0
  }

  /// Ends the chosen unused sessions with Quit, never Force Quit (Q4). The click can come minutes
  /// after the last scan, so it first waits for a fresh one, then re-checks each session against
  /// it and re-reads each agent's own status (Q7); see `EndPlan.plan`. Only sessions whose
  /// processes all exited go into the Ended sessions log: a survivor's resume command would put a
  /// second agent on the same session. An `automatic` end (Q10) posts no row message, and is sent
  /// only while auto mode is still on and the user still away (`autoEndStillAllowed`), checked after
  /// the fresh scan, right before each signal. A `pressure` end (Q18) is automatic too, with Q18's
  /// 12 h idle cutoff in place of the unused one, and is sent only while memory is still at
  /// warning or critical (`pressureEndStillAllowed`).
  func endUnused(
    _ targets: [AIThread], automatic: Bool = false, pressure: Bool = false,
    unusedServer: Bool = false
  ) async -> EndResult {
    await refreshNow()
    let automatic = automatic || pressure || unusedServer
    let eligible: [String: UnusedPolicy.Reason] =
      if pressure {
        SessionEligibility.idleEligible(
          threads, now: .now, lastInput: WorkQueue.lastInput(threads, records: records),
          minimum: PressureEndScheduler.minimumIdle)
      } else if unusedServer {
        SessionEligibility.idleEligible(
          threads, now: unusedServerNow(),
          lastInput: WorkQueue.lastInput(
            threads.filter { thread in targets.contains { $0.id == thread.id } },
            records: records), minimum: UnusedServers.unusedFor)
      } else {
        unused
      }
    var plan = EndPlan.plan(
      targets,
      .init(
        threads: threadsByID, unused: eligible,
        // Q20 lifts the serving protection, and no other: its server was ended just before.
        protections: unusedServer ? protections.filter { $0.value != .serving } : protections,
        identities: identities, stopping: stoppingThreads, home: AgentHome.current),
      probe: statusProbe)
    // An automatic end also needs a resume command and no background job, on the fresh scan (Q10).
    if automatic { plan = SessionEligibility.recheckAutomatic(plan, records: records) }
    // No suspension since the plan, so none of its threads should be in flight; if one is, it
    // still lands in a count.
    var inFlight = plan.inFlight
    var held = 0
    let requests = plan.end.compactMap { thread -> (AIThread, AIThreadStopRequest)? in
      let allowed =
        unusedServer
        ? !meetingActive : pressure ? pressureEndStillAllowed() : autoEndStillAllowed()
      guard !automatic || allowed else {
        held += 1
        return nil
      }
      guard let request = beginSignal(thread, .quit) else {
        inFlight += 1
        return nil
      }
      return (thread, request)
    }
    let outcomes = await withTaskGroup(of: EndPlan.Outcome.self) { group in
      for (thread, request) in requests {
        group.addTask {
          EndPlan.Outcome(
            thread: thread,
            outcome: await self.finishSignal(thread, .quit, request, announce: !automatic))
        }
      }
      var outcomes: [EndPlan.Outcome] = []
      for await outcome in group { outcomes.append(outcome) }
      return outcomes
    }
    var log = endedLog
    EndPlan.log(
      outcomes, into: &log, now: .now, automatic: automatic, pressure: pressure,
      unusedServer: unusedServer)
    if log != endedLog {
      endedLog = log
      log.save(endedDefaults)
    }
    var result = EndPlan.result(
      plan, requested: requests.count, inFlight: inFlight, outcomes: outcomes)
    result.held = held
    return result
  }

  /// The automatic end of one session (Q10): true only when every process of it
  /// quit. Became active, still running, gone, or held back by the user's return all land as not ended.
  func endAutomatically(_ thread: AIThread) async -> Bool {
    await endUnused([thread], automatic: true).confirmed == 1
  }

  /// End after N days is still chosen and the user is still away. The end waited for a fresh scan, and
  /// either can change meanwhile.
  private func autoEndStillAllowed() -> Bool {
    autoEnd.mode == .auto && presence.reading().isAway
  }

  /// The end under memory pressure of one session (Q18): true only when
  /// every process of it quit.
  func endUnderPressure(_ thread: AIThread) async -> Bool {
    await endUnused([thread], pressure: true).confirmed == 1
  }

  /// Memory is still at warning or critical: the end waited for a fresh scan, and pressure can
  /// clear meanwhile.
  private func pressureEndStillAllowed() -> Bool {
    (memoryRiskOverride ?? pressure.memoryRisk) >= .warning
  }

  /// The Ended sessions to show. Hides a session a live thread still runs, so its resume command
  /// is never offered while it is open.
  var visibleEndedSessions: [EndedSession] {
    endedLog.visible(liveSessionIDs: Set(threads.compactMap(\.sessionID)))
  }

  /// Marks the thread as acting and captures its scanned identities, or nil when a signal is
  /// already in flight for it.
  private func beginSignal(_ thread: AIThread, _ signal: AIThreadSignal) -> AIThreadStopRequest? {
    guard stoppingThreads.insert(thread.id).inserted else { return nil }
    return AIThreadStopRequest(
      thread: thread, expected: identities.filter { thread.processIDs.contains($0.key) },
      force: signal == .forceQuit)
  }

  /// Sends the signal, waits for its effect, posts the message unless `announce` is false (an
  /// automatic action), and refreshes. Returns the outcome: "quit" only when every process of a
  /// quit thread exited; nil when none matched any more.
  private func finishSignal(
    _ thread: AIThread, _ signal: AIThreadSignal, _ request: AIThreadStopRequest,
    announce: Bool = true
  ) async -> String? {
    let execute = effects.execute
    let outcome = await Task.detached(priority: .userInitiated) { () async -> String? in
      let result = await execute(
        .init(identities: Array(request.expected.values), signal: signal))
      guard result.affected > 0 else { return nil }
      if result.remaining > 0 {
        return signal == .pause
          ? "pause-pending" : signal == .resume ? "resume-pending" : "still-running"
      }
      switch signal {
      case .pause:
        for _ in 0..<8 {
          if AIThreadStopper.paused(request) { return "paused" }
          try? await Task.sleep(for: .milliseconds(50))
        }
        return "pause-pending"
      case .resume:
        for _ in 0..<8 {
          if !AIThreadStopper.paused(request), AIThreadStopper.running(request) {
            return "resumed"
          }
          try? await Task.sleep(for: .milliseconds(50))
        }
        return "resume-pending"
      case .quit, .forceQuit:
        for _ in 0..<12 {
          guard AIThreadStopper.running(request) else { return "quit" }
          try? await Task.sleep(for: .milliseconds(250))
        }
        return "still-running"
      }
    }.value
    if announce {
      threadMessage = Self.message(
        signal, outcome, label: thread.displayName, bytes: thread.memoryBytes)
    }
    stoppingThreads.remove(thread.id)
    refresh()
    return outcome
  }

  /// The row message for a signal's outcome; nil for none.
  private static func message(
    _ signal: AIThreadSignal, _ outcome: String?, label: String, bytes: UInt64
  ) -> String? {
    switch (signal, outcome) {
    case (_, nil): "\(label) already exited or changed. The list is refreshed."
    case (.pause, "paused"):
      "\(label) paused · CPU stopped, \(ByteText.full(bytes)) RAM still held. Resume when you want it back."
    case (.pause, "pause-pending"):
      "Pause requested for \(label). Some local processes have not stopped yet."
    case (.resume, "resumed"): "\(label) resumed"
    case (.resume, "resume-pending"):
      "Resume requested for \(label). Checking the local processes."
    case (.forceQuit, "quit"):
      "\(label) force quit · it was using \(ByteText.full(bytes))"
    case (.quit, "quit"):
      "\(label) quit · it was using \(ByteText.full(bytes))"
    case (.quit, "still-running"), (.forceQuit, "still-running"):
      "\(label) is still running. Use Force Quit to end it now."
    default: nil
    }
  }

}
