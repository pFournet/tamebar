import Foundation

/// A short read-only command for the process scans (`ps`, `lsof`), with a deadline and an output
/// cap, through `CommandRunner`.
enum DeveloperCommand {
  struct Request: Sendable {
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval
    let maximumBytes: Int
  }

  struct Result: Sendable {
    let status: Int32
    let output: String
  }

  static func run(_ request: Request) -> Result {
    let output = CommandRunner.run(
      .init(
        executable: request.executable, arguments: request.arguments, timeout: request.timeout,
        maximumBytes: request.maximumBytes, input: nil, environment: .noninteractive))
    return .init(status: output.status, output: output.text)
  }
}
