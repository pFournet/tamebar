import Foundation

/// Opens a new Terminal.app window running a command, in front: the Stopped list's Resume on an
/// ended session (Q15, which amends Q4's "never drives the terminal") and the card's Ask Claude /
/// Ask Codex (N8). It goes through `osascript` (`do script`), so macOS asks once for Automation of
/// Terminal (`NSAppleEventsUsageDescription`, the apple-events entitlement).
enum TerminalLauncher {
  /// The AppleScript that runs `command`: backslashes and quotes escaped for its string.
  static func script(_ command: String) -> String {
    let escaped =
      command
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return """
      tell application "Terminal"
          activate
          do script "\(escaped)"
      end tell
      """
  }

  static func run(_ command: String) {
    // The e2e build never opens a real Terminal.
    guard E2EMode.current == nil else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script(command)]
    try? process.run()
  }
}
