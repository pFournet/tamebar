import Darwin
import Foundation

/// The running Tamebar's half of Q19: from each 2-second reading it judges the strain
/// (`StrainPlanner`), says so in `strain.json` for `tamebar wait`, and releases the sessions
/// waiting at start once it clears, oldest first, one per `StartWait.releaseSpacing`. Only the
/// Tamebar that acts has one.
@MainActor
final class StartGate {
  let directory: URL
  private(set) var planner = StrainPlanner()
  /// The sessions waiting now, oldest first, those already released left out.
  private(set) var waiting: [StartWait.Registration] = []
  /// When the clock last released one.
  private var lastRelease: Date?
  private var written: StrainFile?
  private let pid = getpid()
  private let pidStart: Double?
  /// Whether a pid is still running, with its start time; a test swaps in its own.
  var startTime: (Int32) -> Double? = E2EMode.startTime

  /// While struggling, the file is rewritten at most this often for new values.
  static let refresh: TimeInterval = 10

  init(directory: URL, now: Date = .now) {
    self.directory = directory
    pidStart = E2EMode.startTime(getpid())
    write(now: now, force: true)
  }

  var struggling: Bool { planner.struggling }

  /// One reading. Returns the sessions it released.
  @discardableResult
  func observe(_ reading: StrainReading, forced: Bool? = nil) -> [StartWait.Registration] {
    let changed = planner.observe(reading, forced: forced)
    write(now: reading.date, force: changed)
    let live = StartWait.prune(directory, startTime: startTime)
    let released = Set(
      live.map(\.waitPID).filter { StartWait.isReleased($0, directory: directory) })
    var done: [StartWait.Registration] = []
    if let due = StartWait.due(
      live, released: released, struggling: planner.struggling, last: lastRelease,
      now: reading.date),
      StartWait.release(due.waitPID, by: "strain_cleared", at: reading.date, directory: directory)
    {
      lastRelease = reading.date
      done.append(due)
    }
    let gone = released.union(done.map(\.waitPID))
    waiting = live.filter { !gone.contains($0.waitPID) }
    return done
  }

  /// The card's Start now, or `startNow:` from an e2e test: releases that session at once.
  @discardableResult
  func startNow(_ waitPID: Int32, now: Date = .now) -> Bool {
    guard waiting.contains(where: { $0.waitPID == waitPID }),
      StartWait.release(waitPID, by: "start_now", at: now, directory: directory)
    else { return false }
    waiting.removeAll { $0.waitPID == waitPID }
    return true
  }

  /// Rewrites `strain.json` when the strain or its signals changed, and while struggling at most
  /// every `refresh` for the signals' values.
  private func write(now: Date, force: Bool) {
    let file = StrainFile(
      pid: pid, pidStart: pidStart, struggling: planner.struggling, since: planner.since,
      signals: planner.signals, updated: now)
    if !force, let written {
      guard file.struggling, file.signals != written.signals,
        now.timeIntervalSince(written.updated) >= Self.refresh
      else { return }
    }
    file.write(directory)
    written = file
  }
}
