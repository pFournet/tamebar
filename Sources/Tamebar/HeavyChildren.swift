import Foundation

/// What Tamebar slows on its own under CPU pressure or during a call (Q9, Q12): the heavy
/// children of busy AI sessions and heavy terminal jobs. Pure.
///
/// Background priority is inherited by every process forked after it is set, so nothing on a
/// server's line is ever slowed: not a server, not what a server started, and not an ancestor of
/// one, whose next restart would come up slowed.
enum HeavyChildren {
  /// CPU at or above this, per process, 100% being one core, is heavy.
  static let minimumCPU = 30.0
  /// Arguments that mark a tool server the agent talks to. Slowing one stalls the agent.
  static let serverMarkers = ["mcp", "server-", "--stdio"]

  /// What every candidate is checked against.
  struct Scan {
    /// The scan's `ps` records by PID, with their real arguments and parents.
    let records: [Int32: RawProcessRecord]
    /// Processes holding a listening port.
    let serving: Set<Int32>
    /// Directories inside a Keep running project.
    let keptDirectories: Set<String>
  }

  struct Input {
    let thread: AIThread
    let scan: Scan
  }

  /// The heavy children of a busy, running session outside a Keep running project. Never the
  /// agent itself (its root, its native process, or the first process when no root is known).
  static func select(_ input: Input) -> [Int32] {
    let thread = input.thread
    let scan = input.scan
    guard thread.agentStatus == .busy, !thread.isPaused, let first = thread.processIDs.first,
      !(thread.directory.map(scan.keptDirectories.contains) ?? false)
    else { return [] }
    let agent = Set([first, thread.rootProcessID, thread.nativeProcessID].compactMap { $0 })
    let line = ServingLine(serving: scan.serving, parents: parents(scan.records))
    return thread.processIDs.filter { pid in
      !agent.contains(pid) && heavy(pid, records: scan.records) && !line.touches(pid)
    }
  }

  /// At or above `minimumCPU`, and neither a tool server nor an agent of its own (a nested
  /// `claude -p` or `codex exec`), whose own heavy children may still be slowed.
  static func heavy(_ pid: Int32, records: [Int32: RawProcessRecord]) -> Bool {
    guard let record = records[pid], record.cpuPercent >= minimumCPU else { return false }
    return !serverMarkers.contains { record.arguments.contains($0) }
      && !AIThreadGrouping.isAgent(record.arguments)
  }

  struct Workloads {
    let consumers: [ResourceConsumer]
    let scan: Scan
    /// The frontmost app's PID.
    let frontApp: Int32?
  }

  struct Workload: Equatable, Sendable {
    /// The consumer row's ID.
    let id: String
    let name: String
    let processIDs: [Int32]
  }

  /// The heavy processes of terminal jobs (builds, tests, scripts): none in a Keep running
  /// project, none in the front app's tree, none on a server's line.
  static func workloads(_ input: Workloads) -> [Workload] {
    let scan = input.scan
    let parents = parents(scan.records)
    let line = ServingLine(serving: scan.serving, parents: parents)
    let front = Set([input.frontApp].compactMap { $0 })
    return input.consumers.compactMap { consumer in
      guard consumer.kind == .workload, !consumer.isPaused,
        !(consumer.directory.map(scan.keptDirectories.contains) ?? false)
      else { return nil }
      let pids = consumer.processIDs.filter { pid in
        heavy(pid, records: scan.records) && !line.touches(pid)
          && !descends(pid, from: front, parents: parents)
      }
      return pids.isEmpty ? nil : Workload(id: consumer.id, name: consumer.name, processIDs: pids)
    }
  }

  static func parents(_ records: [Int32: RawProcessRecord]) -> [Int32: Int32] {
    records.mapValues(\.parentProcessID)
  }

  /// Every process on a server's line: the servers, their ancestors, and what they started.
  struct ServingLine {
    private let servers: Set<Int32>
    private let ancestors: Set<Int32>
    private let parents: [Int32: Int32]

    init(serving: Set<Int32>, parents: [Int32: Int32]) {
      servers = serving
      self.parents = parents
      var ancestors: Set<Int32> = []
      for server in serving {
        var current = parents[server]
        while let next = current, next > 1, ancestors.insert(next).inserted {
          current = parents[next]
        }
      }
      self.ancestors = ancestors
    }

    func touches(_ pid: Int32) -> Bool {
      ancestors.contains(pid) || HeavyChildren.descends(pid, from: servers, parents: parents)
    }
  }

  /// True when `pid` is in `roots` or one of its ancestors is. A loop or launchd ends the walk.
  static func descends(_ pid: Int32, from roots: Set<Int32>, parents: [Int32: Int32]) -> Bool {
    guard !roots.isEmpty else { return false }
    var current: Int32? = pid
    var visited: Set<Int32> = []
    while let next = current, next > 1, visited.insert(next).inserted {
      if roots.contains(next) { return true }
      current = parents[next]
    }
    return false
  }
}
