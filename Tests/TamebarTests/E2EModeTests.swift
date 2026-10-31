import Foundation
import Testing

@testable import Tamebar

/// A live table with no parents and the given start times; Tamebar is PID 4000.
private func live(_ starts: [Int32: Double]) -> E2EMode.Live {
  E2EMode.Live(parents: [:], start: { starts[$0] }, selfID: 4_000)
}

struct E2EModeTests {
  private func folder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test func needsFlagEnvironmentAndE2EBundleTogether() {
    let args = ["Tamebar", "--e2e", "/tmp/x"]
    #expect(
      E2EMode.resolve(
        .init(
          arguments: args, environment: ["TAMEBAR_E2E": "1"], bundleID: "com.tamebar.Tamebar.e2e"))
        != nil)
    #expect(
      E2EMode.resolve(.init(arguments: args, environment: [:], bundleID: "com.tamebar.Tamebar.e2e"))
        == nil)
    #expect(
      E2EMode.resolve(
        .init(arguments: args, environment: ["TAMEBAR_E2E": "1"], bundleID: "com.tamebar.Tamebar"))
        == nil)
    #expect(
      E2EMode.resolve(
        .init(
          arguments: ["Tamebar"], environment: ["TAMEBAR_E2E": "1"],
          bundleID: "com.tamebar.Tamebar.e2e")) == nil)
  }

  @Test func emergencyHelperNeverEntersE2EMode() {
    let args = ["Tamebar", "--e2e", "/tmp/x"]
    #expect(
      E2EMode.resolve(
        .init(
          arguments: args, environment: ["TAMEBAR_E2E": "1"],
          bundleID: "com.tamebar.Tamebar.e2e.Emergency")) == nil)
    #expect(
      E2EMode.resolve(.init(arguments: args, environment: ["TAMEBAR_E2E": "1"], bundleID: nil))
        == nil)
    #expect(
      E2EMode.resolve(
        .init(
          arguments: args, environment: ["TAMEBAR_E2E": "true"],
          bundleID: "com.tamebar.Tamebar.e2e")) == nil)
  }

  @Test func e2eFolderMustBeAnAbsolutePath() {
    let env = ["TAMEBAR_E2E": "1"]
    let id = "com.tamebar.Tamebar.e2e"
    for value in ["relative/dir", "", "--other", "~/x"] {
      #expect(
        E2EMode.resolve(
          .init(arguments: ["Tamebar", "--e2e", value], environment: env, bundleID: id)) == nil,
        "\(value)")
    }
    #expect(
      E2EMode.resolve(.init(arguments: ["Tamebar", "--e2e"], environment: env, bundleID: id))
        == nil)
    let mode = E2EMode.resolve(
      .init(arguments: ["Tamebar", "--e2e", "/tmp/run"], environment: env, bundleID: id))
    #expect(mode?.directory.path == "/tmp/run")
    #expect(mode?.agentHome.path == "/tmp/run/home")
  }

  @Test func testsNeverRunInE2EMode() {
    #expect(E2EMode.current == nil)
  }

  @Test func onlyListedTargetsMayBeActedOn() throws {
    let dir = try folder()
    try Data(#"[{"pid": 101, "start": 1000.25}, {"pid": 102, "start": 2000}]"#.utf8)
      .write(to: dir.appendingPathComponent("targets.json"))
    let mode = E2EMode(directory: dir)
    #expect(
      mode.declaredTargets() == [.init(pid: 101, start: 1000.25), .init(pid: 102, start: 2000)])
    #expect(mode.targets(live([101: 1000.25, 102: 2000])) == [101, 102])
  }

  @Test func missingOrInvalidTargetsMeanNone() throws {
    let dir = try folder()
    let mode = E2EMode(directory: dir)
    #expect(mode.declaredTargets().isEmpty)
    for text in [
      "", "not json", "{\"pids\": [1]}", "[101, 102]", "[{\"pid\": 101}]",
      "[{\"pid\": \"101\", \"start\": 1}]",
    ] {
      try Data(text.utf8).write(to: dir.appendingPathComponent("targets.json"))
      #expect(mode.declaredTargets().isEmpty, "\(text)")
      #expect(mode.targets(live([101: 1])).isEmpty, "\(text)")
    }
  }

  /// A target whose PID now belongs to a process started at another time is someone else's.
  @Test func aTargetCountsOnlyWhileItsStartTimeMatches() {
    let declared: [E2EMode.Target] = [
      .init(pid: 101, start: 1_790_000_000.123456), .init(pid: 102, start: 500),
      .init(pid: 103, start: 700),
    ]
    let valid = E2EMode.validTargets(
      declared, live: live([101: 1_790_000_000.1234561, 102: 501, 104: 700]))
    #expect(valid == [101], "102 was reused, 103 exited")
  }

  @Test func tamebarAndItsAncestorsAreNeverTargets() {
    let declared: [E2EMode.Target] = [
      .init(pid: 50, start: 1), .init(pid: 60, start: 1), .init(pid: 70, start: 1),
      .init(pid: 80, start: 1), .init(pid: 1, start: 1),
    ]
    // launchd(1) → 50 (the test runner) → 60 (Tamebar) → 70 (a fake agent); 80 is unrelated.
    let starts: [Int32: Double] = [1: 1, 50: 1, 60: 1, 70: 1, 80: 1]
    let check = E2EMode.Live(
      parents: [50: 1, 60: 50, 70: 60, 80: 1], start: { starts[$0] }, selfID: 60)
    #expect(E2EMode.validTargets(declared, live: check) == [70, 80])
  }

  @Test func controlForcesPressureMeetingAndPresence() throws {
    let dir = try folder()
    let mode = E2EMode(directory: dir)
    #expect(mode.control() == .init())
    try Data(#"{"pressure": 2, "meeting": true, "away": false}"#.utf8)
      .write(to: dir.appendingPathComponent("control.json"))
    #expect(mode.control() == .init(pressure: .warning, meeting: true, away: false))
    for (raw, risk) in [(0, MemoryRisk.normal), (1, .growing), (3, .critical)] {
      try Data(#"{"pressure": \#(raw)}"#.utf8).write(to: dir.appendingPathComponent("control.json"))
      #expect(mode.control() == .init(pressure: risk))
    }
    try Data("garbage".utf8).write(to: dir.appendingPathComponent("control.json"))
    #expect(mode.control() == .init())
    try Data(#"{"pressure": 9, "meeting": "yes", "away": true}"#.utf8)
      .write(to: dir.appendingPathComponent("control.json"))
    #expect(mode.control() == .init(away: true), "one bad field never drops the others")
    try Data(#"{"pressure": 0, "cpu": true}"#.utf8)
      .write(to: dir.appendingPathComponent("control.json"))
    #expect(mode.control() == .init(pressure: .normal, cpu: true))
    try Data(#"{"cpu": "yes", "meeting": true}"#.utf8)
      .write(to: dir.appendingPathComponent("control.json"))
    #expect(mode.control() == .init(meeting: true))
    try Data(#"{"pressure": 3, "meeting": 1}"#.utf8)
      .write(to: dir.appendingPathComponent("control.json"))
    #expect(mode.control() == .init(pressure: .critical))
  }

  @Test func commandsAreTakenInNameOrderAndDeleted() throws {
    let dir = try folder()
    let commands = dir.appendingPathComponent("commands")
    try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
    try Data("keep:101\n".utf8).write(to: commands.appendingPathComponent("002"))
    try Data("endUnused".utf8).write(to: commands.appendingPathComponent("001"))
    try Data(" bogus ".utf8).write(to: commands.appendingPathComponent("003"))
    let mode = E2EMode(directory: dir)
    #expect(mode.takeCommands() == ["endUnused", "keep:101", "bogus"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: commands.path).isEmpty)
    #expect(mode.takeCommands().isEmpty)
    #expect(E2EMode(directory: dir.appendingPathComponent("absent")).takeCommands().isEmpty)
  }

  /// The rig writes a dotfile, then renames it; a half-written one is never read or removed.
  @Test func commandsSkipDotfilesAndFolders() throws {
    let dir = try folder()
    let commands = dir.appendingPathComponent("commands")
    try FileManager.default.createDirectory(
      at: commands.appendingPathComponent("004"), withIntermediateDirectories: true)
    try Data("endUnused".utf8).write(to: commands.appendingPathComponent(".001.tmp"))
    try Data("keep:101".utf8).write(to: commands.appendingPathComponent("002"))
    try FileManager.default.createSymbolicLink(
      at: commands.appendingPathComponent("003"),
      withDestinationURL: commands.appendingPathComponent("002"))
    let mode = E2EMode(directory: dir)
    #expect(mode.takeCommands() == ["keep:101"])
    let left = try FileManager.default.contentsOfDirectory(atPath: commands.path).sorted()
    #expect(left == [".001.tmp", "003", "004"])
  }

  /// The domains a reset asked to clear. No real defaults domain is touched: cfprefsd rewrites a
  /// removed suite's plist long after the run, so a real suite would be left behind.
  private final class Cleared: @unchecked Sendable {
    var ids: [String] = []
    var clear: (String) -> Void { { self.ids.append($0) } }
  }

  private let e2eID = "TamebarTests-e2e-reset.e2e"

  @Test func resetClearsOnlyTheE2EDomainAndFolder() throws {
    let root = try folder()
    let data = root.appendingPathComponent("Tamebar-e2e")
    try FileManager.default.createDirectory(
      at: data.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: data.appendingPathComponent("ended-sessions.json"))
    let cleared = Cleared()
    #expect(E2EMode.reset(.init(bundleID: e2eID, dataDirectory: data, clearDomain: cleared.clear)))
    #expect(cleared.ids == [e2eID])
    #expect(try FileManager.default.contentsOfDirectory(atPath: data.path).isEmpty)
  }

  @Test func resetRefusesAnyOtherFolderOrBuild() throws {
    let root = try folder()
    let cases: [(id: String?, name: String)] = [
      (e2eID, "Tamebar"), (e2eID, "Tamebar-e2e-old"), ("TamebarTests-e2e-reset", "Tamebar-e2e"),
      (nil, "Tamebar-e2e"),
    ]
    for (id, name) in cases {
      let data = root.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
      try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
      try Data("x".utf8).write(to: data.appendingPathComponent("keep.json"))
      let cleared = Cleared()
      #expect(!E2EMode.reset(.init(bundleID: id, dataDirectory: data, clearDomain: cleared.clear)))
      #expect(FileManager.default.fileExists(atPath: data.appendingPathComponent("keep.json").path))
      #expect(cleared.ids.isEmpty, "\(String(describing: id)) \(name)")
    }
  }

  @Test func resetRefusesASymlinkedFolder() throws {
    let root = try folder()
    let real = root.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: real.appendingPathComponent("keep.json"))
    let link = root.appendingPathComponent("Tamebar-e2e")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let cleared = Cleared()
    // AppData builds its folder with `isDirectory: true`; the trailing slash must not hide the link.
    for url in [link, URL(fileURLWithPath: link.path, isDirectory: true)] {
      #expect(
        !E2EMode.reset(.init(bundleID: e2eID, dataDirectory: url, clearDomain: cleared.clear)))
    }
    #expect(FileManager.default.fileExists(atPath: real.appendingPathComponent("keep.json").path))
    #expect(cleared.ids.isEmpty)
  }

  @Test func resetClearsTheDomainWhenTheFolderIsMissing() throws {
    let data = try folder().appendingPathComponent("Tamebar-e2e")
    let cleared = Cleared()
    #expect(E2EMode.reset(.init(bundleID: e2eID, dataDirectory: data, clearDomain: cleared.clear)))
    #expect(cleared.ids == [e2eID])
    #expect(!FileManager.default.fileExists(atPath: data.path))
  }

  @Test func stateIsWrittenAsJSON() throws {
    let dir = try folder()
    let mode = E2EMode(directory: dir)
    mode.write(
      E2EState(
        at: Date(timeIntervalSince1970: 0), risk: 2, meeting: false, threads: [], island: "hidden",
        ended: []))
    let data = try Data(contentsOf: dir.appendingPathComponent("state.json"))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["risk"] as? Int == 2)
    #expect(object["island"] as? String == "hidden")
    #expect(object["at"] as? String == "1970-01-01T00:00:00Z")
  }
}

struct E2EPressureTests {
  @Test func forcedRiskKeepsTheReadingAndLimitsMemoryFromWarning() {
    let calm = PressureAssessment(
      risk: .normal, limit: .none, title: "Capacity available", detail: "d", action: "a",
      date: Date(timeIntervalSince1970: 9))
    let warning = calm.forcing(.warning)
    #expect(warning.risk == .warning)
    #expect(warning.limit == .memory)
    #expect(warning.title == calm.title && warning.detail == "d" && warning.action == "a")
    #expect(warning.date == calm.date)
    #expect(calm.forcing(.critical).limit == .memory)
    #expect(calm.forcing(.growing).limit == .none)
    let disk = PressureAssessment(
      risk: .critical, limit: .disk, title: "t", detail: "d", action: "a", date: .distantPast)
    #expect(disk.forcing(.normal).limit == .disk)
    #expect(disk.forcing(.normal).risk == .normal)
  }

  @Test func memoryPressureAndCPUStrainAreForcedEachOnItsOwn() {
    let busy = PressureAssessment(
      risk: .warning, limit: .cpu, title: "CPU is the bottleneck", detail: "d", action: "a",
      date: Date(timeIntervalSince1970: 9), cpuStrained: true)
    // Forced normal hides a real CPU warning and its strain, as it hides a memory one.
    let hidden = busy.forcing(E2EMode.Control(pressure: .normal))
    #expect(hidden.risk == .normal && !hidden.cpuStrained)
    let cpu = busy.forcing(E2EMode.Control(pressure: .normal, cpu: true))
    #expect(cpu.risk == .warning && cpu.limit == .cpu && cpu.cpuStrained)
    #expect(cpu.memoryRisk == .normal, "CPU strain alone pauses nothing")
    #expect(cpu.date == busy.date && cpu.detail == "d")
    let both = busy.forcing(E2EMode.Control(pressure: .warning, cpu: true))
    #expect(both.limit == .memory && both.memoryRisk == .warning && both.cpuStrained)
    let memory = busy.forcing(E2EMode.Control(pressure: .warning, cpu: false))
    #expect(memory.memoryRisk == .warning && !memory.cpuStrained)
    #expect(busy.forcing(E2EMode.Control()) == busy)
  }
}

struct E2ECommandTests {
  @Test func parsesKnownCommandsAndIgnoresTheRest() {
    #expect(E2ECommand("endUnused") == .endUnused)
    #expect(E2ECommand("keep:4242") == .keep(4242))
    #expect(E2ECommand("resumeNow") == .resumeNow)
    for text in [
      "", "endunused", "resumenow", "keep:", "keep:abc", "keep:1", "keep:0", "keep:-5", "quit:12",
      "runNow:4242", "runNow:",
    ] {
      #expect(E2ECommand(text) == nil, "\(text)")
    }
  }

  @Test func endUnusedTakesOnlyUnusedTargetRootedThreads() {
    let threads = [thread("a", root: 101), thread("b", root: 102), thread("c", root: 900)]
    let unused: [String: UnusedPolicy.Reason] = [
      "a": .idle(3_600), "c": .detached,
    ]
    let endable = E2ECommand.endable(threads, unused: unused, targets: [101, 102])
    #expect(endable.map(\.id) == ["a"])
  }

  @Test func keepFindsOnlyATargetRootedThread() {
    let threads = [thread("a", root: 101), thread("b", root: 900, children: [101])]
    #expect(E2ECommand.thread(rootedAt: 101, in: threads, targets: [101])?.id == "a")
    #expect(E2ECommand.thread(rootedAt: 900, in: threads, targets: [101]) == nil)
    #expect(E2ECommand.thread(rootedAt: 555, in: threads, targets: [555]) == nil)
  }
}

struct E2EStateTests {
  @Test func listsOnlyTargetRootedThreads() {
    var busy = thread("a", root: 101)
    busy.agentStatus = .busy
    let threads = [
      thread("z", root: 900, children: [101]), busy, thread("b", root: 102, paused: true),
    ]
    let state = E2EState.build(
      .init(
        at: Date(timeIntervalSince1970: 5), risk: .critical, meeting: true, threads: threads,
        unused: ["b": .detached, "z": .idle(10)], protections: ["a": .busy, "z": .kept],
        ended: [
          EndedSession(
            id: "00000000-0000-4000-8000-000000000001", tool: .claudeCode, directory: "/x",
            name: nil, idleSince: nil, endedAt: .now, memoryBytes: 1),
          EndedSession(
            id: "not-a-uuid", tool: .claudeCode, directory: "/x", name: nil, idleSince: nil,
            endedAt: .now, memoryBytes: 1),
        ],
        targets: [101, 102]))
    #expect(
      state.threads == [
        .init(
          id: "a", pid: 101, status: "busy", unused: nil, protection: "busy", pausedBy: nil,
          paused: false),
        .init(
          id: "b", pid: 102, status: "idle", unused: "detached", protection: nil, pausedBy: nil,
          paused: true),
      ])
    #expect(state.risk == 3)
    #expect(state.meeting)
    #expect(state.island == "hidden")
    #expect(state.ended == ["cd '/x' && claude --resume 00000000-0000-4000-8000-000000000001"])
  }

  /// Task 9.4: the island's state by its short name, panel or not.
  @Test func carriesTheIslandState() {
    func island(_ state: IslandState) -> String {
      var input = E2EState.Input(
        at: .now, risk: .normal, meeting: false, threads: [], unused: [:], protections: [:],
        ended: [], targets: [])
      input.island = state
      return E2EState.build(input).island
    }
    #expect(island(.call(.calendar, paused: 2)) == "call")
    #expect(island(.resumed(2)) == "resumed")
    #expect(island(.hidden) == "hidden")
  }

  /// N7: the dump carries the menu-bar item's text beside the icon, "" for the icon alone.
  @Test func carriesTheMenuBarLabel() {
    func menuBar(_ state: IslandState) -> String {
      var input = E2EState.Input(
        at: .now, risk: .normal, meeting: false, threads: [], unused: [:], protections: [:],
        ended: [], targets: [])
      input.island = state
      return E2EState.build(input).menuBar
    }
    #expect(menuBar(.call(.calendar, paused: 2)) == "Call · 2 paused")
    #expect(menuBar(.autoPaused(3)) == "3 paused")
    #expect(menuBar(.hidden) == "", "the icon alone")
  }
}

struct E2EAllowlistTests {
  private func mode(_ targets: String) throws -> E2EMode {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(targets.utf8).write(to: dir.appendingPathComponent("targets.json"))
    return E2EMode(directory: dir)
  }

  @Test func theGuardUsesLiveStartPinnedTargets() throws {
    let tree = E2EMode.Live(
      parents: [101: 50, 201: 101, 900: 1], start: { [101: 10.0, 201: 11.0][$0] }, selfID: 4_000)
    let pinned = try mode(#"[{"pid": 101, "start": 10}]"#)
    #expect(E2EMode.allowsSignal(to: 201, mode: pinned, live: { tree }))
    #expect(!E2EMode.allowsSignal(to: 900, mode: pinned, live: { tree }))
    let stale = try mode(#"[{"pid": 101, "start": 9}]"#)
    #expect(!E2EMode.allowsSignal(to: 101, mode: stale, live: { tree }), "start time changed")
    #expect(!E2EMode.allowsSignal(to: 201, mode: stale, live: { tree }))
    for empty in ["[]", "", "not json"] {
      #expect(!E2EMode.allowsSignal(to: 101, mode: try mode(empty), live: { tree }), "\(empty)")
    }
    #expect(E2EMode.allowsSignal(to: 900, mode: nil, live: { tree }, otherRuns: []))
  }

  /// 2026-10-29: under the Mac's real CPU strain the installed Tamebar slowed the e2e run's
  /// heavy terminal job, so the e2e build couldn't slow it for heat. Outside e2e mode, another
  /// run's live targets and their trees are refused; everything else is still allowed.
  @Test func withoutAModeAnotherRunsTargetsAreRefused() throws {
    let tree = E2EMode.Live(
      parents: [101: 50, 201: 101, 300: 1, 900: 1],
      start: { [101: 10.0, 201: 11.0, 300: 4.0][$0] }, selfID: 4_000)
    let run = try mode(#"[{"pid": 101, "start": 10}, {"pid": 300, "start": 3}]"#).directory
    #expect(!E2EMode.allowsSignal(to: 101, mode: nil, live: { tree }, otherRuns: [run]))
    #expect(!E2EMode.allowsSignal(to: 201, mode: nil, live: { tree }, otherRuns: [run]))
    #expect(E2EMode.allowsSignal(to: 900, mode: nil, live: { tree }, otherRuns: [run]))
    // A target whose start time no longer matches is a reused PID: not the run's.
    #expect(E2EMode.allowsSignal(to: 300, mode: nil, live: { tree }, otherRuns: [run]))
    let gone = try mode("[]").directory
    #expect(E2EMode.allowsSignal(to: 201, mode: nil, live: { tree }, otherRuns: [gone]))
    #expect(
      E2EMode.allowsSignal(
        to: 201, mode: nil, live: { tree },
        otherRuns: [URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")]))
  }

  @Test func otherRunsAreTamebarBinariesWithAnE2EFolder() {
    func record(_ pid: Int32, _ arguments: String, user: Int = 501) -> RawProcessRecord {
      RawProcessRecord(
        processID: pid, parentProcessID: 1, userID: user, cpuPercent: 0, residentKilobytes: 0,
        elapsed: "00:01", terminal: nil, arguments: arguments)
    }
    let app = "/Users/me/repo/dist/e2e/Tamebar.app/Contents/MacOS/Tamebar"
    let records = [
      record(
        1, app + #" -ProjectPausePolicy ("/a b") --e2e /var/folders/x/T/tamebar-e2e-1 --background"#
      ),
      record(2, app + " --e2e /var/folders/x/T/tamebar-e2e-1 --background"),
      record(3, "/Users/me/Applications/Tamebar.app/Contents/MacOS/Tamebar"),
      record(4, app + " --e2e /var/folders/y/T/tamebar-e2e-2", user: 502),
      record(5, "/bin/sh -c echo --e2e /var/folders/x/T/tamebar-e2e-3"),
      record(6, app + " --e2e relative/folder"),
      record(7, app + " --e2e"),
    ]
    #expect(
      E2EMode.runs(in: records, userID: 501).map(\.path) == ["/var/folders/x/T/tamebar-e2e-1"])
  }

  /// Signal 0 delivers nothing, so even a broken guard can't touch the test runner.
  @Test func processSignalRefusesANonTargetInE2EMode() throws {
    let parent = try #require(DevProcessIdentity.read(getppid()))
    let request = ProcessSignal.Request(expected: parent, signal: 0)
    let other = try mode(#"[{"pid": 999999, "start": 1}]"#)
    #expect(ProcessSignal.send(request, mode: other) == .refused)
    #expect(ProcessSignal.send(request, mode: try mode("[]")) == .refused)
    let start =
      Double(parent.process.startSeconds) + Double(parent.process.startMicroseconds) / 1_000_000
    let ancestor = try mode(#"[{"pid": \#(getppid()), "start": \#(start)}]"#)
    #expect(ProcessSignal.send(request, mode: ancestor) == .refused, "Tamebar's own ancestor")
  }

  @Test func allowsTargetsAndTheirDescendantsOnly() {
    // 101 is a target; 201 is its child, 301 its grandchild. 900 is someone else's, under launchd.
    let parents: [Int32: Int32] = [101: 50, 201: 101, 301: 201, 900: 1, 50: 1, 777: 778, 778: 777]
    func allows(_ pid: Int32, _ targets: Set<Int32> = [101]) -> Bool {
      E2EMode.allows(.init(processID: pid, targets: targets, parents: parents))
    }
    #expect(allows(101))
    #expect(allows(201))
    #expect(allows(301))
    #expect(!allows(900))
    #expect(!allows(50), "a target's parent is outside its tree")
    #expect(!allows(1, [1]), "launchd is never allowed")
    #expect(!allows(0, [0]))
    #expect(!allows(777), "a parent loop ends refused")
    #expect(!allows(4_000), "an unknown process is refused")
    #expect(!allows(101, []), "no targets means nothing")
  }

  /// Quit signals the root first; once it exits, its children belong to launchd. A process seen
  /// inside a target's tree stays allowed while it is the same process (pid and start time).
  @Test func aProcessPinnedInsideATargetsTreeStaysAllowedOnceOrphaned() throws {
    let pins = E2EMode.Pins()
    let mode = try mode(#"[{"pid": 101, "start": 10}]"#)
    let before = E2EMode.Live(
      parents: [101: 50, 201: 101, 301: 201, 900: 1],
      start: { [101: 10.0, 201: 11.0, 301: 12.0, 900: 13.0][$0] }, selfID: 4_000)
    #expect(E2EMode.allowsSignal(to: 101, mode: mode, live: { before }, pins: pins))
    // 101 exited: 201 is launchd's now, and no target is live.
    let after = E2EMode.Live(
      parents: [201: 1, 301: 201, 900: 1], start: { [201: 11.0, 301: 12.0, 900: 13.0][$0] },
      selfID: 4_000)
    #expect(E2EMode.allowsSignal(to: 201, mode: mode, live: { after }, pins: pins))
    #expect(E2EMode.allowsSignal(to: 301, mode: mode, live: { after }, pins: pins))
    #expect(!E2EMode.allowsSignal(to: 900, mode: mode, live: { after }, pins: pins))
    // Never seen in the tree: refused, as before.
    #expect(!E2EMode.allowsSignal(to: 201, mode: mode, live: { after }, pins: E2EMode.Pins()))
    // Its target no longer declared (stale or emptied targets): refused.
    let stale = try self.mode(#"[{"pid": 101, "start": 9}]"#)
    #expect(!E2EMode.allowsSignal(to: 201, mode: stale, live: { after }, pins: pins))
    #expect(!E2EMode.allowsSignal(to: 201, mode: try self.mode("[]"), live: { after }, pins: pins))
    // A reused pid is another process.
    let reused = E2EMode.Live(parents: [201: 1], start: { [201: 99.0][$0] }, selfID: 4_000)
    #expect(!E2EMode.allowsSignal(to: 201, mode: mode, live: { reused }, pins: pins))
    // Nor is Tamebar itself ever allowed through a pin.
    let selfPinned = E2EMode.Live(parents: [201: 1], start: { [201: 11.0][$0] }, selfID: 201)
    #expect(!E2EMode.allowsSignal(to: 201, mode: mode, live: { selfPinned }, pins: pins))
  }

  @Test func outsideE2EModeWithNoOtherRunEverySignalIsAllowed() {
    #expect(E2EMode.allowsSignal(to: 12_345, otherRuns: []))
  }
}

private func thread(
  _ id: String, root: Int32, children: [Int32] = [], paused: Bool = false
) -> AIThread {
  var thread = AIThread(
    id: id, tool: .claudeCode, name: "Claude Code", directory: "/code/\(id)", terminal: nil,
    startedAt: nil, processIDs: [root] + children, memoryBytes: 10, cpuPercent: 0,
    isPaused: paused, isDetached: false)
  thread.rootProcessID = root
  thread.agentStatus = .idle
  return thread
}
