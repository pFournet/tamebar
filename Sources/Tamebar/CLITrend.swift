import Foundation

// `tamebar trend` (Q16): the daily usage record, with the markers between days, and the before
// and after of one marker. Read-only: it reads `usage-daily.json` and `usage-markers.jsonl`, and
// `resource-history.json` for the baseline while Tamebar hasn't recorded a day yet.

/// What `trend` reads.
struct CLITrendFiles {
  var record: UsageRecord?
  var markers: [UsageMarker] = []
  /// The baseline from `resource-history.json`, used only while there is no record.
  var baseline: [ResourceSample] = []
  var notes: [String] = []

  static func read(_ directory: URL) -> CLITrendFiles {
    var files = CLITrendFiles()
    switch CLIFile.decode(
      UsageRecord.self, directory, UsageStore.fileName, limit: UsageStore.maximumBytes)
    {
    case .value(let record): files.record = record
    case .missing: break
    case .unreadable: files.notes.append("\(UsageStore.fileName) is unreadable")
    }
    files.markers = UsageMarkers.read(directory)
    if files.record == nil {
      if case .value(let samples) = CLIFile.decode(
        [ResourceSample].self, directory, "resource-history.json",
        limit: ResourceHistoryStore.maximumBytes)
      {
        files.baseline = samples
      }
    }
    return files
  }
}

struct CLITrend: Encodable {
  let schema = CLIReport.schema
  let command = "trend"
  let generatedAt: Date
  /// `--days`: the window, in local days ending today.
  let windowDays: Int
  let tamebarRunning: Bool
  let notes: [String]
  /// Oldest first, days with data only.
  let days: [Day]
  /// The markers inside the window, oldest first.
  let markers: [Marker]
  @CLINullable var compare: Compare?

  struct Day: Encodable, Equatable {
    /// The local day, `yyyy-MM-dd`.
    let day: String
    /// From `resource-history.json`: RAM and CPU only, the rest null.
    let baseline: Bool
    @CLINullable var awakeMinutes: Int?
    @CLINullable var inUseMinutes: Int?
    @CLINullable var pressureMinutes: Int?
    @CLINullable var warningMinutes: Int?
    @CLINullable var criticalMinutes: Int?
    /// Of in-use time, 0–100.
    @CLINullable var pressurePercent: Double?
    @CLINullable var criticalPercent: Double?
    @CLINullable var cpuSaturatedMinutes: Int?
    @CLINullable var hotMinutes: Int?
    /// In-use time with the Mac struggling (Q19), and its share of in-use time, 0–100; null for
    /// a day recorded before the strain was.
    @CLINullable var strugglingMinutes: Int?
    @CLINullable var strugglingPercent: Double?
    @CLINullable var swapPeakBytes: UInt64?
    @CLINullable var swapAverageBytes: UInt64?
    @CLINullable var availableLowestBytes: UInt64?
    @CLINullable var memoryPeakPercent: Double?
    @CLINullable var memoryAveragePercent: Double?
    @CLINullable var cpuPeakPercent: Double?
    @CLINullable var cpuAveragePercent: Double?
    @CLINullable var aiSessionsAverage: Double?
    @CLINullable var aiSessionsPeak: Int?
    @CLINullable var aiSessionsMemoryAverageBytes: UInt64?
    @CLINullable var aiSessionsMemoryPeakBytes: UInt64?
    @CLINullable var tamebarDid: Did?
  }

  struct Did: Encodable, Equatable {
    let paused: Int
    let queued: Int
    let ended: Int
    let quit: Int
    let slowed: Int
    let freedBytes: UInt64

    init(_ actions: UsageActions) {
      paused = actions.paused
      queued = actions.queued
      ended = actions.ended
      quit = actions.quit
      slowed = actions.slowed
      freedBytes = actions.freedBytes
    }
  }

  struct Marker: Encodable, Equatable {
    let date: Date
    let day: String
    /// `version`, `setting` or `note`.
    let kind: String
    let text: String
    let label: String
    @CLINullable var version: String?
    @CLINullable var commit: String?
  }

  struct Compare: Encodable, Equatable {
    let label: String
    /// The marker's day, or the date given (then the first day after).
    let day: String
    @CLINullable var marker: Marker?
    let before: Side
    let after: Side
    /// `lighter`, `same` or `heavier`, from the AI sessions on average.
    @CLINullable var workload: String?
  }

  struct Side: Encodable, Equatable {
    let days: [String]
    let useDays: Int
    @CLINullable var pressurePercent: Double?
    @CLINullable var criticalMinutesPerDay: Double?
    @CLINullable var strugglingMinutesPerDay: Double?
    @CLINullable var swapPeakBytes: UInt64?
    @CLINullable var memoryPeakPercent: Double?
    @CLINullable var aiSessionsAverage: Double?
    @CLINullable var aiSessionsMemoryAverageBytes: UInt64?
    @CLINullable var inUseMinutesPerDay: Double?
    let tamebarDid: Did
  }
}

enum CLITrendReport {
  static let defaultDays = 14
  static let maximumDays = UsageRecord.retentionDays

  struct Input {
    let files: CLITrendFiles
    let days: Int
    /// `--compare`: a marker's text or version, or a day.
    let compare: String?
    let now: Date
    let calendar: Calendar
    let tamebarRunning: Bool
  }

  enum Failure: Error, Equatable {
    case noMatch(String)
  }

  /// The report, and the comparison its text prints.
  struct Built {
    let report: CLITrend
    let comparison: UsageComparison?
  }

  static func build(_ input: Input) -> Result<Built, Failure> {
    let calendar = input.calendar
    let today = UsageCalendar.key(input.now, calendar)
    var notes = input.files.notes
    var all = input.files.record?.days ?? []
    if input.files.record == nil {
      all = UsageBaseline.days(input.files.baseline, before: today, calendar: calendar)
      notes.append(
        "Tamebar hasn't recorded a day yet; the days shown are the baseline from resource-history.json."
      )
    }
    if !input.tamebarRunning { notes.append("Tamebar isn't running; nothing is recorded now.") }
    let first = UsageCalendar.adding(-(input.days - 1), to: today, calendar) ?? today
    let shown = all.filter { $0.hasData && $0.day >= first && $0.day <= today }
    let markers = UsageMarkers.display(input.files.markers, calendar: calendar)
    var comparison: UsageComparison?
    if let query = input.compare {
      if UsageCalendar.start(query, calendar) != nil, query.count == 10 {
        comparison = .from(day: query, days: all)
      } else if let marker = marker(query, in: input.files.markers) {
        comparison = .around(marker, days: all, calendar: calendar)
      } else {
        return .failure(.noMatch(query))
      }
    }
    let report = CLITrend(
      generatedAt: input.now, windowDays: input.days, tamebarRunning: input.tamebarRunning,
      notes: notes, days: shown.map(day),
      markers: markers.filter { UsageCalendar.key($0.at, calendar) >= first }.map {
        marker($0, calendar)
      },
      compare: comparison.map { compare($0, calendar) })
    return .success(.init(report: report, comparison: comparison))
  }

  /// The latest marker that `query` names exactly, else the latest whose text contains it.
  static func marker(_ query: String, in markers: [UsageMarker]) -> UsageMarker? {
    if let exact = markers.last(where: { $0.matches(query) }) { return exact }
    let needle = query.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return nil }
    return markers.last { $0.label.localizedCaseInsensitiveContains(needle) }
  }

  static func minutes(_ seconds: Double) -> Int { Int((seconds / 60).rounded()) }

  static func day(_ day: UsageDay) -> CLITrend.Day {
    let live = !day.baseline
    return .init(
      day: day.day, baseline: day.baseline,
      awakeMinutes: live ? minutes(day.awakeSeconds) : nil,
      inUseMinutes: live ? minutes(day.inUseSeconds) : nil,
      pressureMinutes: live ? minutes(day.pressureSeconds) : nil,
      warningMinutes: live ? minutes(day.warningSeconds) : nil,
      criticalMinutes: live ? minutes(day.criticalSeconds) : nil,
      pressurePercent: day.pressureShare.map { CLIReport.round($0 * 100) },
      criticalPercent: day.criticalShare.map { CLIReport.round($0 * 100) },
      cpuSaturatedMinutes: live ? minutes(day.cpuSaturatedSeconds) : nil,
      hotMinutes: live ? minutes(day.hotSeconds) : nil,
      strugglingMinutes: live ? day.strugglingSeconds.map(minutes) : nil,
      strugglingPercent: day.strugglingShare.map { CLIReport.round($0 * 100) },
      swapPeakBytes: day.swapPeakBytes, swapAverageBytes: day.swapAverageBytes,
      availableLowestBytes: day.availableLowestBytes,
      memoryPeakPercent: day.memoryPeakPercent.map(CLIReport.round),
      memoryAveragePercent: day.memoryAveragePercent.map(CLIReport.round),
      cpuPeakPercent: day.cpuPeakPercent.map(CLIReport.round),
      cpuAveragePercent: day.cpuAveragePercent.map(CLIReport.round),
      aiSessionsAverage: day.sessionsAverage.map(CLIReport.round),
      aiSessionsPeak: day.sessionsPeak,
      aiSessionsMemoryAverageBytes: day.sessionMemoryAverageBytes,
      aiSessionsMemoryPeakBytes: day.sessionMemoryPeakBytes,
      tamebarDid: live ? .init(day.actions) : nil)
  }

  static func marker(_ marker: UsageMarker, _ calendar: Calendar) -> CLITrend.Marker {
    .init(
      date: marker.at, day: UsageCalendar.key(marker.at, calendar), kind: marker.kind.rawValue,
      text: marker.text, label: marker.label, version: marker.version, commit: marker.commit)
  }

  static func compare(_ comparison: UsageComparison, _ calendar: Calendar) -> CLITrend.Compare {
    .init(
      label: comparison.label, day: comparison.pivotDay,
      marker: comparison.marker.map { marker($0, calendar) },
      before: side(comparison.before), after: side(comparison.after),
      workload: comparison.workload?.rawValue)
  }

  static func side(_ side: UsageComparison.Side) -> CLITrend.Side {
    .init(
      days: side.days, useDays: side.useDays,
      pressurePercent: side.pressureShare.map { CLIReport.round($0 * 100) },
      criticalMinutesPerDay: side.criticalSecondsPerDay.map { CLIReport.round($0 / 60) },
      strugglingMinutesPerDay: side.strugglingSecondsPerDay.map { CLIReport.round($0 / 60) },
      swapPeakBytes: side.swapPeakBytes,
      memoryPeakPercent: side.memoryPeakPercent.map(CLIReport.round),
      aiSessionsAverage: side.sessionsAverage.map(CLIReport.round),
      aiSessionsMemoryAverageBytes: side.sessionMemoryAverageBytes,
      inUseMinutesPerDay: side.inUseSecondsPerDay.map { CLIReport.round($0 / 60) },
      tamebarDid: .init(side.actions))
  }
}

// MARK: Text

enum CLITrendText {
  /// The table of days, a marker line after the day it was set, then the notes. With a comparison,
  /// its block alone.
  static func render(
    _ report: CLITrend, comparison: UsageComparison?, calendar: Calendar
  ) -> String {
    var lines: [String] = []
    if let comparison {
      lines.append(comparison.text.trimmingCharacters(in: .newlines))
    } else if report.days.isEmpty {
      lines.append(
        "No usage recorded yet. Tamebar records each day while it runs; the first one shows tomorrow."
      )
    } else {
      lines.append(
        pad("Day", 8) + pad("Awake", 7) + pad("Pressure", 16) + pad("Critical", 10)
          + pad("Struggling", 12) + pad("Swap peak", 11) + pad("AI sessions", 13) + "Tamebar did")
      var markers = report.markers[...]
      for day in report.days {
        while let marker = markers.first, marker.day < day.day {
          lines.append(line(marker))
          markers = markers.dropFirst()
        }
        lines.append(row(day, calendar))
      }
      lines.append(contentsOf: markers.map(line))
    }
    lines.append(contentsOf: report.notes.map { "Note: \($0)" })
    return lines.joined(separator: "\n") + "\n"
  }

  static func line(_ marker: CLITrend.Marker) -> String { " ── \(marker.label) ──" }

  static func row(_ day: CLITrend.Day, _ calendar: Calendar) -> String {
    let date = pad(UsageCalendar.short(day.day, calendar), 8)
    guard !day.baseline else {
      var detail = "baseline"
      if let memory = day.memoryPeakPercent { detail += " · RAM peak \(Int(memory.rounded()))%" }
      if let cpu = day.cpuPeakPercent { detail += " · CPU peak \(Int(cpu.rounded()))%" }
      return date + pad("—", 7) + pad("—", 16) + pad("—", 10) + pad("—", 12) + pad("—", 11)
        + pad("—", 13) + detail
    }
    let awake = day.inUseMinutes.map(hours) ?? "—"
    var pressure = "—"
    if let minutes = day.pressureMinutes {
      pressure = duration(minutes)
      if let percent = day.pressurePercent { pressure += " · \(Int(percent.rounded()))%" }
    }
    let critical = day.criticalMinutes.map(duration) ?? "—"
    let struggling = day.strugglingMinutes.map(duration) ?? "—"
    let swap = day.swapPeakBytes.map(ByteText.compact) ?? "—"
    var sessions = "—"
    if let average = day.aiSessionsAverage {
      sessions = "\(Int(average.rounded()))"
      if let bytes = day.aiSessionsMemoryAverageBytes {
        sessions += " · \(ByteText.compact(bytes))"
      }
    }
    return date + pad(awake, 7) + pad(pressure, 16) + pad(critical, 10) + pad(struggling, 12)
      + pad(swap, 11) + pad(sessions, 13) + did(day.tamebarDid)
  }

  /// `paused 12`, `ended 3, queued 4 · freed 2 GB`, `none`, or `—` when unknown.
  static func did(_ did: CLITrend.Did?) -> String {
    guard let did else { return "—" }
    let parts = [
      ("paused", did.paused), ("ended", did.ended), ("queued", did.queued), ("quit", did.quit),
      ("slowed", did.slowed),
    ].filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }
    guard !parts.isEmpty else { return "none" }
    var text = parts.joined(separator: ", ")
    if did.freedBytes > 0 { text += " · freed \(ByteText.compact(did.freedBytes))" }
    return text
  }

  /// `40m`, `3h 10m`, `2h`.
  static func duration(_ minutes: Int) -> String {
    guard minutes >= 60 else { return "\(minutes)m" }
    return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
  }

  /// Whole hours from one hour up (`9h`), minutes below.
  static func hours(_ minutes: Int) -> String {
    minutes >= 60 ? "\(Int((Double(minutes) / 60).rounded()))h" : "\(minutes)m"
  }

  static func pad(_ text: String, _ width: Int) -> String {
    text.count >= width - 1
      ? text + " " : text.padding(toLength: width, withPad: " ", startingAt: 0)
  }
}
