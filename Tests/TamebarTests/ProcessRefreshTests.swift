import Foundation
import Testing

@testable import Tamebar

struct ProcessRefreshTests {
  @Test @MainActor
  func backgroundRefreshRemovesAStoppedListenerWithoutAnyWindow() async throws {
    let listener = Process()
    listener.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
    listener.arguments = ["-l", "127.0.0.1", String(Int.random(in: 49_152...60_000))]
    listener.standardOutput = FileHandle.nullDevice
    listener.standardError = FileHandle.nullDevice
    try listener.run()
    defer {
      if listener.isRunning { listener.terminate() }
    }
    let model = DevProcessModel()
    let firstDeadline = Date.now.addingTimeInterval(20)
    while !model.processes.contains(where: { $0.processID == listener.processIdentifier }),
      Date.now < firstDeadline
    {
      try await Task.sleep(for: .milliseconds(250))
    }
    try #require(model.processes.contains(where: { $0.processID == listener.processIdentifier }))
    let before = model.scannedAt
    listener.terminate()
    listener.waitUntilExit()
    let secondDeadline = Date.now.addingTimeInterval(20)
    while model.processes.contains(where: { $0.processID == listener.processIdentifier }),
      Date.now < secondDeadline
    {
      try await Task.sleep(for: .milliseconds(250))
    }
    #expect(!model.processes.contains(where: { $0.processID == listener.processIdentifier }))
    #expect(model.scannedAt != before)
  }

  /// Each scan reads the injected meeting sources once and feeds both the meeting answer and
  /// Q11's app probe from that read.
  @Test @MainActor
  func eachScanFeedsTheMeetingAndTheAppProbeFromOneRead() async {
    final class Count: @unchecked Sendable { var reads = 0 }
    let count = Count()
    let now = Date.now
    let event = MeetingEvent(
      id: "m", start: now.addingTimeInterval(-60), end: now.addingTimeInterval(3_600))
    let reading = CallReading(inputs: [.init(processID: 4_242, bundleID: "us.zoom.xos")])
    let model = DevProcessModel(
      meetingMonitor: MeetingMonitor(
        sources: .init(
          calendar: { _ in [event] },
          calls: {
            count.reads += 1
            return reading
          })))
    await model.refreshNow()
    #expect(model.meetingActive)
    #expect(model.callReading == reading)
    let before = count.reads
    await model.refreshNow()
    #expect(count.reads > before)
  }

  /// A probe stuck in a system call: the scan goes on after the timeout with no reading (every
  /// app held, the last meeting answer kept), and no second read starts behind the stuck one,
  /// from a scan or from the timer's `observeMeeting`.
  @Test(.timeLimit(.minutes(1))) @MainActor
  func aHungProbeNeitherStallsScansNorStacksReads() async throws {
    final class Probe: @unchecked Sendable {
      let gate = BlockingGate()
      private let lock = NSLock()
      private var count = 0
      private var blocks = false
      var reads: Int { lock.withLock { count } }
      func hang() { lock.withLock { blocks = true } }
      func read() -> CallReading? {
        if lock.withLock({ () -> Bool in
          count += 1
          return blocks
        }) {
          gate.block()
        }
        return CallReading(camera: true)
      }
    }
    let probe = Probe()
    defer { probe.gate.open() }
    probe.gate.openAfter(seconds: 20)
    let now = Date.now
    let event = MeetingEvent(
      id: "m", start: now.addingTimeInterval(-60), end: now.addingTimeInterval(3_600))
    let model = DevProcessModel(
      meetingMonitor: MeetingMonitor(
        sources: .init(calendar: { _ in [event] }, calls: { probe.read() })))
    model.meetingReadTimeout = .seconds(1)
    await model.refreshNow()
    #expect(model.meetingActive)
    #expect(model.callReading == CallReading(camera: true))
    probe.hang()
    await model.refreshNow()
    #expect(model.callReading == nil, "a hung read still fed the app probe")
    #expect(model.meetingActive, "the last meeting answer was dropped")
    #expect(model.meetingObserving)
    let reads = probe.reads
    await model.refreshNow()
    let skipped = Date.now
    #expect(await model.observeMeeting() == nil)
    #expect(Date.now.timeIntervalSince(skipped) < 0.5, "the timer waited on a new read")
    #expect(probe.reads == reads, "a read started behind the hung one")
    probe.gate.open()
    let deadline = Date.now.addingTimeInterval(10)
    while model.meetingObserving, Date.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(!model.meetingObserving)
    #expect(await model.observeMeeting()?.calls == CallReading(camera: true))
  }

  /// Q11 through the model: a recording child process holds the app it descends from, read from
  /// the scan's parents; another app stays free.
  @Test @MainActor
  func aRecordingChildHoldsItsAppThroughTheModel() async throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["60"]
    try child.run()
    defer {
      if child.isRunning { child.terminate() }
    }
    let reading = CallReading(inputs: [.init(processID: child.processIdentifier, bundleID: nil)])
    let model = DevProcessModel(meetingMonitor: MeetingMonitor(sources: .init(calls: { reading })))
    await model.refreshNow()
    #expect(model.callReading == reading)
    func app(_ id: String, _ pid: Int32) -> AppPressureWiring.Running {
      .init(
        bundleID: id, name: id, processID: pid, launchDate: nil,
        bundleURL: URL(fileURLWithPath: "/Applications/\(id).app"), isTerminated: false,
        prohibited: false)
    }
    // The test process stands in for the app; the child is its own.
    let scan = model.appPressureScan(
      scope: nil, running: [app("com.example.host", getpid()), app("com.example.other", 999_999)])
    let uses = Dictionary(uniqueKeysWithValues: scan.apps.map { ($0.bundleID, $0.usesMicOrCamera) })
    #expect(uses["com.example.host"] == .some(true))
    #expect(uses["com.example.other"] == .some(false))
  }
}
