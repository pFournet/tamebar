import Foundation

/// Up to 7 days before a change against up to 7 days after it (Q16), for `tamebar trend
/// --compare` and the Trend card. A marker's own day mixes both, so it counts on neither side; a
/// day given as a date is the first day after.
struct UsageComparison: Equatable, Sendable {
  static let sideDays = 7

  struct Side: Equatable, Sendable {
    /// The days compared, oldest first: days with data only.
    var days: [String] = []
    /// Live days with in-use time: the ones with a pressure share.
    var useDays = 0
    /// Pressure time over in-use time, all days together, 0–1.
    var pressureShare: Double?
    var criticalSecondsPerDay: Double?
    /// Time struggling (Q19) a day, over the days that recorded it.
    var strugglingSecondsPerDay: Double?
    /// The mean of the daily swap peaks.
    var swapPeakBytes: UInt64?
    /// The mean of the daily RAM peaks, 0–100; the baseline has it too.
    var memoryPeakPercent: Double?
    var sessionsAverage: Double?
    var sessionMemoryAverageBytes: UInt64?
    var inUseSecondsPerDay: Double?
    var actions = UsageActions()
    /// Every day of the side is a baseline day.
    var baselineOnly: Bool { !days.isEmpty && useDays == 0 }

    init() {}

    init(_ days: [UsageDay]) {
      self.days = days.map(\.day)
      let used = days.filter(\.hasUse)
      useDays = used.count
      let inUse = used.reduce(0) { $0 + $1.inUseSeconds }
      if inUse > 0 {
        pressureShare = min(1, used.reduce(0) { $0 + $1.pressureSeconds } / inUse)
        criticalSecondsPerDay = used.reduce(0) { $0 + $1.criticalSeconds } / Double(used.count)
        inUseSecondsPerDay = inUse / Double(used.count)
      }
      let strained = used.compactMap(\.strugglingSeconds)
      if !strained.isEmpty {
        strugglingSecondsPerDay = strained.reduce(0, +) / Double(strained.count)
      }
      let swaps = used.compactMap(\.swapPeakBytes)
      if !swaps.isEmpty {
        swapPeakBytes = swaps.reduce(0, +) / UInt64(swaps.count)
      }
      let memory = days.compactMap(\.memoryPeakPercent)
      if !memory.isEmpty { memoryPeakPercent = memory.reduce(0, +) / Double(memory.count) }
      let sampled = used.reduce(0) { $0 + $1.sessionSeconds }
      if sampled > 0 {
        sessionsAverage = used.reduce(0) { $0 + $1.sessionCountSeconds } / sampled
        sessionMemoryAverageBytes = UInt64(
          used.reduce(0) { $0 + $1.sessionMemoryByteSeconds } / sampled)
      }
      actions = used.reduce(UsageActions()) { $0 + $1.actions }
    }
  }

  enum Workload: String, Equatable, Sendable {
    case lighter, same, heavier
  }

  /// What the comparison is around: `v0.2`, a marker's text, or a day.
  let label: String
  /// The marker's day, or the date given.
  let pivotDay: String
  let marker: UsageMarker?
  let before: Side
  let after: Side

  /// Fewer AI sessions after (10 % or more) means part of the change may be a lighter workload.
  var workload: Workload? {
    guard let before = before.sessionsAverage, let after = after.sessionsAverage, before > 0
    else { return nil }
    if after < before * 0.9 { return .lighter }
    if after > before * 1.1 { return .heavier }
    return .same
  }

  /// Around a marker: the days before its day against the days after it.
  static func around(_ marker: UsageMarker, days: [UsageDay], calendar: Calendar) -> Self {
    let pivot = UsageCalendar.key(marker.at, calendar)
    return make(
      label: marker.label, pivot: pivot, marker: marker, days: days, afterFrom: pivot, strict: true)
  }

  /// Around a day: the days before it against it and the days after.
  static func from(day: String, days: [UsageDay]) -> Self {
    make(label: day, pivot: day, marker: nil, days: days, afterFrom: day, strict: false)
  }

  private static func make(
    label: String, pivot: String, marker: UsageMarker?, days: [UsageDay], afterFrom: String,
    strict: Bool
  ) -> Self {
    let data = days.filter(\.hasData).sorted { $0.day < $1.day }
    let before = data.filter { $0.day < pivot }.suffix(sideDays)
    let after = data.filter { strict ? $0.day > afterFrom : $0.day >= afterFrom }.prefix(sideDays)
    return .init(
      label: label, pivotDay: pivot, marker: marker, before: Side(Array(before)),
      after: Side(Array(after)))
  }

  // MARK: Text

  static func percent(_ share: Double?) -> String {
    share.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
  }

  /// `24 → 15 GB` when both have the unit, `512 MB → 2 GB` otherwise, `—` for a missing side.
  static func bytes(_ before: UInt64?, _ after: UInt64?) -> String {
    let left = before.map(ByteText.compact) ?? "—"
    let right = after.map(ByteText.compact) ?? "—"
    let leftParts = left.split(separator: " ")
    let rightParts = right.split(separator: " ")
    if leftParts.count == 2, rightParts.count == 2, leftParts[1] == rightParts[1] {
      return "\(leftParts[0]) → \(right)"
    }
    return "\(left) → \(right)"
  }

  static func minutes(_ seconds: Double?) -> String {
    seconds.map { "\(Int(($0 / 60).rounded())) min" } ?? "—"
  }

  static func days(_ count: Int) -> String { "\(count) \(count == 1 ? "day" : "days")" }

  /// The block `tamebar trend --compare` prints.
  var text: String {
    var lines = [
      "\(Self.days(before.days.count)) before → after \(label) (\(Self.days(after.days.count)))"
    ]
    func row(_ name: String, _ value: String) {
      lines.append(name.padding(toLength: 17, withPad: " ", startingAt: 0) + value)
    }
    row(
      "Under pressure",
      "\(Self.percent(before.pressureShare)) → \(Self.percent(after.pressureShare)) of awake time")
    row(
      "Critical",
      "\(Self.minutes(before.criticalSecondsPerDay)) → \(Self.minutes(after.criticalSecondsPerDay)) a day"
    )
    if before.strugglingSecondsPerDay != nil || after.strugglingSecondsPerDay != nil {
      row(
        "Struggling",
        "\(Self.minutes(before.strugglingSecondsPerDay)) → "
          + "\(Self.minutes(after.strugglingSecondsPerDay)) a day")
    }
    row("Swap peak", Self.bytes(before.swapPeakBytes, after.swapPeakBytes))
    if before.memoryPeakPercent != nil || after.memoryPeakPercent != nil {
      row(
        "RAM peak",
        "\(Self.percent(before.memoryPeakPercent.map { $0 / 100 })) → "
          + "\(Self.percent(after.memoryPeakPercent.map { $0 / 100 }))")
    }
    let sessions = { (value: Double?) in value.map { "\(Int($0.rounded()))" } ?? "—" }
    var workloadText =
      "\(sessions(before.sessionsAverage)) → \(sessions(after.sessionsAverage)) on average"
    switch workload {
    case .lighter: workloadText += ", so part of the change may be a lighter workload"
    case .same, .heavier: workloadText += ", so the workload didn't drop"
    case nil: break
    }
    row("AI sessions", workloadText)
    if before.baselineOnly {
      lines.append("The days before are the baseline: RAM and CPU only, no pressure levels.")
    }
    if after.days.isEmpty { lines.append("No full day after \(label) yet.") }
    return lines.joined(separator: "\n") + "\n"
  }

  /// The Trend card's line: `Before v0.2: 35% · after: 17% · swap peak 24 → 15 GB`.
  var summary: String {
    guard !after.days.isEmpty else {
      return "Before \(label): \(Self.percent(before.pressureShare)) · after: no full day yet"
    }
    var line =
      "Before \(label): \(Self.percent(before.pressureShare)) · after: \(Self.percent(after.pressureShare))"
    if before.swapPeakBytes != nil || after.swapPeakBytes != nil {
      line += " · swap peak \(Self.bytes(before.swapPeakBytes, after.swapPeakBytes))"
    }
    return line
  }
}
