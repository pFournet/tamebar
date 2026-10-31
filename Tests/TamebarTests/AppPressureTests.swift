import Darwin
import Foundation
import Testing

@testable import Tamebar

/// Q11, Task 5.5: listed apps quit under memory pressure, reopened after. Nothing here quits or
/// opens a real app: the planner is pure and the controller gets recording actions.
enum AppPressureTests {}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func app(
  _ id: String, bytes: UInt64 = 100, front: Bool = false, media: Bool? = false,
  protected: Bool = false, pid: Int32 = 900
) -> AppPressurePlanner.App {
  .init(
    bundleID: id, name: id.capitalized, processID: pid, launchDate: t0,
    bundleURL: URL(fileURLWithPath: "/Applications/\(id).app"), memoryBytes: bytes,
    isFrontmost: front, usesMicOrCamera: media, isProtected: protected)
}

private func entry(_ id: String, at second: TimeInterval, confirmed: Bool = true)
  -> AppPressurePlanner.Entry
{
  .init(
    bundleID: id, name: id.capitalized, bundleURL: URL(fileURLWithPath: "/Applications/\(id).app"),
    memoryBytes: 100, quitAt: t0.addingTimeInterval(second), confirmed: confirmed)
}

private func input(
  _ second: TimeInterval, pressure: Bool = true, calm: Bool = false, pending: Bool = false,
  lastPause: Date? = nil, apps: [AppPressurePlanner.App] = [], running: Set<String>? = nil,
  quitting: Set<String> = [], list: Set<String>? = nil, state: AppPressurePlanner.State = .init()
) -> AppPressurePlanner.Input {
  .init(
    now: t0.addingTimeInterval(second), pressure: pressure, calm: calm, othersPending: pending,
    lastPause: lastPause, apps: apps, running: running ?? Set(apps.map(\.bundleID)),
    quitting: quitting, list: AppQuitList(list ?? Set(apps.map(\.bundleID))),
    selfBundleID: "com.tamebar.Tamebar", state: state)
}

private func quits(_ output: AppPressurePlanner.Output) -> [String] {
  output.steps.compactMap { step in
    if case .quit(let app) = step { app.bundleID } else { nil }
  }
}

private func reopens(_ output: AppPressurePlanner.Output) -> [String] {
  output.steps.compactMap { step in
    if case .reopen(let entry) = step { entry.bundleID } else { nil }
  }
}

extension AppPressureTests {
  struct Planner {
    @Test func quitsTheLargestListedAppFirstThenOnePerThirtySeconds() {
      let apps = [app("small", bytes: 10), app("loom", bytes: 1_200), app("mid", bytes: 300)]
      var output = AppPressurePlanner.plan(input(0, apps: apps))
      #expect(quits(output) == ["loom"])
      #expect(output.state.ledger.map(\.bundleID) == ["loom"])
      #expect(output.state.ledger.first?.confirmed == false)
      var state = output.state
      state.quitLanded("loom", at: t0, ended: true)
      let left = apps.filter { $0.bundleID != "loom" }
      output = AppPressurePlanner.plan(input(29, apps: left, state: state))
      #expect(quits(output).isEmpty, "a second quit within 30 s")
      output = AppPressurePlanner.plan(input(30, apps: left, state: output.state))
      #expect(quits(output) == ["mid"])
    }

    @Test func waitsThirtySecondsAfterTheLatestAutomaticPause() {
      let apps = [app("loom")]
      #expect(quits(AppPressurePlanner.plan(input(20, lastPause: t0, apps: apps))).isEmpty)
      #expect(quits(AppPressurePlanner.plan(input(30, lastPause: t0, apps: apps))) == ["loom"])
    }

    @Test func nothingIsQuitWhileASessionOrProjectCandidateIsStillUnpaused() {
      let apps = [app("loom")]
      #expect(quits(AppPressurePlanner.plan(input(0, pending: true, apps: apps))).isEmpty)
      #expect(quits(AppPressurePlanner.plan(input(0, pending: false, apps: apps))) == ["loom"])
    }

    @Test func nothingIsQuitWhileAMeetingIsOn() {
      var meeting = input(0, apps: [app("loom")])
      meeting.inMeeting = true
      #expect(quits(AppPressurePlanner.plan(meeting)).isEmpty)
    }

    @Test func onlySustainedPressureQuits() {
      let apps = [app("loom")]
      #expect(quits(AppPressurePlanner.plan(input(0, pressure: false, apps: apps))).isEmpty)
      #expect(
        quits(AppPressurePlanner.plan(input(0, pressure: false, calm: true, apps: apps))).isEmpty)
    }

    @Test func theFrontAppAndAppsUsingTheMicOrCameraAreSkippedAndUnknownCountsAsInUse() {
      let apps = [
        app("front", bytes: 900, front: true), app("call", bytes: 800, media: true),
        app("unknown", bytes: 700, media: nil), app("loom", bytes: 10),
      ]
      #expect(quits(AppPressurePlanner.plan(input(0, apps: apps))) == ["loom"])
      let none = apps.filter { $0.bundleID != "loom" }
      #expect(quits(AppPressurePlanner.plan(input(0, apps: none))).isEmpty)
    }

    @Test func neverAnAppOutsideTheListTamebarItselfOrAProtectedApp() {
      let apps = [
        app("unlisted", bytes: 900), app("com.tamebar.Tamebar", bytes: 800),
        app("com.tamebar.Tamebar.e2e", bytes: 750), app("finder", bytes: 700, protected: true),
        app("loom", bytes: 10),
      ]
      let list: Set<String> = [
        "com.tamebar.Tamebar", "com.tamebar.Tamebar.e2e", "finder", "loom",
      ]
      #expect(quits(AppPressurePlanner.plan(input(0, apps: apps, list: list))) == ["loom"])
      let none = apps.filter { $0.bundleID != "loom" }
      #expect(quits(AppPressurePlanner.plan(input(0, apps: none, list: list))).isEmpty)
    }

    @Test func reopensOnlyWhatItQuitOldestFirstThirtySecondsApartAfterCalm() {
      var state = AppPressurePlanner.State()
      state.ledger = [entry("b", at: 40), entry("a", at: 10)]
      var output = AppPressurePlanner.plan(input(100, pressure: false, running: [], state: state))
      #expect(reopens(output).isEmpty, "a reopen before 30 calm seconds")
      output = AppPressurePlanner.plan(
        input(130, pressure: false, calm: true, running: ["other"], state: state))
      #expect(reopens(output) == ["a"])
      output = AppPressurePlanner.plan(
        input(131, pressure: false, calm: true, running: ["a"], state: output.state))
      #expect(reopens(output).isEmpty, "two reopens within 30 s")
      output = AppPressurePlanner.plan(
        input(159, pressure: false, calm: true, running: ["a"], state: output.state))
      #expect(reopens(output).isEmpty, "two reopens within 30 s")
      output = AppPressurePlanner.plan(
        input(160, pressure: false, calm: true, running: ["a"], state: output.state))
      #expect(reopens(output) == ["b"])
      #expect(output.state.ledger.isEmpty)
      #expect(
        output.state.reopenedAt == [
          "a": t0.addingTimeInterval(130), "b": t0.addingTimeInterval(160),
        ])
    }

    @Test func noForcedReopenUnderPressureHoweverLong() {
      var state = AppPressurePlanner.State()
      state.ledger = [entry("loom", at: 0)]
      state.lastQuit = t0
      let output = AppPressurePlanner.plan(input(3_600, running: [], state: state))
      #expect(reopens(output).isEmpty)
      #expect(output.state.ledger.map(\.bundleID) == ["loom"])
    }

    @Test func aQuitInFlightIsNeitherReopenedNorTakenForTheUsersReopen() {
      var state = AppPressurePlanner.State()
      state.ledger = [entry("loom", at: 0, confirmed: false)]
      let output = AppPressurePlanner.plan(
        input(40, pressure: false, calm: true, running: ["loom"], quitting: ["loom"], state: state))
      #expect(reopens(output).isEmpty)
      #expect(output.state.ledger.map(\.bundleID) == ["loom"])
      #expect(output.state.spared.isEmpty)
    }

    @Test func anAppStillRunningAfterTheTimeoutLeavesTheLedgerAndIsLeftAlone() {
      var output = AppPressurePlanner.plan(input(0, apps: [app("loom")]))
      var state = output.state
      state.quitLanded("loom", at: t0, ended: false)
      #expect(state.ledger.isEmpty)
      output = AppPressurePlanner.plan(input(60, apps: [app("loom")], state: state))
      #expect(quits(output).isEmpty, "quit again in the same episode")
      // Calm with nothing left to reopen ends the episode; the next one may try again.
      output = AppPressurePlanner.plan(
        input(200, pressure: false, calm: true, apps: [app("loom")], state: output.state))
      #expect(output.state.spared.isEmpty)
      output = AppPressurePlanner.plan(input(300, apps: [app("loom")], state: output.state))
      #expect(quits(output) == ["loom"])
    }

    @Test func aUserReopenLeavesTheLedgerAndIsNotQuitAgainThisEpisode() {
      var state = AppPressurePlanner.State()
      state.ledger = [entry("loom", at: 0)]
      state.lastQuit = t0
      var output = AppPressurePlanner.plan(input(40, apps: [app("loom")], state: state))
      #expect(output.state.ledger.isEmpty)
      #expect(output.state.spared == ["loom"])
      #expect(quits(output).isEmpty)
      output = AppPressurePlanner.plan(input(200, apps: [app("loom")], state: output.state))
      #expect(quits(output).isEmpty)
      output = AppPressurePlanner.plan(
        input(400, pressure: false, calm: true, apps: [app("loom")], state: output.state))
      #expect(reopens(output).isEmpty, "reopened an app the user already reopened")
    }

    @Test func aQuitLeftUnconfirmedByAnEarlierRunIsSettledByWhatRuns() {
      var state = AppPressurePlanner.State()
      state.ledger = [
        entry("gone", at: 0, confirmed: false), entry("open", at: 1, confirmed: false),
      ]
      let output = AppPressurePlanner.plan(
        input(5, pressure: false, running: ["open"], state: state))
      #expect(output.state.ledger.map(\.bundleID) == ["gone"])
      #expect(output.state.ledger.first?.confirmed == true)
      #expect(output.state.spared == ["open"])
    }

    @Test func anAppTamebarReopenedIsNotQuitAgainForFifteenMinutes() {
      var state = AppPressurePlanner.State()
      state.reopenedAt = ["loom": t0]
      let apps = [app("loom")]
      #expect(quits(AppPressurePlanner.plan(input(899, apps: apps, state: state))).isEmpty)
      let output = AppPressurePlanner.plan(input(900, apps: apps, state: state))
      #expect(quits(output) == ["loom"])
      #expect(output.state.reopenedAt.isEmpty, "a reopen older than 15 min is forgotten")
    }

    @Test func keepRunningWinsOverTheList() {
      var kept = app("loom", bytes: 900)
      kept.keepRunning = true
      #expect(quits(AppPressurePlanner.plan(input(0, apps: [kept, app("mid")]))) == ["mid"])
      #expect(quits(AppPressurePlanner.plan(input(0, apps: [kept]))).isEmpty)
    }

    @Test func aGoneAppIsDroppedAndAFailedReopenIsRetriedThreeTimes() {
      var state = AppPressurePlanner.State()
      let loom = entry("loom", at: 0)
      state.reopenedAt = ["loom": t0]
      #expect(state.reopenLanded(loom, .gone) == nil)
      #expect(state.ledger.isEmpty && state.reopenedAt.isEmpty)
      #expect(state.reopenLanded(loom, .opened) == nil)
      #expect(state.ledger.isEmpty)
      #expect(state.reopenLanded(loom, .failed) == nil)
      #expect(state.ledger.map(\.reopenAttempts) == [1])
      let second = state.ledger.removeFirst()
      #expect(state.reopenLanded(second, .failed) == nil)
      let third = state.ledger.removeFirst()
      #expect(third.reopenAttempts == 2)
      #expect(state.reopenLanded(third, .failed)?.reopenAttempts == 3)
      #expect(state.ledger.isEmpty)
    }

    @Test func aLeftoverLedgerIsKeptOnlyWhenTamebarWasDownUnderTwoHours() {
      var state = AppPressurePlanner.State()
      state.ledger = [entry("loom", at: 0)]
      let now = t0.addingTimeInterval(10_000)
      var kept = state
      #expect(kept.dropStale(lastTick: now.addingTimeInterval(-7_199), now: now).isEmpty)
      #expect(kept.ledger.count == 1)
      var stale = state
      #expect(stale.dropStale(lastTick: now.addingTimeInterval(-7_200), now: now).count == 1)
      #expect(stale.ledger.isEmpty)
      var unknown = state
      #expect(unknown.dropStale(lastTick: nil, now: now).count == 1)
    }

    @Test func datesLeftInTheFutureByAClockJumpAreRebased() {
      var state = AppPressurePlanner.State()
      state.lastQuit = t0.addingTimeInterval(1_000)
      state.ledger = [entry("a", at: 1_000)]
      let output = AppPressurePlanner.plan(
        input(10, pressure: false, apps: [], running: [], state: state))
      #expect(output.state.lastQuit == t0.addingTimeInterval(10))
      #expect(output.state.ledger.first?.quitAt == t0.addingTimeInterval(10))
    }
  }

  struct StillPausable {
    @Test func leavesOutWhatIsPausedOwnedForcedOrCoolingDown() {
      var state = AutoPausePlanner.State()
      state.ledger = [.init(threadID: "ledger", reason: .pressure, since: t0)]
      state.userResumed = ["user"]
      state.forceResumed = ["forced"]
      state.pauseFailedAt = ["failed": t0, "failedLongAgo": t0.addingTimeInterval(-60)]
      let ids = ["ledger", "user", "forced", "failed", "failedLongAgo", "paused", "free"]
      let candidates = ids.map {
        AutoPausePlanner.Candidate(threadID: $0, memoryBytes: 1, isPaused: false)
      }
      let pending = AutoPausePlanner.stillPausable(
        candidates + [.init(threadID: "flagged", memoryBytes: 1, isPaused: true)],
        pausedNow: ["paused"], state: state)
      // A candidate whose pause failed this episode doesn't hold the apps back, even once its
      // cooldown is over: it may keep failing.
      #expect(pending == ["free"])
    }
  }

  struct List {
    final class Memory {
      var value: Any?
      var store: AppQuitList.Store {
        .init(read: { self.value }, write: { self.value = $0 })
      }
    }

    @Test func savesSortedAndLoadsBack() {
      let memory = Memory()
      var list = AppQuitList()
      list.set("com.loom.desktop", on: true)
      list.set("com.spotify.client", on: true)
      list.set("com.spotify.client", on: false)
      list.set("com.figma.Desktop", on: true)
      list.save(memory.store)
      #expect(memory.value as? [String] == ["com.figma.Desktop", "com.loom.desktop"])
      #expect(AppQuitList.load(memory.store) == list)
      #expect(list.contains("com.loom.desktop") && !list.contains("com.spotify.client"))
    }

    @Test func loadsTolerantly() {
      let memory = Memory()
      #expect(AppQuitList.load(memory.store) == AppQuitList())
      memory.value = "com.loom.desktop"
      #expect(AppQuitList.load(memory.store) == AppQuitList())
      memory.value = ["com.loom.desktop", 7, "", ["nested"]] as [Any]
      #expect(AppQuitList.load(memory.store) == AppQuitList(["com.loom.desktop"]))
    }
  }

  struct Persistence {
    @Test func theAppLedgerRoundTripsWithTheSessionRecord() throws {
      var record = AutoPauseWiring.Record()
      record.state.ledger = [.init(threadID: "a", reason: .pressure, since: t0)]
      record.apps.ledger = [entry("loom", at: 0), entry("figma", at: 30, confirmed: false)]
      record.apps.lastQuit = t0.addingTimeInterval(30)
      record.apps.spared = ["slack"]
      record.apps.reopenedAt = ["zoom": t0]
      record.apps.lastReopen = t0
      record.apps.ledger[0].reopenAttempts = 2
      let data = try JSONEncoder().encode(record)
      #expect(try JSONDecoder().decode(AutoPauseWiring.Record.self, from: data) == record)
    }

    @Test func aBadEntryIsSkippedAndABadAppsFieldDropsNothingElse() throws {
      var record = AutoPauseWiring.Record()
      record.apps.ledger = [entry("loom", at: 0)]
      record.pendingResumes = ["b"]
      var json = try #require(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
      var apps = try #require(json["apps"] as? [String: Any])
      var ledger = try #require(apps["ledger"] as? [Any])
      ledger.append(["bundleID": 7])
      apps["ledger"] = ledger
      apps["spared"] = "not a set"
      json["apps"] = apps
      var decoded = try JSONDecoder().decode(
        AutoPauseWiring.Record.self, from: JSONSerialization.data(withJSONObject: json))
      #expect(decoded.apps.ledger.map(\.bundleID) == ["loom"])
      #expect(decoded.apps.spared.isEmpty)
      json["apps"] = ["ledger": "not a list", "spared": ["slack"]]
      decoded = try JSONDecoder().decode(
        AutoPauseWiring.Record.self, from: JSONSerialization.data(withJSONObject: json))
      #expect(decoded.apps.ledger.isEmpty)
      #expect(decoded.apps.spared == ["slack"], "a bad ledger dropped the other fields")
      json["apps"] = "garbage"
      decoded = try JSONDecoder().decode(
        AutoPauseWiring.Record.self, from: JSONSerialization.data(withJSONObject: json))
      #expect(decoded.apps == .init())
      #expect(decoded.pendingResumes == ["b"])
      json["apps"] = nil
      decoded = try JSONDecoder().decode(
        AutoPauseWiring.Record.self, from: JSONSerialization.data(withJSONObject: json))
      #expect(decoded.apps == .init())
    }
  }

  struct OlderFiles {
    @Test func anEntryWithoutTheNewerCountersStillLoads() throws {
      let json = """
        {"ledger": [{"bundleID": "loom", "name": "Loom", "bundleURL": "file:///Applications/Loom.app",
        "memoryBytes": 5, "quitAt": 0}]}
        """
      let state = try JSONDecoder().decode(AppPressurePlanner.State.self, from: Data(json.utf8))
      #expect(state.ledger.map(\.bundleID) == ["loom"])
      #expect(state.ledger.first?.confirmed == false)
      #expect(state.ledger.first?.reopenAttempts == 0)
    }

    @Test func theAppsOfAnUnreadableFileCanStillBeNamedForTheLog() {
      let data = Data(
        #"{"apps": {"ledger": [{"bundleID": "loom"}, 7, {"bundleID": "zoom"}]}, "state": 3}"#.utf8)
      #expect(AppPressureWiring.ledgerBundleIDs(data) == ["loom", "zoom"])
      #expect(AppPressureWiring.ledgerBundleIDs(Data("nope".utf8)).isEmpty)
    }
  }

  struct OpenOnQuit {
    @Test func opensTheRecordedBundleElseTheBundleID() {
      let loom = entry("loom", at: 0)
      #expect(
        AppPressureWiring.openArguments(loom, bundleExists: true)
          == ["-g", "/Applications/loom.app"])
      #expect(
        AppPressureWiring.openArguments(loom, bundleExists: false) == ["-g", "-b", "loom"])
    }
  }

  struct Note {
    @Test func aReopenThatKeptFailingSaysSo() {
      #expect(AppPressureWiring.reopenFailedNote(entry("loom", at: 0)) == "Couldn't reopen Loom")
    }

    @Test func namesTheAppItsMemoryAndTheReopen() {
      #expect(
        AppPressureWiring.note(.init(name: "Loom", memoryBytes: 1_200_000_000))
          == "Quit Loom · \(ByteText.full(1_200_000_000)) · reopens later")
      #expect(
        AppPressureWiring.note(.init(name: "Figma", memoryBytes: 640_000_000))
          == "Quit Figma · \(ByteText.full(640_000_000)) · reopens later")
      #expect(
        ByteText.full(1_200_000_000).hasPrefix("1") && ByteText.full(1_200_000_000).hasSuffix(" GB")
      )
    }
  }

  struct Scan {
    private func running(
      _ id: String?, pid: Int32, path: String? = nil, terminated: Bool = false,
      prohibited: Bool = false
    ) -> AppPressureWiring.Running {
      .init(
        bundleID: id, name: id.map { $0.capitalized }, processID: pid, launchDate: t0,
        bundleURL: URL(fileURLWithPath: path ?? "/Applications/\(id ?? "x").app"),
        isTerminated: terminated, prohibited: prohibited)
    }

    private func input(
      _ apps: [AppPressureWiring.Running], probes: AppPressureWiring.Probes = .init(),
      scope: Set<Int32>? = nil, parents: [Int32: Int32] = [:]
    ) -> AppPressureWiring.ScanInput {
      .init(
        running: apps, list: AppQuitList(["loom"]), memory: [10: 1_200, 11: 1_200],
        probes: probes, scope: scope, parents: parents, selfBundleID: "com.tamebar.Tamebar",
        selfProcessID: 1)
    }

    @Test func withoutAProbeEveryAppCountsAsUsingTheMicOrCamera() {
      let scan = AppPressureWiring.scan(input([running("loom", pid: 10)]))
      #expect(scan.apps.map(\.usesMicOrCamera) == [nil])
      #expect(scan.apps.first?.memoryBytes == 1_200)
      #expect(scan.list == AppQuitList(["loom"]))
    }

    @Test func theControlStandsInForTheFrontAppAndTheProbe() {
      let scan = AppPressureWiring.scan(
        input(
          [running("loom", pid: 10), running("zoom", pid: 20)],
          probes: .init(frontmost: "zoom", micCameraFree: ["loom"])))
      #expect(scan.apps.map(\.usesMicOrCamera) == [false, nil])
      #expect(scan.apps.map(\.isFrontmost) == [false, true])
    }

    private func uses(_ calls: CallReading?, parents: [Int32: Int32] = [:]) -> [Bool?] {
      var scanInput = input(
        [
          running("loom", pid: 10), running("zoom", pid: 20), running("com.google.Chrome", pid: 30),
        ],
        probes: .live(control: nil, frontmost: "", calls: calls))
      scanInput = .init(
        running: scanInput.running, list: scanInput.list, memory: scanInput.memory,
        probes: scanInput.probes, scope: nil, parents: parents,
        selfBundleID: scanInput.selfBundleID, selfProcessID: scanInput.selfProcessID)
      return AppPressureWiring.scan(scanInput).apps.map(\.usesMicOrCamera)
    }

    private func recording(_ pid: Int32, _ id: String?) -> CallReading.Input {
      .init(processID: pid, bundleID: id)
    }

    /// `Probes.live` in the shipped app: a camera on holds every app, nothing recording frees
    /// them all, and a probe that failed (nil) leaves them all unknown, so held.
    @Test func theLiveProbeHoldsOrFreesEveryApp() {
      #expect(uses(CallReading(camera: true)) == [nil, nil, nil])
      #expect(uses(CallReading()) == [false, false, false])
      #expect(uses(nil) == [nil, nil, nil])
    }

    @Test func aRecordingAppIsHeldAndTheOthersAreFree() {
      // Zoom itself; Chrome through its helper's bundle id; loom through a child process.
      #expect(uses(CallReading(inputs: [recording(20, "us.zoom.xos")])) == [false, true, false])
      #expect(uses(CallReading(inputs: [recording(20, "zoom")])) == [false, true, false])
      #expect(
        uses(CallReading(inputs: [recording(77, "com.google.Chrome.helper")]))
          == [false, false, true])
      #expect(
        uses(CallReading(inputs: [recording(88, nil)]), parents: [88: 10]) == [true, false, false])
    }

    @Test func aRecordingNoAppOwnsHoldsEveryApp() {
      // Safari records through a shared WebKit GPU process whose parent is launchd.
      #expect(
        uses(CallReading(inputs: [recording(99, "com.apple.WebKit.GPU")]), parents: [99: 1])
          == [nil, nil, nil])
      #expect(uses(CallReading(unattributedInput: true)) == [nil, nil, nil])
    }

    @Test func whileAnyMicOrCameraIsHeldTheListedAppIsNotQuit() {
      let scan = AppPressureWiring.scan(
        input(
          [running("loom", pid: 10)],
          probes: .live(control: nil, frontmost: "", calls: CallReading(camera: true))))
      let held = AppPressurePlanner.plan(
        TamebarTests.input(0, apps: scan.apps, running: scan.running, list: ["loom"]))
      #expect(quits(held).isEmpty)
      let recording = AppPressureWiring.scan(
        input(
          [running("loom", pid: 10)],
          probes: .live(
            control: nil, frontmost: "", calls: CallReading(inputs: [recording(10, "loom")]))))
      #expect(
        quits(
          AppPressurePlanner.plan(
            TamebarTests.input(0, apps: recording.apps, running: recording.running, list: ["loom"])
          )
        ).isEmpty)
      let free = AppPressureWiring.scan(
        input(
          [running("loom", pid: 10)], probes: .live(control: nil, frontmost: "", calls: .init())))
      #expect(
        quits(
          AppPressurePlanner.plan(
            TamebarTests.input(0, apps: free.apps, running: free.running, list: ["loom"])))
          == ["loom"])
    }

    /// The e2e build answers from its control and ignores any reading.
    @Test func theE2EControlWinsOverTheProbe() {
      let probes = AppPressureWiring.Probes.live(
        control: .init(frontmost: "zoom", micCameraFree: ["loom"]), frontmost: "finder",
        calls: CallReading())
      #expect(probes.frontmost == "zoom")
      #expect(probes.micCameraFree == ["loom"])
      #expect(probes.calls == nil)
      let real = AppPressureWiring.Probes.live(
        control: nil, frontmost: "finder", calls: CallReading(camera: true))
      #expect(real.frontmost == "finder")
      #expect(real.calls == CallReading(camera: true))
    }

    @Test func appleSpeechIsNotACall() {
      let inputs = [
        recording(1, "com.apple.CoreSpeech"), recording(2, "com.apple.assistantd"),
        recording(3, "us.zoom.xos"), recording(4, nil), recording(5, "com.apple.SiriNCService"),
        recording(6, "com.apple.corespeechd_system"), recording(7, "com.apple.accessibility.heard"),
      ]
      #expect(CallSignals.callInputs(inputs).map(\.processID) == [3, 4])
      // Calls and recordings that look like Apple's are still kept.
      let kept = [
        recording(8, "com.apple.WebKit.GPU"), recording(9, "com.apple.avconferenced"),
        recording(10, "com.apple.VoiceMemos"),
      ]
      #expect(CallSignals.callInputs(kept) == kept)
    }

    @Test func theLiveCallProbeIsOnlyTheShippedApps() {
      #expect(CallSignals.liveProbe(shipped: false) == nil)
      #expect(CallSignals.liveProbe(shipped: true) != nil)
      #expect(CallSignals.liveProbe() == nil)
    }

    @Test func e2eScopeKeepsOnlyTargetAppsButRunningSeesThemAll() {
      let scan = AppPressureWiring.scan(
        input(
          [running("fake", pid: 31), running("loom", pid: 10), running(nil, pid: 12)],
          scope: [30], parents: [31: 30, 10: 1]))
      #expect(scan.apps.map(\.bundleID) == ["fake"])
      #expect(scan.running == ["fake", "loom"])
    }

    @Test func keepRunningIsReadByBundleIDOrPath() {
      var scanInput = input([
        running("loom", pid: 10), running(nil, pid: 11), running("zoom", pid: 20),
      ])
      scanInput.keepRunning = ["loom", "/Applications/zoom.app"]
      #expect(AppPressureWiring.scan(scanInput).apps.map(\.keepRunning) == [true, true])
    }

    @Test func terminatedProhibitedAndSystemAppsAreHandled() {
      let scan = AppPressureWiring.scan(
        input([
          running("gone", pid: 40, terminated: true), running("daemon", pid: 41, prohibited: true),
          running("com.apple.finder", pid: 42, path: "/System/Library/CoreServices/Finder.app"),
        ]))
      #expect(scan.running == ["com.apple.finder"])
      #expect(scan.apps.map(\.isProtected) == [true])
    }
  }
}

// MARK: Controller

private func thread(_ id: String, root: Int32, paused: Bool = false) -> AIThread {
  var thread = AIThread(
    id: id, tool: .claudeCode, name: "Claude Code", directory: "/code/\(id)", terminal: nil,
    startedAt: nil, processIDs: [root], memoryBytes: 10, cpuPercent: 0, isPaused: paused,
    isDetached: false)
  thread.rootProcessID = root
  thread.agentStatus = .idle
  return thread
}

/// Records what the controller asks for; nothing is quit, opened or signalled.
@MainActor
private final class Recorder {
  var calls: [String] = []
  /// What a quit's task answers: whether the app ended in time. Nil refuses the request.
  var ends: Bool? = true
  /// When set, a quit's task waits for `landQuit` instead of answering at once.
  var holdsQuits = false
  private var gates: [AsyncStream<Bool>.Continuation] = []
  /// What the next reopens answer, in order; `.opened` once they run out.
  var reopenResults: [AppPressurePlanner.ReopenResult] = []

  func landQuit(_ ended: Bool) {
    for gate in gates {
      gate.yield(ended)
      gate.finish()
    }
    gates = []
  }

  var signaller: AutoPauseWiring.Signaller {
    .init(
      begin: { [self] thread, signal in
        calls.append("begin \(signal) \(thread.id)")
        return AIThreadStopRequest(thread: thread, expected: [:], force: false)
      },
      finish: { _, _, _, _ in true },
      resumeByIdentity: { _, _ in nil },
      stillStopped: { _ in 0 },
      project: { _, _ in nil })
  }

  var actions: AppPressureWiring.Actions {
    .init(
      quit: { [self] app in
        calls.append("quit \(app.bundleID)")
        guard let ends else { return nil }
        guard holdsQuits else { return Task { ends } }
        let (stream, gate) = AsyncStream<Bool>.makeStream()
        gates.append(gate)
        return Task {
          for await ended in stream { return ended }
          return false
        }
      },
      reopen: { [self] entry in
        calls.append("reopen \(entry.bundleID)")
        let result = reopenResults.isEmpty ? .opened : reopenResults.removeFirst()
        return Task { result }
      },
      openOnQuit: { [self] entry in
        calls.append("open \(entry.bundleID)")
        return true
      })
  }

  func controller(_ record: AutoPauseWiring.Record = .init(), url: URL? = nil)
    -> AutoPauseController
  {
    AutoPauseController(
      record: record, acts: true, url: url, signaller: signaller, apps: actions, scans: { 0 })
  }
}

extension AppPressureTests {
  @MainActor
  struct Controller {
    private let loom = app("loom", bytes: 1_200_000_000)

    private func tick(
      _ second: TimeInterval, risk: MemoryRisk = .warning, meeting: Bool = false,
      threads: [AIThread] = [], unused: [String: UnusedPolicy.Reason] = [:],
      stopped: Set<Int32> = [], apps: [AppPressurePlanner.App]? = nil,
      running: Set<String>? = nil
    ) -> AutoPauseWiring.Tick {
      let apps = apps ?? [loom]
      return .init(
        now: t0.addingTimeInterval(second), scan: Int(second) + 1, threads: threads,
        unused: unused, protections: [:], scope: nil, stopped: stopped, risk: risk,
        inMeeting: meeting, stopping: [], complete: true,
        apps: .init(
          apps: apps, running: running ?? Set(apps.map(\.bundleID)),
          list: AppQuitList(Set(apps.map(\.bundleID))), selfBundleID: "com.tamebar.Tamebar"),
        stillIdle: { _ in true })
    }

    private func settle(_ outcome: AutoPauseWiring.Outcome) async {
      for task in outcome.tasks { await task.value }
    }

    /// Sustained memory pressure during a call, however it was detected, quits nothing.
    @Test func sustainedMemoryPressureInACallQuitsNoApp() async {
      let recorder = Recorder()
      let controller = recorder.controller()
      for second in stride(from: 0.0, through: 120, by: 6) {
        await settle(controller.run(tick(second, meeting: true)))
      }
      #expect(recorder.calls.isEmpty)
    }

    @Test func onlyMemoryPressureQuitsAfterItsSixSeconds() async {
      let cpu = PressureAssessment(
        risk: .critical, limit: .cpu, title: "", detail: "", action: "", date: t0,
        cpuStrained: true)
      let memory = PressureAssessment(
        risk: .warning, limit: .memory, title: "", detail: "", action: "", date: t0)
      // A call alone pauses sessions but never quits an app, even before memory is calm.
      let meeting = Recorder()
      let inCall = meeting.controller()
      for second in stride(from: 0.0, through: 24, by: 6) {
        await settle(inCall.run(tick(second, risk: .normal, meeting: true)))
      }
      #expect(meeting.calls.isEmpty)
      let recorder = Recorder()
      let controller = recorder.controller()
      for second in stride(from: 0.0, through: 60, by: 6) {
        await settle(controller.run(tick(second, risk: cpu.memoryRisk)))
      }
      #expect(recorder.calls.isEmpty)
      await settle(controller.run(tick(200, risk: memory.memoryRisk)))
      await settle(controller.run(tick(205, risk: memory.memoryRisk)))
      #expect(recorder.calls.isEmpty, "quit before 6 s of memory pressure")
      let outcome = controller.run(tick(206, risk: memory.memoryRisk))
      await settle(outcome)
      #expect(recorder.calls == ["quit loom"])
      #expect(outcome.quits.count == 1)
      #expect(await outcome.quits.first?.value == .init(name: "Loom", memoryBytes: 1_200_000_000))
      #expect(controller.record.apps.ledger.map(\.confirmed) == [true])
    }

    /// Was "a session candidate is paused first and the app 30 s later": since Q18 memory
    /// pressure pauses no session, so an unused one no longer holds the app back.
    @Test func anUnusedSessionIsNotPausedAndDoesNotHoldTheAppBack() async {
      let recorder = Recorder()
      let controller = recorder.controller()
      func at(_ second: TimeInterval) async {
        await settle(
          controller.run(
            tick(
              second, threads: [thread("idle", root: 40)], unused: ["idle": .idle(9_000)])))
      }
      await at(0)
      await at(5)
      #expect(recorder.calls.isEmpty)
      await at(6)
      #expect(recorder.calls == ["quit loom"])
      #expect(controller.record.state.ledger.isEmpty)
    }

    @Test func aSessionTheUserResumedDoesNotHoldTheAppBack() async {
      // The user resumed the session this episode: it is no candidate, so the app may go.
      var record = AutoPauseWiring.Record()
      record.state.userResumed = ["idle"]
      let recorder = Recorder()
      let controller = recorder.controller(record)
      let idle = thread("idle", root: 40)
      await settle(controller.run(tick(0, threads: [idle], unused: ["idle": .idle(9_000)])))
      await settle(controller.run(tick(6, threads: [idle], unused: ["idle": .idle(9_000)])))
      #expect(recorder.calls == ["quit loom"])
    }

    @Test func anAppThatDoesNotEndInTimeOrRefusesLeavesTheLedger() async {
      for ends in [false, nil] as [Bool?] {
        let recorder = Recorder()
        recorder.ends = ends
        let controller = recorder.controller()
        await settle(controller.run(tick(0)))
        let outcome = controller.run(tick(6))
        await settle(outcome)
        #expect(recorder.calls == ["quit loom"])
        #expect(controller.record.apps.ledger.isEmpty)
        #expect(controller.record.apps.spared == ["loom"])
        for quit in outcome.quits { #expect(await quit.value == nil) }
        await settle(controller.run(tick(60)))
        #expect(recorder.calls == ["quit loom"], "asked again in the same episode")
      }
    }

    @Test func reopensAfterThirtyCalmSecondsAndOnlyWhatItQuit() async {
      let recorder = Recorder()
      let controller = recorder.controller()
      await settle(controller.run(tick(0)))
      await settle(controller.run(tick(6)))
      #expect(recorder.calls == ["quit loom"])
      let other = app("other")
      // Gone from the running apps, as a quit app is.
      for second in [10.0, 20, 39] {
        await settle(controller.run(tick(second, risk: .normal, apps: [other], running: [])))
      }
      #expect(recorder.calls == ["quit loom"], "reopened before 30 calm seconds")
      let outcome = controller.run(tick(40, risk: .normal, apps: [other], running: []))
      #expect(outcome.reopened == ["loom"])
      #expect(recorder.calls == ["quit loom", "reopen loom"])
      await settle(controller.run(tick(41, risk: .normal, apps: [other], running: ["loom"])))
      #expect(recorder.calls == ["quit loom", "reopen loom"])
      #expect(controller.record.apps.ledger.isEmpty)
      #expect(controller.record.apps.spared.isEmpty)
    }

    @Test func quittingReopensEveryLedgerAppThroughOpenAndForgetsThem() async throws {
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("app-pressure-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: folder) }
      let url = folder.appendingPathComponent("autopause.json")
      let recorder = Recorder()
      var record = AutoPauseWiring.Record()
      record.apps.ledger = [entry("old", at: -60), entry("inflight", at: -1, confirmed: false)]
      let controller = recorder.controller(record, url: url)
      await settle(controller.run(tick(0)))
      await settle(controller.run(tick(6)))
      // Still under pressure: Tamebar is leaving, so it reopens them anyway.
      controller.resumeAllForQuit(.init(parents: [:], read: { _ in nil }, send: { _ in false }))
      #expect(recorder.calls == ["quit loom", "open old", "open inflight", "open loom"])
      #expect(controller.record.apps.ledger.isEmpty)
      #expect(AutoPauseWiring.load(url).apps.ledger.isEmpty)
    }

    @Test func aLogoutRestartOrShutdownKeepsTheLedgerForTheNextLogin() async throws {
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("app-pressure-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: folder) }
      let url = folder.appendingPathComponent("autopause.json")
      let recorder = Recorder()
      var record = AutoPauseWiring.Record()
      record.apps.ledger = [entry("loom", at: 0)]
      let controller = recorder.controller(record, url: url)
      controller.resumeAllForQuit(
        .init(parents: [:], read: { _ in nil }, send: { _ in false }), reopenApps: false)
      #expect(recorder.calls.isEmpty, "opened an app while the Mac powers off")
      #expect(controller.record.apps.ledger.map(\.bundleID) == ["loom"])
      #expect(AutoPauseWiring.load(url).apps.ledger.map(\.bundleID) == ["loom"])
    }

    @Test func aLaunchReopensALeftoverLedgerOnlyAfterADownTimeUnderTwoHours() async throws {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("app-pressure-launch-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      for (name, down, kept) in [("recent", 3_600.0, true), ("stale", 7_300.0, false)] {
        let directory = root.appendingPathComponent(name)
        var record = AutoPauseWiring.Record()
        record.apps.ledger = [entry("loom", at: 0)]
        record.state.lastTick = Date.now.addingTimeInterval(-down)
        AutoPauseWiring.save(record, to: directory.appendingPathComponent("autopause.json"))
        let recorder = Recorder()
        let controller = AutoPauseController.launch(
          signaller: recorder.signaller, apps: recorder.actions, scans: { 0 }, installed: true,
          directory: directory, e2e: false)
        #expect(controller.acts)
        #expect(controller.record.apps.ledger.isEmpty == !kept, "\(name)")
        #expect(
          AutoPauseWiring.load(directory.appendingPathComponent("autopause.json")).apps.ledger
            .isEmpty == !kept, "\(name)")
        #expect(recorder.calls.isEmpty, "a launch reopened or opened something")
      }
    }

    @Test func aQuitInFlightKeepsItsEntryUntilItLandsAndThenFreesTheApp() async {
      let recorder = Recorder()
      recorder.holdsQuits = true
      let controller = recorder.controller()
      await settle(controller.run(tick(0)))
      let started = controller.run(tick(6))
      #expect(recorder.calls == ["quit loom"])
      // The app still runs while it answers its quit: that is not the user reopening it.
      for second in [7.0, 8, 9] { _ = controller.run(tick(second)) }
      #expect(controller.record.apps.ledger.map(\.confirmed) == [false])
      #expect(controller.record.apps.spared.isEmpty)
      #expect(recorder.calls == ["quit loom"])
      recorder.landQuit(true)
      await settle(started)
      #expect(controller.quittingApps.isEmpty)
      await settle(controller.run(tick(10, apps: [], running: [])))
      #expect(controller.record.apps.ledger.map(\.confirmed) == [true])
      #expect(controller.record.apps.spared.isEmpty)
      // The user opens it again, then a later episode may quit it once more.
      await settle(controller.run(tick(11)))
      #expect(controller.record.apps.spared == ["loom"])
      for second in stride(from: 12.0, through: 60, by: 6) {
        await settle(controller.run(tick(second, risk: .normal)))
      }
      #expect(controller.record.apps.spared.isEmpty, "the episode didn't end")
      recorder.holdsQuits = false
      await settle(controller.run(tick(100)))
      await settle(controller.run(tick(106)))
      #expect(recorder.calls == ["quit loom", "quit loom"])
    }

    @Test func aFailingReopenIsRetriedThirtySecondsApartThenDroppedWithANote() async {
      let recorder = Recorder()
      recorder.reopenResults = [.failed, .failed, .failed]
      var record = AutoPauseWiring.Record()
      record.apps.ledger = [entry("loom", at: 0)]
      let controller = recorder.controller(record)
      var notes: [String] = []
      for second in stride(from: 0.0, through: 130, by: 1) {
        let outcome = controller.run(tick(second, risk: .normal, apps: [], running: []))
        await settle(outcome)
        for reopen in outcome.reopens { if let note = await reopen.value { notes.append(note) } }
      }
      #expect(recorder.calls == ["reopen loom", "reopen loom", "reopen loom"])
      #expect(notes == ["Couldn't reopen Loom"])
      #expect(controller.record.apps.ledger.isEmpty)
    }

    @Test func aReopenOfAGoneAppDropsItWithoutANote() async {
      let recorder = Recorder()
      recorder.reopenResults = [.gone]
      var record = AutoPauseWiring.Record()
      record.apps.ledger = [entry("loom", at: 0)]
      let controller = recorder.controller(record)
      var notes: [String] = []
      for second in stride(from: 0.0, through: 90, by: 1) {
        let outcome = controller.run(tick(second, risk: .normal, apps: [], running: []))
        await settle(outcome)
        for reopen in outcome.reopens { if let note = await reopen.value { notes.append(note) } }
      }
      #expect(recorder.calls == ["reopen loom"])
      #expect(notes.isEmpty)
      #expect(controller.record.apps.ledger.isEmpty)
    }

    @Test func theDefaultActionsQuitNothing() async {
      let controller = AutoPauseController(
        record: .init(), acts: true, url: nil, signaller: Recorder().signaller, scans: { 0 })
      await settle(controller.run(tick(0)))
      let outcome = controller.run(tick(6))
      await settle(outcome)
      #expect(outcome.quits.isEmpty)
      #expect(controller.record.apps.ledger.isEmpty)
    }
  }
}
