import Darwin
import Foundation

struct MemoryGuardSample: Codable, Equatable, Sendable {
  let date: Date
  let pressure: MemoryPressureLevel
  let available: UInt64
  let total: UInt64
  let compressed: UInt64
  let swapUsed: UInt64?
  let swapOutBytes: UInt64
  /// The kernel's swap-in counter, in pages; nil when unread (Q19's strain signal).
  var swapInPages: UInt64? = nil

  static func read(pressure: MemoryPressureLevel) -> Self? {
    guard let stats = VMMemoryStatsReader.current() else { return nil }
    var swap = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    let result = sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
    return Self(
      date: .now, pressure: pressure, available: stats.available, total: stats.total,
      compressed: stats.compressed, swapUsed: result == 0 ? swap.xsu_used : nil,
      swapOutBytes: stats.swapOutBytes, swapInPages: stats.swapIns
    )
  }
}

enum MemoryRisk: Int, Codable, Comparable, Sendable {
  case normal, growing, warning, critical

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  var title: String {
    switch self {
    case .normal: "Memory back to normal"
    case .growing: "Memory use rising"
    case .warning: "Memory running low"
    case .critical: "Memory almost full"
    }
  }
}

struct MemoryRiskEvaluator {
  private var samples: [MemoryGuardSample] = []
  private var recoveryStartedAt: Date?
  private(set) var risk = MemoryRisk.normal

  mutating func evaluate(_ sample: MemoryGuardSample) -> MemoryRisk {
    if let last = samples.last,
      sample.date.timeIntervalSince(last.date) > 90 || sample.date < last.date
    {
      samples.removeAll()
      recoveryStartedAt = nil
    }
    samples.append(sample)
    samples.removeAll { sample.date.timeIntervalSince($0.date) > 60 }
    let candidate: MemoryRisk
    switch sample.pressure {
    case .critical: candidate = .critical
    case .warning: candidate = .warning
    case .unknown: candidate = risk
    case .normal:
      let first = samples.first ?? sample
      let elapsed = sample.date.timeIntervalSince(first.date)
      let swapOut =
        sample.swapOutBytes >= first.swapOutBytes ? sample.swapOutBytes - first.swapOutBytes : 0
      let constrained =
        sample.total > 0
        && (Double(sample.available) / Double(sample.total) < 0.15
          || Double(sample.compressed) / Double(sample.total) >= 0.25)
      candidate =
        elapsed >= 30 && swapOut >= 128 * 1_024 * 1_024 && constrained ? .growing : .normal
    }
    if candidate >= risk {
      risk = candidate
      recoveryStartedAt = nil
    } else {
      if recoveryStartedAt == nil { recoveryStartedAt = sample.date }
      if let recoveryStartedAt, sample.date.timeIntervalSince(recoveryStartedAt) >= 30 {
        risk = candidate
        self.recoveryStartedAt = nil
      }
    }
    return risk
  }
}

enum MemoryAppPolicy: String, CaseIterable, Codable, Sendable {
  case review, keepRunning, disposable

  /// Where the policies are kept, by `MemoryApp.policyKey`, as JSON in UserDefaults.
  static let storageKey = "memory.appPolicies"

  var title: String {
    switch self {
    case .review: "Review before quitting"
    case .keepRunning: "Keep running"
    case .disposable: "OK to suggest closing"
    }
  }
}

struct MemoryIncident: Codable, Identifiable, Sendable {
  struct App: Codable, Sendable {
    let name: String
    let bytes: UInt64
    let protected: Bool
  }

  let id: UUID
  let date: Date
  let kind: String
  let detail: String
  let sample: MemoryGuardSample?
  let apps: [App]
  var resources: [ResourceGroup]? = nil
}

struct MemoryIncidentHistory: Codable, Sendable {
  private(set) var events: [MemoryIncident] = []
  static let capacity = 1_440
  /// Routine samples keep their per-process breakdown for an hour; incidents keep it for a day.
  static let detailedSeconds: TimeInterval = 3_600
  static let maximumBytes = 2 * 1_024 * 1_024

  mutating func append(_ event: MemoryIncident) {
    events.append(event)
    events.removeAll { event.date.timeIntervalSince($0.date) > 86_400 }
    for index in events.indices
    where events[index].kind == "sample" && events[index].resources != nil
      && event.date.timeIntervalSince(events[index].date) > Self.detailedSeconds
    {
      events[index].resources = nil
    }
    if events.count > Self.capacity { events.removeFirst(events.count - Self.capacity) }
  }

  func boundedData(maximumBytes: Int) throws -> Data {
    var copy = self
    var data = try JSONEncoder().encode(copy)
    while data.count > maximumBytes && !copy.events.isEmpty {
      copy.events.removeFirst(max(1, copy.events.count / 4))
      data = try JSONEncoder().encode(copy)
    }
    return data
  }
}

actor MemoryIncidentStore {
  let url: URL

  init(url: URL) { self.url = url }

  func load() -> MemoryIncidentHistory {
    guard let data = try? Data(contentsOf: url), data.count <= 8 * 1_024 * 1_024,
      let history = try? JSONDecoder().decode(MemoryIncidentHistory.self, from: data)
    else { return MemoryIncidentHistory() }
    return history
  }

  func save(_ history: MemoryIncidentHistory) throws {
    try Self.write(.init(history: history, url: url))
  }

  struct WriteInput {
    let history: MemoryIncidentHistory
    let url: URL
  }

  /// Synchronous so the last minutes survive a quit.
  nonisolated static func write(_ input: WriteInput) throws {
    try FileManager.default.createDirectory(
      at: input.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try input.history.boundedData(maximumBytes: MemoryIncidentHistory.maximumBytes)
    try data.write(to: input.url, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: input.url.path)
  }
}
