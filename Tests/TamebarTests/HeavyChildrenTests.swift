import Foundation
import Testing

@testable import Tamebar

private func record(
  _ pid: Int32, parent: Int32 = 1, cpu: Double, args: String = "/bin/bash -c npm test"
) -> RawProcessRecord {
  RawProcessRecord(
    processID: pid, parentProcessID: parent, userID: 501, cpuPercent: cpu,
    residentKilobytes: 1_024, elapsed: "01:00", terminal: nil, arguments: args)
}

private func records(_ list: RawProcessRecord...) -> [Int32: RawProcessRecord] {
  Dictionary(uniqueKeysWithValues: list.map { ($0.processID, $0) })
}

private func scan(
  _ records: [Int32: RawProcessRecord], serving: Set<Int32> = [], kept: Set<String> = []
) -> HeavyChildren.Scan {
  .init(records: records, serving: serving, keptDirectories: kept)
}

private func session(
  _ status: AgentStatus?, root: Int32 = 10, children: [Int32] = [11, 12, 13],
  paused: Bool = false, directory: String = "/code/app", id: String = "s"
) -> AIThread {
  var thread = AIThread(
    id: id, tool: .claudeCode, name: "Claude Code", directory: directory, terminal: nil,
    startedAt: nil, processIDs: [root] + children, memoryBytes: 1, cpuPercent: 0,
    isPaused: paused, isDetached: false)
  thread.rootProcessID = root
  thread.agentStatus = status
  return thread
}

private func workload(
  _ name: String, pids: [Int32], cpu: Double = 100, directory: String? = "/code/app",
  paused: Bool = false, kind: ConsumerKind = .workload
) -> ResourceConsumer {
  ResourceConsumer(
    id: "work:\(name)|\(directory ?? "")", kind: kind, name: name, iconName: name,
    processIDs: pids, memoryBytes: 1, cpuPercent: cpu, directory: directory, isPaused: paused,
    threadID: nil)
}

/// What Tamebar slows on its own (Q9, Q12): heavy children of busy sessions, heavy terminal jobs.
enum HeavyChildrenTests {}

extension HeavyChildrenTests {
  struct Sessions {
    /// The plan's example: root 10, children 11 (85 %) and 12 (3 %), MCP server 13 (40 %).
    private let example = records(
      record(10, cpu: 90, args: "claude"), record(11, parent: 10, cpu: 85),
      record(12, parent: 10, cpu: 3), record(13, parent: 10, cpu: 40, args: "node /opt/mcp/gh.js"))

    private func select(_ thread: AIThread, _ scan: HeavyChildren.Scan) -> [Int32] {
      HeavyChildren.select(.init(thread: thread, scan: scan))
    }

    @Test func aBusySessionGivesItsHeavyChildrenButNeverTheRootOrAnMCPServer() {
      #expect(select(session(.busy), scan(example)) == [11])
    }

    @Test func aSessionThatIsNotBusyGivesNothing() {
      for status in [AgentStatus.idle, .shell, nil] {
        #expect(select(session(status), scan(example)).isEmpty)
      }
      #expect(select(session(.busy, paused: true), scan(example)).isEmpty)
    }

    @Test func aSessionInAKeepRunningProjectGivesNothing() {
      #expect(select(session(.busy), scan(example, kept: ["/code/app"])).isEmpty)
      #expect(select(session(.busy), scan(example, kept: ["/code/other"])) == [11])
    }

    @Test func everyServerMarkerExcludes() {
      let records = records(
        record(11, cpu: 50, args: "npx @modelcontextprotocol/server-filesystem /code"),
        record(12, cpu: 50, args: "uvx some-tool --stdio"),
        record(13, cpu: 50, args: "/usr/local/bin/mcp-proxy"),
        record(14, cpu: 50, args: "cargo build --release"))
      #expect(select(session(.busy, children: [11, 12, 13, 14]), scan(records)) == [14])
    }

    @Test func theAgentItselfIsNeverSelected() {
      // Under an npm wrapper the native codex is the root's child; it is the agent too.
      var thread = session(.busy, children: [11, 12])
      thread.nativeProcessID = 11
      let all = records(record(10, cpu: 95), record(11, cpu: 95), record(12, cpu: 95))
      #expect(select(thread, scan(all)) == [12])
      // With no root recorded, the first process stands for it.
      var rootless = session(.busy, children: [12])
      rootless.rootProcessID = nil
      #expect(select(rootless, scan(all)) == [12])
    }

    @Test func aNestedAgentIsNeverSlowedButItsHeavyChildrenAre() {
      let nested = records(
        record(11, parent: 10, cpu: 90, args: "/opt/homebrew/bin/codex exec --full-auto fix"),
        record(12, parent: 11, cpu: 90, args: "cargo test"),
        record(13, parent: 10, cpu: 90, args: "claude -p summarize"),
        record(14, parent: 10, cpu: 90, args: "/usr/local/bin/gemini"))
      #expect(select(session(.busy, children: [11, 12, 13, 14]), scan(nested)) == [12])
    }

    @Test func nothingOnAServersLineIsSlowed() {
      // 11 started 12, which started the server 13 and its worker 14; 15 is a heavy sibling.
      let line = records(
        record(11, parent: 10, cpu: 60), record(12, parent: 11, cpu: 60),
        record(13, parent: 12, cpu: 60, args: "node server.js"), record(14, parent: 13, cpu: 60),
        record(15, parent: 10, cpu: 60))
      let thread = session(.busy, children: [11, 12, 13, 14, 15])
      #expect(select(thread, scan(line, serving: [13])) == [15])
      #expect(select(thread, scan(line)) == [11, 12, 13, 14, 15])
    }

    @Test func thirtyPercentIsHeavyAndJustUnderIsNot() {
      let edge = records(record(11, cpu: 30), record(12, cpu: 29.9))
      #expect(select(session(.busy, children: [11, 12]), scan(edge)) == [11])
    }

    @Test func aChildTheScanHasNoRecordForIsLeftAlone() {
      #expect(select(session(.busy), scan([:])).isEmpty)
    }
  }

  struct Workloads {
    private func workloads(
      _ consumers: [ResourceConsumer], _ records: [Int32: RawProcessRecord],
      serving: Set<Int32> = [], kept: Set<String> = [], front: Int32? = nil
    ) -> [HeavyChildren.Workload] {
      HeavyChildren.workloads(
        .init(
          consumers: consumers, scan: scan(records, serving: serving, kept: kept),
          frontApp: front))
    }

    @Test func onlyTheHeavyProcessesOfAJobAreSelected() {
      let build = workload("cargo", pids: [20, 21, 22])
      let light = workload("node", pids: [30], cpu: 4)
      let all = records(
        record(20, cpu: 95), record(21, cpu: 2), record(22, cpu: 70), record(30, cpu: 4))
      #expect(
        workloads([build, light], all)
          == [.init(id: build.id, name: "cargo", processIDs: [20, 22])])
    }

    @Test func thirtyPercentIsHeavyAndJustUnderIsNot() {
      let all = records(record(20, cpu: 30), record(21, cpu: 29.9))
      #expect(workloads([workload("make", pids: [20, 21])], all).map(\.processIDs) == [[20]])
    }

    @Test func aKeepRunningProjectIsLeftAlone() {
      let kept = workload("cargo", pids: [20], directory: "/code/kept")
      let other = workload("cargo", pids: [30], directory: "/code/other")
      let all = records(record(20, cpu: 90), record(30, cpu: 90))
      #expect(workloads([kept, other], all, kept: ["/code/kept"]).map(\.processIDs) == [[30]])
    }

    @Test func theFrontAppsTreeIsLeftAlone() {
      // 20 runs in the frontmost terminal (500), two levels down; 21 was started elsewhere.
      let all = records(
        record(500, cpu: 1), record(600, parent: 500, cpu: 1), record(20, parent: 600, cpu: 90),
        record(700, cpu: 1), record(21, parent: 700, cpu: 90))
      #expect(
        workloads([workload("make", pids: [20, 21])], all, front: 500).map(\.processIDs)
          == [[21]])
      #expect(workloads([workload("make", pids: [20])], all, front: 500).isEmpty)
    }

    @Test func aDevServersWholeLineIsLeftAlone() {
      // `pnpm dev` → `tsx watch` → `node server` on :3000 → its worker. Slowing pnpm or tsx
      // would make the server's next restart inherit background priority. 25 is a build.
      let all = records(
        record(20, cpu: 40, args: "pnpm dev"), record(21, parent: 20, cpu: 80, args: "tsx watch"),
        record(22, parent: 21, cpu: 90, args: "node server.js"), record(23, parent: 22, cpu: 60),
        record(25, cpu: 90, args: "node build.js"))
      let node = workload("node", pids: [20, 21, 22, 23, 25])
      #expect(workloads([node], all, serving: [22]).map(\.processIDs) == [[25]])
    }

    @Test func otherKindsPausedJobsAndAgentsAreLeftAlone() {
      let consumers = [
        workload("Safari", pids: [20], kind: .app),
        workload("Claude", pids: [21], kind: .aiSession),
        workload("macOS services", pids: [22], kind: .system),
        workload("cargo", pids: [23], paused: true),
        workload("codex", pids: [24]),
      ]
      let all = records(
        record(20, cpu: 300), record(21, cpu: 300), record(22, cpu: 300), record(23, cpu: 300),
        record(24, cpu: 300, args: "codex exec fix the build"))
      #expect(workloads(consumers, all).isEmpty)
    }

    @Test func aParentLoopEndsTheWalk() {
      let all = records(record(20, parent: 21, cpu: 90), record(21, parent: 20, cpu: 1))
      #expect(
        workloads([workload("make", pids: [20])], all, serving: [99], front: 500)
          .map(\.processIDs) == [[20]])
    }
  }

  /// `BackgroundPriority.groups`: what the model hands the controller on each scan.
  struct Groups {
    private let all = records(
      record(10, cpu: 90, args: "claude"), record(11, parent: 10, cpu: 85),
      record(20, parent: 500, cpu: 90), record(30, cpu: 90), record(40, cpu: 90),
      record(50, cpu: 90, args: "node server.js"), record(500, cpu: 1))

    private func groups(
      threads: [AIThread], consumers: [ResourceConsumer], scope: Set<Int32>? = nil,
      ports: Bool = true, front: Int32? = nil, kept: Set<String> = []
    ) -> [BackgroundPriority.Group] {
      BackgroundPriority.groups(
        .init(
          threads: threads, consumers: consumers,
          scan: scan(all, serving: [50], kept: kept), frontApp: front, scope: scope,
          portsScanned: ports))
    }

    private let jobs = [
      workload("make", pids: [20], directory: "/code/front"),
      workload("cargo", pids: [30], directory: "/code/kept"),
      workload("swift", pids: [40], directory: "/code/x"),
      workload("node", pids: [50], directory: "/code/web"),
    ]

    @Test func jobsComeFirstThenSessionsEachUnderItsRow() {
      let thread = session(.busy, children: [11])
      let result = groups(threads: [thread], consumers: jobs, front: 500, kept: ["/code/kept"])
      #expect(
        result == [
          .init(id: jobs[2].id, name: "swift", kind: .workload, processIDs: [40]),
          .init(id: "ai:s", name: thread.displayName, kind: .session, processIDs: [11]),
        ])
    }

    @Test func nothingIsSlowedBeforeACompletePortScan() {
      // Without one, a session's server or its parent may not be known to serve yet.
      let thread = session(.busy, children: [11])
      #expect(groups(threads: [thread], consumers: jobs, ports: false).isEmpty)
      #expect(
        groups(threads: [thread], consumers: jobs).map(\.kind)
          == [.workload, .workload, .workload, .session])
    }

    @Test func e2eScopeKeepsOnlyTheTargetsTrees() {
      // Thread "s" is rooted at the target 10; "t" at 70 is not. Only job 40 descends from 500.
      let all = records(
        record(10, cpu: 90, args: "claude"), record(11, parent: 10, cpu: 85),
        record(70, cpu: 90, args: "claude"), record(71, parent: 70, cpu: 85),
        record(40, parent: 500, cpu: 90), record(41, cpu: 90), record(500, cpu: 1))
      let result = BackgroundPriority.groups(
        .init(
          threads: [
            session(.busy, children: [11]), session(.busy, root: 70, children: [71], id: "t"),
          ],
          consumers: [workload("swift", pids: [40, 41])], scan: scan(all), frontApp: nil,
          scope: [10, 500], portsScanned: true))
      #expect(result.map(\.processIDs) == [[40], [11]])
      let none = BackgroundPriority.groups(
        .init(
          threads: [session(.busy, children: [11])], consumers: [workload("swift", pids: [40])],
          scan: scan(all), frontApp: nil, scope: [], portsScanned: true))
      #expect(none.isEmpty)
    }
  }

  struct Trigger {
    private func assessment(_ risk: MemoryRisk, _ limit: PressureLimit, strained: Bool)
      -> PressureAssessment
    {
      .init(
        risk: risk, limit: limit, title: "", detail: "", action: "", date: .distantPast,
        cpuStrained: strained)
    }

    /// CPU strain, whatever bottleneck is shown (memory pressure can hide it), or a call.
    @Test func onlyCPUStrainOrACallTriggers() {
      for limit in [PressureLimit.none, .memory, .disk, .cpu] {
        for risk in [MemoryRisk.normal, .growing, .warning, .critical] {
          for strained in [false, true] {
            let reading = assessment(risk, limit, strained: strained)
            #expect(
              BackgroundPriority.trigger(reading, meeting: false) == strained,
              "\(limit) at \(risk), strained \(strained)")
            #expect(
              BackgroundPriority.trigger(reading, meeting: true), "a call, \(limit) at \(risk)")
          }
        }
      }
    }
  }
}

extension HeavyChildrenTests {
  /// Seen on this Mac on 2026-10-29 at about 17:00: under CPU strain Q12 slowed callservicesd,
  /// chronod, photoanalysisd, donotdisturbd, filecoordinationd and ClockPosterExtension. Each ran
  /// as the user, with launchd (or a booted iOS Simulator's `launchd_sim`) as parent. From the
  /// scan's records to the groups the controller is handed: none of them is ever a target, at any
  /// CPU, and the real terminal jobs still are.
  struct SystemDaemons {
    private static let runtimeRoot =
      "/private/var/run/com.apple.security.cryptexd/mnt/com.apple.iPhoneOS.SimulatorRuntime-v24.1"
      + ".434.0.QaDtlz/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.0.simruntime"
      + "/Contents/Resources/RuntimeRoot"

    private struct Process {
      let pid: Int32
      let parent: Int32
      let cpu: Double
      let executable: String
      var directory: String?
      /// An Apple platform binary (`CS_PLATFORM_BINARY`).
      var platform = true
    }

    private static let processes: [Process] = [
      // The Mac's own daemons, under launchd.
      .init(
        pid: 101, parent: 1, cpu: 95,
        executable: "/System/Library/PrivateFrameworks/TelephonyUtilities.framework/callservicesd"),
      .init(
        pid: 102, parent: 1, cpu: 90,
        executable: "/System/Library/PrivateFrameworks/ChronoCore.framework/Support/chronod"),
      .init(
        pid: 103, parent: 1, cpu: 97,
        executable:
          "/System/Library/PrivateFrameworks/PhotoAnalysis.framework/Versions/A/Support/"
          + "photoanalysisd"),
      .init(pid: 104, parent: 1, cpu: 80, executable: "/usr/libexec/routined"),
      .init(pid: 105, parent: 1, cpu: 80, executable: "/usr/sbin/distnoted"),
      .init(
        pid: 106, parent: 1, cpu: 80,
        executable: "/Library/Apple/System/Library/CoreServices/XProtect.bundle/XProtectd"),
      // A booted simulator's copies, under launchd_sim (6600, root's, so not in the scan).
      .init(
        pid: 201, parent: 6600, cpu: 95,
        executable: runtimeRoot
          + "/System/Library/PrivateFrameworks/TelephonyUtilities.framework/callservicesd"),
      .init(
        pid: 202, parent: 6600, cpu: 86,
        executable: runtimeRoot
          + "/System/Library/PrivateFrameworks/ChronoCore.framework/Support/chronod"),
      .init(
        pid: 203, parent: 6600, cpu: 70, executable: runtimeRoot + "/usr/sbin/filecoordinationd"),
      .init(
        pid: 204, parent: 6600, cpu: 60,
        executable: runtimeRoot
          + "/System/Library/ExtensionKit/Extensions/ClockPosterExtension.appex/"
          + "ClockPosterExtension"),
      // The simulator's home screen: an app, but the runtime's.
      .init(
        pid: 206, parent: 6600, cpu: 90,
        executable: runtimeRoot + "/System/Library/CoreServices/SpringBoard.app/SpringBoard"),
      // A platform binary somewhere else.
      .init(
        pid: 205, parent: 6600, cpu: 90,
        executable: "/private/var/run/com.apple.security.cryptexd/mnt/x/assetsd"),
      // The user's terminal jobs: `yes` and `sh` are platform binaries too.
      .init(pid: 301, parent: 1, cpu: 99, executable: "/usr/bin/yes", directory: "/code/app"),
      .init(pid: 302, parent: 1, cpu: 95, executable: "/bin/sh", directory: "/code/app"),
      .init(
        pid: 303, parent: 1, cpu: 90, executable: "/opt/homebrew/bin/node", directory: "/code/web",
        platform: false),
    ]

    private func scanned() -> (consumers: [ResourceConsumer], groups: [BackgroundPriority.Group]) {
      let records = Self.processes.map {
        RawProcessRecord(
          processID: $0.pid, parentProcessID: $0.parent, userID: 501, cpuPercent: $0.cpu,
          residentKilobytes: 30_000, elapsed: "20:54:11", terminal: nil, arguments: $0.executable)
      }
      let resources = ResourceOwnership.processes(
        .init(
          records: records,
          directories: Dictionary(
            uniqueKeysWithValues: Self.processes.compactMap { process in
              process.directory.map { (process.pid, $0) }
            }),
          footprints: Dictionary(uniqueKeysWithValues: records.map { ($0.processID, 30_000_000) }),
          executables: Dictionary(
            uniqueKeysWithValues: Self.processes.map { ($0.pid, $0.executable) }),
          platform: Set(Self.processes.filter(\.platform).map(\.pid))))
      let consumers = ResourceConsumers.build(
        .init(threads: [], resources: resources, stopped: []))
      let groups = BackgroundPriority.groups(
        .init(
          threads: [], consumers: consumers,
          scan: .init(
            records: Dictionary(uniqueKeysWithValues: records.map { ($0.processID, $0) }),
            serving: [], keptDirectories: []),
          frontApp: nil, scope: nil, portsScanned: true))
      return (consumers, groups)
    }

    @Test func noSystemDaemonIsATargetWhateverItsCPU() {
      let slowed = Set(scanned().groups.flatMap(\.processIDs))
      #expect(slowed.isDisjoint(with: 101...106), "the Mac's daemons: \(slowed)")
      #expect(slowed.isDisjoint(with: 201...206), "the simulator's daemons: \(slowed)")
    }

    @Test func theyAreTheMacOSServicesRowNotTerminalJobs() {
      let consumers = scanned().consumers
      let system = consumers.first { $0.kind == .system }
      #expect(
        Set(system?.processIDs ?? [])
          == [101, 102, 103, 104, 105, 106, 201, 202, 203, 204, 205, 206])
      #expect(
        consumers.filter { $0.kind == .workload }.map(\.name).sorted()
          == ["node · web", "sh · app", "yes · app"])
    }

    @Test func theUsersTerminalJobsAreStillSlowed() {
      #expect(
        Set(scanned().groups.map(\.processIDs)) == [[301], [302], [303]])
    }
  }
}
