import Foundation
import Testing

@testable import Tamebar

struct UnusedPolicyTests {
  /// Q2: the day cutoff holds while memory is at warning. The model passes
  /// `PressureAssessment.memoryRisk`, so a CPU or disk warning keeps the week.
  @Test func onlyMemoryPressureShortensTheCutoff() {
    for limit in [PressureLimit.none, .memory, .disk, .cpu] {
      let reading = PressureAssessment(
        risk: .warning, limit: limit, title: "", detail: "", action: "", date: .distantPast,
        cpuStrained: limit == .cpu)
      #expect(
        UnusedPolicy.cutoff(risk: reading.memoryRisk, inMeeting: false)
          == (limit == .memory ? UnusedPolicy.day : UnusedPolicy.week), "\(limit)")
    }
  }

  let now = Date(timeIntervalSince1970: 1_800_000_000)

  func thread(
    _ status: AgentStatus?, idleDays: Double, detached: Bool = false, tool: AITool = .claudeCode
  ) -> AIThread {
    var thread = AIThread(
      id: "t-\(UUID())", tool: tool, name: "x", directory: "/code/x", terminal: "ttys001",
      startedAt: nil, processIDs: [10], memoryBytes: 400_000_000, cpuPercent: 4,
      isPaused: false, isDetached: detached)
    thread.rootProcessID = tool == .codexDesktop ? nil : 10
    thread.agentStatus = status
    thread.agentStatusSince = status == nil ? nil : now.addingTimeInterval(-idleDays * 86_400)
    return thread
  }

  func input(_ thread: AIThread, risk: MemoryRisk = .normal, meeting: Bool = false)
    -> UnusedPolicy.Input
  {
    .init(
      thread: thread, now: now, risk: risk, inMeeting: meeting, kept: false, keptProject: false,
      serving: false)
  }

  @Test func idleMoreThanAWeekIsUnused() {
    #expect(UnusedPolicy.reason(input(thread(.idle, idleDays: 8))) == .idle(8 * 86_400))
    #expect(UnusedPolicy.reason(input(thread(.idle, idleDays: 6))) == nil)
  }

  @Test func pressureOrAMeetingLowersTheCutoffToADay() {
    let session = thread(.idle, idleDays: 2)
    #expect(UnusedPolicy.reason(input(session, risk: .warning)) == .idle(2 * 86_400))
    #expect(UnusedPolicy.reason(input(session, meeting: true)) == .idle(2 * 86_400))
    #expect(UnusedPolicy.reason(input(session, risk: .critical)) == .idle(2 * 86_400))
    #expect(UnusedPolicy.reason(input(session, risk: .growing)) == nil)
  }

  @Test func busyAndShellAreNeverUnusedEvenWhenDetached() {
    #expect(UnusedPolicy.reason(input(thread(.busy, idleDays: 30, detached: true))) == nil)
    let shell = thread(.shell, idleDays: 30, detached: true)
    #expect(UnusedPolicy.reason(input(shell)) == nil)
    #expect(UnusedPolicy.protection(input(shell)) == .busy)
  }

  @Test func agentsWithoutASignalAreUnusedOnlyWhenDetached() {
    let cursor = thread(nil, idleDays: 0, tool: .cursorAgent)
    #expect(UnusedPolicy.reason(input(cursor)) == nil)
    let detached = thread(nil, idleDays: 0, detached: true, tool: .cursorAgent)
    #expect(UnusedPolicy.reason(input(detached)) == .detached)
  }

  @Test func protectionsWinOverIdle() {
    let session = thread(.idle, idleDays: 10)
    let cases: [((Bool, Bool, Bool), UnusedPolicy.Protection)] = [
      ((true, false, false), .kept), ((false, true, false), .keptProject),
      ((false, false, true), .serving),
    ]
    for (flags, expected) in cases {
      let protected = UnusedPolicy.Input(
        thread: session, now: now, risk: .critical, inMeeting: false,
        kept: flags.0, keptProject: flags.1, serving: flags.2)
      #expect(UnusedPolicy.reason(protected) == nil)
      #expect(UnusedPolicy.protection(protected) == expected)
    }
  }

  @Test func idleForComesOnlyFromTheAgentSignal() {
    #expect(UnusedPolicy.idleFor(thread(.idle, idleDays: 3), now: now) == TimeInterval(3 * 86_400))
    #expect(UnusedPolicy.idleFor(thread(nil, idleDays: 3), now: now) == nil)
  }

  @Test func idleWithoutATimestampIsUnusedOnlyWhenDetached() {
    var attached = thread(.idle, idleDays: 30)
    attached.agentStatusSince = nil
    #expect(UnusedPolicy.idleFor(attached, now: now) == nil)
    #expect(UnusedPolicy.reason(input(attached, risk: .critical)) == nil)

    var detached = thread(.idle, idleDays: 30, detached: true)
    detached.agentStatusSince = nil
    #expect(UnusedPolicy.reason(input(detached)) == .detached)
  }

  @Test func theCutoffItselfCountsAsUnused() {
    #expect(UnusedPolicy.reason(input(thread(.idle, idleDays: 7))) == .idle(7 * 86_400))
    #expect(
      UnusedPolicy.reason(input(thread(.idle, idleDays: 1), risk: .warning)) == .idle(86_400))
    #expect(UnusedPolicy.reason(input(thread(.idle, idleDays: 1))) == nil)
  }

  @Test func aBusyCodexSessionIsProtected() {
    let codex = thread(.busy, idleDays: 30, detached: true, tool: .codexCLI)
    #expect(UnusedPolicy.protection(input(codex, risk: .critical)) == .busy)
    #expect(UnusedPolicy.reason(input(codex, risk: .critical, meeting: true)) == nil)
  }

  @Test func codexDesktopWorkersAreNeverUnused() {
    let workers = thread(.idle, idleDays: 30, detached: true, tool: .codexDesktop)
    #expect(UnusedPolicy.reason(input(workers, risk: .critical, meeting: true)) == nil)
    let silent = thread(nil, idleDays: 0, detached: true, tool: .codexDesktop)
    #expect(UnusedPolicy.reason(input(silent)) == nil)
  }

  func evaluate(
    _ threads: [AIThread], keeps: SessionKeeps = .init(), keptDirectories: Set<String> = [],
    servingIDs: Set<Int32> = []
  ) -> UnusedPolicy.Evaluation {
    UnusedPolicy.evaluate(
      .init(
        threads: threads, now: now, risk: .normal, inMeeting: false, keeps: keeps,
        keptDirectories: keptDirectories, servingIDs: servingIDs))
  }

  @Test func evaluateKeepsAPinnedSessionOutOfUnused() {
    var session = thread(.idle, idleDays: 30, detached: true)
    session.sessionID = "abc"
    var keeps = SessionKeeps()
    keeps.toggle("session:abc")
    let result = evaluate([session], keeps: keeps)
    #expect(result.reasons.isEmpty)
    #expect(result.protections == [session.id: .kept])
  }

  @Test func evaluateProtectsASessionInAKeptProject() {
    let session = thread(.idle, idleDays: 30)
    let result = evaluate([session], keptDirectories: ["/code/x"])
    #expect(result.reasons.isEmpty)
    #expect(result.protections == [session.id: .keptProject])
  }

  /// Root first, as `AIThreadGrouping.subtree` builds it.
  func tree(_ tool: AITool, _ processIDs: [Int32], idleDays: Double = 8) -> AIThread {
    var thread = AIThread(
      id: "\(tool.rawValue)-\(processIDs[0])-1", tool: tool, name: "x", directory: "/code/x",
      terminal: "ttys001", startedAt: nil, processIDs: processIDs, memoryBytes: 0,
      cpuPercent: 0, isPaused: false, isDetached: false)
    thread.rootProcessID = tool == .codexDesktop ? nil : processIDs[0]
    thread.agentStatus = .idle
    thread.agentStatusSince = now.addingTimeInterval(-idleDays * 86_400)
    return thread
  }

  @Test func evaluateCountsAServerHeldByAGrandchild() {
    let session = tree(.claudeCode, [10, 11, 12])
    let result = evaluate([session], servingIDs: [12, 99])
    #expect(result.reasons.isEmpty)
    #expect(result.protections == [session.id: .serving])
    #expect(evaluate([session], servingIDs: [99]).reasons == [session.id: .idle(8 * 86_400)])
  }

  @Test func theAgentsOwnListenerIsNotServing() {
    let session = tree(.codexCLI, [10, 11])
    let result = evaluate([session], servingIDs: [10])
    #expect(result.protections.isEmpty)
    #expect(result.reasons == [session.id: .idle(8 * 86_400)])
  }

  @Test func theNativeCodexUnderANodeWrapperIsNotServing() {
    var session = tree(.codexCLI, [20, 21, 22])
    session.nativeProcessID = 21
    let result = evaluate([session], servingIDs: [20, 21])
    #expect(result.protections.isEmpty)
    #expect(result.reasons == [session.id: .idle(8 * 86_400)])
    #expect(evaluate([session], servingIDs: [21, 22]).protections == [session.id: .serving])
  }

  @Test func evaluateReportsIdleAndBusySessions() {
    let idle = thread(.idle, idleDays: 8)
    let busy = thread(.busy, idleDays: 30)
    let recent = thread(.idle, idleDays: 2)
    let result = evaluate([idle, busy, recent])
    #expect(result.reasons == [idle.id: .idle(8 * 86_400)])
    #expect(result.protections == [busy.id: .busy])
  }

  @Test func aPinByThreadIDHoldsAfterTheSessionIDAppears() {
    var session = thread(.idle, idleDays: 30)
    var keeps = SessionKeeps()
    keeps.toggle(session.id)
    session.sessionID = "abc"
    #expect(evaluate([session], keeps: keeps).protections == [session.id: .kept])
  }

  @Test func aCodexDesktopWorkerCanServeItself() {
    let workers = tree(.codexDesktop, [30, 31])
    #expect(evaluate([workers], servingIDs: [30]).protections == [workers.id: .serving])
  }

  @Test func aPartialPortScanAddsToTheLastListeners() {
    let partial = UnusedPolicy.PortScan(listening: [13], complete: false)
    #expect(UnusedPolicy.listeners(previous: [12], scan: partial) == [12, 13])
    let complete = UnusedPolicy.PortScan(listening: [13], complete: true)
    #expect(UnusedPolicy.listeners(previous: [12], scan: complete) == [13])
    let empty = UnusedPolicy.PortScan(listening: [], complete: true)
    #expect(UnusedPolicy.listeners(previous: [12], scan: empty) == [])
  }

  @Test func aPartialPortScanStillEvaluatesTheAgentSignal() {
    let listening = UnusedPolicy.listeners(
      previous: [12], scan: .init(listening: [], complete: false))
    var session = tree(.claudeCode, [10, 11, 12])
    #expect(evaluate([session], servingIDs: listening).protections == [session.id: .serving])
    let quiet = tree(.claudeCode, [20, 21])
    #expect(evaluate([quiet], servingIDs: listening).reasons == [quiet.id: .idle(8 * 86_400)])
    var busy = quiet
    busy.agentStatus = .busy
    let result = evaluate([busy], servingIDs: listening)
    #expect(result.reasons.isEmpty)
    #expect(result.protections == [busy.id: .busy])
    session.agentStatus = .busy
    #expect(evaluate([session], servingIDs: listening).protections == [session.id: .busy])
  }

  @Test func onlyAThreadWithAProtectionIsProtected() {
    let protections: [String: UnusedPolicy.Protection] = ["kept": .kept, "busy": .busy]
    #expect(UnusedPolicy.isProtected(threadID: "kept", protections: protections))
    #expect(UnusedPolicy.isProtected(threadID: "busy", protections: protections))
    #expect(!UnusedPolicy.isProtected(threadID: "idle", protections: protections))
    #expect(!UnusedPolicy.isProtected(threadID: nil, protections: protections))
  }
}
