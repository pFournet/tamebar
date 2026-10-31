import Foundation

/// Q19 (settled after spike S5, 2026-10-30: "Yes, these four"): the Mac is really struggling,
/// not merely at macOS's "warning", which this Mac reports nearly all day. New AI sessions wait at
/// start while it is (`tamebar wait`). Any one signal is enough; the strain clears after
/// `clearAfter` with none. The thresholds are S5's normal-day worst × 1.7.

/// One reason the Mac is struggling, as `tamebar status` and the card name it.
struct StrainSignal: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Equatable, Sendable {
    /// Swap-ins averaged over 30 s above 4,000 pages/s while pressure is warning or critical.
    case swap
    /// The fan averaged over 60 s above 70 % of its max.
    case fan
    /// macOS's thermal state serious or critical.
    case heat
    /// macOS's memory pressure critical.
    case critical
    /// An e2e test's control forces the strain.
    case forced
  }

  let kind: Kind
  /// Pages/s for `swap`, percent of the fan's max for `fan`.
  var value: Double?
  /// The thermal state for `heat`.
  var state: String?

  /// "fan 78%", "swap-ins 5,200 pages/s", "heat serious", "memory critical".
  var text: String {
    switch kind {
    case .swap:
      let pages =
        value.map { Int($0.rounded()).formatted(.number.locale(Locale(identifier: "en_US"))) }
        ?? "?"
      return "swap-ins \(pages) pages/s"
    case .fan: return "fan \(value.map { "\(Int($0.rounded()))" } ?? "?")%"
    case .heat: return "heat \(state ?? "serious")"
    case .critical: return "memory critical"
    case .forced: return "forced"
    }
  }
}

/// One 2-second reading of what the strain is judged on.
struct StrainReading: Equatable, Sendable {
  var date: Date
  /// The kernel's swap-in counter (`vm_statistics64.swapins`), in pages; nil when unread.
  var swapIns: UInt64?
  /// `kern.memorystatus_vm_pressure_level`.
  var pressure: MemoryPressureLevel
  /// The fan's speed in percent of its max, the highest of the fans; nil with no fan or when
  /// AppleSMC can't be read, so that signal is just absent.
  var fanPercent: Double?
  var thermal: ThermalStatus
}

/// Whether the Mac is struggling, from the 2-second readings. Pure, so a test drives it with any
/// clock.
struct StrainPlanner: Sendable {
  static let swapWindow: TimeInterval = 30
  /// 1.7 × the worst 30 s of S5's normal day (2,327 pages/s), 64 MB/s at 16 KiB pages.
  static let swapThreshold: Double = 4_000
  static let fanWindow: TimeInterval = 60
  /// 1.7 × the worst 60 s of S5's normal day (40.9 %), about 4,600 rpm on the development Mac.
  static let fanThreshold: Double = 70
  /// The strain clears after this long with none of the signals, so it doesn't flicker.
  static let clearAfter: TimeInterval = 60
  /// Readings further apart than this are a sleep (or Tamebar held up): the averages start over.
  static let maximumGap: TimeInterval = 10

  private(set) var struggling = false
  /// When the strain began; nil while there is none.
  private(set) var since: Date?
  /// The signals of the latest reading that had any, while struggling; empty otherwise.
  private(set) var signals: [StrainSignal] = []
  /// The latest reading with a signal.
  private(set) var lastSignal: Date?
  private var previous: (date: Date, swapIns: UInt64?)?
  /// Swap-ins per second between readings, and the fan's percent, each averaged over its window.
  private var windows = CPUWindow(window: StrainPlanner.swapWindow)
  private var fans = CPUWindow(window: StrainPlanner.fanWindow)

  /// The signals that hold at this reading, from the averages so far.
  func signals(at reading: StrainReading) -> [StrainSignal] {
    var found: [StrainSignal] = []
    if reading.pressure == .warning || reading.pressure == .critical,
      let rate = windows.average("swap", now: reading.date), rate > Self.swapThreshold
    {
      found.append(.init(kind: .swap, value: rate))
    }
    if let fan = fans.average("fan", now: reading.date), fan > Self.fanThreshold {
      found.append(.init(kind: .fan, value: fan))
    }
    if reading.thermal.isHot { found.append(.init(kind: .heat, state: reading.thermal.rawValue)) }
    if reading.pressure == .critical { found.append(.init(kind: .critical)) }
    return found
  }

  /// Adds a reading. `forced` (an e2e control) sets the strain on or off at once, without the
  /// averages or the 60 s clear. Returns true when `struggling` or its signals changed.
  @discardableResult
  mutating func observe(_ reading: StrainReading, forced: Bool? = nil) -> Bool {
    let before = (struggling, signals.map(\.kind))
    let now = reading.date
    if let last = previous?.date,
      now.timeIntervalSince(last) > Self.maximumGap || now < last
    {
      windows = CPUWindow(window: Self.swapWindow)
      fans = CPUWindow(window: Self.fanWindow)
      previous = nil
      // A sleep restarts the clear clock: 60 s awake with none of the signals.
      if struggling { lastSignal = now }
    }
    var readings: [String: Double] = [:]
    if let count = reading.swapIns, let last = previous, let lastCount = last.swapIns,
      count >= lastCount, now > last.date
    {
      readings["swap"] = Double(count - lastCount) / now.timeIntervalSince(last.date)
    }
    windows.record(readings, at: now)
    fans.record(reading.fanPercent.map { ["fan": $0] } ?? [:], at: now)
    previous = (now, reading.swapIns)

    if let forced {
      struggling = forced
      since = forced ? (since ?? now) : nil
      signals = forced ? [.init(kind: .forced)] : []
      lastSignal = forced ? now : nil
      return before != (struggling, signals.map(\.kind))
    }
    let found = signals(at: reading)
    if !found.isEmpty {
      lastSignal = now
      if !struggling {
        struggling = true
        since = now
      }
      signals = found
    } else if struggling, let lastSignal, now.timeIntervalSince(lastSignal) >= Self.clearAfter {
      struggling = false
      since = nil
      signals = []
    }
    return before != (struggling, signals.map(\.kind))
  }
}

/// `strain.json`, which the running Tamebar writes and `tamebar wait` and `tamebar status` read:
/// whether the Mac is struggling now, by that Tamebar's pid. A file from a Tamebar that no longer
/// runs means nothing.
struct StrainFile: Codable, Equatable, Sendable {
  static let fileName = "strain.json"

  /// The Tamebar that wrote it, with its start time (`E2EMode.startTime`'s measure).
  var pid: Int32
  var pidStart: Double?
  var struggling: Bool
  var since: Date?
  var signals: [StrainSignal]
  var updated: Date

  static func url(_ directory: URL) -> URL { directory.appendingPathComponent(fileName) }

  static func read(_ directory: URL) -> StrainFile? {
    guard let data = try? Data(contentsOf: url(directory)), data.count < 65_536 else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(StrainFile.self, from: data)
  }

  func write(_ directory: URL) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(self) else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = Self.url(directory)
    try? data.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  /// The Tamebar that wrote it still runs: its pid is alive with the same start time.
  func writerRuns(startTime: (Int32) -> Double?) -> Bool {
    guard pid > 1, let started = startTime(pid) else { return false }
    guard let pidStart else { return true }
    return abs(started - pidStart) < 0.001
  }

  /// "struggling (fan 78%)", "struggling (swap-ins 5,200 pages/s, heat serious)", "none".
  var summary: String {
    guard struggling else { return "none" }
    let reasons = signals.map(\.text)
    return reasons.isEmpty ? "struggling" : "struggling (\(reasons.joined(separator: ", ")))"
  }
}
