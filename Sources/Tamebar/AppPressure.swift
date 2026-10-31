import Foundation

/// The apps the user lets Tamebar quit under memory pressure and reopen after (Q11): bundle ids in
/// UserDefaults `apps.quitUnderPressure.v1`, toggled from an app row's ⋯ menu.
struct AppQuitList: Equatable, Sendable {
  static let key = "apps.quitUnderPressure.v1"

  private(set) var bundleIDs: Set<String> = []

  init(_ bundleIDs: Set<String> = []) { self.bundleIDs = bundleIDs }

  func contains(_ bundleID: String) -> Bool { bundleIDs.contains(bundleID) }

  mutating func set(_ bundleID: String, on: Bool) {
    if on { bundleIDs.insert(bundleID) } else { bundleIDs.remove(bundleID) }
  }

  /// Where the list is kept: `UserDefaults.standard` in the app, a dictionary in tests, so a
  /// test never makes cfprefsd write a plist.
  struct Store {
    let read: () -> Any?
    let write: ([String]) -> Void

    static func defaults(_ defaults: UserDefaults) -> Store {
      .init(
        read: { defaults.object(forKey: AppQuitList.key) },
        write: { defaults.set($0, forKey: AppQuitList.key) })
    }
  }

  /// Tolerant: an array keeps its strings and skips the rest; anything else is an empty list.
  static func load(_ store: Store) -> AppQuitList {
    let values = store.read() as? [Any] ?? []
    return AppQuitList(Set(values.compactMap { $0 as? String }.filter { !$0.isEmpty }))
  }

  func save(_ store: Store) { store.write(bundleIDs.sorted()) }
}

/// Decides which listed apps Tamebar quits under memory pressure and when it reopens them (Q11,
/// Task 5.5). Pure. It runs after `AutoPausePlanner` in the same tick and reads its clocks: the
/// same sustained memory pressure, the same 30 calm seconds.
///
/// It is the last rung. An app is quit only while no session or dev-server candidate is left
/// unpaused, and at least `pressureSpacing` after the latest automatic pressure pause or quit, so
/// each action has time to relieve memory before the next one. One listed app per 30 s, largest
/// first. No app is quit while a meeting is on, whatever told Tamebar about it (the calendar, the
/// mic, the camera): quitting during a call is the disruption Tamebar is there to prevent. An app
/// holding the mic or camera is never quit either.
///
/// There is no forced reopen: a quit app costs nothing, and reopening it under pressure would undo
/// the relief. Reopens are spaced by `pressureSpacing`, and an app Tamebar reopened isn't quit
/// again for `requitAfter`, so a Mac at the edge doesn't quit and relaunch it in a loop.
enum AppPressurePlanner {
  static let pressureSpacing = AutoPausePlanner.pressureSpacing
  /// A quit that hasn't ended the app by then (a save dialog) leaves it alone.
  static let quitTimeout: TimeInterval = 10
  /// An app Tamebar reopened is not quit again before this.
  static let requitAfter: TimeInterval = 15 * 60
  /// A reopen that fails for another reason than the app being gone is tried this many times.
  static let reopenTries = 3
  /// A ledger left by a run that ended without reopening (a crash, SIGKILL) is reopened at launch
  /// only if Tamebar was down for less than this; after longer, the user may have opened and
  /// quit the app since.
  static let staleAfter: TimeInterval = 2 * 3_600

  /// A running app, as the scan sees it.
  struct App: Equatable, Sendable {
    let bundleID: String
    let name: String
    let processID: Int32
    let launchDate: Date?
    let bundleURL: URL
    let memoryBytes: UInt64
    let isFrontmost: Bool
    /// Whether it holds the microphone or camera; nil when unknown, which counts as in use.
    let usesMicOrCamera: Bool?
    /// macOS keeps it open (`MemoryAppProtection`).
    let isProtected: Bool
    /// The user set it to Keep running (`MemoryAppPolicy.keepRunning`), which wins over the list.
    var keepRunning = false
    /// Q17.3: an AI app (ChatGPT, Claude) is quit only once quiet, under 5 % CPU over its tree
    /// for 5 minutes (`AppCPUWatch`), so a task running inside it is never killed. Other apps
    /// are always quiet.
    var quiet = true
  }

  struct Entry: Codable, Equatable, Sendable {
    let bundleID: String
    let name: String
    let bundleURL: URL
    let memoryBytes: UInt64
    let quitAt: Date
    /// The app was seen to end. Until then the quit is in flight, and the app still running is
    /// not the user reopening it.
    var confirmed = false
    /// Reopens that failed so far.
    var reopenAttempts = 0

    init(
      bundleID: String, name: String, bundleURL: URL, memoryBytes: UInt64, quitAt: Date,
      confirmed: Bool = false, reopenAttempts: Int = 0
    ) {
      self.bundleID = bundleID
      self.name = name
      self.bundleURL = bundleURL
      self.memoryBytes = memoryBytes
      self.quitAt = quitAt
      self.confirmed = confirmed
      self.reopenAttempts = reopenAttempts
    }

    /// The identifying fields are required; the counters take their defaults when missing.
    init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      bundleID = try values.decode(String.self, forKey: .bundleID)
      name = try values.decode(String.self, forKey: .name)
      bundleURL = try values.decode(URL.self, forKey: .bundleURL)
      memoryBytes = try values.decode(UInt64.self, forKey: .memoryBytes)
      quitAt = try values.decode(Date.self, forKey: .quitAt)
      confirmed = (try? values.decodeIfPresent(Bool.self, forKey: .confirmed)) ?? false
      reopenAttempts = (try? values.decodeIfPresent(Int.self, forKey: .reopenAttempts)) ?? 0
    }

    func with(quitAt: Date) -> Entry {
      .init(
        bundleID: bundleID, name: name, bundleURL: bundleURL, memoryBytes: memoryBytes,
        quitAt: quitAt, confirmed: confirmed, reopenAttempts: reopenAttempts)
    }
  }

  struct State: Codable, Equatable, Sendable {
    /// What Tamebar quit and may reopen, oldest first.
    var ledger: [Entry] = []
    var lastQuit: Date?
    /// Apps the user reopened, or that didn't quit in time: left alone until the episode ends.
    var spared: Set<String> = []
    /// When Tamebar last reopened each app, kept for `requitAfter`.
    var reopenedAt: [String: Date] = [:]
    var lastReopen: Date?

    init() {}

    /// Tolerant decoding: missing keys take their defaults, an unreadable entry is skipped.
    init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      ledger =
        ((try? values.decodeIfPresent([Lossy<Entry>].self, forKey: .ledger)) ?? [])
        .compactMap(\.value)
      lastQuit = try? values.decodeIfPresent(Date.self, forKey: .lastQuit)
      spared = (try? values.decodeIfPresent(Set<String>.self, forKey: .spared)) ?? []
      reopenedAt = (try? values.decodeIfPresent([String: Date].self, forKey: .reopenedAt)) ?? [:]
      lastReopen = try? values.decodeIfPresent(Date.self, forKey: .lastReopen)
    }
  }

  struct Input: Sendable {
    let now: Date
    /// Memory pressure has held for `AutoPausePlanner.pressureSustain` (its clocks, this tick).
    let pressure: Bool
    /// Memory has been calm for `AutoPausePlanner.calmAfter`.
    let calm: Bool
    /// A session or dev-server candidate the auto-pause planner could still pause.
    let othersPending: Bool
    /// The auto-pause planner's latest pressure pause. Meeting pauses don't set it.
    let lastPause: Date?
    /// Running apps Tamebar may act on (in e2e mode, only the test's own).
    let apps: [App]
    /// Bundle ids running now, all of them: a ledger app here was reopened by the user.
    let running: Set<String>
    /// Bundle ids whose quit is in flight.
    let quitting: Set<String>
    let list: AppQuitList
    /// The running Tamebar's bundle id. No Tamebar build is ever quit (`AppBrand.isOwn`).
    let selfBundleID: String?
    let state: State
    /// A meeting is on (`MeetingMonitor`): nothing is quit.
    var inMeeting = false
  }

  enum Step: Equatable, Sendable {
    case quit(App)
    case reopen(Entry)
  }

  struct Output: Sendable {
    let steps: [Step]
    let state: State
  }

  /// How a reopen ended.
  enum ReopenResult: Equatable, Sendable {
    case opened
    /// No bundle at the recorded path and none LaunchServices knows by its id.
    case gone
    case failed
  }

  static func plan(_ input: Input) -> Output {
    var state = input.state
    let now = input.now
    rebase(&state, now)
    reconcile(&state, input)
    if input.calm && state.ledger.isEmpty { state.spared = [] }
    var steps: [Step] = []
    if input.calm, state.lastReopen.map({ now.timeIntervalSince($0) >= pressureSpacing }) ?? true,
      let oldest = state.ledger.filter(\.confirmed).min(by: { $0.quitAt < $1.quitAt })
    {
      state.ledger.removeAll { $0.bundleID == oldest.bundleID }
      state.reopenedAt[oldest.bundleID] = now
      state.lastReopen = now
      steps.append(.reopen(oldest))
    }
    if let app = nextQuit(state, input) {
      steps.append(.quit(app))
      state.ledger.append(
        .init(
          bundleID: app.bundleID, name: app.name, bundleURL: app.bundleURL,
          memoryBytes: app.memoryBytes, quitAt: now))
      state.lastQuit = now
    }
    return Output(steps: steps, state: state)
  }

  /// Dates a backward clock jump left in the future come back to now; reopens older than
  /// `requitAfter` are forgotten.
  private static func rebase(_ state: inout State, _ now: Date) {
    state.lastQuit = state.lastQuit.map { min($0, now) }
    state.lastReopen = state.lastReopen.map { min($0, now) }
    state.ledger = state.ledger.map { $0.quitAt > now ? $0.with(quitAt: now) : $0 }
    state.reopenedAt = state.reopenedAt.mapValues { min($0, now) }
      .filter { now.timeIntervalSince($0.value) < requitAfter }
  }

  /// The user wins: a confirmed ledger app running again was reopened by them, so it leaves the
  /// ledger and isn't quit again this episode. A quit no longer in flight that never confirmed
  /// (Tamebar ended mid-quit) is settled by what runs: still running, it is left alone.
  private static func reconcile(_ state: inout State, _ input: Input) {
    var kept: [Entry] = []
    for var entry in state.ledger {
      let running = input.running.contains(entry.bundleID)
      if entry.confirmed || !input.quitting.contains(entry.bundleID) {
        if running {
          state.spared.insert(entry.bundleID)
          continue
        }
        entry.confirmed = true
      }
      kept.append(entry)
    }
    state.ledger = kept
  }

  /// The largest app that may be quit now, if this tick may quit one.
  private static func nextQuit(_ state: State, _ input: Input) -> App? {
    let now = input.now
    let latest = [state.lastQuit, input.lastPause].compactMap { $0 }.max()
    guard input.pressure, !input.calm, !input.othersPending, !input.inMeeting,
      latest.map({ now.timeIntervalSince($0) >= pressureSpacing }) ?? true
    else { return nil }
    let taken = Set(state.ledger.map(\.bundleID)).union(state.spared).union(input.quitting)
      .union(state.reopenedAt.keys)
    return input.apps
      .filter { app in
        input.list.contains(app.bundleID)
          && !AppBrand.isOwn(app.bundleID, running: input.selfBundleID)
          && !app.isFrontmost && app.usesMicOrCamera == false && !app.isProtected
          && !app.keepRunning && app.quiet && !taken.contains(app.bundleID)
      }
      .max {
        $0.memoryBytes == $1.memoryBytes
          ? $0.bundleID > $1.bundleID : $0.memoryBytes < $1.memoryBytes
      }
  }
}

extension AppPressurePlanner.State {
  /// A quit landed. Done when the app ended; otherwise (still running after `quitTimeout`, or
  /// refused) it leaves the ledger and is left alone this episode. Never forced.
  mutating func quitLanded(_ bundleID: String, at: Date, ended: Bool) {
    guard let index = ledger.firstIndex(where: { $0.bundleID == bundleID && $0.quitAt == at })
    else { return }
    if ended {
      ledger[index].confirmed = true
    } else {
      ledger.remove(at: index)
      spared.insert(bundleID)
    }
  }

  /// A reopen landed. A gone app is dropped. Any other failure goes back in the ledger, to be
  /// tried again after `pressureSpacing`, until `reopenTries` failures: then it is dropped and
  /// returned, for the note.
  @discardableResult
  mutating func reopenLanded(
    _ entry: AppPressurePlanner.Entry, _ result: AppPressurePlanner.ReopenResult
  )
    -> AppPressurePlanner.Entry?
  {
    switch result {
    case .opened:
      return nil
    case .gone:
      reopenedAt[entry.bundleID] = nil
      return nil
    case .failed:
      var retry = entry
      retry.reopenAttempts += 1
      guard retry.reopenAttempts < AppPressurePlanner.reopenTries else {
        reopenedAt[entry.bundleID] = nil
        return retry
      }
      ledger.append(retry)
      return nil
    }
  }

  /// At launch: a ledger left by a run that didn't reopen it is kept only when that run ticked
  /// less than `staleAfter` ago. Returns the entries dropped.
  mutating func dropStale(lastTick: Date?, now: Date) -> [AppPressurePlanner.Entry] {
    guard !ledger.isEmpty,
      lastTick.map({ now.timeIntervalSince($0) >= AppPressurePlanner.staleAfter }) ?? true
    else { return [] }
    let dropped = ledger
    ledger = []
    return dropped
  }

  /// Quitting: every ledger app is handed to `open` and forgotten.
  mutating func takeAllForQuit() -> [AppPressurePlanner.Entry] {
    let all = ledger.sorted { $0.quitAt < $1.quitAt }
    ledger = []
    return all
  }
}
