import Foundation

/// Ask Claude / Ask Codex, at the bottom of the hover card (N8, 2026-10-29: "it miss a little
/// button to spawn a terminal of a claude or codex to do action"). A click opens Terminal.app in
/// the home folder running the tool with one prompt, through the Stopped list's Resume mechanism
/// (`TerminalLauncher`, Q15). A button shows only while its tool is installed (`AskAgents`).
enum AskAgent: String, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
  case claude
  case codex

  var id: String { rawValue }

  /// The command's name, typed bare: Terminal's `do script` types it into the user's interactive
  /// login shell, so their own alias or function for it applies (a zsh that runs
  /// `agentrun run claude` for `claude`).
  var executable: String { rawValue }

  var title: String {
    switch self {
    case .claude: "Ask Claude"
    case .codex: "Ask Codex"
    }
  }

  static let prompt =
    "The Mac is under pressure. Use `tamebar status` and `tamebar sessions`, propose what to end or quit, and ask me before ending anything."

  /// What Terminal runs: in the home folder, the tool with `prompt` as its one argument. Nil when
  /// the prompt can't be typed safely (`ShellQuote.single`).
  func command(prompt: String = Self.prompt) -> String? {
    guard let quoted = ShellQuote.single(prompt) else { return nil }
    return "cd ~ && \(executable) \(quoted)"
  }
}

enum ShellQuote {
  /// `text` as one word for a POSIX shell (zsh, bash): in single quotes, where nothing expands
  /// (backticks, `$`, `!`, `\`), and a single quote in it closes the quotes, is escaped and
  /// reopens them. Nil when it holds a control character (a newline, a return, Ctrl-U, an escape),
  /// which a terminal's line editor acts on even inside quotes.
  static func single(_ text: String) -> String? {
    guard !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
    else { return nil }
    return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

/// Which tools are installed, found as the user's login shell finds them: on the PATH their
/// interactive login shell sets (read once, `$SHELL -lic`), then the app's own PATH, then the
/// places the tools install to. Pure; `AskAgents` reads the Mac.
enum AskAgentInstall {
  /// Printed before the PATH, so whatever the shell's startup files print is skipped.
  static let marker = "__TAMEBAR_PATH__"

  /// The arguments that print the login shell's PATH after `marker`. `printenv` is the same in
  /// every shell.
  static let shellArguments = ["-lic", "echo \(marker); /usr/bin/printenv PATH"]

  /// Where Claude Code and Codex install themselves, and the package managers' bin folders.
  static func knownLocations(home: String) -> [String] {
    [
      home + "/.local/bin", home + "/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
      home + "/.npm-global/bin", home + "/.bun/bin", home + "/.volta/bin",
    ]
  }

  /// The PATH on the line after `marker` in the shell's output; nil when there is none.
  static func shellPath(from output: String) -> String? {
    let lines = output.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard let index = lines.lastIndex(of: marker), index + 1 < lines.count else { return nil }
    let path = lines[index + 1]
    return path.isEmpty ? nil : path
  }

  /// The folders to look in, in order, each once: the login shell's PATH, the app's PATH, then the
  /// known locations. Relative entries are skipped: they depend on a folder Terminal won't be in.
  static func directories(shellPath: String?, processPath: String?, home: String) -> [String] {
    var seen: Set<String> = []
    let entries =
      [shellPath, processPath].compactMap { $0 }.flatMap {
        $0.split(separator: ":").map(String.init)
      }
      + knownLocations(home: home)
    return entries.compactMap { entry in
      let folder = entry.hasPrefix("~/") ? home + entry.dropFirst() : entry
      guard folder.hasPrefix("/") else { return nil }
      let trimmed = folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder
      return seen.insert(trimmed).inserted ? trimmed : nil
    }
  }

  /// The tools with an executable file of their name in one of `directories`, in `AskAgent`'s
  /// order.
  static func installed(in directories: [String], isExecutable: (String) -> Bool) -> [AskAgent] {
    AskAgent.allCases.filter { agent in
      directories.contains { isExecutable($0 + "/" + agent.executable) }
    }
  }
}

/// The installed tools, for the card's buttons (N8). Read off the main thread when the app starts
/// (`start`), and again when a card opens once the last read is `recheckAfter` old, so a tool
/// installed while Tamebar runs appears; never per frame. The login shell's PATH is read once.
/// Until `start`, nothing is installed, so tests never read this Mac.
@MainActor
final class AskAgents: ObservableObject {
  @Published private(set) var installed: [AskAgent]
  private var started = false
  private var checking = false
  private var checkedAt: Date?
  private var shellRead = false
  private var shellPath: String?

  static let recheckAfter: TimeInterval = 60
  /// The longest the login shell may take to print its PATH; past it, the known locations do.
  nonisolated static let shellTimeout: TimeInterval = 5

  init(installed: [AskAgent] = []) {
    self.installed = installed
  }

  func start() {
    started = true
    refresh()
  }

  /// Looks again, off the main thread, when the last look is `recheckAfter` old.
  func refresh(now: Date = .now) {
    guard started, !checking,
      checkedAt.map({ now.timeIntervalSince($0) >= Self.recheckAfter }) ?? true
    else { return }
    checking = true
    let known: String?? = shellRead ? .some(shellPath) : nil
    Task.detached(priority: .utility) { [weak self] in
      let path = known ?? Self.readShellPath()
      let directories = AskAgentInstall.directories(
        shellPath: path, processPath: ProcessInfo.processInfo.environment["PATH"],
        home: NSHomeDirectory())
      let installed = AskAgentInstall.installed(in: directories) {
        FileManager.default.isExecutableFile(atPath: $0)
      }
      await self?.finish(shellPath: path, installed: installed)
    }
  }

  private func finish(shellPath: String?, installed: [AskAgent]) {
    checking = false
    checkedAt = .now
    shellRead = true
    self.shellPath = shellPath
    if installed != self.installed { self.installed = installed }
  }

  /// The PATH the user's interactive login shell sets, as Terminal's shell will have it; nil when
  /// it can't be read in `shellTimeout`. The e2e build never runs the user's shell.
  nonisolated static func readShellPath() -> String? {
    guard E2EMode.current == nil else { return nil }
    let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap {
      $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil
    }
    let output = CommandRunner.run(
      .init(
        executable: shell ?? "/bin/zsh", arguments: AskAgentInstall.shellArguments,
        timeout: shellTimeout, maximumBytes: 64 * 1024, input: nil, environment: .inherited))
    guard output.ending == .exited(0) else { return nil }
    return AskAgentInstall.shellPath(from: output.text)
  }

  /// Opens a Terminal window in the home folder running `agent` with the prompt.
  static func launch(_ agent: AskAgent) {
    guard let command = agent.command() else { return }
    TerminalLauncher.run(command)
  }
}
