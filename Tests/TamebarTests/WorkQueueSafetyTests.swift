import Darwin
import Foundation
import Testing

@testable import Tamebar

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func record(_ pid: Int32, _ parent: Int32, _ arguments: String, tty: String? = nil)
  -> RawProcessRecord
{
  .init(
    processID: pid, parentProcessID: parent, userID: Int(getuid()), cpuPercent: 0,
    residentKilobytes: 1, elapsed: "1:00", terminal: tty, arguments: arguments)
}

private func records(_ list: [RawProcessRecord]) -> [Int32: RawProcessRecord] {
  Dictionary(uniqueKeysWithValues: list.map { ($0.processID, $0) })
}

private func session(
  _ id: String = "s", root: Int32 = 100, tool: AITool = .claudeCode, pids: [Int32]? = nil,
  status: AgentStatus? = .busy, paused: Bool = false, started: TimeInterval = 0
) -> AIThread {
  var thread = AIThread(
    id: id, tool: tool, name: tool.title, directory: "/code/\(id)", terminal: nil,
    startedAt: t0.addingTimeInterval(started), processIDs: pids ?? [root], memoryBytes: 10,
    cpuPercent: 0, isPaused: paused, isDetached: false)
  thread.rootProcessID = root
  thread.agentStatus = status
  return thread
}

/// A session's terminal (spike S4): which ttys reach it, their last input (Q18: a keystroke resets
/// the idle clock), and the title restore owed to a session Q14's work queue stopped.
enum WorkQueueSafetyTests {}

extension WorkQueueSafetyTests {
  struct TTYs {
    /// Under agentrun the agent has its own pty; the pane's is the shell's above agentrun.
    @Test func thePaneIsTheFirstShellUpTheParents() {
      let world = records([
        record(5, 1, "/usr/bin/login -fp alex", tty: "ttys018"),
        record(10, 5, "-/bin/zsh", tty: "ttys018"),
        record(20, 10, "agentrun run claude", tty: "ttys018"),
        record(100, 20, "claude", tty: "ttys020"),
      ])
      let ttys = WorkQueue.ttys(session(), records: world)
      #expect(ttys?.agent == "ttys020" && ttys?.pane == "ttys018")
    }

    /// Without a shell above it on a terminal, the agent's own tty is the pane's.
    @Test func withoutAShellTheAgentsOwn() {
      let world = records([
        record(10, 1, "tmux new -s s"), record(20, 10, "/bin/sh -c claude", tty: "ttys005"),
        record(100, 20, "claude", tty: "ttys005"),
      ])
      #expect(WorkQueue.ttys(session(), records: world)?.pane == "ttys005")
      let noShell = records([record(20, 1, "node app"), record(100, 20, "claude", tty: "ttys009")])
      #expect(WorkQueue.ttys(session(), records: noShell)?.pane == "ttys009")
    }

    /// A shell reached only through a process with no terminal isn't this session's terminal.
    @Test func neverAcrossAProcessWithNoTerminal() {
      let world = records([
        record(10, 1, "-/bin/zsh", tty: "ttys001"), record(20, 10, "Code Helper"),
        record(100, 20, "claude", tty: "ttys030"),
      ])
      #expect(WorkQueue.ttys(session(), records: world)?.pane == "ttys030")
    }

    @Test func noTerminalNoNotice() {
      #expect(WorkQueue.ttys(session(), records: records([record(100, 1, "claude")])) == nil)
      let odd = records([record(100, 1, "claude", tty: "../disk0")])
      #expect(WorkQueue.ttys(session(), records: odd) == nil)
    }

    @Test func onlyPlainTTYNames() {
      #expect(WorkQueue.isTTYName("ttys012"))
      #expect(!WorkQueue.isTTYName("ttys/../../etc"))
      #expect(!WorkQueue.isTTYName("console"))
      #expect(!WorkQueue.isTTYName(""))
    }
  }

  struct LastInput {
    /// The later of the agent's own tty and its pane's: keys typed into agentrun's pane count.
    @Test func lastInputIsTheLaterOfTheAgentsAndThePanes() {
      let world = records([
        record(5, 1, "-/bin/zsh", tty: "ttys018"), record(6, 5, "agentrun run", tty: "ttys018"),
        record(100, 6, "claude", tty: "ttys020"), record(200, 1, "claude"),
      ])
      let reads = ["ttys018": t0, "ttys020": t0.addingTimeInterval(-600)]
      let inputs = WorkQueue.lastInput(
        [session("a", root: 100), session("none", root: 200)], records: world,
        read: { reads[$0] })
      #expect(inputs == ["a": t0], "no terminal, no input")
    }
  }

  struct Notice {
    @Test func theResumeClearsThenPopsTheTitleAndWritesNoLine() {
      #expect(WorkQueue.resumedNotice == "\u{1B}]2;\u{07}\u{1B}[23;0t")
      #expect(!WorkQueue.resumedNotice.contains("\n"))
    }

    /// Nothing is ever written to a path that isn't a plain tty name.
    @Test func neverWritesOutsideDev() {
      #expect(!WorkQueue.TTY.write("../tmp/x", "x"))
      #expect(WorkQueue.TTY.lastInput("../tmp/x") == nil)
    }
  }
}
