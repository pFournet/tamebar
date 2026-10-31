import Foundation

/// The days and markers the Trend card draws.
struct UsageTrendData: Equatable, Sendable {
  var days: [UsageDay] = []
  var markers: [UsageMarker] = []

  /// What Tamebar did on its own on `date`'s local day, for the card's Today line (N11); nil when
  /// the record has no such day yet. As fresh as the last flush, at most a minute old.
  func actions(on date: Date, calendar: Calendar = .autoupdatingCurrent) -> UsageActions? {
    let key = UsageCalendar.key(date, calendar)
    return days.last { $0.day == key }?.actions
  }

  /// What the files say, read only: for a Tamebar that doesn't record (a second instance, a
  /// test host). An unreadable file reads as empty and is left where it is.
  static func read(_ directory: URL) -> UsageTrendData {
    let url = directory.appendingPathComponent(UsageStore.fileName)
    let record = (try? Data(contentsOf: url)).flatMap {
      try? JSONDecoder().decode(UsageRecord.self, from: $0)
    }
    return .init(days: record?.days ?? [], markers: UsageMarkers.read(directory))
  }
}

/// Keeps the daily usage record (Q16) from the app's 2-second pressure tick: it adds each
/// reading in memory and writes `usage-daily.json` at most once a minute, and on sleep and quit.
/// It marks a new Tamebar build at launch and an automatic setting switched at a flush. Only the
/// Tamebar that acts (the one holding `autopause.lock`, not the e2e build) has one.
@MainActor
final class UsageRecorder {
  static let flushInterval: TimeInterval = 60

  private(set) var record: UsageRecord
  let directory: URL
  private let store: UsageStore
  private var calendar: Calendar
  /// The previous reading; nil after a sleep, so the gap isn't counted.
  private var last: UsageReading?
  private var flushedAt: Date
  private let settings: @MainActor () -> UsageSettings
  private let appName: @MainActor (String) -> String
  /// Called after each flush with what the card shows.
  var flushed: (@MainActor (UsageTrendData) -> Void)?

  struct Launch {
    let directory: URL
    let now: Date
    var calendar: Calendar = .autoupdatingCurrent
    /// `UsageBuild.label` of this build.
    let build: String
    let version: String
    let commit: String?
    /// The first run's baseline: `resource-history.json`'s samples.
    let baseline: () -> [ResourceSample]
    let settings: @MainActor () -> UsageSettings
    let appName: @MainActor (String) -> String
  }

  init(_ launch: Launch) {
    directory = launch.directory
    store = UsageStore(directory: launch.directory)
    calendar = launch.calendar
    settings = launch.settings
    appName = launch.appName
    flushedAt = launch.now
    var record = store.load(now: launch.now) ?? UsageRecord()
    if !record.baselineImported {
      record.importBaseline(
        UsageBaseline.days(
          launch.baseline(), before: UsageCalendar.key(launch.now, launch.calendar),
          calendar: launch.calendar))
    }
    if let previous = record.build, previous != launch.build {
      UsageMarkers.append(
        .init(
          at: launch.now, kind: .version, text: launch.build, version: launch.version,
          commit: launch.commit), directory: launch.directory)
    }
    record.build = launch.build
    if record.settings == nil { record.settings = launch.settings() }
    record.prune(now: launch.now, calendar: launch.calendar)
    self.record = record
    UsageMarkers.prune(directory: launch.directory, now: launch.now)
    store.save(record)
  }

  var data: UsageTrendData { .init(days: record.days, markers: UsageMarkers.read(directory)) }

  func observe(_ reading: UsageReading) {
    record.observe(reading, after: last, calendar: calendar)
    last = reading
    if reading.date.timeIntervalSince(flushedAt) >= Self.flushInterval
      || reading.date < flushedAt
    {
      flush(now: reading.date)
    }
  }

  func add(_ action: UsageAction, at date: Date = .now) {
    record.record(action, at: date, calendar: calendar)
  }

  /// Q17.2: these apps were among the three using the most memory under pressure now.
  func recordTops(_ bundleIDs: [String], at date: Date = .now) {
    record.recordTops(bundleIDs, at: date, calendar: calendar)
  }

  /// Takes `memory-history.json`'s pressure events in, once: `events` is read only then.
  func importTops(_ events: () -> [(date: Date, bundleIDs: [String])]) {
    guard !record.topsImported else { return }
    record.importTops(events(), calendar: calendar)
  }

  /// Sleep, wake and quit: the time until the next reading isn't awake time.
  func pause(now: Date = .now) {
    last = nil
    flush(now: now)
  }

  /// Marks the automatic settings switched since the last flush, prunes a year, and writes.
  func flush(now: Date = .now) {
    flushedAt = now
    let current = settings()
    if let previous = record.settings, previous != current {
      for text in UsageSettings.changes(from: previous, to: current, name: appName) {
        UsageMarkers.append(.init(at: now, kind: .setting, text: text), directory: directory)
      }
    }
    record.settings = current
    record.prune(now: now, calendar: calendar)
    store.save(record)
    flushed?(data)
  }
}
