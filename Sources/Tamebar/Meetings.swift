import Foundation

/// A calendar meeting that qualified (`MeetingRules.qualifies`), from any source.
struct MeetingEvent: Equatable, Sendable {
  let id: String
  let start: Date
  let end: Date
}

/// What counts as a meeting, and when Tamebar treats one as on (M1). Pure.
///
/// A qualifying event is on from `lead` before its start until its end. The mic or camera alone
/// is a call only once it has stayed in use (`micSustain`, `cameraSustain`), so a short
/// dictation or a camera check doesn't pause anything. A call held by the mic or camera ends
/// `hold` after both go off, so a brief mute or a rejoin doesn't resume and re-pause
/// everything. A calendar-only meeting still ends at its end.
enum MeetingRules {
  /// A meeting is on from this long before its start.
  static let lead: TimeInterval = 120
  /// The mic alone, with no qualifying event, is a call after this long in use.
  static let micSustain: TimeInterval = 30
  /// The camera alone is a call after this long in use.
  static let cameraSustain: TimeInterval = 10
  /// A call that was on stays on this long after the mic and camera both go off.
  static let hold: TimeInterval = 45
  /// A longer gap between two steps means the Mac slept: the mic and camera are timed afresh.
  static let wakeGap = AutoPausePlanner.wakeGap

  /// A calendar event, as the rules read it.
  struct Candidate: Equatable, Sendable {
    /// Attendees other than the user.
    let otherAttendees: Int
    let hasVideoLink: Bool
    let allDay: Bool
    /// Shown as free (`EKEventAvailability.free`, Google's `transparent`).
    let free: Bool
    /// The user declined it.
    let declined: Bool
    /// The event itself was canceled.
    var canceled = false
  }

  /// A timed, busy event the user hasn't declined, not canceled, with someone else or a video
  /// link.
  static func qualifies(_ candidate: Candidate) -> Bool {
    !candidate.allDay && !candidate.free && !candidate.declined && !candidate.canceled
      && (candidate.otherAttendees > 0 || candidate.hasVideoLink)
  }

  /// Meet, Zoom (and ZoomGov), Teams (work and personal) and Webex join links, in any case.
  static let videoLinks = [
    "meet.google.com/", "zoom.us/j/", "zoom.us/my/", "zoomgov.com/j/",
    "teams.microsoft.com/l/meetup-join", "teams.microsoft.com/meet/", "teams.live.com/meet/",
    "webex.com/meet/", ".webex.com/wbxmjs/", ".webex.com/join/",
  ]

  static func hasVideoLink(_ text: String) -> Bool {
    videoLinks.contains { text.localizedCaseInsensitiveContains($0) }
  }

  /// When the mic and camera went on, when both went off, and the last step. Kept between
  /// steps.
  struct Clocks: Equatable, Sendable {
    var micSince: Date?
    var cameraSince: Date?
    var offSince: Date?
    var lastStep: Date?

    /// Dates a backward clock jump left in the future come back to now.
    func rebased(_ now: Date) -> Clocks {
      .init(
        micSince: micSince.map { min($0, now) }, cameraSince: cameraSince.map { min($0, now) },
        offSince: offSince.map { min($0, now) }, lastStep: lastStep.map { min($0, now) })
    }
  }

  struct State: Sendable {
    let now: Date
    /// Qualifying events around now.
    let events: [MeetingEvent]
    /// A process is recording from a microphone (`CallSignals`).
    let mic: Bool
    /// A camera is in use.
    let camera: Bool
    /// The previous step's answer.
    let wasActive: Bool
    var clocks = Clocks()
  }

  struct Step: Equatable, Sendable {
    let active: Bool
    let clocks: Clocks
    /// A qualifying event is in its window (with the lead): the island's "calendar" label.
    let inEvent: Bool
  }

  /// A qualifying event is under way at `now`, counting the lead.
  static func inEvent(_ events: [MeetingEvent], now: Date) -> Bool {
    events.contains { now >= $0.start.addingTimeInterval(-lead) && now < $0.end }
  }

  static func step(_ state: State) -> Step {
    let now = state.now
    var clocks = state.clocks.rebased(now)
    if let last = clocks.lastStep, now.timeIntervalSince(last) > wakeGap {
      // A sleep: what was on before it isn't proof it stayed on.
      clocks.micSince = nil
      clocks.cameraSince = nil
    }
    clocks.lastStep = now
    clocks.micSince = state.mic ? clocks.micSince ?? now : nil
    clocks.cameraSince = state.camera ? clocks.cameraSince ?? now : nil
    clocks.offSince = state.mic || state.camera ? nil : clocks.offSince ?? now
    func lasted(_ since: Date?, _ length: TimeInterval) -> Bool {
      since.map { now.timeIntervalSince($0) >= length } ?? false
    }
    let sustained =
      lasted(clocks.micSince, micSustain) || lasted(clocks.cameraSince, cameraSustain)
    // A call already on holds while the mic or camera is on, and for `hold` after both go off.
    let held =
      state.wasActive && (clocks.offSince.map { now.timeIntervalSince($0) < hold } ?? true)
    let event = inEvent(state.events, now: now)
    return Step(active: event || sustained || held, clocks: clocks, inEvent: event)
  }
}
