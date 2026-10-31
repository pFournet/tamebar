import Foundation
import Testing

@testable import Tamebar

/// Blocks a synchronous caller, as a probe stuck in a system call would, until `open()`.
final class BlockingGate: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var opened = false

  func block() {
    if lock.withLock({ opened }) { return }
    semaphore.wait()
    semaphore.signal()
  }

  func open() {
    lock.withLock { opened = true }
    semaphore.signal()
  }

  /// Opens the gate after `seconds` whatever happens, so code that waits on the blocked caller
  /// (a missing timeout) fails its expectations instead of hanging the run: a time limit can't
  /// end an await on a detached task.
  func openAfter(seconds: Double) {
    Task.detached { [self] in
      try? await Task.sleep(for: .seconds(seconds))
      open()
    }
  }
}

/// M1's combining step. The sources are injected: nothing here reads the real mic, camera or
/// calendar.
@MainActor
struct MeetingMonitorTests {
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  var meeting: MeetingEvent {
    .init(id: "m", start: t0.addingTimeInterval(600), end: t0.addingTimeInterval(2_400))
  }

  /// A pure tick: what the sources would have read, at `second`.
  func tick(
    _ monitor: MeetingMonitor, _ second: TimeInterval, events: [MeetingEvent] = [],
    calls: CallReading? = nil, forced: Bool? = nil
  ) -> Bool {
    monitor.tick(
      now: t0.addingTimeInterval(second),
      observation: .init(events: events, calls: calls, forced: forced))
  }

  let mic = CallReading(unattributedInput: true)
  let quiet = CallReading()

  @Test func aCalendarMeetingIsOnFromTwoMinutesBefore() {
    let monitor = MeetingMonitor(sources: .none)
    #expect(!tick(monitor, 479, events: [meeting], calls: quiet))
    #expect(monitor.source == .none)
    #expect(tick(monitor, 480, events: [meeting], calls: quiet))
    #expect(monitor.source == .calendar)
    #expect(!tick(monitor, 2_400, events: [meeting], calls: quiet))
    #expect(monitor.source == .none)
  }

  @Test func theMicIsACallAfterThirtySecondsAndTheCameraAfterTen() {
    let monitor = MeetingMonitor(sources: .none)
    #expect(!tick(monitor, 0, calls: mic))
    #expect(tick(monitor, 30, calls: mic))
    #expect(monitor.source == .mic)
    let camera = MeetingMonitor(sources: .none)
    #expect(!tick(camera, 0, calls: CallReading(camera: true)))
    #expect(tick(camera, 10, calls: CallReading(camera: true)))
  }

  @Test func aCallThatRunsOverStaysOnWhileTheMicIsOn() {
    let monitor = MeetingMonitor(sources: .none)
    #expect(tick(monitor, 1_000, events: [meeting], calls: mic))
    #expect(monitor.source == .calendar)
    #expect(tick(monitor, 2_500, events: [meeting], calls: mic))
    #expect(monitor.source == .mic)
  }

  @Test func aFailedReadKeepsTheLastAnswer() {
    let monitor = MeetingMonitor(sources: .none)
    let camera = CallReading(camera: true)
    #expect(!tick(monitor, 0, calls: camera))
    #expect(tick(monitor, 10, calls: camera))
    #expect(tick(monitor, 60, calls: nil), "a failed read ended the call")
    #expect(tick(monitor, 110, calls: nil), "failed reads ended the call")
    #expect(tick(monitor, 125, calls: nil), "failed reads under 2 min ended the call")
    #expect(tick(monitor, 130, calls: quiet), "the 45 s hold")
    #expect(!tick(monitor, 175, calls: quiet))
    #expect(!tick(monitor, 200, calls: nil), "a failed read started a call")
  }

  /// A probe that keeps failing can't hold a call forever: after 2 min with no good read the
  /// mic and camera count as off, then the 45 s hold ends it.
  @Test func twoMinutesOfFailedReadsCountTheMicAndCameraAsOff() {
    let monitor = MeetingMonitor(sources: .none)
    let camera = CallReading(camera: true)
    #expect(!tick(monitor, 0, calls: camera))
    #expect(tick(monitor, 10, calls: camera))
    #expect(tick(monitor, 129, calls: nil))
    #expect(tick(monitor, 130, calls: nil), "the hold after the stale read")
    #expect(tick(monitor, 174, calls: nil))
    #expect(!tick(monitor, 175, calls: nil), "failed reads held the call forever")
    #expect(MeetingMonitor.staleRead == 120)
  }

  /// A read that didn't come back in time (nil): the last events and control stand.
  @Test func aMissedReadKeepsTheLastEventsAndControl() {
    let monitor = MeetingMonitor(sources: .none)
    #expect(tick(monitor, 1_000, events: [meeting], calls: quiet))
    #expect(monitor.tick(now: t0.addingTimeInterval(1_005), observation: nil))
    #expect(monitor.source == .calendar)
    #expect(!monitor.tick(now: t0.addingTimeInterval(2_400), observation: nil), "past its end")
    let forced = MeetingMonitor(sources: .none)
    #expect(tick(forced, 0, forced: true))
    #expect(forced.tick(now: t0.addingTimeInterval(1), observation: nil))
  }

  /// The race a scan runs: a task that blocks answers nil after the limit; one that finishes
  /// answers its value.
  @Test(.timeLimit(.minutes(1))) func aSlowReadTimesOut() async {
    let gate = BlockingGate()
    gate.openAfter(seconds: 20)
    let blocked = Task.detached { () -> Int in
      gate.block()
      return 1
    }
    let started = Date.now
    #expect(await MeetingMonitor.value(of: blocked, within: .milliseconds(200)) == nil)
    #expect(Date.now.timeIntervalSince(started) < 5)
    gate.open()
    #expect(await blocked.value == 1)
    let quick = Task.detached { 2 }
    #expect(await MeetingMonitor.value(of: quick, within: .seconds(10)) == 2)
  }

  @Test func theE2EControlWinsOverEverySourceAtOnce() {
    let off = MeetingMonitor(sources: .none)
    #expect(!tick(off, 1_000, events: [meeting], calls: mic, forced: false))
    #expect(off.source == .none)
    let on = MeetingMonitor(sources: .none)
    #expect(tick(on, 0, forced: true), "the control is immediate")
    #expect(on.source == .calendar)
    #expect(!tick(on, 1, forced: false), "the control ends it at once")
  }

  @Test func observeReadsEverySourceOnce() async {
    final class Count: @unchecked Sendable { var calls = 0 }
    let count = Count()
    let event = meeting
    let sources = MeetingMonitor.Sources(
      calendar: { _ in [event] },
      calls: {
        count.calls += 1
        return CallReading(camera: true)
      }, forced: { nil })
    let observation = await MeetingMonitor.observe(sources, now: t0)
    #expect(observation == .init(events: [event], calls: CallReading(camera: true), forced: nil))
    #expect(count.calls == 1)
    #expect(await MeetingMonitor.observe(.none, now: t0) == .init())
  }

  @Test func onlyTheShippedAppReadsTheRealSources() {
    #expect(!MeetingMonitor.launch(e2e: nil, shipped: false).isLive)
    #expect(MeetingMonitor.launch(e2e: nil, shipped: false).sources.calendar == nil)
    #expect(MeetingMonitor.launch(e2e: nil, shipped: true).isLive)
    #expect(!MeetingMonitor.launch().isLive, "this test process isn't the shipped app")
  }

  @Test func theE2EBuildReadsItsControlFileAndNoRealSource() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tamebar-meeting-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let control = dir.appendingPathComponent("control.json")
    let monitor = MeetingMonitor.launch(e2e: E2EMode(directory: dir), shipped: true)
    #expect(!monitor.isLive)
    #expect(monitor.sources.calendar == nil)
    func step() async -> Bool {
      monitor.tick(now: t0, observation: await MeetingMonitor.observe(monitor.sources, now: t0))
    }
    #expect(await !step(), "no control file is no meeting")
    try Data(#"{"meeting": true}"#.utf8).write(to: control)
    #expect(await step())
    try Data(#"{"meeting": false}"#.utf8).write(to: control)
    #expect(await !step())
  }
}
