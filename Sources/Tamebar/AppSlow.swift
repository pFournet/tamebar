import Foundation

/// Slow background apps that burn CPU (Q17.1, amends Q12): an app that isn't in front and uses
/// more than `threshold` CPU for `sustain` in a row gets Q12's lever, Darwin background priority,
/// on its busy processes. It keeps running. It is restored as soon as it comes to the front, or
/// once its CPU has stayed under `calmBelow` for `calmAfter` (the hysteresis: an app hovering at
/// the threshold is neither slowed and restored in a loop). Once one app's trigger fires, every
/// other app busy in the background now (over `threshold`, not excluded) is slowed in the same
/// tick, without waiting for its own `sustain` (Q19: freed at once, no spacing between apps).
/// Never macOS's own apps (Finder, Music,
/// Safari): no system process is ever slowed (`SystemExecutable`). Pure; `BackgroundPriorityController`
/// applies it through the same ledger as Q12, so restore on quit, at the next launch and the e2e
/// scope all hold.
///
/// An app's CPU is its row on the CPU page: every process of its bundle (helpers, renderers,
/// XPC services), without AI sessions' processes. Those are Q12's and Q13's (a session's heavy
/// children), and Codex desktop workers are never a target (Q1: the ChatGPT app owns them, and
/// they are AI sessions here). The app's own Codex host (`codex app-server`) is an agent, so it
/// is never slowed either: the workers it forks would inherit background.
enum AppSlow {
  /// Above this, in percent of one core summed over the app's row, the app is busy.
  static let threshold: Double = 150
  /// Busy this long in a row, in the background, before it is slowed.
  static let sustain: TimeInterval = 120
  /// The run breaks only once the app has been at or under `threshold` this long: `ps` reads a
  /// starved process low now and then, and one low reading isn't the app calming down.
  static let dipAllowance: TimeInterval = 15
  /// Under this for `calmAfter` in a row, a slowed app is restored.
  static let calmBelow: Double = 50
  static let calmAfter: TimeInterval = 60
  /// A process of a busy app at or above this is slowed. Lower than Q12's per-process bar: an
  /// app spreads its load over many helpers.
  static let heavyCPU: Double = 10
  /// An app slowed in this window stays in Settings' apps list.
  static let recentFor: TimeInterval = 7 * 86_400

  /// The AI apps Q17.3 quits only once quiet. `com.openai.codex` is the ChatGPT app on this Mac
  /// (checked 2026-10-29: `id of app "ChatGPT"`); `com.openai.chat` is its earlier id.
  static let aiApps: Set<String> = [
    "com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop",
  ]

  static func isAIApp(_ bundleID: String) -> Bool { aiApps.contains(bundleID) }

  /// A running app with a regular activation policy, as one scan sees it.
  struct App: Equatable, Sendable {
    /// Its row on the Memory and CPU pages, `app:<bundle name>`: the ledger's group.
    let group: String
    let bundleID: String
    let name: String
    let cpuPercent: Double
    /// Its busy processes (`heavy`), the ones to slow.
    let processIDs: [Int32]
    var isFrontmost = false
    /// Nil when unknown, which counts as in use (Q11's rule).
    var usesMicOrCamera: Bool? = false
    /// "Slow in background" unticked in Settings.
    var optedOut = false
    /// Tamebar itself.
    var isOwn = false
    /// macOS's own app (Finder, Music, Safari): never slowed.
    var isSystem = false

    var excluded: Bool {
      isFrontmost || usesMicOrCamera != false || optedOut || isOwn || isSystem
    }
  }

  /// The per-app clocks, by group. In memory only: a relaunch restores what was slowed instead.
  struct Clock: Equatable, Sendable {
    var above: [String: Date] = [:]
    /// Since when a busy app has read at or under the threshold.
    var below: [String: Date] = [:]
    var calm: [String: Date] = [:]
    var lastTick: Date?
  }

  struct Plan: Equatable, Sendable {
    /// Busy for two minutes: slow now, with a note.
    var start: [App] = []
    /// Already slowed and not calm yet: busy processes that appeared since are slowed too.
    var hold: [App] = []
    /// Groups to restore: in front, on a call, opted out, calm, or gone.
    var restore: [String] = []
  }

  static func plan(_ clock: inout Clock, now: Date, apps: [App], slowed: Set<String>) -> Plan {
    clock.above = clock.above.mapValues { min($0, now) }
    clock.below = clock.below.mapValues { min($0, now) }
    clock.calm = clock.calm.mapValues { min($0, now) }
    if let last = clock.lastTick, now.timeIntervalSince(last) > AutoPausePlanner.wakeGap {
      clock.above = [:]
      clock.below = [:]
      clock.calm = [:]
    }
    clock.lastTick = now
    var plan = Plan()
    var seen: Set<String> = []
    // Busy in the background now, not slowed, its own `sustain` not reached yet: slowed with the
    // first one whose trigger fires (Q19).
    var alsoBusy: [App] = []
    for app in apps where seen.insert(app.group).inserted {
      let group = app.group
      let isSlowed = slowed.contains(group)
      guard !app.excluded else {
        clock.above[group] = nil
        clock.below[group] = nil
        clock.calm[group] = nil
        if isSlowed { plan.restore.append(group) }
        continue
      }
      let busy = app.cpuPercent > threshold
      if busy {
        clock.calm[group] = nil
        clock.below[group] = nil
        clock.above[group] = clock.above[group] ?? now
      } else {
        let below = clock.below[group] ?? now
        clock.below[group] = clock.above[group] == nil ? nil : below
        if now.timeIntervalSince(below) >= dipAllowance {
          clock.above[group] = nil
          clock.below[group] = nil
        }
        clock.calm[group] = app.cpuPercent < calmBelow ? clock.calm[group] ?? now : nil
      }
      if isSlowed {
        if let calm = clock.calm[group], now.timeIntervalSince(calm) >= calmAfter {
          clock.calm[group] = nil
          plan.restore.append(group)
        } else {
          plan.hold.append(app)
        }
      } else if busy, let above = clock.above[group], now.timeIntervalSince(above) >= sustain {
        plan.start.append(app)
      } else if busy {
        alsoBusy.append(app)
      }
    }
    if !plan.start.isEmpty { plan.start += alsoBusy }
    for group in slowed.sorted() where !seen.contains(group) { plan.restore.append(group) }
    clock.above = clock.above.filter { seen.contains($0.key) }
    clock.below = clock.below.filter { seen.contains($0.key) }
    clock.calm = clock.calm.filter { seen.contains($0.key) }
    return plan
  }

  /// The processes of an app's row to slow: busy ones (`heavyCPU`), never an agent (the Codex
  /// host, a `claude`), nothing on a server's line (Q12's rule: a server never runs slowed).
  static func heavy(_ processIDs: [Int32], scan: HeavyChildren.Scan) -> [Int32] {
    let line = HeavyChildren.ServingLine(
      serving: scan.serving, parents: HeavyChildren.parents(scan.records))
    return processIDs.filter { pid in
      guard let record = scan.records[pid], record.cpuPercent >= heavyCPU else { return false }
      return !AIThreadGrouping.isAgent(record.arguments) && !line.touches(pid)
    }
  }

  /// The 4 s note when apps start being slowed: "Slowed ChatGPT · 490% CPU". No note when it
  /// ends.
  static func note(_ apps: [(name: String, cpu: Double)]) -> String? {
    guard let busiest = apps.max(by: { $0.cpu < $1.cpu }) else { return nil }
    let others = apps.count - 1
    let name =
      others == 0
      ? busiest.name : "\(busiest.name) and \(others) more \(others == 1 ? "app" : "apps")"
    return "Slowed \(name) · \(percent(busiest.cpu)) CPU"
  }

  static func percent(_ cpu: Double) -> String { "\(Int(cpu.rounded()))%" }
}

/// Each running app's CPU over the last scans (Q17): the recent peak shown in Settings, and
/// whether an AI app has been quiet long enough to quit (Q17.3). Pure; in memory only.
struct AppCPUWatch: Equatable, Sendable {
  /// Q17.3: an AI app is quit only under this, over its whole tree, for `quietFor`.
  static let quietBelow: Double = 5
  static let quietFor: TimeInterval = 5 * 60
  /// The peak shown in Settings is over this window.
  static let peakWindow: TimeInterval = 3_600

  struct Reading: Equatable, Sendable {
    /// The app's row, as the slow trigger reads it.
    let row: Double
    /// The row and every descendant of the app's processes, AI sessions included (a Codex task
    /// running in ChatGPT): what "quiet" reads.
    let tree: Double
  }

  private struct Sample: Equatable, Sendable {
    let at: Date
    let cpu: Double
  }

  private(set) var quietSince: [String: Date] = [:]
  private var samples: [String: [Sample]] = [:]
  private var lastTick: Date?

  /// One scan's readings, by bundle id. An app missing from them isn't running.
  mutating func observe(now: Date, apps: [String: Reading]) {
    if let last = lastTick, now.timeIntervalSince(last) > AutoPausePlanner.wakeGap || now < last {
      quietSince = [:]
    }
    lastTick = now
    for (id, reading) in apps {
      quietSince[id] = reading.tree < Self.quietBelow ? quietSince[id] ?? now : nil
      var kept = (samples[id] ?? []).filter { now.timeIntervalSince($0.at) < Self.peakWindow }
      kept.append(.init(at: now, cpu: reading.row))
      samples[id] = kept
    }
    quietSince = quietSince.filter { apps[$0.key] != nil }
    samples = samples.filter { apps[$0.key] != nil }
  }

  /// Under `quietBelow` over its tree for `quietFor`, unbroken.
  func isQuiet(_ bundleID: String, now: Date) -> Bool {
    quietSince[bundleID].map { now.timeIntervalSince($0) >= Self.quietFor } ?? false
  }

  /// The highest row CPU seen in the last hour; nil when the app wasn't seen.
  func peak(_ bundleID: String, now: Date) -> Double? {
    samples[bundleID]?.filter { now.timeIntervalSince($0.at) < Self.peakWindow }.map(\.cpu).max()
  }
}

/// A running app as Q17 reads it, from `NSWorkspace.runningApplications`.
struct ScannedApp: Equatable, Sendable {
  let bundleID: String
  let name: String
  let processID: Int32
  let bundleURL: URL
  /// A regular activation policy: an app with a Dock icon and windows.
  let regular: Bool

  /// The outermost bundle's name: Docker for Docker's VM service, which lives inside Docker.app.
  var bundleName: String {
    ResourceOwnership.appName(bundleURL.path + "/")
      ?? bundleURL.deletingPathExtension().lastPathComponent
  }
  /// Its row on the Memory and CPU pages (`ResourceConsumers`).
  var group: String { "app:" + bundleName }
  /// Not a helper app inside another bundle.
  var isOutermost: Bool { !bundleURL.path.contains(".app/") }
}

extension AppSlow {
  struct Scan {
    let running: [ScannedApp]
    let consumers: [ResourceConsumer]
    let processes: HeavyChildren.Scan
    /// The front app's bundle id (the e2e control's in e2e mode).
    let frontmost: String?
    /// Q11's probe: nil unknown, which counts as in use.
    let usesMicOrCamera: (String) -> Bool?
    let optedOut: AppSlowOptOut
    let selfBundleID: String?
    let selfProcessID: Int32
    /// The e2e scope; always true outside e2e mode.
    var allows: (Int32) -> Bool = { _ in true }
  }

  /// One `App` per row with a regular app in it. A row stands for all its running apps: in
  /// front, on a call or opted out if any of them is.
  static func apps(_ scan: Scan) -> [App] {
    let rows = Dictionary(
      scan.consumers.filter { $0.kind == .app }.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first })
    let groups = Dictionary(grouping: scan.running, by: \.group)
    let front = scan.running.first { $0.bundleID == scan.frontmost }?.group
    return groups.keys.sorted().compactMap { group -> App? in
      guard let members = groups[group], let row = rows[group],
        let lead = members.first(where: \.isOutermost) ?? members.first(where: \.regular),
        members.contains(where: \.regular), scan.allows(lead.processID)
      else { return nil }
      let calls = members.map { scan.usesMicOrCamera($0.bundleID) }
      let mic: Bool? =
        calls.contains(true) ? true : calls.contains(where: { $0 == nil }) ? nil : false
      return App(
        group: group, bundleID: lead.bundleID,
        name: lead.isOutermost ? lead.name : lead.bundleName, cpuPercent: row.cpuPercent,
        processIDs: heavy(row.processIDs, scan: scan.processes).filter(scan.allows),
        isFrontmost: front == group, usesMicOrCamera: mic,
        optedOut: members.contains { scan.optedOut.contains($0.bundleID) },
        isOwn: members.contains {
          AppBrand.isOwn($0.bundleID, running: scan.selfBundleID)
            || $0.processID == scan.selfProcessID
        },
        isSystem: members.contains { SystemExecutable.isSystem($0.bundleURL.path + "/") })
    }
  }
}

extension AppCPUWatch {
  /// Each running app's readings: its row's CPU, and its tree's, every descendant of the row's
  /// processes and the app's own (AI sessions and Codex workers included).
  static func readings(
    running: [ScannedApp], consumers: [ResourceConsumer], records: [Int32: RawProcessRecord]
  ) -> [String: Reading] {
    let rows = Dictionary(
      consumers.filter { $0.kind == .app }.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first })
    let tree = LiveProcessTree(parents: records.mapValues(\.parentProcessID))
    var readings: [String: Reading] = [:]
    for app in running {
      let row = rows[app.group]
      let roots = Set((row?.processIDs ?? []) + [app.processID])
      let total = tree.descendants(roots).reduce(0) { $0 + (records[$1]?.cpuPercent ?? 0) }
      readings[app.bundleID] = .init(row: row?.cpuPercent ?? 0, tree: total)
    }
    return readings
  }
}

extension AppSuggestions {
  /// The bundle ids of the `top` app rows by memory. A row is named by its outermost bundle;
  /// `bundleID` resolves one with no app of its own running (a helper's).
  static func topBundleIDs(
    consumers: [ResourceConsumer], running: [ScannedApp], bundleID: (ScannedApp) -> String?
  ) -> [String] {
    let groups = Dictionary(grouping: running, by: \.group)
    let names = top(consumers.filter { $0.kind == .app }.map { ($0.name, $0.memoryBytes) })
    return names.compactMap { name in
      guard let members = groups["app:" + name] else { return nil }
      if let lead = members.first(where: \.isOutermost) { return lead.bundleID }
      return members.first.flatMap(bundleID)
    }
  }
}
