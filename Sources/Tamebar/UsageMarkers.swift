import Darwin
import Foundation

/// A point in time worth comparing around (Q16): a new Tamebar build, an automatic setting
/// switched, or the user's own `tamebar mark "<text>"`.
struct UsageMarker: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable {
    case version, setting, note
  }

  var at: Date
  var kind: Kind
  /// What the marker line shows: `0.1.0 · 4f3a2b1`, `Auto-end after 7 days`, or the user's text.
  var text: String
  var version: String?
  var commit: String?

  /// `v0.1.0 · 4f3a2b1` for a build, the text otherwise.
  var label: String { kind == .version ? "v" + text : text }

  /// Whether `query` names this marker: its text or label, its version with or without the `v`,
  /// or its commit; case doesn't matter.
  func matches(_ query: String) -> Bool {
    let query = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return false }
    let bare = query.hasPrefix("v") ? String(query.dropFirst()) : query
    return [text, label, version, commit].compactMap { $0?.lowercased() }.contains {
      $0 == query || $0 == bare
    }
  }
}

/// `usage-markers.jsonl`: one marker per line, appended by the app and by `tamebar mark`. Each
/// append takes `usage-markers.lock` (an exclusive `flock`), so the CLI and the app never write
/// at once; the app's yearly prune rewrites the file under the same lock. Reads take no lock: a
/// line is written in one `write`, and a torn or unreadable line is skipped.
enum UsageMarkers {
  static let fileName = "usage-markers.jsonl"
  static let lockName = "usage-markers.lock"
  static let maximumBytes = 1_024 * 1_024
  static let maximumText = 200

  static func url(_ directory: URL) -> URL { directory.appendingPathComponent(fileName) }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()

  /// The markers, oldest first; missing file, none.
  static func read(_ directory: URL) -> [UsageMarker] {
    guard let data = try? Data(contentsOf: url(directory)) else { return [] }
    return parse(data.suffix(maximumBytes))
  }

  static func parse(_ data: Data) -> [UsageMarker] {
    data.split(separator: UInt8(ascii: "\n")).compactMap {
      try? decoder.decode(UsageMarker.self, from: Data($0))
    }.sorted { $0.at < $1.at }
  }

  enum AppendError: Error, Equatable {
    case emptyText
    case unwritable(String)
  }

  /// Appends one marker under the lock. Text is trimmed, kept to one line and 200 characters.
  @discardableResult
  static func append(_ marker: UsageMarker, directory: URL) -> Result<UsageMarker, AppendError> {
    var marker = marker
    marker.text = String(
      marker.text.components(separatedBy: .newlines).joined(separator: " ")
        .trimmingCharacters(in: .whitespaces).prefix(maximumText))
    guard !marker.text.isEmpty else { return .failure(.emptyText) }
    guard var line = try? encoder.encode(marker) else { return .failure(.unwritable("encode")) }
    line.append(UInt8(ascii: "\n"))
    return locked(directory) {
      let path = url(directory).path
      let file = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
      guard file >= 0 else { return .failure(.unwritable(String(cString: strerror(errno)))) }
      defer { close(file) }
      let written = line.withUnsafeBytes { Darwin.write(file, $0.baseAddress, $0.count) }
      guard written == line.count else {
        return .failure(.unwritable(String(cString: strerror(errno))))
      }
      return .success(marker)
    }
  }

  /// Rewrites the file without markers older than a year, under the lock. The app only.
  static func prune(directory: URL, now: Date) {
    let cutoff = now.addingTimeInterval(-Double(UsageRecord.retentionDays) * 86_400)
    _ = locked(directory) { () -> Result<Void, AppendError> in
      let markers = read(directory)
      guard markers.contains(where: { $0.at < cutoff }) else { return .success(()) }
      var data = Data()
      for marker in markers where marker.at >= cutoff {
        guard let line = try? encoder.encode(marker) else { continue }
        data.append(line)
        data.append(UInt8(ascii: "\n"))
      }
      try? data.write(to: url(directory), options: .atomic)
      return .success(())
    }
  }

  private static func locked<T>(_ directory: URL, _ body: () -> Result<T, AppendError>)
    -> Result<T, AppendError>
  {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let lock = open(
      directory.appendingPathComponent(lockName).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard lock >= 0 else { return .failure(.unwritable(String(cString: strerror(errno)))) }
    defer { close(lock) }
    guard flock(lock, LOCK_EX) == 0 else {
      return .failure(.unwritable(String(cString: strerror(errno))))
    }
    defer { flock(lock, LOCK_UN) }
    return body()
  }

  /// The markers a trend shows: a build installed several times in one day is that day's last
  /// install only.
  static func display(_ markers: [UsageMarker], calendar: Calendar) -> [UsageMarker] {
    var lastBuild: [String: Int] = [:]
    for (index, marker) in markers.enumerated() where marker.kind == .version {
      lastBuild[UsageCalendar.key(marker.at, calendar)] = index
    }
    return markers.enumerated().filter { index, marker in
      marker.kind != .version || lastBuild[UsageCalendar.key(marker.at, calendar)] == index
    }.map(\.element)
  }
}
