import Foundation

/// Q17.2: which apps keep topping memory under pressure, from the usage record's pressure tops
/// (fed on each scan under memory pressure, and once from `memory-history.json`'s pressure
/// events). Pure.
///
/// "Keeps topping": among the `top` apps using the most memory while memory was under pressure
/// (`PressureAssessment.memoryRisk` at warning or critical), in at least `minimumTimes` separate
/// half-hours over the last `windowDays` days. A half-hour counts once however long it lasts, so
/// one long or flapping episode counts once per half-hour, not once per reading.
enum AppSuggestions {
  static let top = 3
  static let minimumTimes = 3
  static let windowDays = 7
  /// The tops are dropped from older days.
  static let keptDays = 30
  static let slotLength: TimeInterval = 1_800

  /// The half-hour of the local day, 0–47 (a DST day has one more or one fewer).
  static func slot(_ date: Date, _ calendar: Calendar) -> Int {
    Int(date.timeIntervalSince(calendar.startOfDay(for: date)) / slotLength)
  }

  /// The names of the `top` apps by memory.
  static func top(_ apps: [(name: String, bytes: UInt64)]) -> [String] {
    apps.sorted { $0.bytes == $1.bytes ? $0.name < $1.name : $0.bytes > $1.bytes }
      .prefix(top).map(\.name)
  }

  /// The bundle ids that kept topping memory under pressure over the window ending today.
  static func suggested(_ days: [UsageDay], now: Date, calendar: Calendar) -> Set<String> {
    guard
      let first = calendar.date(byAdding: .day, value: -(windowDays - 1), to: now)
    else { return [] }
    let cutoff = UsageCalendar.key(first, calendar)
    var times: [String: Int] = [:]
    for day in days where day.day >= cutoff {
      for (id, slots) in day.pressureTops { times[id, default: 0] += Set(slots).count }
    }
    return Set(times.filter { $0.value >= minimumTimes }.keys)
  }
}

/// The apps the user doesn't want slowed in the background (Q17.1): bundle ids in UserDefaults
/// `apps.slowInBackground.off.v1`, unticked in Settings. Every other app may be slowed.
struct AppSlowOptOut: Equatable, Sendable {
  static let key = "apps.slowInBackground.off.v1"

  private(set) var bundleIDs: Set<String> = []

  init(_ bundleIDs: Set<String> = []) { self.bundleIDs = bundleIDs }

  func contains(_ bundleID: String) -> Bool { bundleIDs.contains(bundleID) }

  mutating func set(_ bundleID: String, slow: Bool) {
    if slow { bundleIDs.remove(bundleID) } else { bundleIDs.insert(bundleID) }
  }

  /// Where it is kept: `UserDefaults.standard` in the app, a closure pair in tests.
  struct Store {
    let read: () -> Any?
    let write: ([String]) -> Void

    static func defaults(_ defaults: UserDefaults) -> Store {
      .init(
        read: { defaults.object(forKey: AppSlowOptOut.key) },
        write: { defaults.set($0, forKey: AppSlowOptOut.key) })
    }
  }

  /// Tolerant: an array keeps its strings and skips the rest; anything else is an empty list.
  static func load(_ store: Store) -> AppSlowOptOut {
    let values = store.read() as? [Any] ?? []
    return AppSlowOptOut(Set(values.compactMap { $0 as? String }.filter { !$0.isEmpty }))
  }

  func save(_ store: Store) { store.write(bundleIDs.sorted()) }
}

/// Settings › Automatic actions › "Apps under pressure" (Q17, approved as mocked): one row per
/// app with "Slow in background" and "Quit under pressure". Pure.
enum AppsUnderPressure {
  struct Input: Equatable, Sendable {
    /// Q11's list.
    let quit: Set<String>
    /// "Slow in background" unticked.
    let optedOut: Set<String>
    let suggested: Set<String>
    /// Slowed in the last week (`AppSlow.recentFor`).
    let recent: Set<String>
    /// Added with "+ Add app", or ticked, while Settings shows: kept so a row never jumps away
    /// under the pointer.
    let added: Set<String>
  }

  /// What the Mac says about an app now.
  struct Info: Equatable, Sendable {
    let name: String
    /// Its row's memory while it runs; nil when it doesn't.
    let memoryBytes: UInt64?
    /// The highest CPU seen lately (the last hour, or its latest slow).
    let peakCPU: Double?
  }

  struct Row: Identifiable, Equatable, Sendable {
    let bundleID: String
    let name: String
    /// "6 GB · 490% CPU": the CPU only at or above the slow threshold; "Not running".
    let detail: String
    let slow: Bool
    let quit: Bool
    /// Keeps topping memory under pressure and isn't ticked yet.
    let suggested: Bool
    var id: String { bundleID }
  }

  /// The apps with a setting, the suggested ones, those slowed lately and those just added,
  /// by name.
  static func rows(_ input: Input, info: (String) -> Info) -> [Row] {
    let ids = input.quit.union(input.optedOut).union(input.suggested).union(input.recent)
      .union(input.added)
    return ids.map { id in
      let app = info(id)
      var detail = app.memoryBytes.map(ByteText.compact) ?? "Not running"
      if let cpu = app.peakCPU, cpu >= AppSlow.threshold {
        detail += " · \(AppSlow.percent(cpu)) CPU"
      }
      let quit = input.quit.contains(id)
      return Row(
        bundleID: id, name: app.name, detail: detail, slow: !input.optedOut.contains(id),
        quit: quit, suggested: !quit && input.suggested.contains(id))
    }
    .sorted {
      let order = $0.name.localizedStandardCompare($1.name)
      return order == .orderedSame ? $0.bundleID < $1.bundleID : order == .orderedAscending
    }
  }
}
