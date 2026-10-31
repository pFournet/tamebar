import Foundation
import Testing

@testable import Tamebar

private let hour: TimeInterval = 3_600
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Q20: a session idle 24 h whose dev server had no connection for 24 h is ended with it.
enum UnusedServersTests {}

/// A Codex session in web-frontend: codex (10) → `npm run dev …` (11) → vite (12, :5180) →
/// esbuild (13), plus an MCP helper (14). Optionally a zsh job (15) running `sleep`.
private struct World {
  var idleHours: Double = 30
  var job = false
  var helperListens = false
  var port = 5180

  var records: [Int32: RawProcessRecord] {
    var records: [Int32: RawProcessRecord] = [
      10: StubWorld.record(10, parent: 1, "codex --no-daemon"),
      11: StubWorld.record(
        11, parent: 10, "npm run dev --host 127.0.0.1 --port \(port) --strictPort"),
      12: StubWorld.record(
        12, parent: 11, "node /code/web-frontend/apps/web/node_modules/.bin/vite --port \(port)"),
      13: StubWorld.record(13, parent: 12, "/code/web-frontend/node_modules/esbuild --service"),
      14: StubWorld.record(14, parent: 10, "/Users/x/.local/bin/chat mcp"),
    ]
    if job { records[15] = StubWorld.record(15, parent: 10, "/bin/zsh -lc sleep 3600") }
    return records
  }

  var thread: AIThread {
    var thread = AIThread(
      id: "codex-10", tool: .codexCLI, name: "Codex", directory: "/code/web-frontend",
      terminal: nil, startedAt: nil, processIDs: [10, 11, 12, 13, 14] + (job ? [15] : []),
      memoryBytes: 2_000_000_000, cpuPercent: 0, isPaused: false, isDetached: false)
    thread.rootProcessID = 10
    thread.sessionID = "019a0000-0000-7000-8000-000000000001"
    thread.agentStatus = .idle
    thread.agentStatusSince = t0.addingTimeInterval(-idleHours * hour)
    return thread
  }

  var listening: [Int32: [Int]] {
    var listening: [Int32: [Int]] = [10: [62_862], 12: [port]]
    if helperListens { listening[14] = [41_000] }
    return listening
  }

  func scan(
    clockHours: Double = 30,
    protections: [String: UnusedPolicy.Protection] = [
      "codex-10": .serving
    ], lastInput: [String: Date] = [:]
  ) -> UnusedServers.Scan {
    var clock = ServedPortClock()
    clock.observe(
      served: Set(listening.values.flatMap { $0 }).subtracting([62_862]), connected: [],
      now: t0.addingTimeInterval(-clockHours * hour), complete: true)
    var scan = UnusedServers.Scan(
      now: t0, threads: [thread], protections: protections, scope: nil, inFlight: [],
      records: records)
    scan.listening = listening
    scan.directories = [11: "/code/web-frontend/apps/web", 12: "/code/web-frontend/apps/web"]
    scan.lastInput = lastInput
    scan.clock = clock
    return scan
  }
}

extension UnusedServersTests {
  struct Servers {
    @Test func theServerIsTheAgentsChildWithTheListenerAndItsTree() throws {
      let world = World()
      let servers = UnusedServers.servers(
        world.thread, records: world.records, listening: world.listening,
        directories: world.scan().directories)
      let server = try #require(servers.first)
      #expect(servers.count == 1)
      #expect(server.head == 11)
      #expect(server.processIDs == [11, 12, 13])
      #expect(server.ports == [5180])
      #expect(server.commandProcess == 11)
      #expect(
        server.command
          == "cd '/code/web-frontend/apps/web' && npm run dev -- --host 127.0.0.1 --port 5180 --strictPort"
      )
    }

    @Test func throughAShellTheCommandIsTheFirstProgramBelowIt() throws {
      let records: [Int32: RawProcessRecord] = [
        10: StubWorld.record(10, parent: 1, "codex"),
        20: StubWorld.record(20, parent: 10, "/bin/zsh -lc ./node_modules/.bin/vite --port 5175 &"),
        21: StubWorld.record(21, parent: 20, "node ./node_modules/.bin/vite --port 5175"),
      ]
      var thread = World().thread
      thread = AIThread(
        id: thread.id, tool: .codexCLI, name: "Codex", directory: "/code/x", terminal: nil,
        startedAt: nil, processIDs: [10, 20, 21], memoryBytes: 1, cpuPercent: 0, isPaused: false,
        isDetached: false)
      thread.rootProcessID = 10
      let server = try #require(
        UnusedServers.servers(
          thread, records: records, listening: [21: [5175]], directories: [21: "/code/x/web"]
        ).first)
      #expect(server.head == 20)
      #expect(server.command == "cd '/code/x/web' && node ./node_modules/.bin/vite --port 5175")
      #expect(UnusedServers.otherJobs(thread, servers: [server], records: records).isEmpty)
    }

    @Test func aListeningHelperIsNotADevServer() {
      let world = World(helperListens: true)
      let servers = UnusedServers.servers(
        world.thread, records: world.records, listening: world.listening, directories: [:])
      #expect(servers.map(\.head) == [11])
    }

    @Test func commandsWithControlCharactersOrNoFolderAreNone() {
      #expect(EndedServer.command(directory: nil, commandLine: "npm run dev") == nil)
      #expect(EndedServer.command(directory: "/a", commandLine: "x\ny") == nil)
      #expect(
        EndedServer.command(directory: "/it's", commandLine: "pnpm dev")
          == "cd '/it'\\''s' && pnpm dev")
      #expect(UnusedServers.commandLine("npm run dev -- --port 1") == "npm run dev -- --port 1")
      #expect(UnusedServers.commandLine("pnpm dev --port 1") == "pnpm dev --port 1")
    }
  }

  struct Judge {
    private func hold(_ scan: UnusedServers.Scan) -> UnusedServers.Hold? {
      switch UnusedServers.judge(scan.threads[0], scan) {
      case .success: nil
      case .failure(let error): error.hold
      }
    }

    @Test func idleAndUnusedForADayIsACandidate() throws {
      let candidates = UnusedServers.candidates(World().scan())
      let candidate = try #require(candidates.first)
      #expect(candidate.id == "codex-10")
      #expect(candidate.servers.map(\.ports) == [[5180]])
      #expect(candidate.unused == 30 * hour)
    }

    @Test func underADayIdleOrAKeystrokeHoldsIt() {
      #expect(hold(World(idleHours: 23).scan()) == .idleUnder24h)
      #expect(
        hold(World().scan(lastInput: ["codex-10": t0.addingTimeInterval(-hour)])) == .idleUnder24h)
    }

    @Test func aConnectionInTheLastDayHoldsIt() {
      #expect(hold(World().scan(clockHours: 23)) == .portUsed)
      var scan = World().scan()
      scan.clock.observe(
        served: [5180], connected: [5180], now: t0.addingTimeInterval(-hour), complete: true)
      #expect(hold(scan) == .portUsed)
    }

    @Test func protectedPortsAndPortlessAreNeverEnded() {
      // The portless proxy's own ports, whatever Settings lists.
      #expect(hold(World(port: 1355).scan()) == .protectedPort)
      #expect(hold(World(port: 3000).scan()) != .protectedPort)
      var scan = World().scan()
      scan.protectedPorts = ProtectedPorts.current(
        home: URL(fileURLWithPath: "/nonexistent"), listed: [5180])
      #expect(hold(scan) == .protectedPort)
      var portless = World().scan()
      portless.records[11] = StubWorld.record(
        11, parent: 10, "/opt/homebrew/bin/portless web pnpm dev")
      #expect(hold(portless) == .portless)
    }

    @Test func keepAKeptProjectOrBusyStillProtect() {
      for protection in [UnusedPolicy.Protection.kept, .keptProject, .busy] {
        #expect(hold(World().scan(protections: ["codex-10": protection])) == .protected)
      }
    }

    @Test func aJobBesidesTheServerKeepsTheSession() {
      #expect(hold(World(job: true).scan()) == .otherJob)
    }

    @Test func notServingIsNotQ20s() {
      var scan = World().scan()
      scan.listening = [10: [62_862]]
      #expect(hold(scan) == .notServing)
    }
  }

  struct Clock {
    @Test func aPortFirstSeenStartsNowAndAConnectionResetsIt() {
      var clock = ServedPortClock()
      clock.observe(served: [5180], connected: [], now: t0, complete: true)
      #expect(clock.unused(5180, now: t0.addingTimeInterval(hour)) == hour)
      clock.observe(
        served: [5180], connected: [], now: t0.addingTimeInterval(2 * hour), complete: true)
      #expect(clock.unused(5180, now: t0.addingTimeInterval(2 * hour)) == 2 * hour)
      clock.observe(
        served: [5180], connected: [5180], now: t0.addingTimeInterval(3 * hour), complete: true)
      #expect(clock.unused(5180, now: t0.addingTimeInterval(3 * hour)) == 0)
    }

    @Test func aPortNoLongerServedIsForgottenUnlessTheScanWasPartial() {
      var clock = ServedPortClock()
      clock.observe(served: [5180], connected: [], now: t0, complete: true)
      clock.observe(served: [], connected: [], now: t0, complete: false)
      #expect(clock.unused(5180, now: t0) != nil)
      clock.observe(served: [], connected: [], now: t0, complete: true)
      #expect(clock.unused(5180, now: t0) == nil)
    }

    @Test func itSurvivesARestart() throws {
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("tamebar-ports-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: folder) }
      var clock = ServedPortClock()
      clock.observe(served: [5180], connected: [], now: t0, complete: true)
      clock.save(folder)
      #expect(ServedPortClock.load(folder) == clock)
    }

    @Test func establishedLocalPortsAreRead() {
      let output = """
        p123
        n127.0.0.1:5180->127.0.0.1:61234
        n[::1]:5181->[::1]:61235
        n10.0.0.2:61236->1.2.3.4:443
        n*:5182
        """
      #expect(ConnectedPorts.local(output) == [5180, 5181, 61_236])
    }

    /// Tamebar's own port probe is no use of the server.
    @Test func tamebarsOwnConnectionsDontCount() {
      let output = """
        p500
        n127.0.0.1:61000->127.0.0.1:5180
        p123
        n127.0.0.1:5180->127.0.0.1:61000
        n127.0.0.1:5181->127.0.0.1:62000
        """
      #expect(ConnectedPorts.local(output, selfID: 500) == [5181])
    }
  }

  struct Scheduler {
    private func candidate(_ id: String, bytes: UInt64) -> UnusedServers.Candidate {
      .init(id: id, idle: 30 * hour, memoryBytes: bytes, servers: [], unused: 30 * hour)
    }

    @Test func oneAtATimeLargestFirstNeverInACall() {
      var scheduler = UnusedServerScheduler()
      let candidates = [candidate("a", bytes: 1), candidate("b", bytes: 9)]
      #expect(scheduler.step(now: t0, inCall: true, candidates: candidates) == nil)
      #expect(scheduler.step(now: t0, inCall: false, candidates: candidates) == "b")
      #expect(scheduler.step(now: t0, inCall: false, candidates: candidates) == nil)
      scheduler.landed("b", ended: true, now: t0)
      #expect(scheduler.step(now: t0, inCall: false, candidates: [candidates[0]]) == "a")
    }

    @Test func oneThatDidNotEndWaitsAnHour() {
      var scheduler = UnusedServerScheduler()
      let candidates = [candidate("a", bytes: 1)]
      #expect(scheduler.step(now: t0, inCall: false, candidates: candidates) == "a")
      scheduler.landed("a", ended: false, now: t0)
      #expect(
        scheduler.step(now: t0.addingTimeInterval(59 * 60), inCall: false, candidates: candidates)
          == nil)
      #expect(
        scheduler.step(now: t0.addingTimeInterval(61 * 60), inCall: false, candidates: candidates)
          == "a")
    }

    @Test func theNote() {
      #expect(
        UnusedServers.note(
          name: "web-frontend", ports: [5180], sessionEnded: true, freed: 2_000_000_000)
          == "Ended web-frontend and its server :5180 · \(ByteText.full(2_000_000_000)) back")
      #expect(
        UnusedServers.note(
          name: "web-frontend", ports: [5181, 5180], sessionEnded: false, freed: 0)
          == "Ended web-frontend's servers :5180, :5181")
    }
  }

  struct Log {
    @Test func aServerLeavesOnceItListensAgainFromItsFolder() {
      var log = EndedServerLog()
      let server = EndedServer(
        id: "1", session: "web-frontend", ports: [5180], directory: "/code/web-frontend/apps/web",
        commandLine: "npm run dev", endedAt: t0, memoryBytes: 1)
      log.record(server, now: t0)
      let other = log.dropBack(listeners: [(port: 5180, directory: "/other")])
      let otherPort = log.dropBack(
        listeners: [(port: 5181, directory: "/code/web-frontend/apps/web")])
      let back = log.dropBack(listeners: [(port: 5180, directory: "/code/web-frontend/apps/web")])
      #expect(!other && !otherPort && back)
      #expect(log.servers.isEmpty)
    }

    @Test func itIsInTheStoppedListWithResumeAndItsCommand() throws {
      var input = StoppedLog.Input(now: t0)
      input.servers = [
        EndedServer(
          id: "1", session: "web-frontend", ports: [5180], directory: "/code/web",
          commandLine: "npm run dev", endedAt: t0, memoryBytes: 40_000_000,
          unusedFor: 50 * hour)
      ]
      input.codexPlugins = [.init(kind: .server, name: "context7", offAt: t0)]
      let entries = StoppedLog.entries(input)
      let server = try #require(entries.first { $0.kind == .server })
      #expect(server.name == "web-frontend :5180")
      #expect(server.command == "cd '/code/web' && npm run dev")
      #expect(server.trayDetail(now: t0) == "ended · unused 2d")
      #expect(server.commandDetail == "ended · unused 2 days")
      #expect(server.actionTitle == "Resume")
      let plugin = try #require(entries.first { $0.kind == .codexPlugin })
      #expect(plugin.kind.rawValue == "codex plugin")
      #expect(plugin.trayDetail(now: t0) == "off · unused 30d")
      #expect(plugin.actionTitle == "Undo")
      #expect(plugin.command == nil)
      #expect(plugin.target == .codexPlugin("server:context7"))
    }
  }
}

extension UnusedServersTests {
  /// The model's own Q20 path, with a stubbed scan and signal: the server first, then the session.
  @MainActor
  struct ModelEnds {
    final class ServerWorld: @unchecked Sendable {
      private let lock = NSLock()
      private var world = World()
      private var serverGone = false
      private(set) var requests: [[Int32]] = []

      fileprivate init(_ world: World) { self.world = world }

      func snapshot() -> DevProcessSnapshot {
        lock.withLock {
          var thread = world.thread
          thread.agentStatusSince = Date.now.addingTimeInterval(-30 * hour)
          var records = world.records
          var listening = world.listening
          if serverGone {
            for pid: Int32 in [11, 12, 13] { records[pid] = nil }
            listening[12] = nil
            thread = AIThread(
              id: thread.id, tool: thread.tool, name: thread.name, directory: thread.directory,
              terminal: nil, startedAt: nil, processIDs: [10, 14], memoryBytes: thread.memoryBytes,
              cpuPercent: 0, isPaused: false, isDetached: false, rootProcessID: 10,
              sessionID: thread.sessionID, agentStatus: .idle,
              agentStatusSince: thread.agentStatusSince)
          }
          return DevProcessSnapshot(
            processes: [], identities: [:], threads: [thread], resources: [],
            listeningIDs: Set(listening.keys), listeningPorts: listening, portsComplete: true,
            directories: [11: "/code/web-frontend/apps/web"], records: records)
        }
      }

      func execute(_ request: WorkloadControl.Request) -> WorkloadControl.Result {
        lock.withLock {
          requests.append(request.identities.map(\.process.processID))
          serverGone = true
          return .init(affected: 1, remaining: 0, retainedBytes: 0, identities: [])
        }
      }
    }

    private func model(_ world: ServerWorld) async -> DevProcessModel {
      let model = DevProcessModel(
        meetingMonitor: MeetingMonitor(sources: .none),
        effects: .init(snapshot: { world.snapshot() }, execute: { world.execute($0) }))
      model.endedDefaults = TestDefaults("q20-ended").defaults
      model.endedServersDefaults = TestDefaults("q20-servers").defaults
      model.statusProbe = { _ in true }
      var clock = ServedPortClock()
      clock.observe(
        served: [5180], connected: [], now: Date.now.addingTimeInterval(-30 * hour), complete: true)
      model.portClock = clock
      await model.refreshNow()
      return model
    }

    @Test func endsTheServerThenTheSessionAndRecordsBoth() async throws {
      let world = ServerWorld(World())
      let model = await model(world)
      let outcome = await model.endUnusedServer(World().thread)
      #expect(outcome.sessionEnded)
      #expect(world.requests.count == 2, "one Quit for the server, one for the session")
      let server = try #require(model.endedServers.servers.first)
      #expect(server.ports == [5180])
      #expect(
        server.command?.hasPrefix("cd '/code/web-frontend/apps/web' && npm run dev -- ") == true)
      #expect(model.endedLog.sessions.first?.unusedServer == true)
      #expect(model.stopped.contains { $0.kind == .server })
      // The stub still lists the session, which hides it from the model's list: read the log.
      var input = StoppedLog.Input(now: .now)
      input.ended = model.endedLog.sessions
      let session = StoppedLog.entries(input).first
      #expect(session?.reason == .unused(days: 1))
      #expect(session?.trayDetail(now: .now) == "ended · unused 1d")
      #expect(outcome.name == "web-frontend")
    }

    @Test func aStatusWrittenSinceTheScanHoldsBoth() async {
      let world = ServerWorld(World())
      let model = await model(world)
      model.statusProbe = { _ in false }
      let outcome = await model.endUnusedServer(World().thread)
      #expect(!outcome.sessionEnded && outcome.servers.isEmpty)
      #expect(world.requests.isEmpty)
    }

    @Test func aRecentConnectionHoldsBoth() async {
      let world = ServerWorld(World())
      let model = await model(world)
      var clock = model.portClock
      clock.observe(served: [5180], connected: [5180], now: .now, complete: true)
      model.portClock = clock
      let outcome = await model.endUnusedServer(World().thread)
      #expect(outcome.servers.isEmpty)
      #expect(world.requests.isEmpty)
    }
  }
}
