import Foundation

// The daily usage record (decisions Q16): per local day, how much of the awake, in-use time the
// Mac spent under memory pressure, with swap, CPU, heat, the AI sessions and what Tamebar did. It
// is built from the readings Tamebar already takes, kept a year in `usage-daily.json`, and read by
// `tamebar trend` and the Trend card on the window's Activity tab. Pure: the readings come in,
// the days go out.

/// What Tamebar did on its own in a day, and the memory those actions freed where they say.
struct UsageActions: Codable, Equatable, Sendable {
  var paused = 0
  /// Busy sessions the work queue stopped under memory pressure (Q14). Read from the days before
  /// Q19 removed the queue (2026-10-30); nothing adds to it now.
  var queued = 0
  var ended = 0
  var quit = 0
  var slowed = 0
  var freedBytes: UInt64 = 0

  var isEmpty: Bool { paused + queued + ended + quit + slowed == 0 }

  init() {}

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    paused = container.lenient(Int.self, .paused) ?? 0
    queued = container.lenient(Int.self, .queued) ?? 0
    ended = container.lenient(Int.self, .ended) ?? 0
    quit = container.lenient(Int.self, .quit) ?? 0
    slowed = container.lenient(Int.self, .slowed) ?? 0
    freedBytes = container.lenient(UInt64.self, .freedBytes) ?? 0
  }

  static func + (lhs: Self, rhs: Self) -> Self {
    var sum = lhs
    sum.paused += rhs.paused
    sum.queued += rhs.queued
    sum.ended += rhs.ended
    sum.quit += rhs.quit
    sum.slowed += rhs.slowed
    sum.freedBytes += rhs.freedBytes
    return sum
  }
}

/// One local day. Durations are seconds and averages are kept as sums (value × seconds), so a day
/// merges exactly across flushes and relaunches; the derived values are computed on read.
struct UsageDay: Codable, Equatable, Sendable {
  /// The local calendar day, `yyyy-MM-dd`.
  var day: String
  /// Imported from `resource-history.json` on the first run: memory and CPU percentages only, no
  /// presence, pressure levels, swap, sessions or actions.
  var baseline = false
  /// The Mac awake with Tamebar running, present or not.
  var awakeSeconds: Double = 0
  /// Awake with the user present (Q5: not locked, input in the last 10 min).
  var inUseSeconds: Double = 0
  /// In-use time with memory pressure at warning, and at critical (`PressureAssessment.memoryRisk`).
  var warningSeconds: Double = 0
  var criticalSeconds: Double = 0
  /// In-use time with the CPU saturated (`cpuStrained`: 90 % for 15 s).
  var cpuSaturatedSeconds: Double = 0
  /// In-use time with macOS's thermal state serious or critical.
  var hotSeconds: Double = 0
  /// In-use time with the Mac struggling (Q19's strain); nil for a day recorded before it was.
  var strugglingSeconds: Double?
  var swapPeakBytes: UInt64?
  var swapByteSeconds: Double = 0
  var swapSeconds: Double = 0
  var availableLowestBytes: UInt64?
  /// RAM in use, 0–100.
  var memoryPeakPercent: Double?
  var memoryPercentSeconds: Double = 0
  var memorySeconds: Double = 0
  /// 0–100 across all cores.
  var cpuPeakPercent: Double?
  var cpuPercentSeconds: Double = 0
  var cpuSeconds: Double = 0
  var sessionsPeak: Int?
  var sessionCountSeconds: Double = 0
  var sessionMemoryPeakBytes: UInt64?
  var sessionMemoryByteSeconds: Double = 0
  var sessionSeconds: Double = 0
  var actions = UsageActions()
  /// Q17.2: the apps among the three using the most memory while memory was under pressure, by
  /// bundle id, with the half-hours of the day (0–47) it happened in. Kept `AppSuggestions.keptDays`.
  var pressureTops: [String: [Int]] = [:]

  init(day: String, baseline: Bool = false) {
    self.day = day
    self.baseline = baseline
  }

  /// Every field but the day is optional, so a file from another build still loads.
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    day = try c.decode(String.self, forKey: .day)
    baseline = c.lenient(Bool.self, .baseline) ?? false
    awakeSeconds = c.lenient(Double.self, .awakeSeconds) ?? 0
    inUseSeconds = c.lenient(Double.self, .inUseSeconds) ?? 0
    warningSeconds = c.lenient(Double.self, .warningSeconds) ?? 0
    criticalSeconds = c.lenient(Double.self, .criticalSeconds) ?? 0
    cpuSaturatedSeconds = c.lenient(Double.self, .cpuSaturatedSeconds) ?? 0
    hotSeconds = c.lenient(Double.self, .hotSeconds) ?? 0
    strugglingSeconds = c.lenient(Double.self, .strugglingSeconds)
    swapPeakBytes = c.lenient(UInt64.self, .swapPeakBytes)
    swapByteSeconds = c.lenient(Double.self, .swapByteSeconds) ?? 0
    swapSeconds = c.lenient(Double.self, .swapSeconds) ?? 0
    availableLowestBytes = c.lenient(UInt64.self, .availableLowestBytes)
    memoryPeakPercent = c.lenient(Double.self, .memoryPeakPercent)
    memoryPercentSeconds = c.lenient(Double.self, .memoryPercentSeconds) ?? 0
    memorySeconds = c.lenient(Double.self, .memorySeconds) ?? 0
    cpuPeakPercent = c.lenient(Double.self, .cpuPeakPercent)
    cpuPercentSeconds = c.lenient(Double.self, .cpuPercentSeconds) ?? 0
    cpuSeconds = c.lenient(Double.self, .cpuSeconds) ?? 0
    sessionsPeak = c.lenient(Int.self, .sessionsPeak)
    sessionCountSeconds = c.lenient(Double.self, .sessionCountSeconds) ?? 0
    sessionMemoryPeakBytes = c.lenient(UInt64.self, .sessionMemoryPeakBytes)
    sessionMemoryByteSeconds = c.lenient(Double.self, .sessionMemoryByteSeconds) ?? 0
    sessionSeconds = c.lenient(Double.self, .sessionSeconds) ?? 0
    actions = c.lenient(UsageActions.self, .actions) ?? UsageActions()
    pressureTops = c.lenient([String: [Int]].self, .pressureTops) ?? [:]
  }

  // MARK: Derived

  var pressureSeconds: Double { warningSeconds + criticalSeconds }
  /// The headline: the share of in-use time under memory pressure, 0–1. Nil without in-use time.
  var pressureShare: Double? {
    baseline || inUseSeconds <= 0 ? nil : min(1, pressureSeconds / inUseSeconds)
  }
  var criticalShare: Double? {
    baseline || inUseSeconds <= 0 ? nil : min(1, criticalSeconds / inUseSeconds)
  }
  /// The share of in-use time the Mac was struggling, 0–1; nil without in-use time or a strain
  /// recorded.
  var strugglingShare: Double? {
    guard !baseline, inUseSeconds > 0, let strugglingSeconds else { return nil }
    return min(1, strugglingSeconds / inUseSeconds)
  }
  var swapAverageBytes: UInt64? {
    swapSeconds > 0 ? UInt64(max(0, swapByteSeconds / swapSeconds)) : nil
  }
  var memoryAveragePercent: Double? {
    memorySeconds > 0 ? memoryPercentSeconds / memorySeconds : nil
  }
  var cpuAveragePercent: Double? { cpuSeconds > 0 ? cpuPercentSeconds / cpuSeconds : nil }
  var sessionsAverage: Double? { sessionSeconds > 0 ? sessionCountSeconds / sessionSeconds : nil }
  var sessionMemoryAverageBytes: UInt64? {
    sessionSeconds > 0 ? UInt64(max(0, sessionMemoryByteSeconds / sessionSeconds)) : nil
  }
  /// A live day the Mac was in use: it has a pressure share.
  var hasUse: Bool { !baseline && inUseSeconds > 0 }
  /// Anything to show: a live day with awake time, or a baseline day.
  var hasData: Bool { baseline ? memorySeconds > 0 : awakeSeconds > 0 }
}

extension KeyedDecodingContainer {
  /// The value, or nil when it is absent or of another type: one odd field never fails the day.
  func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
    (try? decodeIfPresent(type, forKey: key)) ?? nil
  }
}

/// One reading of the Mac, as the app's 2-second pressure tick sees it.
struct UsageReading: Equatable, Sendable {
  var date: Date
  /// The user is at the Mac (Q5).
  var present: Bool
  /// Memory pressure, as automatic pause plans from it (`PressureAssessment.memoryRisk`).
  var risk: MemoryRisk = .normal
  var cpuStrained = false
  var hot = false
  /// The Mac struggling (Q19); nil where the strain isn't judged.
  var struggling: Bool?
  var swapBytes: UInt64?
  var availableBytes: UInt64?
  /// RAM in use, 0–100.
  var memoryPercent: Double?
  /// 0–100 across all cores.
  var cpuPercent: Double?
  /// The AI sessions of the latest scan; nil before the first scan.
  var sessions: Int?
  var sessionBytes: UInt64?
}

/// What one automatic action adds to its day.
enum UsageAction: Equatable, Sendable {
  case paused(count: Int, freedBytes: UInt64)
  case ended(freedBytes: UInt64)
  case quit(freedBytes: UInt64)
  case slowed(count: Int)

  var actions: UsageActions {
    var actions = UsageActions()
    switch self {
    case .paused(let count, let freed):
      actions.paused = count
      actions.freedBytes = freed
    case .ended(let freed):
      actions.ended = 1
      actions.freedBytes = freed
    case .quit(let freed):
      actions.quit = 1
      actions.freedBytes = freed
    case .slowed(let count):
      actions.slowed = count
    }
    return actions
  }
}

/// Local calendar days, by key.
enum UsageCalendar {
  static func key(_ date: Date, _ calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  /// The start of a day key, in the calendar's time zone.
  static func start(_ key: String, _ calendar: Calendar) -> Date? {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
  }

  /// The day key `offset` days from `key`.
  static func adding(_ offset: Int, to key: String, _ calendar: Calendar) -> String? {
    guard let start = start(key, calendar),
      let moved = calendar.date(byAdding: .day, value: offset, to: start)
    else { return nil }
    return Self.key(moved, calendar)
  }

  /// `Oct 29`.
  static func short(_ key: String, _ calendar: Calendar) -> String {
    guard let start = start(key, calendar) else { return key }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "MMM d"
    return formatter.string(from: start)
  }
}

/// The whole record, as `usage-daily.json` holds it.
struct UsageRecord: Codable, Equatable, Sendable {
  static let version = 1
  /// A year of days; older ones are dropped.
  static let retentionDays = 366
  /// A longer gap between two readings is sleep or Tamebar not running: not awake time.
  static let maximumGap: TimeInterval = 60

  var version = UsageRecord.version
  /// Oldest first, one per local day.
  var days: [UsageDay] = []
  /// `resource-history.json` was imported as the baseline (or there was nothing to import).
  var baselineImported = false
  /// The Tamebar build that last ran (`UsageBuild.label`), to mark a new version.
  var build: String?
  /// The automatic settings at the last flush, to mark a change.
  var settings: UsageSettings?
  /// `memory-history.json`'s pressure events were taken into `pressureTops` (Q17.2), once.
  var topsImported = false

  init() {}

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = c.lenient(Int.self, .version) ?? UsageRecord.version
    days = (c.lenient([Lossy<UsageDay>].self, .days) ?? []).compactMap(\.value)
      .sorted { $0.day < $1.day }
    baselineImported = c.lenient(Bool.self, .baselineImported) ?? false
    build = c.lenient(String.self, .build)
    settings = c.lenient(UsageSettings.self, .settings)
    topsImported = c.lenient(Bool.self, .topsImported) ?? false
  }

  // MARK: Accumulation

  /// Adds the time from `previous` to `reading` at `previous`'s state, split at each local
  /// midnight (a DST day is 23 or 25 hours, as the calendar says), then takes `reading`'s peaks.
  /// A gap over `maximumGap`, or a clock that went back, adds no time.
  mutating func observe(_ reading: UsageReading, after previous: UsageReading?, calendar: Calendar)
  {
    if let previous {
      let gap = reading.date.timeIntervalSince(previous.date)
      if gap > 0, gap <= Self.maximumGap {
        var start = previous.date
        while start < reading.date {
          let dayStart = calendar.startOfDay(for: start)
          let next =
            calendar.date(byAdding: .day, value: 1, to: dayStart) ?? reading.date
          let end = min(reading.date, next > start ? next : reading.date)
          let key = UsageCalendar.key(start, calendar)
          update(key) { $0.add(end.timeIntervalSince(start), at: previous) }
          start = end
        }
      }
    }
    update(UsageCalendar.key(reading.date, calendar)) { $0.peak(reading) }
  }

  mutating func record(_ action: UsageAction, at date: Date, calendar: Calendar) {
    update(UsageCalendar.key(date, calendar)) { $0.actions = $0.actions + action.actions }
  }

  /// Drops days older than a year before `now`, and the pressure tops older than
  /// `AppSuggestions.keptDays`.
  mutating func prune(now: Date, calendar: Calendar) {
    guard let oldest = calendar.date(byAdding: .day, value: -(Self.retentionDays - 1), to: now)
    else { return }
    let cutoff = UsageCalendar.key(oldest, calendar)
    days.removeAll { $0.day < cutoff }
    if let tops = calendar.date(byAdding: .day, value: -AppSuggestions.keptDays, to: now) {
      let topsCutoff = UsageCalendar.key(tops, calendar)
      for index in days.indices where days[index].day < topsCutoff {
        days[index].pressureTops = [:]
      }
    }
  }

  /// Q17.2: these apps were among the three using the most memory under memory pressure at
  /// `date`. Each counts once per half-hour.
  mutating func recordTops(_ bundleIDs: [String], at date: Date, calendar: Calendar) {
    guard !bundleIDs.isEmpty else { return }
    let slot = AppSuggestions.slot(date, calendar)
    update(UsageCalendar.key(date, calendar)) { day in
      for id in bundleIDs {
        var slots = day.pressureTops[id] ?? []
        guard !slots.contains(slot) else { continue }
        slots.append(slot)
        day.pressureTops[id] = slots.sorted()
      }
    }
  }

  /// Takes `memory-history.json`'s pressure events in once, so suggestions start from the day
  /// Tamebar already kept.
  mutating func importTops(_ events: [(date: Date, bundleIDs: [String])], calendar: Calendar) {
    defer { topsImported = true }
    guard !topsImported else { return }
    for event in events { recordTops(event.bundleIDs, at: event.date, calendar: calendar) }
  }

  /// Adds the baseline days that aren't already recorded, once.
  mutating func importBaseline(_ baseline: [UsageDay]) {
    defer { baselineImported = true }
    guard !baselineImported else { return }
    let known = Set(days.map(\.day))
    days.append(contentsOf: baseline.filter { !known.contains($0.day) })
    days.sort { $0.day < $1.day }
  }

  private mutating func update(_ key: String, _ change: (inout UsageDay) -> Void) {
    if let index = days.lastIndex(where: { $0.day == key }) {
      change(&days[index])
      return
    }
    var day = UsageDay(day: key)
    change(&day)
    days.append(day)
    days.sort { $0.day < $1.day }
  }
}

extension UsageDay {
  /// `seconds` spent in `state`: awake always, the counters only while in use.
  fileprivate mutating func add(_ seconds: Double, at state: UsageReading) {
    guard seconds > 0 else { return }
    baseline = false
    awakeSeconds += seconds
    if state.present {
      inUseSeconds += seconds
      if state.risk == .warning { warningSeconds += seconds }
      if state.risk == .critical { criticalSeconds += seconds }
      if state.cpuStrained { cpuSaturatedSeconds += seconds }
      if state.hot { hotSeconds += seconds }
      if let struggling = state.struggling {
        strugglingSeconds = (strugglingSeconds ?? 0) + (struggling ? seconds : 0)
      }
    }
    if let swap = state.swapBytes {
      swapByteSeconds += Double(swap) * seconds
      swapSeconds += seconds
    }
    if let memory = state.memoryPercent {
      memoryPercentSeconds += memory * seconds
      memorySeconds += seconds
    }
    if let cpu = state.cpuPercent {
      cpuPercentSeconds += cpu * seconds
      cpuSeconds += seconds
    }
    if let sessions = state.sessions {
      sessionCountSeconds += Double(sessions) * seconds
      sessionMemoryByteSeconds += Double(state.sessionBytes ?? 0) * seconds
      sessionSeconds += seconds
    }
  }

  fileprivate mutating func peak(_ reading: UsageReading) {
    if let swap = reading.swapBytes { swapPeakBytes = max(swapPeakBytes ?? 0, swap) }
    if let available = reading.availableBytes {
      availableLowestBytes = min(availableLowestBytes ?? .max, available)
    }
    if let memory = reading.memoryPercent {
      memoryPeakPercent = max(memoryPeakPercent ?? 0, memory)
    }
    if let cpu = reading.cpuPercent { cpuPeakPercent = max(cpuPeakPercent ?? 0, cpu) }
    if let sessions = reading.sessions { sessionsPeak = max(sessionsPeak ?? 0, sessions) }
    if let bytes = reading.sessionBytes {
      sessionMemoryPeakBytes = max(sessionMemoryPeakBytes ?? 0, bytes)
    }
  }
}

/// The first run's baseline: `resource-history.json`'s week of memory and CPU percentages, as
/// days before today. Each sample stands for the time to the next one, at most its five minutes.
enum UsageBaseline {
  static func days(_ samples: [ResourceSample], before today: String, calendar: Calendar)
    -> [UsageDay]
  {
    let sorted = samples.sorted { $0.date < $1.date }
    var days: [String: UsageDay] = [:]
    for (index, sample) in sorted.enumerated() {
      let key = UsageCalendar.key(sample.date, calendar)
      guard key < today else { continue }
      let next = index + 1 < sorted.count ? sorted[index + 1].date : nil
      let weight = min(300, max(1, next.map { $0.timeIntervalSince(sample.date) } ?? 300))
      var day = days[key] ?? UsageDay(day: key, baseline: true)
      let memory = min(100, max(0, sample.memory * 100))
      day.memoryPeakPercent = max(day.memoryPeakPercent ?? 0, memory)
      day.memoryPercentSeconds += memory * weight
      day.memorySeconds += weight
      if let cpu = sample.cpu.map({ min(100, max(0, $0 * 100)) }) {
        day.cpuPeakPercent = max(day.cpuPeakPercent ?? 0, cpu)
        day.cpuPercentSeconds += cpu * weight
        day.cpuSeconds += weight
      }
      days[key] = day
    }
    return days.values.sorted { $0.day < $1.day }
  }
}

/// The automatic settings, to mark when one is switched (Q16).
struct UsageSettings: Codable, Equatable, Sendable {
  /// "Unused AI sessions": `ask`, or `auto` after `autoEndDays`.
  var autoEnd: String
  var autoEndDays: Int
  /// Q11's apps, by bundle id, sorted.
  var quitApps: [String]
  /// Projects paused automatically under pressure, by folder, sorted.
  var autoPauseProjects: [String]
  /// Apps with "Slow in background" unticked (Q17.1), by bundle id, sorted.
  var slowOptOut: [String] = []
  /// P2's switches; nil in a record from before them, which marks nothing.
  var endIdleSessions: Bool? = nil
  var trimCodexPlugins: Bool? = nil

  /// One marker text per change, such as "Auto-end after 7 days" or "Quit under pressure: + Loom".
  /// `name` names an app by bundle id.
  static func changes(from old: Self, to new: Self, name: (String) -> String) -> [String] {
    var texts: [String] = []
    if old.autoEnd != new.autoEnd || (new.autoEnd == "auto" && old.autoEndDays != new.autoEndDays) {
      texts.append(
        new.autoEnd == "auto"
          ? "Auto-end after \(new.autoEndDays) \(new.autoEndDays == 1 ? "day" : "days")"
          : "Auto-end off (Ask me)")
    }
    let added = new.quitApps.filter { !old.quitApps.contains($0) }.map(name)
    let removed = old.quitApps.filter { !new.quitApps.contains($0) }.map(name)
    if !added.isEmpty || !removed.isEmpty {
      texts.append("Quit under pressure: " + list(added: added, removed: removed))
    }
    let project = { (path: String) in URL(fileURLWithPath: path).lastPathComponent }
    let paused = new.autoPauseProjects.filter { !old.autoPauseProjects.contains($0) }.map(project)
    let unpaused = old.autoPauseProjects.filter { !new.autoPauseProjects.contains($0) }
      .map(project)
    if !paused.isEmpty || !unpaused.isEmpty {
      texts.append("Auto-pause: " + list(added: paused, removed: unpaused))
    }
    // Unticking "Slow in background" takes the app out of the slowing: "−".
    let unslowed = new.slowOptOut.filter { !old.slowOptOut.contains($0) }.map(name)
    let slowed = old.slowOptOut.filter { !new.slowOptOut.contains($0) }.map(name)
    if !slowed.isEmpty || !unslowed.isEmpty {
      texts.append("Slow in background: " + list(added: slowed, removed: unslowed))
    }
    if let was = old.endIdleSessions, let now = new.endIdleSessions, was != now {
      texts.append("End idle sessions: \(now ? "on" : "off")")
    }
    if let was = old.trimCodexPlugins, let now = new.trimCodexPlugins, was != now {
      texts.append("Turn off unused Codex plugins: \(now ? "on" : "off")")
    }
    return texts
  }

  private static func list(added: [String], removed: [String]) -> String {
    (added.map { "+ \($0)" } + removed.map { "− \($0)" }).joined(separator: ", ")
  }
}

extension UsageSettings {
  /// A record from before Q17 has no `slowOptOut`: none was unticked.
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    autoEnd = try c.decode(String.self, forKey: .autoEnd)
    autoEndDays = try c.decode(Int.self, forKey: .autoEndDays)
    quitApps = try c.decode([String].self, forKey: .quitApps)
    autoPauseProjects = try c.decode([String].self, forKey: .autoPauseProjects)
    slowOptOut = c.lenient([String].self, .slowOptOut) ?? []
    endIdleSessions = c.lenient(Bool.self, .endIdleSessions)
    trimCodexPlugins = c.lenient(Bool.self, .trimCodexPlugins)
  }
}

/// The running build, for the version marker: `0.1.0 · 4f3a2b1`, or the version alone.
enum UsageBuild {
  static func label(version: String, commit: String?) -> String {
    guard let commit, !commit.isEmpty else { return version }
    return "\(version) · \(commit)"
  }
}

/// `usage-daily.json`: written by the app only, atomically; an unreadable file is kept aside.
struct UsageStore {
  static let fileName = "usage-daily.json"
  /// A year of days is about 250 KB.
  static let maximumBytes = 2 * 1_024 * 1_024
  let url: URL

  init(directory: URL) {
    url = directory.appendingPathComponent(Self.fileName)
  }

  /// The saved record; none when the file is missing. An unreadable one is moved aside as
  /// `usage-daily.json.unreadable-<seconds>` and the record starts empty.
  func load(now: Date = .now) -> UsageRecord? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    if data.count <= Self.maximumBytes,
      let record = try? JSONDecoder().decode(UsageRecord.self, from: data)
    {
      return record
    }
    let aside = url.deletingLastPathComponent().appendingPathComponent(
      "\(Self.fileName).unreadable-\(Int(now.timeIntervalSince1970))")
    try? FileManager.default.moveItem(at: url, to: aside)
    return UsageRecord()
  }

  func save(_ record: UsageRecord) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(record), data.count <= Self.maximumBytes else { return }
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
