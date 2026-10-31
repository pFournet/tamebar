import Foundation
import Testing

@testable import Tamebar

struct MeetingRulesTests {
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  func event(start: TimeInterval, minutes: Double) -> MeetingEvent {
    .init(
      id: "e", start: t0.addingTimeInterval(start),
      end: t0.addingTimeInterval(start + minutes * 60))
  }

  func candidate(
    attendees: Int = 1, video: Bool = false, allDay: Bool = false, free: Bool = false,
    declined: Bool = false, canceled: Bool = false
  ) -> MeetingRules.Candidate {
    .init(
      otherAttendees: attendees, hasVideoLink: video, allDay: allDay, free: free,
      declined: declined, canceled: canceled)
  }

  /// Steps the rules through `samples` (seconds after t0, mic, camera), carrying the state, and
  /// returns each answer.
  func run(
    _ samples: [(TimeInterval, mic: Bool, camera: Bool)], events: [MeetingEvent] = []
  ) -> [Bool] {
    var clocks = MeetingRules.Clocks()
    var active = false
    return samples.map { second, mic, camera in
      let step = MeetingRules.step(
        .init(
          now: t0.addingTimeInterval(second), events: events, mic: mic, camera: camera,
          wasActive: active, clocks: clocks))
      clocks = step.clocks
      active = step.active
      return active
    }
  }

  @Test func qualifiesOnlyRealMeetings() {
    #expect(MeetingRules.qualifies(candidate()))
    #expect(MeetingRules.qualifies(candidate(attendees: 0, video: true)))
    #expect(!MeetingRules.qualifies(candidate(attendees: 0)))
  }

  @Test func allDayFreeDeclinedAndCanceledEventsNeverCount() {
    #expect(!MeetingRules.qualifies(candidate(attendees: 3, video: true, allDay: true)))
    #expect(!MeetingRules.qualifies(candidate(attendees: 3, video: true, free: true)))
    #expect(!MeetingRules.qualifies(candidate(attendees: 3, video: true, declined: true)))
    #expect(!MeetingRules.qualifies(candidate(attendees: 3, video: true, canceled: true)))
  }

  @Test func videoLinksAreRecognised() {
    for link in [
      "Join: https://meet.google.com/abc-defg-hij", "https://us02web.zoom.us/j/123",
      "https://zoom.us/my/alex", "https://acme.zoomgov.com/j/161", "HTTPS://MEET.GOOGLE.COM/ABC",
      "https://teams.microsoft.com/l/meetup-join/x", "https://teams.microsoft.com/meet/123?p=x",
      "https://teams.live.com/meet/9876", "https://acme.webex.com/meet/alex",
      "https://acme.webex.com/wbxmjs/joinservice/sites/acme/meeting/download/x",
      "https://acme.webex.com/join/alex",
    ] {
      #expect(MeetingRules.hasVideoLink(link), "\(link)")
    }
    #expect(!MeetingRules.hasVideoLink("Room 4"))
    #expect(!MeetingRules.hasVideoLink("https://zoom.us/pricing"))
    #expect(!MeetingRules.hasVideoLink("https://www.webex.com/pricing"))
  }

  @Test func aMeetingIsOnFromTwoMinutesBeforeUntilItsEnd() {
    let events = [event(start: 600, minutes: 30)]
    let off = (mic: false, camera: false)
    #expect(
      run([(479, off.mic, off.camera)], events: events) == [false], "on before the lead")
    #expect(run([(480, off.mic, off.camera)], events: events) == [true], "on at once")
    #expect(
      run([(1_000, off.mic, off.camera), (2_399, off.mic, off.camera)], events: events)
        == [true, true])
    #expect(MeetingRules.lead == 120)
  }

  @Test func aCalendarOnlyMeetingEndsAtItsEnd() {
    let events = [event(start: 600, minutes: 30)]
    #expect(
      run(
        [(1_000, false, false), (2_399, false, false), (2_400, false, false)], events: events)
        == [true, true, false])
  }

  @Test func theMicAloneIsACallAfterThirtySecondsOfUse() {
    #expect(run([(0, true, false), (29, true, false)]) == [false, false])
    #expect(run([(0, true, false), (30, true, false)]) == [false, true])
    // A gap restarts the count.
    #expect(
      run([(0, true, false), (20, false, false), (25, true, false), (50, true, false)])
        == [false, false, false, false])
    #expect(MeetingRules.micSustain == 30)
  }

  @Test func theCameraAloneIsACallAfterTenSeconds() {
    #expect(run([(0, false, true), (9, false, true)]) == [false, false])
    #expect(run([(0, false, true), (10, false, true)]) == [false, true])
    #expect(MeetingRules.cameraSustain == 10)
  }

  @Test func aCallFromTheMicOrCameraEndsFortyFiveSecondsAfterBothGoOff() {
    let call: [(TimeInterval, mic: Bool, camera: Bool)] = [
      (0, true, false), (30, true, true), (60, false, false),
    ]
    #expect(run(call + [(104, false, false)]) == [false, true, true, true])
    #expect(run(call + [(105, false, false)]) == [false, true, true, false])
    // The camera alone keeps it on; turning it off starts the 45 s again.
    #expect(
      run(call + [(100, false, true), (140, false, false), (184, false, false)])
        == [false, true, true, true, true, true])
    #expect(MeetingRules.hold == 45)
  }

  @Test func aMeetingThatRunsOverStaysOnWhileTheMicIsOnThenHolds() {
    let events = [event(start: 0, minutes: 10)]
    #expect(
      run(
        [
          (100, true, false), (599, true, false), (650, true, false), (694, false, false),
          (740, false, false),
        ], events: events)
        == [true, true, true, true, false])
  }

  /// A hold that started "in the future" (the clock went back) restarts at now, so the call
  /// still gets its 45 s and no more.
  @Test func aBackwardJumpRebasesTheHold() {
    let clocks = MeetingRules.Clocks(offSince: t0.addingTimeInterval(500), lastStep: t0)
    let step = MeetingRules.step(
      .init(now: t0, events: [], mic: false, camera: false, wasActive: true, clocks: clocks))
    #expect(step.clocks.offSince == t0)
    #expect(step.active)
    let later = MeetingRules.step(
      .init(
        now: t0.addingTimeInterval(45), events: [], mic: false, camera: false, wasActive: true,
        clocks: step.clocks))
    #expect(!later.active, "the hold outlived 45 s after the jump")
  }

  /// After a sleep the mic is timed afresh: 30 s of use before it, then more after, isn't a call
  /// until 30 s after the wake.
  @Test func aWakeGapRestartsTheMicAndCamera() {
    #expect(
      run([
        (0, true, true), (5, true, false), (66, true, false), (95, true, false), (96, true, false),
      ])
        == [false, false, false, false, true])
    #expect(
      run([
        (0, false, true), (5, false, true), (70, false, true), (79, false, true), (80, false, true),
      ])
        == [false, false, false, false, true], "the camera kept its time across a sleep")
    #expect(run([(0, false, true), (60, false, true)]) == [false, true], "60 s is no sleep")
    #expect(MeetingRules.wakeGap == 60)
  }

  @Test func aBackwardClockJumpIsRebased() {
    let clocks = MeetingRules.Clocks(micSince: t0.addingTimeInterval(500))
    let step = MeetingRules.step(
      .init(now: t0, events: [], mic: true, camera: false, wasActive: false, clocks: clocks))
    #expect(step.clocks.micSince == t0)
  }
}
