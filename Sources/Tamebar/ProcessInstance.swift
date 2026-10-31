import Darwin
import Foundation

/// One process instance as the kernel reports it: its PID, owner, start time and state. Two reads
/// are the same process only when the PID, the owner and the start time all match, so a reused
/// PID never passes for the process that was shown or recorded.
struct RecoveryProcess: Codable, Equatable, Sendable {
  let processID: Int32
  let owner: UInt32
  let startSeconds: UInt64
  let startMicroseconds: UInt64
  let state: UInt32

  var stopped: Bool { state == SSTOP }
  var exited: Bool { state == SZOMB }

  func isSameInstance(_ other: Self) -> Bool {
    processID == other.processID && owner == other.owner
      && startSeconds == other.startSeconds && startMicroseconds == other.startMicroseconds
  }

  /// The process now; nil for launchd, the kernel, or a PID that isn't running.
  static func read(_ processID: Int32) -> RecoveryProcess? {
    guard processID > 1 else { return nil }
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    let read = withUnsafeMutablePointer(to: &info) {
      proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, $0, Int32(size))
    }
    guard read == size, info.pbi_pid == UInt32(processID) else { return nil }
    return RecoveryProcess(
      processID: processID, owner: info.pbi_uid, startSeconds: info.pbi_start_tvsec,
      startMicroseconds: info.pbi_start_tvusec, state: info.pbi_status)
  }
}
