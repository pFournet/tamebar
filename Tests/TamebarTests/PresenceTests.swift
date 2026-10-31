import Foundation
import Testing

@testable import Tamebar

/// Q5, Task 7.1: away is the screen locked, or 10 min with no input.
struct PresenceTests {
  @Test func awayWhenLockedOrTenMinutesWithoutInput() {
    #expect(PresenceTracker.isAway(.init(locked: true, idleSeconds: 0)))
    #expect(PresenceTracker.isAway(.init(locked: false, idleSeconds: 600)))
    #expect(PresenceTracker.isAway(.init(locked: false, idleSeconds: 86_400)))
    #expect(!PresenceTracker.isAway(.init(locked: false, idleSeconds: 599)))
    #expect(!PresenceTracker.isAway(.init(locked: false, idleSeconds: 0)))
  }

  @Test func theE2EControlDecidesAndDefaultsToPresent() {
    let locked = PresenceTracker.Reading(locked: true, idleSeconds: 9_999)
    #expect(PresenceTracker.reading(e2e: .init(away: true), live: { locked }).isAway)
    #expect(!PresenceTracker.reading(e2e: .init(away: false), live: { locked }).isAway)
    // An e2e run never reads the real Mac: no `away` means present.
    #expect(!PresenceTracker.reading(e2e: .init(), live: { locked }).isAway)
    // Outside e2e, the live reading.
    #expect(PresenceTracker.reading(e2e: nil, live: { locked }).isAway)
  }

  @Test func lockStateReadFromTheSessionDictionary() {
    #expect(PresenceTracker.isLocked(["CGSSessionScreenIsLocked": true]))
    #expect(PresenceTracker.isLocked(["CGSSessionScreenIsLocked": 1]))
    #expect(!PresenceTracker.isLocked(["CGSSessionScreenIsLocked": false]))
    #expect(!PresenceTracker.isLocked([:]))
    #expect(!PresenceTracker.isLocked(nil))
  }
}

/// The live monitor reads the lock on every scan: a missed screenIsUnlocked notification (AppKit
/// can hold them while a menu-bar app isn't active) must not leave Tamebar "away" for good.
@MainActor
struct PresenceMonitorTests {
  final class Session { var locked = true }

  @Test func aStaleLockClearsOnTheNextReading() {
    let session = Session()
    let monitor = PresenceMonitor(
      session: { ["CGSSessionScreenIsLocked": session.locked] }, idle: { 0 })
    #expect(monitor.reading(e2e: nil).isAway)
    session.locked = false
    #expect(!monitor.reading(e2e: nil).isAway)
    session.locked = true
    #expect(monitor.reading(e2e: nil).isAway)
  }

  /// A failed idle read (NaN) or a clock oddity (negative) is present, never away.
  @Test func anUnreadableIdleTimeIsPresent() {
    for idle in [TimeInterval.nan, -1, -86_400] {
      let monitor = PresenceMonitor(session: { [:] }, idle: { idle })
      #expect(!monitor.reading(e2e: nil).isAway, "\(idle)")
      // Read as no input for 0 s, so nothing downstream sees NaN or a negative age.
      #expect(monitor.reading(e2e: nil).idleSeconds == 0, "\(idle)")
      #expect(!PresenceTracker.isAway(.init(locked: false, idleSeconds: idle)), "\(idle)")
    }
    let away = PresenceMonitor(session: { nil }, idle: { 600 })
    #expect(away.reading(e2e: nil).isAway)
  }
}
