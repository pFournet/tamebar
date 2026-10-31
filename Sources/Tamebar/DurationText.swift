import Foundation

/// How long, in the largest whole unit, for `tamebar status`'s paused lines.
enum DurationText {
  /// The largest whole unit: "8 d", "2 h", "45 min".
  static func span(_ seconds: TimeInterval) -> String {
    let minutes = max(1, Int(seconds / 60))
    if minutes >= 24 * 60 { return "\(minutes / (24 * 60)) d" }
    if minutes >= 60 { return "\(minutes / 60) h" }
    return "\(minutes) min"
  }
}
