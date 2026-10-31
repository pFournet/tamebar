import Foundation
import os

/// Combines the meeting sources into the model's `meetingActive` (M1): calendar events, and the
/// mic or camera in use. The e2e control's `meeting` wins when set.
///
/// Reading and deciding are split. `observe` reads every source once, off the main actor: the
/// probe, the calendar through its actor, the e2e control file. `tick` is a pure step of the
/// kept state, an explicit `now` and that observation. Both the scan and the meeting timer tick
/// it; the rules are timed by the dates they are given, so an extra tick only samples more often.
@MainActor
final class MeetingMonitor {
  struct Sources: Sendable {
    /// Qualifying calendar events around a date; nil when there is no calendar.
    var calendar: (@Sendable (Date) async -> [MeetingEvent])?
    /// Google Calendar's last result (`GoogleCalendarMeetings`); nil without a Google source. It
    /// answers at once and fetches in the background, so it never holds up a read.
    var google: (@Sendable (Date) async -> [MeetingEvent])?
    /// The mic and camera (`CallSignals`); nil when there is no probe. A read that answers nil
    /// failed, and the last answer stands.
    var calls: (@Sendable () -> CallReading?)?
    /// The e2e control's `meeting`; nil when unset, or outside e2e mode.
    var forced: (@Sendable () -> Bool?)?

    static let none = Sources()
  }

  /// One read of every source.
  struct Observation: Equatable, Sendable {
    /// EventKit's meetings.
    var events: [MeetingEvent] = []
    /// Google's, before the dedupe against `events` (`MeetingEvent.merged`).
    var google: [MeetingEvent] = []
    /// Nil when there is no probe or the read failed.
    var calls: CallReading?
    var forced: Bool?
  }

  /// What made the last tick a meeting, for the island's label.
  enum Source: String { case none, calendar, mic }

  /// After this long with no good probe read, the mic and camera count as off for the meeting
  /// (a probe that keeps failing can't hold a call forever). Q11 still holds every app: the
  /// model's `callReading` stays nil.
  static let staleRead: TimeInterval = 120

  let sources: Sources
  private var wasActive = false
  private var clocks = MeetingRules.Clocks()
  /// The last mic and camera read that worked; a failed read keeps it, up to `staleRead`.
  private var signals = (mic: false, camera: false)
  private var lastGoodRead: Date?
  /// The last observation's events and control, for a tick with no read (it timed out).
  private var last = Observation()
  private(set) var source: Source = .none

  init(sources: Sources) {
    self.sources = sources
  }

  /// The monitor the model starts with. Only the shipped app reads the real calendar and
  /// devices. The e2e build reads its control file and nothing real; tests and debug runs get
  /// no source, so no meeting.
  static func launch(
    e2e: E2EMode? = E2EMode.current, shipped: Bool = AppBrand.isShippedApp,
    google: @autoclosure () -> GoogleCalendarMeetings? = GoogleCalendarMeetings.shared
  ) -> MeetingMonitor {
    if let e2e {
      return MeetingMonitor(sources: .init(forced: { e2e.control().meeting }))
    }
    guard shipped else { return MeetingMonitor(sources: .none) }
    let calendar = CalendarMeetings()
    var googleEvents: (@Sendable (Date) async -> [MeetingEvent])?
    if let google = google() { googleEvents = { await google.events(around: $0) } }
    return MeetingMonitor(
      sources: .init(
        calendar: { await calendar.events(around: $0) }, google: googleEvents,
        calls: CallSignals.liveProbe(shipped: true)))
  }

  /// It reads the real mic and camera, so it is worth polling between scans.
  var isLive: Bool { sources.calls != nil }

  /// The task's value, or nil when it takes longer than `limit`. The task isn't cancelled: a
  /// probe stuck in a system call can't be, so the caller must not start another read until
  /// this one ends (`DevProcessModel.meetingObserving`).
  nonisolated static func value<T: Sendable>(of task: Task<T, Never>, within limit: Duration)
    async -> T?
  {
    let done = OSAllocatedUnfairLock(initialState: false)
    return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
      let finish: @Sendable (T?) -> Void = { value in
        let first = done.withLock { done in
          defer { done = true }
          return !done
        }
        if first { continuation.resume(returning: value) }
      }
      Task.detached { finish(await task.value) }
      Task.detached {
        try? await Task.sleep(for: limit)
        finish(nil)
      }
    }
  }

  /// Reads every source once. Never on the main actor: call it from a detached task.
  nonisolated static func observe(_ sources: Sources, now: Date) async -> Observation {
    Observation(
      events: await sources.calendar?(now) ?? [], google: await sources.google?(now) ?? [],
      calls: sources.calls?(), forced: sources.forced?())
  }

  /// One step. A nil observation is a read that didn't come back in time: the last events and
  /// control stand, and the probe counts as failed.
  func tick(now: Date, observation: Observation?) -> Bool {
    let observation =
      observation
      ?? .init(events: last.events, google: last.google, calls: nil, forced: last.forced)
    last = observation
    if let forced = observation.forced {
      wasActive = forced
      source = forced ? .calendar : .none
      return forced
    }
    if let reading = observation.calls {
      signals = (reading.mic, reading.camera)
      lastGoodRead = now
    } else if lastGoodRead.map({ now.timeIntervalSince($0) >= Self.staleRead }) ?? true {
      signals = (false, false)
    }
    let step = MeetingRules.step(
      .init(
        now: now,
        events: MeetingEvent.merged(local: observation.events, google: observation.google),
        mic: signals.mic,
        camera: signals.camera, wasActive: wasActive, clocks: clocks))
    clocks = step.clocks
    source = !step.active ? .none : step.inEvent ? .calendar : .mic
    wasActive = step.active
    return step.active
  }
}
