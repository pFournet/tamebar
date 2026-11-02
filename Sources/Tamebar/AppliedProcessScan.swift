import Foundation

/// Reconciles one process scan with earlier serving observations.
/// A partial lsof read must not remove a serving protection, while Q20 may use only the ports
/// observed in this scan and must not infer inactivity from missing lines.
struct AppliedProcessScan: Sendable {
  private var servingIDs: Set<Int32> = []
  private var hasCompletePortScan = false

  struct Observation: Sendable {
    let consumers: [ResourceConsumer]
    let stoppedIDs: Set<Int32>
    /// The current listeners plus prior listeners when this port scan is partial (Q7).
    let servingIDs: Set<Int32>
    /// True once at least one complete listener scan has landed. Background priority waits for it.
    let portsScanned: Bool
    /// The scanner's overall completeness judgment for this tick.
    let scanComplete: Bool
    /// Only the ports the current scan actually observed (Q20).
    let listeningPorts: [Int32: [Int]]
    let establishedPorts: Set<Int>
    /// Both listener and connection reads completed, so Q20 may forget absent ports.
    let portActivityComplete: Bool
    let directories: [Int32: String]
    let threads: [AIThread]

    /// Current ports with their project folders. A partial scan cannot prove an old server left.
    var listenerLocations: [(port: Int, directory: String?)] {
      listeningPorts.flatMap { pid, ports in
        ports.map { (port: $0, directory: directories[pid]) }
      }
    }

    /// Advances Q20's persisted clock from the same current ports and completeness judgment.
    /// Returns ports served by AI sessions for the action's early exit and candidate scan.
    @discardableResult
    func observePortUse(in clock: inout ServedPortClock, now: Date) -> Set<Int> {
      let served = threads.reduce(into: Set<Int>()) {
        $0.formUnion(UnusedServers.servedPorts($1, listening: listeningPorts))
      }
      clock.observe(
        served: served, connected: establishedPorts, now: now, complete: portActivityComplete)
      return served
    }
  }

  mutating func apply(_ scan: DevProcessSnapshot) -> Observation {
    servingIDs = UnusedPolicy.listeners(
      previous: servingIDs,
      scan: .init(listening: scan.listeningIDs, complete: scan.portsComplete))
    if scan.portsComplete { hasCompletePortScan = true }
    let stopped = Set(scan.identities.values.filter(\.process.stopped).map(\.process.processID))
    return Observation(
      consumers: ResourceConsumers.build(
        .init(threads: scan.threads, resources: scan.resources, stopped: stopped)),
      stoppedIDs: stopped, servingIDs: servingIDs, portsScanned: hasCompletePortScan,
      scanComplete: !scan.incomplete, listeningPorts: scan.listeningPorts,
      establishedPorts: scan.establishedPorts,
      portActivityComplete: scan.portsComplete && scan.establishedComplete,
      directories: scan.directories, threads: scan.threads)
  }
}
