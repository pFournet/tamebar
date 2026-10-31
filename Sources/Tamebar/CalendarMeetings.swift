import EventKit
import Foundation

/// What `CalendarMeetings` reads through: EventKit in the app, a fake in tests.
protocol CalendarStore: AnyObject, Sendable {
  /// Shows the system prompt once; true when full access was granted.
  func requestAccess() async -> Bool
  /// The events between two dates, as the rules read them.
  func events(from start: Date, to end: Date) -> [CalendarMeetings.Fields]
}

/// Meetings from the Mac's own calendars, through EventKit (M1). An actor, so EventKit is never
/// read on the main thread. It reads only once the user has granted full calendar access; until
/// then it returns no events and never prompts. Only the Calendars permission row's Allow… asks
/// (`requestAccess()`, through `PermissionsModel`).
actor CalendarMeetings {
  /// How long a read is reused, unless the store reports a change. Whether a meeting is on is
  /// still decided every tick from the events read; only a new or moved event can wait this
  /// long to be seen.
  static let refreshAfter: TimeInterval = 60

  nonisolated static var isAuthorized: Bool {
    EKEventStore.authorizationStatus(for: .event) == .fullAccess
  }

  typealias MakeStore = @Sendable (_ changed: @escaping @Sendable () -> Void) -> any CalendarStore

  private let authorized: @Sendable () -> Bool
  private let makeStore: MakeStore
  /// Created on the first read or request, and dropped when access is revoked.
  private var store: (any CalendarStore)?
  private var cached: (at: Date, events: [MeetingEvent])?

  init(
    authorized: @escaping @Sendable () -> Bool = { CalendarMeetings.isAuthorized },
    makeStore: @escaping MakeStore = { EventKitStore(changed: $0) }
  ) {
    self.authorized = authorized
    self.makeStore = makeStore
  }

  func requestAccess() async -> Bool {
    let store = currentStore()
    cached = nil
    return await store.requestAccess()
  }

  /// Qualifying meetings from 6 h before `now` to 1 h after (`MeetingRules.qualifies`).
  func events(around now: Date) -> [MeetingEvent] {
    guard authorized() else {
      // Revoked: the next grant starts from a fresh store.
      store = nil
      cached = nil
      return []
    }
    if let cached, now >= cached.at, now.timeIntervalSince(cached.at) < Self.refreshAfter {
      return cached.events
    }
    let events = currentStore().events(
      from: now.addingTimeInterval(-6 * 3_600), to: now.addingTimeInterval(3_600)
    ).compactMap(Self.meeting)
    cached = (now, events)
    return events
  }

  /// The store changed (`EKEventStoreChanged`): the next read fetches again.
  func storeChanged() { cached = nil }

  private func currentStore() -> any CalendarStore {
    if let store { return store }
    let store = makeStore { [weak self] in Task { await self?.storeChanged() } }
    self.store = store
    return store
  }

  /// What the rules read from an attendee.
  struct Attendee: Equatable, Sendable {
    let isCurrentUser: Bool
    let declined: Bool
  }

  /// What the rules read from an event, so the mapping is tested without EventKit.
  struct Fields: Equatable, Sendable {
    /// `calendarItemExternalIdentifier`, shared with Google's copy of the same event.
    let externalID: String?
    /// `eventIdentifier`, this store's own.
    let eventID: String?
    let start: Date?
    let end: Date?
    let attendees: [Attendee]?
    let isAllDay: Bool
    let free: Bool
    /// Location, notes and URL, where a video link may be.
    let text: [String?]
    /// `EKEvent.status == .canceled`.
    var canceled = false
  }

  /// The meeting an event is, if it qualifies. Attendees other than the user count; with none,
  /// a video link in the location, notes or URL does. Declined, free, all-day and canceled
  /// events never count. An event with neither id gets one from its times, so it still counts.
  /// Task 6.5 dedupes Google's copy against these on (id, start): a recurring event's
  /// occurrences share one id.
  static func meeting(_ event: Fields) -> MeetingEvent? {
    let me = event.attendees?.first(where: \.isCurrentUser)
    let others = event.attendees?.filter { !$0.isCurrentUser }.count ?? 0
    let candidate = MeetingRules.Candidate(
      otherAttendees: others,
      hasVideoLink: MeetingRules.hasVideoLink(event.text.compactMap { $0 }.joined(separator: " ")),
      allDay: event.isAllDay, free: event.free, declined: me?.declined == true,
      canceled: event.canceled)
    guard MeetingRules.qualifies(candidate), let start = event.start, let end = event.end
    else { return nil }
    let id =
      event.externalID ?? event.eventID
      ?? "local:\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)"
    return MeetingEvent(id: id, start: start, end: end)
  }
}

/// EventKit's side, reached only from its `CalendarMeetings` actor. The change observer posts
/// on any thread; it only clears that actor's cache.
///
/// `@unchecked Sendable` rests on the app's two instances having one role each: the
/// `CalendarMeetings` in `PermissionsModel` only requests access, the meeting monitor's only
/// reads events. So one `EKEventStore` never has a read and a pending request at once, which an
/// actor's reentrancy across `requestAccess()`'s await would otherwise allow.
final class EventKitStore: CalendarStore, @unchecked Sendable {
  private let store = EKEventStore()
  private let observer: any NSObjectProtocol

  init(changed: @escaping @Sendable () -> Void) {
    observer = NotificationCenter.default.addObserver(
      forName: .EKEventStoreChanged, object: store, queue: nil
    ) { _ in changed() }
  }

  deinit { NotificationCenter.default.removeObserver(observer) }

  func requestAccess() async -> Bool {
    (try? await store.requestFullAccessToEvents()) ?? false
  }

  func events(from start: Date, to end: Date) -> [CalendarMeetings.Fields] {
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
    return store.events(matching: predicate).map { event in
      .init(
        externalID: event.calendarItemExternalIdentifier, eventID: event.eventIdentifier,
        start: event.startDate, end: event.endDate,
        attendees: event.attendees?.map {
          .init(isCurrentUser: $0.isCurrentUser, declined: $0.participantStatus == .declined)
        },
        isAllDay: event.isAllDay, free: event.availability == .free,
        text: [event.location, event.notes, event.url?.absoluteString],
        canceled: event.status == .canceled)
    }
  }
}
