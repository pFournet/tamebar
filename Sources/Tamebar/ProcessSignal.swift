import Darwin
import Foundation

/// The only way the app signals another process. The target must still be the exact instance that
/// was shown (same PID, start time and executable), owned by this user, and not launchd or the app.
/// In e2e mode it must also sit in a live test target's tree, or have been seen in one while that
/// target is still declared (`E2EMode.allowsSignal`). That check
/// runs first, so in e2e mode a PID that has exited returns `.refused`, not `.changed`.
enum ProcessSignal {
  struct Request: Sendable {
    let expected: DevProcessIdentity
    let signal: Int32
  }

  enum Outcome: Equatable, Sendable {
    case sent(DevProcessIdentity)
    case changed
    case refused
    case failed(Int32)

    var wasSent: Bool {
      if case .sent = self { return true }
      return false
    }
  }

  /// `mode` is the e2e mode to enforce; tests pass one, the app always uses `E2EMode.current`.
  static func send(_ request: Request, mode: E2EMode? = E2EMode.current) -> Outcome {
    let processID = request.expected.process.processID
    guard processID > 1, processID != getpid(), E2EMode.allowsSignal(to: processID, mode: mode)
    else {
      return .refused
    }
    guard let current = DevProcessIdentity.read(processID), request.expected.matches(current)
    else { return .changed }
    guard current.process.owner == getuid() else { return .refused }
    guard kill(processID, request.signal) == 0 else { return .failed(errno) }
    if request.signal == SIGTERM, current.process.stopped,
      let latest = DevProcessIdentity.read(processID), request.expected.matches(latest)
    {
      kill(processID, SIGCONT)
    }
    return .sent(current)
  }
}
