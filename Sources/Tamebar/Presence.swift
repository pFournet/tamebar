import CoreGraphics
import Foundation

/// Is the user at the Mac (Q5): away when the screen is locked, or after 10 min with no input. It
/// times automatic ending (Q10); it never decides on its own what Tamebar does.
enum PresenceTracker {
  static let awayAfter: TimeInterval = 600

  struct Reading: Equatable, Sendable {
    let locked: Bool
    let idleSeconds: TimeInterval

    var isAway: Bool { PresenceTracker.isAway(self) }
  }

  static func isAway(_ reading: Reading) -> Bool {
    reading.locked || reading.idleSeconds >= awayAfter
  }

  /// The e2e control decides in e2e mode, and an unset `away` counts as present there: a test run
  /// never reads the real Mac's presence. Otherwise the live reading.
  static func reading(e2e control: E2EMode.Control?, live: () -> Reading) -> Reading {
    guard let control else { return live() }
    return .init(locked: control.away == true, idleSeconds: 0)
  }

  /// The screen-lock flag of `CGSessionCopyCurrentDictionary`, absent while unlocked.
  static func isLocked(_ session: [String: Any]?) -> Bool {
    (session?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true
  }
}

/// The live presence signals, with no new permission: the login session's screen-lock flag and
/// the seconds since the last input event of any kind, both read again on every scan. No
/// notification state is kept: AppKit can hold the screenIsLocked/Unlocked distributed
/// notifications while a menu-bar app isn't active, and a missed unlock would have left Tamebar
/// "away" for good. A test swaps in its own session dictionary and idle time.
@MainActor
final class PresenceMonitor {
  private let session: () -> [String: Any]?
  private let idle: () -> TimeInterval

  init(
    session: @escaping () -> [String: Any]? = {
      CGSessionCopyCurrentDictionary() as? [String: Any]
    },
    idle: @escaping () -> TimeInterval = PresenceMonitor.idleSeconds
  ) {
    self.session = session
    self.idle = idle
  }

  /// Seconds since the last keyboard, mouse or trackpad event in this login session.
  nonisolated static func idleSeconds() -> TimeInterval {
    // kCGAnyInputEventType: every event type.
    guard let any = CGEventType(rawValue: ~0) else { return 0 }
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
  }

  /// A NaN or negative idle time (a failed read) counts as present: no input for 0 s.
  func reading(e2e mode: E2EMode? = E2EMode.current) -> PresenceTracker.Reading {
    PresenceTracker.reading(e2e: mode?.control()) {
      let seconds = idle()
      return .init(
        locked: PresenceTracker.isLocked(session()),
        idleSeconds: seconds.isNaN || seconds < 0 ? 0 : seconds)
    }
  }
}
