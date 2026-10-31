import AppKit
import Darwin
import Foundation

/// The `tamebar` command line's readings on this Mac: the app's own scanners, run once.
enum CLILive {
  static func environment() -> CLIEnvironment {
    let defaults = appDefaults()
    return CLIEnvironment(
      directory: directory(), defaults: defaults, now: { .now }, timeZone: .current,
      system: system, sessions: { sessions(defaults) }, tamebarPID: tamebarPID, label: label,
      out: { print($0, terminator: "") }, err: { fputs($0, stderr) },
      runningApps: StoppedLog.runningApps, startTime: E2EMode.startTime,
      wait: { StartWaitLive.run(directory: directory(), input: StartWaitLive.readHookInput()) },
      home: home(), executable: { hookExecutable(home: home()) })
  }

  /// `HOME`, as a shell sees it, else the account's.
  static func home() -> URL {
    if let path = ProcessInfo.processInfo.environment["HOME"], path.hasPrefix("/") {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }

  /// The path the start hook runs: `~/.local/bin/tamebar` when it leads to this executable (it
  /// survives a reinstall into another folder), else this executable's own path.
  static func hookExecutable(home: URL) -> String {
    let own = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
      .resolvingSymlinksInPath().standardizedFileURL
    let link = home.appendingPathComponent(".local/bin/tamebar")
    if link.resolvingSymlinksInPath().standardizedFileURL.path == own.path { return link.path }
    return own.path
  }

  /// Tamebar's data folder; `TAMEBAR_STATE_DIR` points the command line at another one (tests).
  static func directory() -> URL {
    if let path = ProcessInfo.processInfo.environment["TAMEBAR_STATE_DIR"], !path.isEmpty {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return AppData.directory
  }

  /// The app's settings. Run through the `~/.local/bin/tamebar` link or from `.build`, this
  /// process isn't the app, so its standard defaults are another domain: read the app's by name.
  static func appDefaults() -> UserDefaults {
    if Bundle.main.bundleIdentifier?.hasPrefix(AppBrand.bundleIdentifier) == true {
      return .standard
    }
    return UserDefaults(suiteName: AppBrand.bundleIdentifier) ?? .standard
  }

  /// How long CPU is measured: the app samples every 2 s; half a second keeps the command quick.
  static let cpuWindow: TimeInterval = 0.5

  static func system() -> CLISystemReading {
    let provider = SystemMetricsProvider()
    _ = provider.snapshot()
    let own = getpid()
    let before = CPUProcessReader.counters().filter { $0.id != own }
    let started = ProcessInfo.processInfo.systemUptime
    Thread.sleep(forTimeInterval: cpuWindow)
    let snapshot = provider.snapshot()
    let after = CPUProcessReader.counters().filter { $0.id != own }
    let seconds = ProcessInfo.processInfo.systemUptime - started
    let leads =
      CPUProcessReader.nanosecondsPerTick.map {
        CPUProcessReader.leads(
          CPUInterval(previous: before, current: after, seconds: seconds, nanosecondsPerTick: $0))
      } ?? ResourceLeads(cpu: nil, memory: nil)
    let memory =
      MemoryGuardSample.read(pressure: snapshot.memoryPressure)
      ?? MemoryGuardSample(
        date: snapshot.updatedAt, pressure: snapshot.memoryPressure,
        available: snapshot.ramAvailable, total: snapshot.ramTotal, compressed: 0, swapUsed: nil,
        swapOutBytes: 0)
    return CLISystemReading(
      memory: memory, cpu: snapshot.cpuUsage, diskFree: snapshot.diskAvailable,
      diskTotal: snapshot.diskTotal, leads: leads, call: CallSignals.read(),
      thermal: snapshot.thermalStatus)
  }

  static func sessions(_ defaults: UserDefaults) -> CLISessionScan {
    let kept = (CLIReport.preferences(defaults) ?? []).filter(\.keepRunning).map(\.directory)
    let snapshot = DevProcessScanner(keptRunningRoots: { kept }).snapshot()
    return CLISessionScan(
      threads: snapshot.threads, records: snapshot.records, listening: snapshot.listeningIDs,
      ports: snapshot.listeningPorts, incomplete: snapshot.incomplete)
  }

  /// The running Tamebar app, never this process.
  static func tamebarPID() -> Int32? {
    let own = getpid()
    return NSRunningApplication.runningApplications(withBundleIdentifier: AppBrand.bundleIdentifier)
      .first { $0.processIdentifier != own && !$0.isTerminated }?.processIdentifier
  }

  /// A session's project from its root's folder, while the pid is still that session's process.
  static func label(_ threadID: String) -> String? {
    guard let parts = CLIReport.threadParts(threadID),
      let identity = DevProcessIdentity.read(parts.pid),
      Int(identity.process.startSeconds) == parts.start,
      let directory = ProcessWorkingDirectory.read(parts.pid), directory != "/"
    else { return nil }
    return URL(fileURLWithPath: directory).lastPathComponent
  }
}
