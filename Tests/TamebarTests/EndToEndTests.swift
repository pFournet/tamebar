import Darwin
import Foundation
import Testing

@testable import Tamebar

/// Launches the real e2e build against fake agents. Runs only with `TAMEBAR_E2E_APP` set
/// (`scripts/e2e.sh`). It signals only its own fakes, their verified descendants, the server it
/// pinned, the app it launched and the fake apps it compiled into its own folder.
@Suite(.serialized)
struct EndToEndTests {
  static let appPath = ProcessInfo.processInfo.environment["TAMEBAR_E2E_APP"]
  static let bundleID = "com.tamebar.Tamebar.e2e"

  struct Fake {
    let name: String
    let process: Process
    /// Read at spawn, in `E2EMode.Target.start`'s measure. Every signal checks it again.
    let start: Double
    var pid: Int32 { process.processIdentifier }
  }

  /// A process the rig didn't spawn itself but pinned by its start time: the fake's server.
  struct Pinned {
    let name: String
    let pid: Int32
    let start: Double
  }

  enum RigError: Error, CustomStringConvertible {
    /// A child of ours whose start time can't be read has already exited.
    case exitedAtStart(String)
    case timedOut(String, state: String)

    var description: String {
      switch self {
      case .exitedAtStart(let name): "\(name) exited before its start time could be read"
      case .timedOut(let label, let state): "timed out: \(label)\nstate: \(state)"
      }
    }
  }

  final class Rig {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tamebar-e2e-\(UUID().uuidString.prefix(8))", isDirectory: true)
    private(set) var fakes: [Fake] = []
    private var app: (process: Process, start: Double)?
    private var servers: [Pinned] = []
    /// Processes the rig started detached, so launchd is their parent.
    private var detached: [Pinned] = []
    /// A fake's descendants, pinned before Tamebar ends it: a survivor is orphaned, out of the
    /// fake's tree, and would hold the test's output open.
    private var pinnedDescendants: [Pinned] = []
    private var registered: [Pinned] = []
    /// Fake apps the rig compiled, by executable path inside `dir`, and every instance pinned.
    private var fakeApps: [String] = []
    private var appInstances: [Pinned] = []
    /// The fake apps the rig started: targets while they run, since Tamebar may quit one.
    private var appTargets: [Pinned] = []
    /// Agents a fake started under a shell of its own (spike S4): targets while they
    /// run, ended with that fake's tree.
    private var agentTargets: [Pinned] = []
    /// Merged into every control write: what the e2e build reads in place of the probes.
    var controlBase: [String: Any] = [:]
    private var cleaned = false
    var home: URL { dir.appendingPathComponent("home") }
    /// `/bin/sleep` under an MCP server's name.
    var mcpServer: String { dir.appendingPathComponent("bin/mcp-server-fake").path }

    init() throws {
      let manager = FileManager.default
      for sub in [
        "home/.claude/sessions", "home/.codex/sessions/2026/10/19", "bin", "commands", "www",
      ] {
        try manager.createDirectory(
          at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
      }
      // A symlink, not a copy: macOS kills a copied /bin/sh (launch constraints). argv[0] keeps
      // the link's path, which is all `AIThreadGrouping` reads.
      for tool in ["claude", "codex"] {
        try manager.createSymbolicLink(
          atPath: dir.appendingPathComponent("bin/\(tool)").path, withDestinationPath: "/bin/sh")
      }
      // A `sleep` that reads as the agent's MCP server: an agent helper, not a background job,
      // so a session whose only child it is can still be ended automatically (Q10).
      try manager.createSymbolicLink(
        atPath: mcpServer, withDestinationPath: "/bin/sleep")
      // Lines an interrupted earlier run left, for pids that no longer run.
      try AgentProcRegistry.pruneDead(from: AgentProcRegistry.file)
    }

    @discardableResult
    func spawn(_ name: String, tool: String, script: String) throws -> Fake {
      let process = Process()
      process.executableURL = dir.appendingPathComponent("bin/\(tool)")
      process.arguments = ["-c", script]
      process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
      process.standardInput = FileHandle.nullDevice
      try process.run()
      // No start time means it already exited, and with nothing to check a pid against, the rig
      // sends no signal at all.
      guard let start = E2EMode.startTime(process.processIdentifier) else {
        throw RigError.exitedAtStart(name)
      }
      let fake = Fake(name: name, process: process, start: start)
      fakes.append(fake)
      return fake
    }

    /// A fake `claude` started by an interactive zsh (`zsh -f -i -c`), the shell staying its
    /// parent: the case spike S4 found a stop unsafe for. Returns the
    /// shell, whose tree cleanup ends, and the agent, pinned as a target.
    func spawnUnderInteractiveShell(_ name: String, script: String) async throws -> (
      shell: Fake, agent: Pinned
    ) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      let agent = dir.appendingPathComponent("bin/claude").path
      // The trailing `:` keeps zsh from exec'ing the agent in its place.
      process.arguments = ["-f", "-i", "-c", "'\(agent)' -c \"\(script)\"; :"]
      process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      guard let start = E2EMode.startTime(process.processIdentifier) else {
        throw RigError.exitedAtStart(name)
      }
      let shell = Fake(name: "\(name) shell", process: process, start: start)
      fakes.append(shell)
      var found: Pinned?
      try await poll("\(name) under its shell") {
        found =
          LiveProcessTree.read().descendants([shell.pid]).lazy
          .filter { $0 != shell.pid && Self.parent($0) == shell.pid }
          .compactMap { pid -> Pinned? in
            guard Self.arguments(pid).hasPrefix(agent), let start = E2EMode.startTime(pid)
            else { return nil }
            return Pinned(name: name, pid: pid, start: start)
          }.first
        return found != nil
      }
      let pinned = try #require(found)
      agentTargets.append(pinned)
      return (shell, pinned)
    }

    /// Pins the fake's live descendants, so cleanup ends any that outlive it.
    func pinDescendants(of fake: Fake) -> [Pinned] {
      let pinned = LiveProcessTree.read().descendants([fake.pid]).filter { $0 != fake.pid }
        .compactMap { pid in
          E2EMode.startTime(pid).map { Pinned(name: "\(fake.name) child", pid: pid, start: $0) }
        }
      pinnedDescendants += pinned
      return pinned
    }

    /// Waits for the python child the serving fake runs, and pins it: that pid holds the port.
    func pinServer(of fake: Fake) async throws -> Pinned {
      var found: Pinned?
      try await poll("\(fake.name)'s python") {
        found =
          LiveProcessTree.read().descendants([fake.pid]).lazy.filter { $0 != fake.pid }
          .compactMap { pid -> Pinned? in
            guard Self.isPython(pid), let start = E2EMode.startTime(pid) else { return nil }
            return Pinned(name: "\(fake.name) server", pid: pid, start: start)
          }.first
        return found != nil
      }
      let server = try #require(found)
      servers.append(server)
      return server
    }

    private static func isPython(_ pid: Int32) -> Bool {
      guard let path = path(pid) else { return false }
      return URL(fileURLWithPath: path).lastPathComponent.lowercased().hasPrefix("python")
    }

    static func path(_ pid: Int32) -> String? {
      var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
      guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
      return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
    }

    /// The fake's live descendant that `matches`, waited for.
    func descendant(of fake: Fake, _ label: String, _ matches: @escaping (Int32) -> Bool)
      async throws -> Int32
    {
      var found: Int32?
      try await poll("\(fake.name)'s \(label)") {
        found = LiveProcessTree.read().descendants([fake.pid]).first {
          $0 != fake.pid && matches($0)
        }
        return found != nil
      }
      let pid = try #require(found)
      // Pinned, so cleanup ends it once it has outlived the fake (reparented to launchd).
      pin(pid, "\(fake.name)'s \(label)")
      return pid
    }

    /// Pins a process the rig started indirectly (a fake's background job), so cleanup ends it.
    /// A `yes` left behind runs at 100% CPU until someone kills it (2026-10-31).
    func pin(_ pid: Int32, _ name: String) {
      guard let start = E2EMode.startTime(pid) else { return }
      pinnedDescendants.append(Pinned(name: name, pid: pid, start: start))
    }

    /// `ps`'s arguments for the process.
    static func arguments(_ pid: Int32) -> String {
      ps(["-o", "args=", "-p", "\(pid)"])
    }

    private static func ps(_ arguments: [String]) -> String {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/ps")
      process.arguments = arguments
      let pipe = Pipe()
      process.standardOutput = pipe
      guard (try? process.run()) != nil else { return "" }
      process.waitUntilExit()
      return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Something accepts connections on 127.0.0.1:`port`.
    static func accepts(_ port: UInt16) -> Bool {
      let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
      guard socket >= 0 else { return false }
      defer { close(socket) }
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = port.bigEndian
      address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
      return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
      }
    }

    /// Starts `executable` with `arguments` in `directory` through a shell that exits at once,
    /// so launchd becomes its parent and no app's tree holds it, and pins it by its start time.
    func detach(
      _ name: String, executable: String, arguments: [String] = [],
      directory: URL = URL(fileURLWithPath: "/tmp")
    ) throws -> Pinned {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      let command = ([executable] + arguments).map { "'\($0)'" }.joined(separator: " ")
      process.arguments = ["-c", "\(command) >/dev/null 2>&1 </dev/null & echo $!"]
      process.currentDirectoryURL = directory
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardInput = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      let output = String(
        decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      let pid = try #require(Int32(output.trimmingCharacters(in: .whitespacesAndNewlines)))
      guard let start = E2EMode.startTime(pid) else { throw RigError.exitedAtStart(name) }
      let job = Pinned(name: name, pid: pid, start: start)
      detached.append(job)
      return job
    }

    /// `pti_priority`: 4 in Darwin background (spike S3).
    static func priority(_ pid: Int32) -> Int32? { BackgroundPriority.taskPriority(pid) }

    /// `ps`'s decaying CPU average, as Tamebar's scan reads it.
    static func cpu(_ pid: Int32) -> Double {
      Double(ps(["-o", "pcpu=", "-p", "\(pid)"])) ?? 0
    }

    /// Writes ~/.claude/sessions/<pid>.json the way Claude does, with procStart in UTC.
    func claudeSession(_ fake: Fake, status: String, idleDays: Double, sessionID: String) throws {
      try claudeSession(
        pid: fake.pid, start: fake.start, name: fake.name, status: status, idleDays: idleDays,
        sessionID: sessionID)
    }

    func claudeSession(
      pid: Int32, start: Double, name: String, status: String, idleDays: Double,
      sessionID: String
    ) throws {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
      let json: [String: Any] = [
        "pid": Int(pid), "sessionId": sessionID, "cwd": "/tmp",
        "procStart": formatter.string(from: Date(timeIntervalSince1970: start.rounded(.down))),
        "name": name, "status": status,
        "statusUpdatedAt": (Date.now.timeIntervalSince1970 - idleDays * 86_400) * 1_000,
      ]
      try JSONSerialization.data(withJSONObject: json)
        .write(to: home.appendingPathComponent(".claude/sessions/\(pid).json"))
    }

    /// A free port at 3100 or above: nothing holds it on IPv4 or IPv6, and no registry line
    /// claims it.
    func freePort(excluding taken: Set<UInt16> = []) throws -> UInt16 {
      let skipped = AgentProcRegistry.ports(in: AgentProcRegistry.file)
        .union(taken)
      let port = (UInt16(3100)...3199).first { !skipped.contains($0) && Self.bindable($0) }
      return try #require(port, "no free port in 3100...3199")
    }

    private static func bindable(_ port: UInt16) -> Bool {
      func attempt(_ family: Int32, _ bind: (Int32) -> Int32) -> Bool {
        let socket = Darwin.socket(family, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        if family == AF_INET6 {
          var only: Int32 = 1
          setsockopt(socket, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
        }
        return bind(socket) == 0
      }
      func v4(_ address: in_addr_t) -> Bool {
        attempt(AF_INET) { socket in
          var value = sockaddr_in()
          value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
          value.sin_family = sa_family_t(AF_INET)
          value.sin_port = port.bigEndian
          value.sin_addr = in_addr(s_addr: address)
          return withUnsafePointer(to: &value) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
          }
        }
      }
      let v6 = attempt(AF_INET6) { socket in
        var value = sockaddr_in6()
        value.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        value.sin6_family = sa_family_t(AF_INET6)
        value.sin6_port = port.bigEndian
        value.sin6_addr = in6addr_any
        return withUnsafePointer(to: &value) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
          }
        }
      }
      return v4(INADDR_LOOPBACK.bigEndian) && v4(INADDR_ANY) && v6
    }

    /// Adds the server to `~/.claude/agent-procs.jsonl`; `cleanup()` removes the line once the
    /// pinned pid is gone.
    func register(_ server: Pinned, port: UInt16) throws {
      try AgentProcRegistry.append(
        .init(pid: server.pid, port: port, purpose: "Tamebar e2e \(server.name)"),
        to: AgentProcRegistry.file)
      registered.append(server)
    }

    /// Pinned targets: pid plus its start time, for every fake still running and detached job.
    /// Fails, so the app never launches, unless each is still the process that was started. A
    /// fake that has exited (Tamebar ended it, scenarios 10 and 13) is left out.
    func targets() throws {
      let started =
        fakes.filter(\.process.isRunning).map { ($0.name, $0.pid, $0.start) }
        + detached.map { ($0.name, $0.pid, $0.start) }
        + appTargets.filter { Self.same($0.pid, $0.start) }.map { ($0.name, $0.pid, $0.start) }
        + agentTargets.filter { Self.same($0.pid, $0.start) }.map { ($0.name, $0.pid, $0.start) }
      let pinned: [[String: Any]] = try started.map { name, pid, expected in
        let identity = try #require(DevProcessIdentity.read(pid), "can't read \(name)")
        let start =
          Double(identity.process.startSeconds) + Double(identity.process.startMicroseconds) / 1e6
        try #require(abs(start - expected) < 0.001, "\(name) changed")
        return ["pid": Int(pid), "start": start]
      }
      try JSONSerialization.data(withJSONObject: pinned)
        .write(to: dir.appendingPathComponent("targets.json"), options: .atomic)
    }

    func control(_ value: [String: Any]) throws {
      try JSONSerialization.data(withJSONObject: controlBase.merging(value) { $1 })
        .write(to: dir.appendingPathComponent("control.json"), options: .atomic)
    }

    /// A tiny AppKit app in `dir`, compiled with `swiftc`: no Dock icon (LSUIElement), quits on a
    /// normal quit request, and holds `megabytes` it has touched when started with that argument.
    /// A second argument spins that many threads; a third, `regular`, makes it a regular app (a
    /// Dock icon, never activated). Its bundle id is unique, so nothing else on this Mac shares
    /// it. Returns the bundle.
    func buildFakeApp(name: String, bundleID: String) throws -> URL {
      let bundle = dir.appendingPathComponent("apps/\(name).app")
      let macOS = bundle.appendingPathComponent("Contents/MacOS")
      try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
      let source = dir.appendingPathComponent("apps/\(name).swift")
      try Data(
        """
        import AppKit
        let arguments = Array(CommandLine.arguments.dropFirst())
        let megabytes = Int(arguments.first ?? "") ?? 0
        let ballast = [UInt8](repeating: 1, count: megabytes * 1_048_576)
        for _ in 0..<(arguments.count > 1 ? Int(arguments[1]) ?? 0 : 0) {
          Thread.detachNewThread {
            var spin: UInt64 = 0
            while true { spin &+= 1 }
          }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(arguments.count > 2 && arguments[2] == "regular" ? .regular : .accessory)
        withExtendedLifetime(ballast) { app.run() }
        """.utf8
      ).write(to: source)
      let plist: [String: Any] = [
        "CFBundleIdentifier": bundleID, "CFBundleExecutable": name, "CFBundleName": name,
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0", "LSUIElement": true,
      ]
      try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
      let executable = macOS.appendingPathComponent(name).path
      try Self.run("/usr/bin/xcrun", ["swiftc", "-O", source.path, "-o", executable])
      try Self.run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
      fakeApps.append(Self.real(executable))
      return bundle
    }

    /// The path with every link resolved (`realpath`), as `proc_pidpath` reports it: the temporary
    /// folder is `/var/…`, a link to `/private/var/…`.
    static func real(_ path: String) -> String {
      guard let resolved = realpath(path, nil) else { return path }
      defer { free(resolved) }
      return String(cString: resolved)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: tool)
      process.arguments = arguments
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      try #require(process.terminationStatus == 0, "\(tool) \(arguments) failed")
    }

    /// Runs a tool whose failure is not an issue, and returns its exit status.
    @discardableResult
    private static func status(_ tool: String, _ arguments: [String]) -> Int32 {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: tool)
      process.arguments = arguments
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      guard (try? process.run()) != nil else { return -1 }
      process.waitUntilExit()
      return process.terminationStatus
    }

    /// Starts a fake app's executable as this runner's child, pinned and declared a target.
    @discardableResult
    func launchFakeApp(_ bundle: URL, megabytes: Int) throws -> Pinned {
      let name = bundle.deletingPathExtension().lastPathComponent
      let process = Process()
      process.executableURL = bundle.appendingPathComponent("Contents/MacOS/\(name)")
      process.arguments = [String(megabytes)]
      process.standardInput = FileHandle.nullDevice
      try process.run()
      guard let start = E2EMode.startTime(process.processIdentifier) else {
        throw RigError.exitedAtStart(name)
      }
      let pinned = Pinned(name: name, pid: process.processIdentifier, start: start)
      appTargets.append(pinned)
      appInstances.append(pinned)
      return pinned
    }

    /// The live instances of a fake app, found by their executable path inside `dir`, each
    /// pinned for cleanup.
    func fakeAppInstances(_ bundle: URL) -> [Pinned] {
      let name = bundle.deletingPathExtension().lastPathComponent
      let executable = Self.real(bundle.appendingPathComponent("Contents/MacOS/\(name)").path)
      return LiveProcessTree.read().parents.keys.sorted().compactMap { pid in
        guard Self.path(pid).map(Self.real) == executable, let start = E2EMode.startTime(pid)
        else { return nil }
        let pinned = Pinned(name: name, pid: pid, start: start)
        if !appInstances.contains(where: { $0.pid == pid && $0.start == start }) {
          appInstances.append(pinned)
        }
        return pinned
      }
    }

    /// Written as a dotfile then renamed, so the app never reads half a command (it skips dotfiles).
    func command(_ text: String) throws {
      let name = "\(Date.now.timeIntervalSince1970).cmd"
      let folder = dir.appendingPathComponent("commands")
      let temporary = folder.appendingPathComponent(".\(name).tmp")
      try Data(text.utf8).write(to: temporary)
      try FileManager.default.moveItem(at: temporary, to: folder.appendingPathComponent(name))
    }

    /// Starts the e2e build as this runner's child, only when the bundle is the e2e build: a live
    /// Tamebar never launches from here. `--background` opens no window. `autoPause` opts these
    /// project directories in to automatic pause, and `autoEnd` sets "Unused AI sessions", in the
    /// launched app's argument domain only: nothing is written to any defaults domain. A second
    /// launch, once the first app has exited, starts from a fresh state file.
    func launch(
      _ appPath: String, autoPause: [String] = [], quitApps: [String] = [],
      autoEnd: AutoEndSettings? = nil
    ) throws {
      let bundle = URL(fileURLWithPath: appPath)
      let identifier = Bundle(url: bundle)?.bundleIdentifier
      try #require(
        identifier == EndToEndTests.bundleID,
        "\(appPath) is \(identifier ?? "not a bundle"), not the e2e build")
      let process = Process()
      process.executableURL = bundle.appendingPathComponent("Contents/MacOS/Tamebar")
      // First: `--background` takes no value, so the argument domain must not read past it.
      func argument(_ key: String, _ values: [String]) -> [String] {
        values.isEmpty
          ? [] : ["-\(key)", "(" + values.map { "\"\($0)\"" }.joined(separator: ", ") + ")"]
      }
      // A plist data literal, which the argument domain reads as the JSON the app saves.
      let settings = try autoEnd.map { settings -> [String] in
        let json = try JSONEncoder().encode(settings)
        return [
          "-\(AutoEndSettings.key)", "<" + json.map { String(format: "%02x", $0) }.joined() + ">",
        ]
      }
      // Q18 and Q20 are off on a new install (P2); the scenarios switch them on.
      let optIn =
        argument(ProjectPausePolicy.key, autoPause) + argument(AppQuitList.key, quitApps)
        + (settings ?? []) + ["-\(AutomaticSafety.Key.endIdleSessions)", "YES"]
      process.arguments = optIn + ["--e2e", dir.path, "--background"]
      try? FileManager.default.removeItem(at: dir.appendingPathComponent("state.json"))
      process.environment = ProcessInfo.processInfo.environment.merging(["TAMEBAR_E2E": "1"]) {
        $1
      }
      let log = dir.appendingPathComponent("app.log")
      FileManager.default.createFile(atPath: log.path, contents: nil)
      let output = try FileHandle(forWritingTo: log)
      process.standardOutput = output
      process.standardError = output
      process.standardInput = FileHandle.nullDevice
      try process.run()
      guard let start = E2EMode.startTime(process.processIdentifier) else {
        throw RigError.exitedAtStart("the app")
      }
      app = (process, start)
    }

    func state() -> [String: Any] {
      (try? Data(contentsOf: dir.appendingPathComponent("state.json")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    static func project(_ directory: String, in state: [String: Any]) -> [String: Any]? {
      (state["projects"] as? [[String: Any]])?.first { $0["directory"] as? String == directory }
    }

    static func thread(_ fake: Fake, in state: [String: Any]) -> [String: Any]? {
      (state["threads"] as? [[String: Any]])?.first {
        ($0["pid"] as? Int).map(Int32.init) == fake.pid
      }
    }

    /// Checks `condition` every 0.5 s until it holds, or throws after `timeout`.
    func poll(_ label: String, timeout: TimeInterval = 60, _ condition: () -> Bool) async throws {
      let deadline = Date.now.addingTimeInterval(timeout)
      while Date.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(500))
      }
      throw RigError.timedOut(label, state: "\(state())")
    }

    /// Polls state.json (1 s app tick), reading it once per poll, until `condition` holds.
    func until(
      _ label: String, timeout: TimeInterval = 60, _ condition: ([String: Any]) -> Bool
    ) async throws {
      try await poll(label, timeout: timeout) { condition(state()) }
    }

    static func stopped(_ pid: Int32) -> Bool {
      RecoveryProcess.read(pid)?.stopped == true
    }

    /// The fake's live descendants that are stopped.
    func stoppedDescendants(of fake: Fake) -> [Int32] {
      LiveProcessTree.read().descendants([fake.pid]).filter { $0 != fake.pid && Self.stopped($0) }
    }

    // MARK: Cleanup

    /// Ends the app, the fakes with their descendants and the pinned servers, drops the registry
    /// lines of servers confirmed gone, then the folder. Safe to call twice; the test calls it
    /// from `defer`, `deinit` is the backstop.
    func cleanup() {
      guard !cleaned else { return }
      cleaned = true
      stopApp()
      for fake in fakes { end(fake) }
      for server in servers { end(server) }
      for job in detached { end(job) }
      for stray in pinnedDescendants { end(stray) }
      // Unregistered first, so LaunchServices can't start the fake apps again. Then, for a full
      // 2 s, every instance is killed by its pinned identity, the rig's own and any Tamebar
      // reopened (no child of ours: found by its path in `dir`): a reopen already on its way
      // (the app's quit path hands apps to `open`) may land late.
      for executable in fakeApps {
        let bundle = URL(fileURLWithPath: executable).deletingLastPathComponent()
          .deletingLastPathComponent().deletingLastPathComponent()
        // -10814 (not registered at this path) is fine: no instance may run, checked below.
        Self.status(
          "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
          ["-u", bundle.path])
      }
      for app in appInstances { end(app) }
      let deadline = Date.now.addingTimeInterval(2)
      repeat {
        for app in liveFakeApps() { end(app) }
        usleep(100_000)
      } while Date.now < deadline
      let left = liveFakeApps()
      if !left.isEmpty { Issue.record("fake apps still run after cleanup: \(left)") }
      for server in registered {
        guard !Self.same(server.pid, server.start) else {
          Issue.record("\(server.name) (pid \(server.pid)) still runs; its registry line stays")
          continue
        }
        do { try AgentProcRegistry.remove(pid: server.pid, from: AgentProcRegistry.file) } catch {
          Issue.record("registry line for \(server.pid) left behind: \(error)")
        }
      }
      keepLogs()
      let base = FileManager.default.temporaryDirectory.path
      if dir.path.hasPrefix(base.hasSuffix("/") ? base : base + "/"),
        dir.lastPathComponent.hasPrefix("tamebar-e2e-")
      {
        try? FileManager.default.removeItem(at: dir)
      }
    }

    deinit { cleanup() }

    /// With `TAMEBAR_E2E_KEEP` set to a folder, the run's app log and its last state, control and
    /// targets files are copied to `<folder>/<run folder>/` before the run folder goes.
    private func keepLogs() {
      guard let keep = ProcessInfo.processInfo.environment["TAMEBAR_E2E_KEEP"], keep.hasPrefix("/")
      else { return }
      let destination = URL(fileURLWithPath: keep, isDirectory: true)
        .appendingPathComponent(dir.lastPathComponent, isDirectory: true)
      try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      for name in ["app.log", "state.json", "control.json", "targets.json"] {
        try? FileManager.default.copyItem(
          at: dir.appendingPathComponent(name), to: destination.appendingPathComponent(name))
      }
    }

    /// Every live instance of a fake app the rig built, by its real executable path, pinned.
    private func liveFakeApps() -> [Pinned] {
      LiveProcessTree.read().parents.keys.sorted().compactMap { pid -> Pinned? in
        guard let path = Self.path(pid).map(Self.real), fakeApps.contains(path),
          let start = E2EMode.startTime(pid)
        else { return nil }
        return Pinned(name: URL(fileURLWithPath: path).lastPathComponent, pid: pid, start: start)
      }
    }

    /// The live process at `pid` is still the one that started at `start`.
    static func same(_ pid: Int32, _ start: Double) -> Bool {
      E2EMode.startTime(pid).map { abs($0 - start) < 0.001 } ?? false
    }

    private static func wait(seconds: TimeInterval, while running: () -> Bool) {
      let deadline = Date.now.addingTimeInterval(seconds)
      while running(), Date.now < deadline { usleep(50_000) }
    }

    /// SIGTERM to the app, only while its pid is still the app we launched. Returns it once it
    /// exited within `seconds`, nil if it still runs (then `cleanup()` ends it).
    func terminateApp(within seconds: TimeInterval) -> Process? {
      guard let (process, start) = app else { return nil }
      if process.isRunning, Self.same(process.processIdentifier, start) { process.terminate() }
      Self.wait(seconds: seconds) { process.isRunning }
      return process.isRunning ? nil : process
    }

    /// SIGTERM, up to 5 s, then SIGKILL, each only while the pid is still the app we launched.
    private func stopApp() {
      guard let (process, start) = app else { return }
      let pid = process.processIdentifier
      if process.isRunning, Self.same(pid, start) { process.terminate() }
      Self.wait(seconds: 5) { process.isRunning }
      if process.isRunning, Self.same(pid, start) { kill(pid, SIGKILL) }
      Self.wait(seconds: 2) { process.isRunning }
    }

    /// Descendants aren't pinned: they come from one live snapshot, deepest first (reversed
    /// breadth-first order), and each is signalled only after a live walk of its parent chain
    /// still reaches the fake. Then the fake itself, only while its start time still matches.
    private func end(_ fake: Fake) {
      guard Self.same(fake.pid, fake.start) else { return }
      for pid in LiveProcessTree.read().descendants([fake.pid]).reversed()
      where pid != fake.pid && Self.descends(pid, from: fake) {
        kill(pid, SIGCONT)
        kill(pid, SIGKILL)
      }
      if Self.same(fake.pid, fake.start) {
        kill(fake.pid, SIGCONT)
        kill(fake.pid, SIGKILL)
      }
      Self.wait(seconds: 2) { fake.process.isRunning }
    }

    /// A pinned server, even when its fake is already gone: only while its start time matches.
    private func end(_ server: Pinned) {
      if Self.same(server.pid, server.start) {
        kill(server.pid, SIGCONT)
        kill(server.pid, SIGKILL)
      }
      Self.wait(seconds: 2) { Self.same(server.pid, server.start) }
    }

    private static func descends(_ pid: Int32, from fake: Fake) -> Bool {
      var current = pid
      var visited: Set<Int32> = []
      while current > 1, visited.insert(current).inserted, let parent = parent(current) {
        if parent == fake.pid { return same(fake.pid, fake.start) }
        current = parent
      }
      return false
    }

    private static func parent(_ pid: Int32) -> Int32? {
      var info = proc_bsdinfo()
      let size = MemoryLayout<proc_bsdinfo>.size
      let read = withUnsafeMutablePointer(to: &info) {
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(size))
      }
      guard read == size, info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(),
        info.pbi_status != SZOMB
      else { return nil }
      return Int32(info.pbi_ppid)
    }
  }

  /// Q17.1: a regular app busy in the background (three spinning threads, about 300 % CPU) is
  /// slowed once it has been busy for two minutes, with one note, and restored as soon as it
  /// comes to the front (the control stands in for the front app and the mic and camera).
  ///
  /// Skipped (2026-10-29), left to fix in the harness: the e2e build sees the fake (app row at
  /// about 290 %, not in front, mic free) and its two-minute clock runs past 120 s, but nothing
  /// lands in the ledger, so `BackgroundPriorityController.slow` refuses the process. The likely
  /// cause: macOS App Naps a windowless app in the background and moves it to Darwin background
  /// on and off (a probe of the same fake read `pri` 4 between 46s), and Tamebar never takes a
  /// process already in background (it is someone else's). Next step: have the fake hold
  /// `ProcessInfo.beginActivity(options: .userInitiated, …)` so it never naps, then re-enable.
  /// The planner and the ledger are covered by `AppSlowTests` and `BackgroundPriorityTests.Apps`.
  @Test(
    .disabled("the windowless fake app is App Napped; see the comment"),
    .enabled(if: EndToEndTests.appPath != nil, "needs TAMEBAR_E2E_APP (scripts/e2e.sh)"))
  func busyBackgroundApp() async throws {
    let appPath = try #require(Self.appPath)
    let rig = try Rig()
    defer { rig.cleanup() }
    let busyID = "com.tamebar.e2e.fakeapp.busy.\(UUID().uuidString.lowercased())"
    let busyApp = try rig.buildFakeApp(name: "FakeBusy", bundleID: busyID)
    // Detached, so launchd is its parent: as the runner's child it would sit in the tree of
    // the agent session running the tests, an AI session, whose processes no app row holds.
    let busy = try rig.detach(
      "FakeBusy", executable: busyApp.appendingPathComponent("Contents/MacOS/FakeBusy").path,
      arguments: ["0", "3", "regular"])
    try rig.targets()
    rig.controlBase = ["frontmost": "", "micCameraFree": [busyID]]
    try rig.control(["pressure": MemoryRisk.normal.rawValue])
    try await rig.poll("the fake app busy", timeout: 30) { Rig.cpu(busy.pid) >= 150 }
    let busySince = Date.now
    try rig.launch(appPath)
    var notes: Set<String> = []
    func slowedApps(_ state: [String: Any]) -> [String] { state["slowedApps"] as? [String] ?? [] }
    func watch(_ state: [String: Any]) {
      if let note = state["note"] as? String { notes.insert(note) }
    }
    try await rig.until("the busy app slowed", timeout: 240) { state in
      watch(state)
      return slowedApps(state) == [busyID] && Rig.priority(busy.pid) == 4
    }
    #expect(
      Date.now.timeIntervalSince(busySince) >= AppSlow.sustain,
      "slowed before two minutes busy")
    #expect(
      notes.contains { $0.hasPrefix("Slowed FakeBusy · ") && $0.hasSuffix("% CPU") },
      "notes seen: \(notes)")
    // In front: restored at once.
    let front = Date.now
    try rig.control(["frontmost": busyID, "pressure": MemoryRisk.normal.rawValue])
    try await rig.until("restored in front", timeout: 30) { state in
      slowedApps(state).isEmpty && Rig.priority(busy.pid) != 4
    }
    #expect(Date.now.timeIntervalSince(front) < 20, "not restored at once in front")
    #expect(Rig.same(busy.pid, busy.start), "the busy app was quit or replaced")
  }

  /// Q19: while the Mac struggles (forced), a fresh session's start hook, `tamebar wait` run by a
  /// fake `claude`, blocks and prints nothing; a resume never waits. `tamebar start <project>`
  /// and the card's Start now each release theirs at once; `tamebar start` with no match exits 1.
  /// Once the strain clears, the rest start oldest first, a minute apart.
  @Test(.enabled(if: EndToEndTests.appPath != nil, "needs TAMEBAR_E2E_APP (scripts/e2e.sh)"))
  func newSessionsWaitWhileTheMacStruggles() async throws {
    let appPath = try #require(Self.appPath)
    let tamebar = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/MacOS/Tamebar")
    let rig = try Rig()
    defer { rig.cleanup() }
    try rig.targets()
    try rig.control(["pressure": MemoryRisk.normal.rawValue, "strain": true])
    try rig.launch(appPath)
    try await rig.until("struggling", timeout: 60) { $0["strain"] as? Bool == true }
    // N12: the strain is what the menu bar and the notch show as pressure, memory normal or not.
    try await rig.until("the strain shows as pressure", timeout: 10) {
      $0["island"] as? String == "pressure"
    }

    /// A fake `claude` running the hook: `tamebar wait` with its JSON on stdin, its output kept.
    func hook(_ project: String, source: String = "startup") throws -> (Fake, URL) {
      let input = rig.dir.appendingPathComponent("\(project).json")
      let output = rig.dir.appendingPathComponent("\(project).out")
      try Data(
        #"{"hook_event_name":"SessionStart","source":"\#(source)","session_id":"\#(project)","cwd":"/tmp/e2e/\#(project)","transcript_path":"/tmp/e2e/.claude/projects/x/\#(project).jsonl"}"#
          .utf8
      ).write(to: input)
      // `; :` keeps the shell, the fake agent, as the hook's parent.
      let fake = try rig.spawn(
        "hook-\(project)", tool: "claude",
        script: "'\(tamebar.path)' wait < '\(input.path)' > '\(output.path)' 2>&1; :")
      return (fake, output)
    }
    func command(_ arguments: [String]) throws -> (Int32, String) {
      let process = Process()
      process.executableURL = tamebar
      process.arguments = arguments
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = pipe
      process.standardInput = FileHandle.nullDevice
      try process.run()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // A resume never waits, struggling or not.
    let (resumed, _) = try hook("q19resume", source: "resume")
    try await rig.poll("the resume went on", timeout: 10) { !resumed.process.isRunning }

    var hooks: [String: (fake: Fake, output: URL)] = [:]
    for project in ["q19a", "q19b", "q19c", "q19d"] {
      hooks[project] = try hook(project)
      try await Task.sleep(for: .milliseconds(1_200))
    }
    try await rig.until("four waiting, oldest first", timeout: 30) {
      $0["waiting"] as? [String] == ["q19a", "q19b", "q19c", "q19d"]
    }
    try await Task.sleep(for: .seconds(4))
    for (project, hook) in hooks {
      #expect(hook.fake.process.isRunning, "\(project) went on while the Mac struggles")
    }

    let (code, out) = try command(["start", "q19b"])
    #expect(code == 0)
    #expect(out.hasPrefix("Started q19b · Claude (waited "), "\(out)")
    let b = try #require(hooks["q19b"])
    try await rig.poll("tamebar start released q19b", timeout: 5) { !b.fake.process.isRunning }
    #expect(try command(["start", "nope"]).0 == 1)

    try rig.command("startNow:q19c")
    let c = try #require(hooks["q19c"])
    try await rig.poll("Start now released q19c", timeout: 5) { !c.fake.process.isRunning }
    let a = try #require(hooks["q19a"])
    let d = try #require(hooks["q19d"])
    #expect(a.fake.process.isRunning && d.fake.process.isRunning, "only those two started")

    try rig.control(["pressure": MemoryRisk.normal.rawValue, "strain": false])
    try await rig.poll("the oldest starts once it eases", timeout: 15) { !a.fake.process.isRunning }
    let first = Date.now
    #expect(d.fake.process.isRunning, "the next waits a minute")
    try await rig.poll("the next one a minute later", timeout: 90) { !d.fake.process.isRunning }
    let spacing = Date.now.timeIntervalSince(first)
    #expect(spacing >= StartWait.releaseSpacing - 5, "released \(spacing) s apart")
    try await rig.until("nothing waits", timeout: 10) { ($0["waiting"] as? [String]) == [] }
    #expect(rig.state()["island"] as? String != "pressure", "the strain eased: no pressure")
    for (project, hook) in hooks {
      let printed = (try? Data(contentsOf: hook.output)) ?? Data()
      #expect(printed.isEmpty, "\(project) printed \(String(decoding: printed, as: UTF8.self))")
    }
  }

  /// Q19, which removed Q14's work queue: busy sessions under memory pressure are never paused,
  /// at warning (held well past the old queue's 6 s and 30 s) nor at critical, whatever their
  /// parent, and nothing reads queued.
  @Test(.enabled(if: EndToEndTests.appPath != nil, "needs TAMEBAR_E2E_APP (scripts/e2e.sh)"))
  func busySessionsUnderMemoryPressureAreNeverPaused() async throws {
    let appPath = try #require(Self.appPath)
    let rig = try Rig()
    defer { rig.cleanup() }
    var busy: [Fake] = []
    for index in 1...3 {
      let fake = try rig.spawn("b\(index)-claude", tool: "claude", script: "sleep 3600; :")
      try rig.claudeSession(
        fake, status: "busy", idleDays: 0,
        sessionID: "00000000-0000-4000-8000-00000000010\(index)")
      busy.append(fake)
    }
    let (shell, shellAgent) = try await rig.spawnUnderInteractiveShell(
      "shell-claude", script: "sleep 3600; :")
    try rig.claudeSession(
      pid: shellAgent.pid, start: shellAgent.start, name: shellAgent.name, status: "busy",
      idleDays: 0, sessionID: "00000000-0000-4000-8000-000000000104")
    try rig.targets()
    try rig.control(["pressure": MemoryRisk.normal.rawValue, "away": false])
    try rig.launch(appPath)
    let pids = busy.map(\.pid) + [shellAgent.pid]
    func thread(_ pid: Int32, _ state: [String: Any]) -> [String: Any]? {
      (state["threads"] as? [[String: Any]])?.first { ($0["pid"] as? Int).map(Int32.init) == pid }
    }
    try await rig.until("the four seen busy", timeout: 60) { state in
      pids.allSatisfy { thread($0, state)?["status"] as? String == "busy" }
    }
    var notes: [String] = []
    var held: [String] = []
    func watch(_ state: [String: Any]) {
      if let note = state["note"] as? String, notes.last != note { notes.append(note) }
      for pid in pids where Rig.stopped(pid) || thread(pid, state)?["pausedBy"] != nil {
        held.append("\(pid)")
      }
    }

    for (risk, seconds) in [(MemoryRisk.warning, 50.0), (.critical, 20.0)] {
      try rig.control(["pressure": risk.rawValue, "away": false])
      try await rig.until("risk \(risk) seen", timeout: 30) { state in
        watch(state)
        return state["risk"] as? Int ?? 0 == risk.rawValue
      }
      let since = Date.now
      try await rig.until("\(Int(seconds)) s of \(risk)", timeout: seconds + 30) { state in
        watch(state)
        return Date.now.timeIntervalSince(since) >= seconds
      }
    }
    try rig.control(["pressure": MemoryRisk.normal.rawValue, "away": false])
    try await rig.until("the calm seen", timeout: 30) { state in
      watch(state)
      return state["risk"] as? Int ?? 0 < MemoryRisk.warning.rawValue
    }
    #expect(held.isEmpty, "busy sessions held under memory pressure: \(Set(held).sorted())")
    #expect(!notes.contains { $0.contains("Queued") }, "a queue note: \(notes)")
    for fake in busy {
      #expect(Rig.same(fake.pid, fake.start), "\(fake.name) is gone or replaced")
      #expect(!Rig.stopped(fake.pid), "\(fake.name) is stopped")
    }
    #expect(Rig.same(shellAgent.pid, shellAgent.start), "the shell's agent is gone")
    #expect(!Rig.stopped(shellAgent.pid) && !Rig.stopped(shell.pid), "the shell's tree stopped")
  }

  @Test(.enabled(if: EndToEndTests.appPath != nil, "needs TAMEBAR_E2E_APP (scripts/e2e.sh)"))
  func fullLifecycle() async throws {
    let appPath = try #require(Self.appPath)
    let rig = try Rig()
    defer { rig.cleanup() }
    let port = try rig.freePort()
    // Idle's only child is its "MCP server" (a `sleep`): scenario 10 can end it automatically,
    // which a background job would forbid, and Quit must still reach that child once idle exits.
    let idle = try rig.spawn(
      "idle-claude", tool: "claude", script: "'\(rig.mcpServer)' 3600; :")
    // Once the test creates `heavy` (scenario 5), busy starts two heavy children: a shell loop
    // that keeps forking short `sleep`s, which inherit its priority, and a `yes` that is the
    // parent of a python server on a second port.
    let heavy = rig.dir.appendingPathComponent("heavy").path
    let port2 = try rig.freePort(excluding: [port])
    let loop =
      "while :; do i=0; while [ $i -lt 300000 ]; do i=$((i+1)); done; sleep 2 & done"
    let serve =
      "python3 -m http.server \(port2) --bind 127.0.0.1 --directory \"\(rig.dir.path)/www\""
      + " >/dev/null 2>&1 & exec /usr/bin/yes >/dev/null"
    let busy = try rig.spawn(
      "busy-claude", tool: "claude",
      script:
        "sleep 3600 & s=$!; until [ -e '\(heavy)' ]; do sleep 1; done;"
        + " /bin/sh -c '\(loop)' >/dev/null 2>&1 & /bin/sh -c '\(serve)' & wait $s; :")
    let kept = try rig.spawn("kept-claude", tool: "claude", script: "sleep 3600; :")
    let serving = try rig.spawn(
      "serving-claude", tool: "claude",
      script:
        "python3 -m http.server \(port) --bind 127.0.0.1 --directory '\(rig.dir.path)/www'"
        + " >/dev/null 2>&1; :")
    let server = try await rig.pinServer(of: serving)
    try rig.register(server, port: port)
    try rig.claudeSession(
      idle, status: "idle", idleDays: 8, sessionID: "00000000-0000-4000-8000-000000000001")
    try rig.claudeSession(
      busy, status: "busy", idleDays: 0, sessionID: "00000000-0000-4000-8000-000000000002")
    try rig.claudeSession(
      kept, status: "idle", idleDays: 9, sessionID: "00000000-0000-4000-8000-000000000003")
    try rig.claudeSession(
      serving, status: "idle", idleDays: 9, sessionID: "00000000-0000-4000-8000-000000000004")
    try rig.targets()
    // The dev-server project of scenario 6, opted in to automatic pause from launch. Its server
    // starts in scenario 6, so scenarios 1–3 never see it.
    let webFolder = rig.dir.appendingPathComponent("web")
    try FileManager.default.createDirectory(at: webFolder, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: webFolder.appendingPathComponent("package.json"))
    let webDirectory = WorkspacePreferences.canonical(webFolder.path)
    // Scenario 7's fake apps, each with a bundle id no other app shares. Only the listed one is
    // opted in to Q11, in the launched app's argument domain. The control says neither holds the
    // mic or camera and nothing is in front, in place of the probes.
    let suffix = UUID().uuidString.lowercased()
    let listedID = "com.tamebar.e2e.fakeapp.\(suffix)"
    let unlistedID = "com.tamebar.e2e.fakeapp.unlisted.\(suffix)"
    let listedApp = try rig.buildFakeApp(name: "FakeListed", bundleID: listedID)
    let unlistedApp = try rig.buildFakeApp(name: "FakeUnlisted", bundleID: unlistedID)
    rig.controlBase = ["frontmost": "", "micCameraFree": [listedID, unlistedID]]
    // Normal pressure is forced from the start, so a real warning on this Mac can't pause anything
    // before scenario 2 asks for it.
    try rig.control(["pressure": MemoryRisk.normal.rawValue])
    try rig.launch(appPath, autoPause: [webDirectory], quitApps: [listedID])

    // Scenario 1: detection; nothing touched while OK.
    try await rig.until("4 fakes seen") { ($0["threads"] as? [Any])?.count == 4 }
    try rig.command("keep:\(kept.pid)")
    try await rig.until("unused and protections") { state in
      Rig.thread(idle, in: state)?["unused"] as? String == "idle"
        && Rig.thread(busy, in: state)?["protection"] as? String == "busy"
        && Rig.thread(kept, in: state)?["protection"] as? String == "kept"
        && Rig.thread(serving, in: state)?["protection"] as? String == "serving"
    }
    for fake in [idle, busy, kept, serving] {
      #expect(Rig.same(fake.pid, fake.start), "\(fake.name) is gone or replaced")
      #expect(!Rig.stopped(fake.pid), "\(fake.name) is stopped")
      let stopped = rig.stoppedDescendants(of: fake)
      #expect(stopped.isEmpty, "\(fake.name) has stopped descendants \(stopped)")
    }
    #expect(Rig.same(server.pid, server.start), "\(server.name) is gone or replaced")

    // Scenario 2: sustained memory pressure pauses no session (Q18: pausing an idle session frees
    // nothing; long-idle ones are ended after 2 minutes instead, scenario 13). For 20 s under the
    // warning, past the 6 s a pause would have needed, nothing is a candidate and idle runs on.
    // Scenario 3 (idle resumed after 30 calm seconds) went with the pressure pause.
    var seen: Set<String> = []
    var idleStopped = false
    func watch(_ state: [String: Any]) {
      seen.formUnion(state["candidates"] as? [String] ?? [])
      if Rig.stopped(idle.pid) || Rig.thread(idle, in: state)?["pausedBy"] != nil {
        idleStopped = true
      }
    }
    try rig.control(["pressure": MemoryRisk.warning.rawValue])
    try await rig.until("the warning seen", timeout: 30) { state in
      watch(state)
      return state["risk"] as? Int ?? 0 >= MemoryRisk.warning.rawValue
    }
    let holdPressure = Date.now.addingTimeInterval(20)
    try await rig.until("20 s of pressure", timeout: 30) { state in
      watch(state)
      return Date.now >= holdPressure
    }
    #expect(seen.isEmpty, "candidates seen under pressure: \(seen)")
    #expect(!idleStopped, "idle was paused under memory pressure")
    #expect(Rig.same(idle.pid, idle.start), "idle is gone or replaced")
    untouched([idle, busy, kept, serving], server: server, rig: rig)
    try rig.control(["pressure": MemoryRisk.normal.rawValue])
    // Seen calm, so scenario 6's pressure starts its own clocks (and Q18's 2 minutes) afresh.
    try await rig.until("back to normal", timeout: 30) { state in
      state["risk"] as? Int ?? MemoryRisk.warning.rawValue < MemoryRisk.warning.rawValue
    }
    let gap = try #require(rig.state()["maxTickGap"] as? Double)
    #expect(gap < 60, "a tick gap of \(gap) s")

    // Scenario 6: an opted-in dev-server project pauses under sustained memory pressure, and
    // resumes after 30 calm seconds (D6.4); idle, beside it, is never paused for memory (Q18).
    // The server is a pinned `ruby`, a target of its own, in a folder with a manifest.
    // Scenario 7 runs in the same pressure: once web is paused, the listed fake app is quit 30 s
    // later, with its note, and reopened after 30 calm seconds (Q11). The unlisted one, larger,
    // is never quit. The pressure lasts well under Q18's 2 minutes, so idle isn't ended either.
    let web = try rig.detach(
      "web-ruby", executable: "/usr/bin/ruby", arguments: ["-e", "sleep"], directory: webFolder)
    let listed = try rig.launchFakeApp(listedApp, megabytes: 24)
    let unlisted = try rig.launchFakeApp(unlistedApp, megabytes: 96)
    try rig.targets()
    try await rig.until("web seen as a running project", timeout: 30) { state in
      Rig.project(webDirectory, in: state)?["paused"] as? Bool == false
    }
    var pausedAt: [String: Date] = [:]
    var notes: [String] = []
    func watchPauses(_ state: [String: Any]) {
      if Rig.thread(idle, in: state)?["pausedBy"] != nil, pausedAt["idle"] == nil {
        pausedAt["idle"] = .now
      }
      if Rig.project(webDirectory, in: state)?["pausedBy"] != nil, pausedAt["web"] == nil {
        pausedAt["web"] = .now
      }
      if let note = state["note"] as? String, notes.last != note { notes.append(note) }
    }
    let webPressure = Date.now
    try rig.control(["pressure": MemoryRisk.warning.rawValue])
    try await rig.until("web paused under pressure", timeout: 75) { state in
      watchPauses(state)
      return Rig.stopped(web.pid)
        && Rig.project(webDirectory, in: state)?["pausedBy"] as? String == "pressure"
        && Rig.project(webDirectory, in: state)?["paused"] as? Bool == true
    }
    #expect(Date.now.timeIntervalSince(webPressure) >= 6, "paused before 6 s of pressure")
    // The note follows once the pause has landed.
    try await rig.until("web's note", timeout: 10) { state in
      watchPauses(state)
      return notes.contains {
        $0.hasPrefix("Paused web · ") && $0.hasSuffix(" · resumes when memory recovers")
      }
    }
    let webPaused = try #require(pausedAt["web"])
    func quitApps(_ state: [String: Any]) -> [String] { state["quitApps"] as? [String] ?? [] }
    try await rig.until("the listed fake app quit after the pause", timeout: 60) { state in
      watchPauses(state)
      if !quitApps(state).isEmpty, pausedAt["app"] == nil { pausedAt["app"] = .now }
      return !Rig.same(listed.pid, listed.start) && quitApps(state) == [listedID]
    }
    let appQuit = try #require(pausedAt["app"])
    #expect(
      appQuit.timeIntervalSince(webPaused) >= 28,
      "the app quit \(appQuit.timeIntervalSince(webPaused)) s after the pause")
    #expect(pausedAt["idle"] == nil, "idle was paused under memory pressure")
    try await rig.until("the app's note", timeout: 10) { state in
      watchPauses(state)
      return notes.contains {
        $0.hasPrefix("Quit FakeListed · ") && $0.hasSuffix(" · reopens later")
      }
    }
    #expect(Rig.same(unlisted.pid, unlisted.start), "the unlisted app was quit")
    #expect(rig.fakeAppInstances(listedApp).isEmpty, "the listed app still runs")
    let webCalm = Date.now
    try rig.control(["pressure": MemoryRisk.normal.rawValue])
    try await rig.until("web resumed and the app reopened after calm", timeout: 60) {
      state in
      watchPauses(state)
      // A nil `pausedBy` is left out of the JSON.
      let project = Rig.project(webDirectory, in: state)
      return !Rig.stopped(web.pid) && project != nil && project?["pausedBy"] == nil
        && quitApps(state).isEmpty && !rig.fakeAppInstances(listedApp).isEmpty
    }
    #expect(pausedAt["idle"] == nil, "idle was paused under memory pressure")
    #expect(Rig.same(idle.pid, idle.start), "idle is gone or replaced")
    #expect(Date.now.timeIntervalSince(webCalm) >= 29, "resumed before 30 calm seconds")
    #expect(Rig.same(web.pid, web.start), "web is gone or replaced")
    let reopened = rig.fakeAppInstances(listedApp)
    #expect(reopened.count == 1, "reopened instances: \(reopened)")
    #expect(reopened.allSatisfy { $0.pid != listed.pid }, "the quit instance still runs")
    #expect(Rig.same(unlisted.pid, unlisted.start), "the unlisted app was quit")
    untouched([idle, busy, kept, serving], server: server, rig: rig)

    // Scenario 5: CPU strain alone (memory normal) slows heavy work on its own (Q12) and pauses
    // nothing (Q9): busy's heavy loop and a heavy terminal job get Darwin background priority,
    // never the session itself and nothing on a server's line; the loop's children that inherit
    // it are adopted; all are restored after 30 calm seconds. Idle and web are never paused.
    FileManager.default.createFile(atPath: heavy, contents: nil)
    let looping = try await rig.descendant(of: busy, "loop") {
      Rig.arguments($0).hasPrefix("/bin/sh -c while :")
    }
    let busyServer = try await rig.pinServer(of: busy)
    try rig.register(busyServer, port: port2)
    let parents = LiveProcessTree.read().parents
    let servingYes = try #require(parents[busyServer.pid])
    rig.pin(servingYes, "busy's yes")
    #expect(Rig.path(servingYes) == "/usr/bin/yes", "the server's parent isn't the heavy yes")
    let job = try rig.detach("yes-job", executable: "/usr/bin/yes")
    try rig.targets()
    try await rig.poll("python listening on \(port2)", timeout: 30) { Rig.accepts(port2) }
    try await rig.poll("heavy at 30% CPU or more", timeout: 30) {
      Rig.cpu(looping) >= 30 && Rig.cpu(job.pid) >= 30 && Rig.cpu(servingYes) >= 30
    }
    func slowed(_ state: [String: Any]) -> Set<Int32> {
      Set((state["slowed"] as? [Int] ?? []).map(Int32.init))
    }
    /// Never in background nor recorded: the session root, the server and its heavy parent.
    let spared = [busy.pid, busyServer.pid, servingYes]
    var touched: Set<Int32> = []
    var adopted: Set<Int32> = []
    var slowNotes: Set<String> = []
    let noteBefore = rig.state()["note"] as? String
    /// Pauses seen while only the CPU is strained: there must be none (Q9, 2026-10-20).
    var pausedUnderCPU: Set<String> = []
    var cpuOnly = true
    func watchSlow(_ state: [String: Any]) {
      touched.formUnion(spared.filter { Rig.priority($0) == 4 })
      touched.formUnion(slowed(state).intersection(spared))
      adopted.formUnion(slowed(state).subtracting([looping, job.pid]))
      // The note scenario 6 left stays until the next action; only new ones count.
      if let note = state["note"] as? String, note != noteBefore { slowNotes.insert(note) }
      guard cpuOnly else { return }
      if Rig.stopped(idle.pid) || Rig.thread(idle, in: state)?["pausedBy"] != nil {
        pausedUnderCPU.insert("idle")
      }
      if Rig.stopped(web.pid) || Rig.project(webDirectory, in: state)?["pausedBy"] != nil {
        pausedUnderCPU.insert("web")
      }
    }
    let cpuOn = Date.now
    try rig.control(["pressure": MemoryRisk.normal.rawValue, "cpu": true])
    try await rig.until("heavy work slowed", timeout: 30) { state in
      watchSlow(state)
      return Rig.priority(looping) == 4 && Rig.priority(job.pid) == 4
        && slowed(state).isSuperset(of: [looping, job.pid])
    }
    #expect(Date.now.timeIntervalSince(cpuOn) >= 6, "slowed before 6 s of CPU pressure")
    // The loop's `sleep`s inherit background; Tamebar takes them in.
    try await rig.until("an inheriting child adopted", timeout: 20) { state in
      watchSlow(state)
      return !adopted.isEmpty
    }
    watchSlow(rig.state())
    #expect(slowNotes.contains("Slowed 1 build"), "notes seen: \(slowNotes)")
    #expect(
      !slowNotes.contains(where: { $0.hasPrefix("Paused") }), "paused under CPU: \(slowNotes)")
    for fake in [idle, busy, kept, serving] {
      #expect(Rig.priority(fake.pid) != 4, "\(fake.name) was slowed")
    }
    let cpuCalm = Date.now
    try rig.control(["pressure": MemoryRisk.normal.rawValue])
    try await rig.until("priority restored after calm", timeout: 60) { state in
      watchSlow(state)
      return Rig.priority(looping) != 4 && Rig.priority(job.pid) != 4 && slowed(state).isEmpty
    }
    #expect(Date.now.timeIntervalSince(cpuCalm) >= 29, "restored before 30 calm seconds")
    #expect(pausedUnderCPU.isEmpty, "paused under CPU strain alone: \(pausedUnderCPU)")
    cpuOnly = false
    #expect(touched.isEmpty, "slowed on a server's line or the root: \(touched)")
    let left = LiveProcessTree.read().descendants([looping, job.pid]).filter {
      Rig.priority($0) == 4
    }
    #expect(left.isEmpty, "still in background after the restore: \(left)")
    #expect(Rig.same(job.pid, job.start), "the job is gone or replaced")

    // Scenario 5b: heat (Q13). Serious for 30 s slows the same heavy work, with one note, and
    // pauses nothing here: idle, kept and serving use no CPU, busy is busy, and heat never
    // pauses a project. Back at nominal, everything is restored once 60 cool seconds have held.
    var heatNotes: [String] = []
    var pausedForHeat: Set<String> = []
    let noteBeforeHeat = rig.state()["note"] as? String
    func watchHeat(_ state: [String: Any]) {
      touched.formUnion(spared.filter { Rig.priority($0) == 4 })
      touched.formUnion(slowed(state).intersection(spared))
      if let note = state["note"] as? String, note != noteBeforeHeat, heatNotes.last != note {
        heatNotes.append(note)
      }
      for fake in [idle, busy, kept, serving]
      where Rig.stopped(fake.pid) || Rig.thread(fake, in: state)?["pausedBy"] != nil {
        pausedForHeat.insert(fake.name)
      }
      if Rig.stopped(web.pid) || Rig.project(webDirectory, in: state)?["pausedBy"] != nil {
        pausedForHeat.insert("web")
      }
    }
    let hotOn = Date.now
    try rig.control(["pressure": MemoryRisk.normal.rawValue, "thermal": "serious"])
    do {
      try await rig.until("heavy work slowed for heat", timeout: 60) { state in
        watchHeat(state)
        return state["heat"] as? Bool == true && Rig.priority(looping) == 4
          && Rig.priority(job.pid) == 4 && slowed(state).isSuperset(of: [looping, job.pid])
      }
    } catch {
      // In background yet not slowed by this build: another Tamebar took it, and one already
      // in background is never taken. An installed build without `E2EMode.inOtherRun` does
      // that under the Mac's real CPU strain (2026-10-29).
      let state = rig.state()
      for pid in [looping, job.pid] where Rig.priority(pid) == 4 && !slowed(state).contains(pid) {
        Issue.record(
          "pid \(pid) is in background but not slowed by the e2e build: another Tamebar slowed it")
      }
      throw error
    }
    #expect(Date.now.timeIntervalSince(hotOn) >= 29, "slowed before 30 s of heat")
    try await rig.until("the heat note", timeout: 10) { state in
      watchHeat(state)
      return heatNotes.contains("Mac hot · slowed 1 build")
    }
    let hotOff = Date.now
    try rig.control(["pressure": MemoryRisk.normal.rawValue, "thermal": "nominal"])
    try await rig.until("priority restored once cool", timeout: 90) { state in
      watchHeat(state)
      return state["heat"] as? Bool == false && Rig.priority(looping) != 4
        && Rig.priority(job.pid) != 4 && slowed(state).isEmpty
    }
    #expect(Date.now.timeIntervalSince(hotOff) >= 59, "restored before 60 cool seconds")
    #expect(pausedForHeat.isEmpty, "paused for heat: \(pausedForHeat)")
    #expect(touched.isEmpty, "slowed on a server's line or the root under heat: \(touched)")
    #expect(heatNotes.allSatisfy { $0.hasPrefix("Mac hot · ") }, "notes under heat: \(heatNotes)")
    let leftHot = LiveProcessTree.read().descendants([looping, job.pid]).filter {
      Rig.priority($0) == 4
    }
    #expect(leftHot.isEmpty, "still in background after heat: \(leftHot)")

    // Scenario 8: a call pauses every unused session and opted-in project at once, for the call
    // (M1, Q9): idle and web in the same tick, with no pressure and no 30 s spacing. Heavy work
    // is slowed. Busy, kept and serving are left running, and no app is quit.
    try rig.control(["pressure": MemoryRisk.normal.rawValue, "meeting": true])
    var firstMeetingPause: (idle: Bool, web: Bool)?
    try await rig.until("idle and web paused for the call", timeout: 20) { state in
      watchSlow(state)
      let idleBy = Rig.thread(idle, in: state)?["pausedBy"] as? String
      let webBy = Rig.project(webDirectory, in: state)?["pausedBy"] as? String
      if firstMeetingPause == nil, idleBy != nil || webBy != nil {
        firstMeetingPause = (idleBy == "meeting", webBy == "meeting")
      }
      let tree = LiveProcessTree.read().descendants([idle.pid])
      return state["meeting"] as? Bool == true && idleBy == "meeting" && webBy == "meeting"
        && tree.count > 1 && tree.allSatisfy(Rig.stopped) && Rig.stopped(web.pid)
    }
    let together = try #require(firstMeetingPause)
    #expect(together.idle && together.web, "not paused in one tick: \(together)")
    // The island shows the call while it lasts (Task 9.4). The dump resolves it from the model,
    // so it holds on a Mac with no notch; with one, the e2e build also draws it to island.png.
    #expect(rig.state()["island"] as? String == "call")
    // N7: the menu-bar item says it too, beside the icon: "Call · N paused", or "Call".
    let callLabel = rig.state()["menuBar"] as? String ?? ""
    #expect(callLabel == "Call" || callLabel.hasPrefix("Call · "), "menu bar: \(callLabel)")
    if await MainActor.run(body: { NotchGeometry.notchedScreen() != nil }) {
      let image = rig.dir.appendingPathComponent("island.png").path
      try await rig.poll("island.png written", timeout: 5) {
        FileManager.default.fileExists(atPath: image)
      }
    }
    // Every note since scenario 5's, so a later one can't hide the call's.
    try await rig.until("the call's note", timeout: 10) { state in
      watchSlow(state)
      return slowNotes.contains { $0.hasSuffix("for your call") }
    }
    // A call slows heavy work too (Q9), never the session root nor a server's line.
    try await rig.until("heavy work slowed for the call", timeout: 30) { state in
      watchSlow(state)
      return Rig.priority(looping) == 4 && Rig.priority(job.pid) == 4
        && slowed(state).isSuperset(of: [looping, job.pid])
    }
    #expect(quitApps(rig.state()).isEmpty, "an app was quit for the call")
    untouched([busy, kept, serving], server: server, rig: rig)
    // The slow's note ("Slowed 1 build") outranks the resumed flash for its 4 s (no banners), so
    // ending the call right after it would leave the flash a second or less. Let it age out.
    let slowSeen = Date.now
    try await rig.until("the slow's note is over", timeout: 10) { _ in
      Date.now.timeIntervalSince(slowSeen) >= IslandState.noteFor + 1
    }

    // Scenario 9: the call ends, so everything it paused resumes at once, with no 30 s wait.
    // The island flashes "resumed" for 4 s, then hides (Task 9.4).
    var islands: [String] = []
    func watchIsland(_ state: [String: Any]) {
      if let island = state["island"] as? String, islands.last != island { islands.append(island) }
    }
    let callEnded = Date.now
    try rig.control(["pressure": MemoryRisk.normal.rawValue, "meeting": false])
    try await rig.until("idle and web resumed after the call", timeout: 20) { state in
      watchSlow(state)
      watchIsland(state)
      let project = Rig.project(webDirectory, in: state)
      return state["meeting"] as? Bool == false
        && !Rig.stopped(idle.pid) && rig.stoppedDescendants(of: idle).isEmpty
        && Rig.thread(idle, in: state).map { $0["pausedBy"] == nil } == true
        && !Rig.stopped(web.pid) && project != nil && project?["pausedBy"] == nil
    }
    #expect(Date.now.timeIntervalSince(callEnded) < 15, "resumed only after the calm wait")
    #expect(Rig.same(idle.pid, idle.start), "idle is gone or replaced")
    #expect(Rig.same(web.pid, web.start), "web is gone or replaced")
    try await rig.until("resumed flash", timeout: 10) { state in
      watchIsland(state)
      return islands.contains("resumed")
    }
    var hiddenLabel: String?
    try await rig.until("flash ends", timeout: 10) { state in
      watchIsland(state)
      guard state["island"] as? String == "hidden" else { return false }
      hiddenLabel = state["menuBar"] as? String
      return true
    }
    #expect(hiddenLabel == "", "N7: back to the icon alone")
    untouched([busy, kept, serving], server: server, rig: rig)

    // Scenario 12: the island's Resume now (N3), during a second call. It resumes what the call
    // paused at once, through the header button's path, and counts as the user's resume, so the
    // call that is still on doesn't pause it again. Memory has been calm all along, so the
    // episode ends with this call and scenario 4 starts afresh.
    try rig.control(["pressure": MemoryRisk.normal.rawValue, "meeting": true])
    try await rig.until("idle and web paused for the second call", timeout: 20) { state in
      watchSlow(state)
      let tree = LiveProcessTree.read().descendants([idle.pid])
      return state["meeting"] as? Bool == true
        && Rig.thread(idle, in: state)?["pausedBy"] as? String == "meeting"
        && Rig.project(webDirectory, in: state)?["pausedBy"] as? String == "meeting"
        && tree.count > 1 && tree.allSatisfy(Rig.stopped) && Rig.stopped(web.pid)
    }
    let resumeNow = Date.now
    try rig.command("resumeNow")
    try await rig.until("Resume now resumed idle and web, as the user's resume", timeout: 15) {
      state in
      watchSlow(state)
      let project = Rig.project(webDirectory, in: state)
      let mine = Set(state["userResumed"] as? [String] ?? [])
      let idleID = Rig.thread(idle, in: state)?["id"] as? String
      return state["meeting"] as? Bool == true
        && !Rig.stopped(idle.pid) && rig.stoppedDescendants(of: idle).isEmpty
        && Rig.thread(idle, in: state).map { $0["pausedBy"] == nil } == true
        && !Rig.stopped(web.pid) && project != nil && project?["pausedBy"] == nil
        && idleID.map(mine.contains) == true
        && mine.contains(AutoPauseWiring.projectID(webDirectory))
    }
    #expect(Date.now.timeIntervalSince(resumeNow) < 10, "Resume now took 10 s or more")
    #expect(Rig.same(idle.pid, idle.start), "idle is gone or replaced")
    #expect(Rig.same(web.pid, web.start), "web is gone or replaced")
    // Several scans with the call still on: nothing is paused again.
    var pausedAgain: Set<String> = []
    let holdUntil = Date.now.addingTimeInterval(8)
    try await rig.until("Resume now holds through the call", timeout: 20) { state in
      watchSlow(state)
      if Rig.stopped(idle.pid) || Rig.thread(idle, in: state)?["pausedBy"] != nil {
        pausedAgain.insert("idle")
      }
      if Rig.stopped(web.pid) || Rig.project(webDirectory, in: state)?["pausedBy"] != nil {
        pausedAgain.insert("web")
      }
      return Date.now >= holdUntil
    }
    #expect(pausedAgain.isEmpty, "paused again during the call: \(pausedAgain)")
    #expect(rig.state()["island"] as? String == "call")
    untouched([busy, kept, serving], server: server, rig: rig)
    try rig.control(["pressure": MemoryRisk.normal.rawValue, "meeting": false])
    // The hand-off to scenario 4: the call is over and the episode with it, so what the user
    // resumed may be paused again under pressure.
    try await rig.until("the second call and its episode ended", timeout: 15) { state in
      watchSlow(state)
      return state["meeting"] as? Bool == false
        && (state["userResumed"] as? [String])?.isEmpty == true
    }

    // Scenario 4: quitting resumes what Tamebar paused (Q9) and restores what it slowed (Q12).
    // SIGTERM, as `pkill -x Tamebar` sends it, during a call with CPU strain: idle and web are
    // paused for the call (a session is no longer paused for memory, Q18), the heavy work is
    // slowed, and nothing is due to be resumed or restored before the quit. The app resumes
    // idle's whole tree and web, restores priorities, children included, then exits.
    try rig.control(["pressure": MemoryRisk.normal.rawValue, "meeting": true, "cpu": true])
    try await rig.until(
      "heavy work slowed under CPU strain, idle and web paused for the call", timeout: 80
    ) { state in
      watchSlow(state)
      let tree = LiveProcessTree.read().descendants([idle.pid])
      return Rig.priority(looping) == 4 && Rig.priority(job.pid) == 4
        && slowed(state).isSuperset(of: [looping, job.pid])
        && tree.count > 1 && tree.allSatisfy(Rig.stopped)
        && Rig.thread(idle, in: state)?["pausedBy"] as? String == "meeting"
        && Rig.stopped(web.pid)
        && Rig.project(webDirectory, in: state)?["pausedBy"] as? String == "meeting"
    }
    let quit = Date.now
    let exited = try #require(rig.terminateApp(within: 5), "the app still runs 5 s after SIGTERM")
    #expect(
      exited.terminationReason == .uncaughtSignal && exited.terminationStatus == SIGTERM,
      "ended by \(exited.terminationReason.rawValue)/\(exited.terminationStatus), not SIGTERM")
    #expect(Date.now.timeIntervalSince(quit) < 5)
    #expect(Rig.same(idle.pid, idle.start), "idle is gone or replaced")
    let tree = LiveProcessTree.read().descendants([idle.pid])
    #expect(tree.count > 1, "idle's tree is gone")
    let stopped = tree.filter(Rig.stopped)
    #expect(stopped.isEmpty, "still stopped after quit: \(stopped)")
    #expect(Rig.same(web.pid, web.start), "web is gone or replaced")
    #expect(!Rig.stopped(web.pid), "web still stopped after quit")
    let background = LiveProcessTree.read().descendants([looping, job.pid]).filter {
      Rig.priority($0) == 4
    }
    #expect(background.isEmpty, "still in background after quit: \(background)")
    #expect(touched.isEmpty, "slowed on a server's line or the root: \(touched)")
    untouched([busy, kept, serving], server: server, rig: rig)
    #expect(Rig.same(unlisted.pid, unlisted.start), "the unlisted app was quit")
    #expect(!rig.fakeAppInstances(listedApp).isEmpty, "the reopened app was quit again")

    // Scenario 11: "Free N GB" ends the unused session through the click's path (`endUnused`):
    // a fresh scan, then each session re-checked against it and its agent's own status (Q4, Q7).
    // Protected sessions survive. Scenario 10 ends idle on its own, so this one ends a fifth
    // fake, `stale`, while idle is kept with the others. Scenario 4 quit the app, so it is
    // launched again; a launch clears the e2e build's data and defaults, so Keep is set again.
    let stale = try rig.spawn("stale-claude", tool: "claude", script: "sleep 3600; :")
    try rig.claudeSession(
      stale, status: "idle", idleDays: 8, sessionID: "00000000-0000-4000-8000-000000000005")
    try rig.targets()
    try? FileManager.default.removeItem(at: rig.dir.appendingPathComponent("state.json"))
    try rig.control(["pressure": MemoryRisk.normal.rawValue])
    try rig.launch(appPath)
    try await rig.until("5 fakes seen after the relaunch") {
      ($0["threads"] as? [Any])?.count == 5
    }
    try rig.command("keep:\(kept.pid)")
    try rig.command("keep:\(idle.pid)")
    try await rig.until("only stale unused after the relaunch") { state in
      Rig.thread(stale, in: state)?["unused"] as? String == "idle"
        && Rig.thread(idle, in: state)?["protection"] as? String == "kept"
        && Rig.thread(busy, in: state)?["protection"] as? String == "busy"
        && Rig.thread(kept, in: state)?["protection"] as? String == "kept"
        && Rig.thread(serving, in: state)?["protection"] as? String == "serving"
    }
    try rig.command("endUnused")
    // A zombie root no longer matches its start time either (`E2EMode.startTime`).
    try await rig.poll("stale session ended", timeout: 15) { !Rig.same(stale.pid, stale.start) }
    try await rig.until("stale in Ended sessions", timeout: 10) { state in
      (state["ended"] as? [String] ?? []).contains(
        "cd '/tmp' && claude --resume 00000000-0000-4000-8000-000000000005")
    }
    untouched([idle, busy, kept, serving], server: server, rig: rig)
    // Scenario 10 launches its own app.
    try #require(rig.terminateApp(within: 5) != nil, "the app still runs 5 s after SIGTERM")

    // Scenario 10: End after 7 days while away (Q10). Last, since it ends idle: a fresh launch with
    // auto mode in its argument domain. While present nothing is ended; once away, idle (8 days)
    // is ended and recorded in Ended sessions, and busy, kept (9 days, kept again: the launch
    // cleared the e2e defaults) and serving (9 days) stay untouched. Back, one note.
    try rig.control(["pressure": MemoryRisk.normal.rawValue, "away": false])
    try rig.launch(appPath, autoEnd: .init(mode: .auto, days: 7))
    try await rig.until("relaunched with auto mode, present", timeout: 30) { state in
      state["autoEnd"] as? String == "auto:7" && state["away"] as? Bool == false
        && (state["threads"] as? [Any])?.count == 4
    }
    try rig.command("keep:\(kept.pid)")
    try await rig.until("unused and protections after the relaunch") { state in
      Rig.thread(idle, in: state)?["unused"] as? String == "idle"
        && Rig.thread(busy, in: state)?["protection"] as? String == "busy"
        && Rig.thread(kept, in: state)?["protection"] as? String == "kept"
        && Rig.thread(serving, in: state)?["protection"] as? String == "serving"
    }
    try await Task.sleep(for: .seconds(3))
    #expect(Rig.same(idle.pid, idle.start), "idle was ended while present")
    let resume = "cd '/tmp' && claude --resume 00000000-0000-4000-8000-000000000001"
    let idleChildren = rig.pinDescendants(of: idle)
    #expect(!idleChildren.isEmpty, "idle has no child")
    try rig.control(["pressure": MemoryRisk.normal.rawValue, "away": true])
    try await rig.until("idle ended while away", timeout: 30) { state in
      state["away"] as? Bool == true && !Rig.same(idle.pid, idle.start)
        && (state["ended"] as? [String] ?? []).contains(resume)
    }
    let survivors = idleChildren.filter { Rig.same($0.pid, $0.start) }
    #expect(survivors.isEmpty, "idle's children outlived it: \(survivors.map(\.pid))")
    #expect(!idle.process.isRunning, "idle still runs")
    #expect(rig.state()["note"] == nil, "a note while still away")
    untouched([busy, kept, serving], server: server, rig: rig)
    try rig.control(["pressure": MemoryRisk.normal.rawValue, "away": false])
    try await rig.until("the note on return", timeout: 15) { state in
      // With what it freed: "Ended 1 session idle 8+ days · 4.2 MB".
      (state["note"] as? String)?.hasPrefix("Ended 1 session idle 8+ days") == true
    }
    let ended = rig.state()["ended"] as? [String] ?? []
    #expect(ended == [resume], "ended: \(ended)")
    untouched([busy, kept, serving], server: server, rig: rig)

    // Scenario 13: memory pressure held 2 minutes ends the largest session idle 12 h or more
    // (Q18), while the user is present, through Q10's automatic path (fresh scan, status re-read,
    // resume command, no background job), with one note and an entry in Ended sessions. A session
    // idle 6 h stays, as do busy, kept and serving. `old` has an MCP-server child, like idle, so
    // Quit must reach it too.
    let old = try rig.spawn("old-claude", tool: "claude", script: "'\(rig.mcpServer)' 3600; :")
    let young = try rig.spawn("young-claude", tool: "claude", script: "sleep 3600; :")
    try rig.claudeSession(
      old, status: "idle", idleDays: 14.0 / 24, sessionID: "00000000-0000-4000-8000-000000000006")
    try rig.claudeSession(
      young, status: "idle", idleDays: 6.0 / 24, sessionID: "00000000-0000-4000-8000-000000000007")
    try rig.targets()
    try await rig.until("old and young seen idle", timeout: 30) { state in
      Rig.thread(old, in: state)?["status"] as? String == "idle"
        && Rig.thread(young, in: state)?["status"] as? String == "idle"
    }
    let oldChildren = rig.pinDescendants(of: old)
    #expect(!oldChildren.isEmpty, "old has no child")
    let oldResume = "cd '/tmp' && claude --resume 00000000-0000-4000-8000-000000000006"
    var pressureNotes: [String] = []
    let notePressure = rig.state()["note"] as? String
    func watchEnd(_ state: [String: Any]) {
      if let note = state["note"] as? String, note != notePressure, pressureNotes.last != note {
        pressureNotes.append(note)
      }
    }
    try rig.control(["pressure": MemoryRisk.warning.rawValue, "away": false])
    try await rig.until("the warning seen, present", timeout: 30) { state in
      watchEnd(state)
      return state["risk"] as? Int ?? 0 >= MemoryRisk.warning.rawValue
        && state["away"] as? Bool == false
    }
    let warned = Date.now
    try await rig.until("old ended under pressure", timeout: 180) { state in
      watchEnd(state)
      return !Rig.same(old.pid, old.start)
        && (state["ended"] as? [String] ?? []).contains(oldResume)
    }
    #expect(Date.now.timeIntervalSince(warned) >= 115, "ended before 2 minutes of pressure")
    try await rig.until("the end's note", timeout: 10) { state in
      watchEnd(state)
      // "Ended tmp · 4.2 MB back": the fakes run in /tmp.
      return pressureNotes.contains { $0.hasPrefix("Ended tmp") }
    }
    let oldSurvivors = oldChildren.filter { Rig.same($0.pid, $0.start) }
    #expect(oldSurvivors.isEmpty, "old's children outlived it: \(oldSurvivors.map(\.pid))")
    try rig.control(["pressure": MemoryRisk.normal.rawValue, "away": false])
    untouched([young, busy, kept, serving], server: server, rig: rig)
    #expect(
      Set(rig.state()["ended"] as? [String] ?? []) == [resume, oldResume],
      "ended: \(rig.state()["ended"] ?? "none")")
  }

  /// Q20: a session idle two days whose dev server had no connection for 24 h is ended with
  /// its server, server first, both in the Stopped log. The control's `clockAdvance` moves
  /// Q20's clock a day on in a second. While a connection is open, nothing is ended.
  @Test(.enabled(if: EndToEndTests.appPath != nil, "needs TAMEBAR_E2E_APP (scripts/e2e.sh)"))
  func unusedDevServer() async throws {
    let appPath = try #require(Self.appPath)
    let rig = try Rig()
    defer { rig.cleanup() }
    let port = try rig.freePort()
    // The agent outlives its server, as a real one does: its MCP helper keeps it waiting.
    let serving = try rig.spawn(
      "dev-claude", tool: "claude",
      script:
        "'\(rig.mcpServer)' 3600 & python3 -m http.server \(port) --bind 127.0.0.1"
        + " --directory '\(rig.dir.path)/www' >/dev/null 2>&1; wait; :")
    let server = try await rig.pinServer(of: serving)
    try rig.register(server, port: port)
    try rig.claudeSession(
      serving, status: "idle", idleDays: 2, sessionID: "00000000-0000-4000-8000-000000000020")
    try rig.targets()
    try rig.control(["pressure": MemoryRisk.normal.rawValue])
    try rig.launch(appPath)
    let key = String(port)
    try await rig.until("serving, its port on Q20's clock") { state in
      Rig.thread(serving, in: state)?["protection"] as? String == "serving"
        && (state["servedPorts"] as? [String: Int])?[key] != nil
    }
    // First seen now: nothing is judged unused retroactively.
    try await Task.sleep(for: .seconds(4))
    #expect(Rig.same(serving.pid, serving.start) && Rig.same(server.pid, server.start))

    // A day passes with a connection open: the port was used, nothing is ended.
    let client = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    try #require(client >= 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
    try #require(connected, "can't connect to the fake server")
    try rig.control(["pressure": MemoryRisk.normal.rawValue, "clockAdvance": 25 * 3_600.0])
    try await rig.until("the connection seen at Q20's clock", timeout: 30) { state in
      ((state["servedPorts"] as? [String: Int])?[key] ?? 99) < 60
    }
    try await Task.sleep(for: .seconds(4))
    #expect(Rig.same(serving.pid, serving.start), "ended while its server had a connection")
    #expect(Rig.same(server.pid, server.start), "the server ended while connected")
    close(client)

    // Another day with no connection: the server, then the session, end.
    let resume = "cd '/tmp' && claude --resume 00000000-0000-4000-8000-000000000020"
    try rig.control(["pressure": MemoryRisk.normal.rawValue, "clockAdvance": 50 * 3_600.0])
    try await rig.until("server and session ended", timeout: 60) { state in
      !Rig.same(server.pid, server.start) && !Rig.same(serving.pid, serving.start)
        && (state["ended"] as? [String] ?? []).contains(resume)
        && (state["endedServers"] as? [String] ?? []).contains {
          $0.contains("http.server \(port)")
        }
    }
    try await rig.until("the note", timeout: 15) { state in
      (state["note"] as? String)?.hasPrefix("Ended tmp and its server :\(port)") == true
    }
    let commands = rig.state()["endedServers"] as? [String] ?? []
    #expect(commands.count == 1 && commands[0].hasPrefix("cd '"), "servers: \(commands)")
  }

  /// Alive, not stopped, no stopped descendants; the pinned server too.
  private func untouched(_ fakes: [Fake], server: Pinned, rig: Rig) {
    for fake in fakes {
      #expect(Rig.same(fake.pid, fake.start), "\(fake.name) is gone or replaced")
      #expect(!Rig.stopped(fake.pid), "\(fake.name) is stopped")
      let stopped = rig.stoppedDescendants(of: fake)
      #expect(stopped.isEmpty, "\(fake.name) has stopped descendants \(stopped)")
    }
    #expect(Rig.same(server.pid, server.start), "\(server.name) is gone or replaced")
    #expect(!Rig.stopped(server.pid), "\(server.name) is stopped")
  }
}
