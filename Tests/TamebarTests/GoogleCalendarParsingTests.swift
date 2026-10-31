import Foundation
import Testing

@testable import Tamebar

/// Task 6.5's parsing and dedupe, from a recorded `events.list` response. Pure: no network.
struct GoogleCalendarParsingTests {
  /// 08:00Z on 2026-10-20, 10:00 in Paris.
  static let eight = Date(timeIntervalSince1970: 1_792_483_200)

  /// A `calendars/primary/events` response, trimmed to the requested `fields`. Each event
  /// but the first and last fails exactly one rule, so dropping a rule lets that event through.
  /// "focus" has only the user and no link.
  static let fixture = Data(
    #"""
    {
      "items": [
        {
          "id": "standup123",
          "iCalUID": "standup123@google.com",
          "status": "confirmed",
          "start": { "dateTime": "2026-10-20T10:00:00+02:00", "timeZone": "Europe/Paris" },
          "end": { "dateTime": "2026-10-20T10:30:00+02:00", "timeZone": "Europe/Paris" },
          "attendees": [
            { "self": true, "responseStatus": "accepted" },
            { "responseStatus": "accepted" }
          ],
          "hangoutLink": "https://meet.google.com/abc-defg-hij"
        },
        {
          "id": "offsite",
          "iCalUID": "offsite@google.com",
          "status": "confirmed",
          "start": { "date": "2026-10-20" },
          "end": { "date": "2026-10-21" },
          "attendees": [
            { "self": true, "responseStatus": "accepted" },
            { "responseStatus": "accepted" }
          ],
          "hangoutLink": "https://meet.google.com/all-day-link"
        },
        {
          "id": "lunch",
          "iCalUID": "lunch@google.com",
          "status": "confirmed",
          "start": { "dateTime": "2026-10-20T08:00:00Z" },
          "end": { "dateTime": "2026-10-20T09:00:00Z" },
          "attendees": [
            { "self": true, "responseStatus": "accepted" },
            { "responseStatus": "accepted" }
          ],
          "transparency": "transparent"
        },
        {
          "id": "review",
          "iCalUID": "review@google.com",
          "status": "confirmed",
          "start": { "dateTime": "2026-10-20T08:00:00Z" },
          "end": { "dateTime": "2026-10-20T09:00:00Z" },
          "attendees": [
            { "self": true, "responseStatus": "declined" },
            { "responseStatus": "accepted" }
          ],
          "hangoutLink": "https://meet.google.com/declined-link"
        },
        {
          "id": "sync",
          "iCalUID": "sync@google.com",
          "status": "cancelled",
          "start": { "dateTime": "2026-10-20T08:00:00Z" },
          "end": { "dateTime": "2026-10-20T09:00:00Z" },
          "attendees": [
            { "self": true, "responseStatus": "accepted" },
            { "responseStatus": "accepted" }
          ],
          "hangoutLink": "https://meet.google.com/cancelled-link"
        },
        {
          "id": "focus",
          "iCalUID": "focus@google.com",
          "status": "confirmed",
          "start": { "dateTime": "2026-10-20T08:00:00Z" },
          "end": { "dateTime": "2026-10-20T09:00:00Z" },
          "attendees": [{ "self": true, "responseStatus": "accepted" }],
          "description": "Heads down. No calls."
        },
        {
          "id": "teams456",
          "iCalUID": "040000008200E00074C5B7101A82E00800000000AB12CD@outlook",
          "status": "confirmed",
          "start": { "dateTime": "2026-10-20T11:00:00+02:00" },
          "end": { "dateTime": "2026-10-20T12:00:00+02:00" },
          "description": "<p>Join on your computer</p><a href=\"https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZmQ%40thread.v2/0\">Click here to join</a>"
        }
      ]
    }
    """#.utf8)

  @Test func onlyTimedBusyAcceptedEventsWithSomeoneOrALinkCount() {
    #expect(
      GoogleCalendarParsing.events(Self.fixture) == [
        MeetingEvent(
          id: "standup123@google.com", start: Self.eight,
          end: Self.eight.addingTimeInterval(1_800)),
        MeetingEvent(
          id: "040000008200E00074C5B7101A82E00800000000AB12CD@outlook",
          start: Self.eight.addingTimeInterval(3_600), end: Self.eight.addingTimeInterval(7_200)),
      ])
  }

  @Test func theEventIDStandsInWithoutAnICalUID() {
    let data = Data(
      #"""
      {"items": [{"id": "abc_20261020T080000Z", "status": "confirmed",
        "start": {"dateTime": "2026-10-20T08:00:00Z"}, "end": {"dateTime": "2026-10-20T08:30:00Z"},
        "location": "https://zoom.us/j/123"}]}
      """#.utf8)
    #expect(
      GoogleCalendarParsing.events(data) == [
        MeetingEvent(
          id: "abc_20261020T080000Z", start: Self.eight, end: Self.eight.addingTimeInterval(1_800))
      ])
  }

  @Test func fractionalSecondsParse() {
    let data = Data(
      #"""
      {"items": [{"iCalUID": "f@google.com", "hangoutLink": "https://meet.google.com/x",
        "start": {"dateTime": "2026-10-20T08:00:00.000Z"}, "end": {"dateTime": "2026-10-20T08:30:00.000Z"}}]}
      """#.utf8)
    #expect(GoogleCalendarParsing.events(data).map(\.start) == [Self.eight])
  }

  @Test func anythingElseIsNoEvents() {
    #expect(GoogleCalendarParsing.events(Data("not json".utf8)).isEmpty)
    #expect(GoogleCalendarParsing.events(Data(#"{"error": {"code": 401}}"#.utf8)).isEmpty)
    #expect(GoogleCalendarParsing.events(Data(#"{"items": [{"id": 3}]}"#.utf8)).isEmpty)
  }

  // MARK: Dedupe against EventKit

  @Test func googleCopiesOfEventKitEventsAreDroppedOnIDAndStart() {
    let mine = MeetingEvent(
      id: "standup123@google.com", start: Self.eight, end: Self.eight.addingTimeInterval(1_800))
    let google = [
      mine,
      // The same recurring event, the next day: occurrences share the iCalUID.
      MeetingEvent(
        id: mine.id, start: Self.eight.addingTimeInterval(86_400),
        end: Self.eight.addingTimeInterval(88_200)),
      // Another event at the same time.
      MeetingEvent(id: "other@google.com", start: Self.eight, end: mine.end),
    ]
    #expect(MeetingEvent.merged(local: [mine], google: google) == [mine] + google.dropFirst())
    #expect(MeetingEvent.merged(local: [], google: google) == google)
    #expect(MeetingEvent.merged(local: [mine], google: []) == [mine])
  }
}
