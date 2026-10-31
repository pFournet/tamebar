import Foundation
import Testing

@testable import Tamebar

/// EventKit's side of M1, without EventKit: the event-to-meeting mapping is pure. Nothing here
/// creates an `EKEventStore` or asks for calendar access.
struct CalendarMeetingsTests {
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  func event(
    attendees: [CalendarMeetings.Attendee]? = nil, allDay: Bool = false, free: Bool = false,
    text: [String?] = [], start: Date? = nil, end: Date? = nil,
    externalID: String? = "ext-1", canceled: Bool = false
  ) -> CalendarMeetings.Fields {
    .init(
      externalID: externalID, eventID: "local-1", start: start ?? t0,
      end: end ?? t0.addingTimeInterval(1_800), attendees: attendees, isAllDay: allDay,
      free: free, text: text, canceled: canceled)
  }

  let me = CalendarMeetings.Attendee(isCurrentUser: true, declined: false)
  let guest = CalendarMeetings.Attendee(isCurrentUser: false, declined: false)

  @Test func anEventWithAnotherAttendeeIsAMeeting() {
    let meeting = CalendarMeetings.meeting(event(attendees: [me, guest]))
    #expect(meeting == MeetingEvent(id: "ext-1", start: t0, end: t0.addingTimeInterval(1_800)))
  }

  @Test func onlyTheUserOrNoOneIsNotAMeetingWithoutAVideoLink() {
    #expect(CalendarMeetings.meeting(event(attendees: [me])) == nil)
    #expect(CalendarMeetings.meeting(event(attendees: nil)) == nil)
    #expect(CalendarMeetings.meeting(event(attendees: [])) == nil)
  }

  @Test func aVideoLinkInTheLocationNotesOrURLMakesAMeetingAlone() {
    for text in [
      ["https://meet.google.com/abc-defg-hij", nil, nil],
      [nil, "Join https://us02web.zoom.us/j/123", nil],
      [nil, nil, "https://teams.microsoft.com/l/meetup-join/x"],
    ] {
      #expect(CalendarMeetings.meeting(event(text: text)) != nil, "\(text)")
    }
    #expect(CalendarMeetings.meeting(event(text: ["Room 4", "Bring snacks"])) == nil)
  }

  @Test func aDeclinedEventIsNotAMeeting() {
    let declined = CalendarMeetings.Attendee(isCurrentUser: true, declined: true)
    #expect(CalendarMeetings.meeting(event(attendees: [declined, guest])) == nil)
    // Another attendee's decline doesn't matter.
    let other = CalendarMeetings.Attendee(isCurrentUser: false, declined: true)
    #expect(CalendarMeetings.meeting(event(attendees: [other, me, guest])) != nil)
  }

  @Test func aFreeEventIsNotAMeeting() {
    #expect(CalendarMeetings.meeting(event(attendees: [me, guest], free: true)) == nil)
  }

  @Test func aCanceledEventIsNotAMeeting() {
    #expect(CalendarMeetings.meeting(event(attendees: [me, guest], canceled: true)) == nil)
  }

  @Test func anAllDayEventIsNotAMeeting() {
    #expect(
      CalendarMeetings.meeting(
        event(attendees: [me, guest], allDay: true, text: ["https://meet.google.com/x"])) == nil)
  }

  @Test func theExternalIDIsPreferredAndTheLocalOneStandsIn() {
    #expect(CalendarMeetings.meeting(event(attendees: [guest]))?.id == "ext-1")
    #expect(CalendarMeetings.meeting(event(attendees: [guest], externalID: nil))?.id == "local-1")
  }

  @Test func anEventWithNoIDStillCountsUnderOneFromItsTimes() {
    let fields = CalendarMeetings.Fields(
      externalID: nil, eventID: nil, start: t0, end: t0.addingTimeInterval(1_800),
      attendees: [guest], isAllDay: false, free: false, text: [])
    let meeting = CalendarMeetings.meeting(fields)
    #expect(meeting?.id == "local:1800000000.0-1800001800.0")
    #expect(meeting?.start == t0)
  }
}

/// `CalendarMeetings` over a fake store: the cache, a revoke, a change, and the permission row's
/// deny path. No `EKEventStore` is made.
@MainActor
struct CalendarStoreTests {
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  final class Fake: CalendarStore, @unchecked Sendable {
    var reads = 0
    var grants = true
    var fields: [CalendarMeetings.Fields] = []
    var changed: (@Sendable () -> Void)?

    func requestAccess() async -> Bool { grants }

    func events(from start: Date, to end: Date) -> [CalendarMeetings.Fields] {
      reads += 1
      return fields.filter {
        ($0.start ?? .distantPast) < end && ($0.end ?? .distantFuture) > start
      }
    }
  }

  final class Setup: @unchecked Sendable {
    var authorized = true
    var stores: [Fake] = []
    lazy var calendar = CalendarMeetings(
      authorized: { [unowned self] in authorized },
      makeStore: { [unowned self] changed in
        let store = Fake()
        store.changed = changed
        store.fields = [
          .init(
            externalID: "x", eventID: nil, start: Date(timeIntervalSince1970: 1_800_000_600),
            end: Date(timeIntervalSince1970: 1_800_002_400),
            attendees: [.init(isCurrentUser: false, declined: false)], isAllDay: false,
            free: false, text: [])
        ]
        stores.append(store)
        return store
      })
  }

  @Test func aReadIsReusedForAMinute() async {
    let setup = Setup()
    #expect(await setup.calendar.events(around: t0).map(\.id) == ["x"])
    _ = await setup.calendar.events(around: t0.addingTimeInterval(59))
    #expect(setup.stores.map(\.reads) == [1])
    _ = await setup.calendar.events(around: t0.addingTimeInterval(60))
    #expect(setup.stores.map(\.reads) == [2])
    #expect(CalendarMeetings.refreshAfter == 60)
  }

  @Test func aStoreChangeClearsTheCache() async {
    let setup = Setup()
    _ = await setup.calendar.events(around: t0)
    setup.stores.first?.changed?()
    // The change hops to the actor in a task; the next read after it fetches again.
    await setup.calendar.storeChanged()
    _ = await setup.calendar.events(around: t0.addingTimeInterval(1))
    #expect(setup.stores.map(\.reads) == [2])
  }

  @Test func withoutAccessNothingIsReadAndARevokeDropsTheStore() async {
    let setup = Setup()
    setup.authorized = false
    #expect(await setup.calendar.events(around: t0).isEmpty)
    #expect(setup.stores.isEmpty, "a store was made without access")
    setup.authorized = true
    _ = await setup.calendar.events(around: t0)
    setup.authorized = false
    #expect(await setup.calendar.events(around: t0.addingTimeInterval(1)).isEmpty)
    setup.authorized = true
    #expect(await setup.calendar.events(around: t0.addingTimeInterval(2)).map(\.id) == ["x"])
    #expect(setup.stores.count == 2, "a revoke kept the old store")
    #expect(setup.stores.map(\.reads) == [1, 1], "a revoke kept the cache")
  }

  @Test func deniedAccessOpensTheCalendarsPane() async {
    let setup = Setup()
    var opened = 0
    let model = PermissionsModel(
      calendar: setup.calendar, calendarAuthorized: { false }, openCalendarsPane: { opened += 1 })
    #expect(!model.calendars)
    _ = await setup.calendar.events(around: t0)
    setup.stores.first?.grants = false
    await model.requestCalendars()
    #expect(!model.calendars)
    #expect(opened == 1)
    setup.stores.first?.grants = true
    await model.requestCalendars()
    #expect(model.calendars)
    #expect(opened == 1, "the pane opened after a grant")
  }
}
