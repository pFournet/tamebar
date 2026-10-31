import Foundation

extension ThermalStatus {
  init(_ state: ProcessInfo.ThermalState) {
    switch state {
    case .nominal: self = .nominal
    case .fair: self = .fair
    case .serious: self = .serious
    case .critical: self = .critical
    @unknown default: self = .unknown
    }
  }

  /// The state now, as `SystemMetricsProvider` and `PressureSentinel` read it.
  static var current: ThermalStatus { .init(ProcessInfo.processInfo.thermalState) }

  /// Serious or critical: once it holds, Tamebar acts on heat (Q13).
  var isHot: Bool { self == .serious || self == .critical }
}

/// Acting on heat (Q13, 2026-10-27: "Act on heat"). Serious or critical for 30 s slows heavy
/// builds and tests (`BackgroundPriority`) and pauses idle sessions still using CPU
/// (`AutoPausePlanner`, reason `heat`); 60 s back at nominal or fair undoes both. The clocks live
/// in the planner's state, so `tamebar status` reads them from `autopause.json`. Pure.
enum Heat {
  /// An idle session is paused for heat only above this CPU, in percent of one core, averaged
  /// over `cpuWindow`.
  static let cpuThreshold: Double = 5
  static let cpuWindow: TimeInterval = 30

  /// The 4 s note when Tamebar acts on heat: "Mac hot · slowed 2 builds, paused 1 idle session".
  /// `slowed` is `BackgroundPriority.note`'s line. Nil when it did nothing.
  static func note(slowed: String?, paused: Int) -> String? {
    var parts: [String] = []
    if let slowed, let first = slowed.first {
      parts.append(first.lowercased() + slowed.dropFirst())
    }
    if paused > 0 { parts.append("paused \(idleSessions(paused))") }
    return parts.isEmpty ? nil : "Mac hot · " + parts.joined(separator: ", ")
  }

  private static func idleSessions(_ count: Int) -> String {
    count == 1 ? "1 idle session" : "\(count) idle sessions"
  }
}

/// Each session's CPU averaged over the last `Heat.cpuWindow`, from the scans' readings. A
/// reading counts for the time since the one before it. A session is averaged only once it has
/// been seen for the whole window; one missing from a scan starts over.
struct CPUWindow: Equatable, Sendable {
  struct Sample: Equatable, Sendable {
    let at: Date
    let percent: Double
  }

  var window = Heat.cpuWindow
  private(set) var samples: [String: [Sample]] = [:]

  /// This scan's CPU by thread ID. Keeps one reading at or before the window's start, and every
  /// reading after it.
  mutating func record(_ readings: [String: Double], at now: Date) {
    samples = samples.filter { readings[$0.key] != nil }
    let start = now.addingTimeInterval(-window)
    for (id, percent) in readings {
      var list = (samples[id] ?? []).filter { $0.at < now }
      list.append(.init(at: now, percent: percent))
      while list.count > 1, list[1].at <= start { list.removeFirst() }
      samples[id] = list
    }
  }

  func average(_ id: String, now: Date) -> Double? {
    let start = now.addingTimeInterval(-window)
    guard let list = samples[id], list.count > 1, list[0].at <= start, let last = list.last,
      last.at > start
    else { return nil }
    var total = 0.0
    for (previous, sample) in zip(list, list.dropFirst()) {
      let from = max(previous.at, start)
      guard sample.at > from else { continue }
      total += sample.percent * sample.at.timeIntervalSince(from)
    }
    return total / last.at.timeIntervalSince(start)
  }

  func averages(now: Date) -> [String: Double] {
    var result: [String: Double] = [:]
    for id in samples.keys {
      if let average = average(id, now: now) { result[id] = average }
    }
    return result
  }
}
