import Darwin
import Foundation

// The `tamebar` reports (docs/CLI.md): what each command prints with `--json`, built from the app's
// own scanners, decoders and rules. Pure: the readings come in, the report goes out.

/// Encodes nil as `null`, so a key is always present and a reader can tell unknown from absent.
@propertyWrapper
struct CLINullable<Value: Encodable & Equatable>: Encodable, Equatable {
  var wrappedValue: Value?

  /// Spelled out: a wrapper needs `init(wrappedValue:)` itself, not as the memberwise init.
  init(wrappedValue value: Value?) { wrappedValue = value }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    if let wrappedValue { try container.encode(wrappedValue) } else { try container.encodeNil() }
  }
}

/// Memory, CPU, disk, the top apps and the call probe, read once.
struct CLISystemReading {
  let memory: MemoryGuardSample
  /// 0…1 across all cores; nil when it couldn't be measured.
  let cpu: Double?
  let diskFree: UInt64
  let diskTotal: UInt64
  /// The app or process group using the most CPU and the most memory, helpers counted in.
  let leads: ResourceLeads
  /// Nil when the mic and camera couldn't be read.
  let call: CallReading?
  /// macOS's thermal state.
  var thermal: ThermalStatus = .nominal
}

/// The AI sessions a scan saw, with what the protections need.
struct CLISessionScan {
  let threads: [AIThread]
  let records: [Int32: RawProcessRecord]
  /// Processes holding a listening TCP port.
  let listening: Set<Int32>
  let ports: [Int32: [Int]]
  /// The scan read only part of the process table or the ports.
  let incomplete: Bool
}

/// What Tamebar's files say it did, read without the side effects of the app's `load`: an
/// unreadable file is reported, never moved aside.
struct CLIState {
  var autopause: AutoPauseWiring.Record?
  var background: BackgroundPriority.Record?
  /// `strain.json` (Q19), as the Tamebar that wrote it left it.
  var strain: StrainFile?
  /// The sessions waiting at start (`waiting/`), oldest first, as registered.
  var waiting: [StartWait.Registration] = []
  /// `codex-plugins.json` (Q21): what Tamebar turned off in Codex's config, and its last run.
  var codexTrim: CodexTrimState?
  var notes: [String] = []

  static func read(_ directory: URL) -> CLIState {
    var state = CLIState()
    state.codexTrim = CodexTrimState.read(directory)
    switch CLIFile.decode(AutoPauseWiring.Record.self, directory, "autopause.json") {
    case .value(let record): state.autopause = record
    case .missing: break
    case .unreadable: state.notes.append("autopause.json is unreadable")
    }
    switch CLIFile.decode(BackgroundPriority.Record.self, directory, "background.json") {
    case .value(let record): state.background = record
    case .missing: break
    case .unreadable: state.notes.append("background.json is unreadable")
    }
    state.strain = StrainFile.read(directory)
    state.waiting = StartWait.list(directory)
    return state
  }
}

/// Tamebar's history files, read the same way.
struct CLIHistoryFiles {
  /// `memory-history.json`: a day of memory events and samples.
  var memory: MemoryIncidentHistory?
  /// `resource-history.json`: a week of CPU and RAM samples, five-minute peaks after 15 minutes.
  var resources: [ResourceSample] = []
  /// `pressure-latest.json`: the pressure log, one entry a minute, with the projects by memory.
  var pressure: [[String: String]] = []
  var notes: [String] = []

  static func read(_ directory: URL) -> CLIHistoryFiles {
    var files = CLIHistoryFiles()
    switch CLIFile.decode(
      MemoryIncidentHistory.self, directory, "memory-history.json", limit: 8 * 1_024 * 1_024)
    {
    case .value(let history): files.memory = history
    case .missing: break
    case .unreadable: files.notes.append("memory-history.json is unreadable")
    }
    switch CLIFile.decode(
      [ResourceSample].self, directory, "resource-history.json",
      limit: ResourceHistoryStore.maximumBytes)
    {
    case .value(let samples): files.resources = samples
    case .missing: break
    case .unreadable: files.notes.append("resource-history.json is unreadable")
    }
    switch CLIFile.data(directory, "pressure-latest.json", limit: 524_288) {
    case .value(let data):
      if let log = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]] {
        files.pressure = log
      } else {
        files.notes.append("pressure-latest.json is unreadable")
      }
    case .missing: break
    case .unreadable: files.notes.append("pressure-latest.json is unreadable")
    }
    return files
  }
}

/// Reads one of Tamebar's files. Only reads: no lock, no rename.
enum CLIFile {
  enum Read<Value> {
    case value(Value)
    case missing
    case unreadable
  }

  static func data(_ directory: URL, _ name: String, limit: Int = 4 * 1_024 * 1_024)
    -> Read<Data>
  {
    let url = directory.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
    guard let data = try? Data(contentsOf: url), data.count <= limit else { return .unreadable }
    return .value(data)
  }

  static func decode<Value: Decodable>(
    _ type: Value.Type, _ directory: URL, _ name: String, limit: Int = 4 * 1_024 * 1_024
  ) -> Read<Value> {
    switch data(directory, name, limit: limit) {
    case .value(let data):
      guard let value = try? JSONDecoder().decode(type, from: data) else { return .unreadable }
      return .value(value)
    case .missing: return .missing
    case .unreadable: return .unreadable
    }
  }
}

// MARK: Reports

struct CLIStatus: Encodable {
  let schema = CLIReport.schema
  let command = "status"
  let generatedAt: Date
  let tamebar: Tamebar
  let memory: Memory
  let assessment: Assessment
  let cpu: CPU
  let disk: Disk
  let top: Top
  @CLINullable var call: Call?
  let thermal: Thermal
  let strain: Strain
  /// Q21's last run: the Codex MCP servers and plugins with no call in 30 days.
  @CLINullable var codexPlugins: CodexPlugins?
  /// What may end or edit on its own, and what never is (P2), from Settings.
  var automatic = Automatic()

  struct Automatic: Encodable, Equatable {
    /// Q18 and Q20.
    var endIdleSessions = false
    /// Q21.
    var trimCodexPlugins = false
    /// Ports never ended, besides portless's.
    var protectedPorts: [Int] = []
    /// Codex MCP servers never turned off.
    var keptCodexServers: [String] = []
  }

  struct CodexPlugins: Encodable, Equatable {
    let checkedAt: Date
    /// The run wrote Codex's config.
    let applied: Bool
    /// What that run turned off: server names, plugins as `plugin <id>`.
    let turnOff: [String]
    /// Calls in the last 30 days by server (its name lowercased, `-` read as `_`).
    let calls: [String: Int]
    /// Why nothing may be turned off, when that holds.
    @CLINullable var held: String?
    /// What Tamebar turned off and is still off.
    let off: [String]
  }

  struct Tamebar: Encodable {
    let running: Bool
    @CLINullable var pid: Int32?
    let dataDirectory: String
    /// Files that couldn't be read.
    let notes: [String]
    /// The last scan the running app planned from, as saved.
    @CLINullable var lastTick: Date?
    /// Memory pressure has held since then, by the app's clocks.
    @CLINullable var pressureSince: Date?
    let autoPaused: [Paused]
    let quitApps: [QuitApp]
    let slowed: [Slowed]
    /// Something is paused for a call.
    let inCall: Bool
  }

  struct Paused: Encodable, Equatable {
    let id: String
    /// `session` or `project`.
    let kind: String
    @CLINullable var tool: String?
    @CLINullable var toolName: String?
    @CLINullable var pid: Int32?
    @CLINullable var project: String?
    @CLINullable var directory: String?
    /// `pressure` or `meeting`.
    let reason: String
    let since: Date
  }

  struct QuitApp: Encodable, Equatable {
    let bundleId: String
    let name: String
    let memoryBytes: UInt64
    let quitAt: Date
    /// The app was seen to end; until then the quit is in flight.
    let confirmed: Bool
  }

  struct Slowed: Encodable, Equatable {
    /// The Memory/CPU row it belongs to: `ai:<session>`, `app:<app>` or a workload's.
    let group: String
    /// `session`, `workload`, or `app` for an app slowed in the background (Q17.1).
    let kind: String
    let label: String
    let processIds: [Int32]
    let executables: [String]
    let slowedAt: Date
    /// An app's bundle id; null for a session or a workload.
    @CLINullable var bundleId: String?
    /// An app's CPU when it was slowed, 100 being one core; null for a session or a workload.
    @CLINullable var cpuPercent: Double?
  }

  struct Memory: Encodable {
    let totalBytes: UInt64
    let availableBytes: UInt64
    let compressedBytes: UInt64
    @CLINullable var swapUsedBytes: UInt64?
    /// The kernel's level: `normal`, `warning`, `critical` or `unknown`.
    let pressure: String
  }

  /// The app's verdict on this reading (`PressureEvaluator`).
  struct Assessment: Encodable {
    /// `normal`, `growing`, `warning` or `critical`.
    let risk: String
    /// The bottleneck: `none`, `memory`, `disk` or `cpu`.
    let limit: String
    let title: String
    let advice: String
  }

  struct CPU: Encodable {
    /// 0–100 across all cores.
    @CLINullable var percent: Double?
  }

  struct Disk: Encodable {
    let freeBytes: UInt64
    let totalBytes: UInt64
  }

  struct Top: Encodable {
    @CLINullable var memory: MemoryLead?
    @CLINullable var cpu: CPULead?
  }

  struct MemoryLead: Encodable, Equatable {
    let name: String
    let bytes: UInt64
  }

  struct CPULead: Encodable, Equatable {
    let name: String
    /// 100 is one core.
    let percent: Double
  }

  struct Call: Encodable, Equatable {
    let mic: Bool
    let camera: Bool
    let active: Bool
  }

  /// Q19: the Mac really struggling, judged by the running Tamebar, and the new sessions waiting
  /// at start for it.
  struct Strain: Encodable, Equatable {
    /// Null when no running Tamebar judges it.
    @CLINullable var struggling: Bool?
    @CLINullable var since: Date?
    let signals: [Signal]
    let waiting: [Waiting]
  }

  struct Signal: Encodable, Equatable {
    /// `swap`, `fan`, `heat`, `critical` (or `forced`, an e2e test).
    let kind: String
    /// Swap-ins in pages/s, or the fan in percent of its max.
    @CLINullable var value: Double?
    /// The thermal state, for `heat`.
    @CLINullable var state: String?
    /// "fan 78%".
    let text: String
  }

  struct Waiting: Encodable, Equatable {
    let project: String
    /// `claude`, `codex`, or null.
    @CLINullable var tool: String?
    let toolName: String
    @CLINullable var directory: String?
    @CLINullable var sessionId: String?
    /// The agent held, and the `tamebar wait` holding it.
    @CLINullable var agentPid: Int32?
    let waitPid: Int32
    let since: Date
    let waitedSeconds: Int
  }

  /// Heat (Q13).
  struct Thermal: Encodable, Equatable {
    /// macOS's thermal state: `nominal`, `fair`, `serious` or `critical` (`unknown` if macOS
    /// names a new one).
    let state: String
    /// The running Tamebar is acting on heat: serious or critical held 30 s, and nominal or fair
    /// hasn't held 60 s since.
    let acting: Bool
  }
}

struct CLISessions: Encodable {
  let schema = CLIReport.schema
  let command = "sessions"
  let generatedAt: Date
  let tamebarRunning: Bool
  let all: Bool
  /// Sessions below this are left out unless `all`.
  let minBytes: UInt64
  let total: Int
  let hidden: Int
  let incomplete: Bool
  let sessions: [Session]

  struct Session: Encodable, Equatable {
    let id: String
    let tool: String
    let toolName: String
    @CLINullable var project: String?
    @CLINullable var directory: String?
    let title: String
    @CLINullable var pid: Int32?
    let memoryBytes: UInt64
    let cpuPercent: Double
    /// `busy`, `idle`, `paused` or `unknown`.
    let state: String
    /// What the agent itself reports: `busy`, `idle`, `shell`, or null.
    @CLINullable var agentStatus: String?
    @CLINullable var idleSeconds: Int?
    @CLINullable var idleSince: Date?
    /// `tamebar` or `user` while paused.
    @CLINullable var pausedBy: String?
    /// `pressure`, `meeting` or `heat` when Tamebar paused it (`queue`: a session an older build
    /// queued, Q14, until Tamebar resumes it at its first scan, Q19).
    @CLINullable var pauseReason: String?
    @CLINullable var pausedSince: Date?
    let protected: Bool
    /// Any of `kept`, `kept_project`, `serving`, `background_job`.
    let protections: [String]
    let ports: [Int]
    let detached: Bool
    @CLINullable var sessionId: String?
    @CLINullable var resumeCommand: String?
  }
}

struct CLIHistory: Encodable {
  let schema = CLIReport.schema
  let command = "history"
  let generatedAt: Date
  let since: Date
  let windowSeconds: Int
  let tamebarRunning: Bool
  let notes: [String]
  /// Memory events other than routine samples, oldest first: `pressure`, `disk-alert`,
  /// `app-exit`, `quit-request`, `quit-completed`, `started`…
  let events: [Event]
  /// CPU and RAM samples with their leads, oldest first.
  let samples: [Sample]
  /// The pressure log: the verdict each minute it was logged, with projects by memory.
  let pressureLog: [PressureEntry]

  struct Event: Encodable, Equatable {
    let date: Date
    let kind: String
    let detail: String
    @CLINullable var pressure: String?
    @CLINullable var availableBytes: UInt64?
    @CLINullable var swapUsedBytes: UInt64?
    let topApps: [App]
    let topProjects: [Project]
  }

  struct App: Encodable, Equatable {
    let name: String
    let bytes: UInt64
  }

  struct Project: Encodable, Equatable {
    let name: String
    let bytes: UInt64
  }

  struct Sample: Encodable, Equatable {
    let date: Date
    /// RAM in use, 0–100.
    let memoryPercent: Double
    /// 0–100 across all cores.
    @CLINullable var cpuPercent: Double?
    @CLINullable var memoryLead: CLIStatus.MemoryLead?
    @CLINullable var cpuLead: CLIStatus.CPULead?
  }

  struct PressureEntry: Encodable, Equatable {
    let date: Date
    let risk: String
    let detail: String
    let action: String
    let topProjects: [LoggedProject]
  }

  struct LoggedProject: Encodable, Equatable {
    let name: String
    /// As the log wrote it, such as `6 GB`.
    let memory: String
  }
}

enum CLIReport {
  static let schema = 1
  /// Sessions below this are left out of `sessions` unless `--all`.
  static let smallSession: UInt64 = 100_000_000

  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  static func json(_ value: some Encodable) -> String {
    guard let data = try? encoder.encode(value) else { return "{}\n" }
    return String(decoding: data, as: UTF8.self) + "\n"
  }

  static func round(_ value: Double) -> Double { (value * 10).rounded() / 10 }

  /// `claude_code`, `codex_cli`…
  static func toolKey(_ tool: AITool) -> String {
    tool.rawValue.replacingOccurrences(
      of: "([a-z])([A-Z])", with: "$1_$2", options: .regularExpression
    ).lowercased()
  }

  /// A thread ID is `<tool>-<pid>-<start seconds>` (`AIThreadGrouping`).
  static func threadParts(_ id: String) -> (tool: AITool, pid: Int32, start: Int)? {
    let parts = id.split(separator: "-")
    guard parts.count == 3, let tool = AITool(rawValue: String(parts[0])),
      let pid = Int32(parts[1]), let start = Int(parts[2])
    else { return nil }
    return (tool, pid, start)
  }

  /// Saved projects, decoded as the app decodes them but without its backup of an unreadable
  /// value. Nil when they can't be read: Keep running is then unknown, so every folder is kept.
  static func preferences(_ defaults: UserDefaults) -> [WorkspacePreference]? {
    guard let data = defaults.data(forKey: WorkspacePreferences.key) else { return [] }
    guard let entries = try? JSONDecoder().decode([Lossy<WorkspacePreference>].self, from: data)
    else { return nil }
    return entries.compactMap(\.value)
  }

  // MARK: status

  struct StatusInput {
    let reading: CLISystemReading
    let state: CLIState
    let tamebarPID: Int32?
    let directory: URL
    let now: Date
    let label: (String) -> String?
    /// A pid's start time while it runs: whether `strain.json`'s Tamebar and each waiting
    /// `tamebar wait` still do.
    var startTime: (Int32) -> Double? = { _ in nil }
    /// Settings' automatic actions (P2).
    var safety = AutomaticSafety()
  }

  static func status(_ input: StatusInput) -> CLIStatus {
    let reading = input.reading
    let memory = reading.memory
    var evaluator = PressureEvaluator()
    let assessment = evaluator.evaluate(
      .init(
        memory: memory,
        disk: DiskGuardSample(
          date: memory.date, available: reading.diskFree, swapUsed: memory.swapUsed),
        cpu: reading.cpu))
    let record = input.state.autopause
    let ledger = record?.state.ledger ?? []
    return CLIStatus(
      generatedAt: input.now,
      tamebar: .init(
        running: input.tamebarPID != nil, pid: input.tamebarPID,
        dataDirectory: input.directory.path, notes: input.state.notes,
        lastTick: record?.state.lastTick,
        pressureSince: record?.state.elevatedSince,
        autoPaused: ledger.map { paused($0, label: input.label) },
        quitApps: (record?.apps.ledger ?? []).map {
          .init(
            bundleId: $0.bundleID, name: $0.name, memoryBytes: $0.memoryBytes, quitAt: $0.quitAt,
            confirmed: $0.confirmed)
        },
        slowed: slowed(input.state.background, label: input.label),
        inCall: ledger.contains { $0.reason == .meeting }),
      memory: .init(
        totalBytes: memory.total, availableBytes: memory.available,
        compressedBytes: memory.compressed, swapUsedBytes: memory.swapUsed,
        pressure: memory.pressure.rawValue),
      assessment: .init(
        risk: riskName(assessment.risk), limit: limitName(assessment.limit),
        title: assessment.title, advice: assessment.action),
      cpu: .init(percent: reading.cpu.map { round($0 * 100) }),
      disk: .init(freeBytes: reading.diskFree, totalBytes: reading.diskTotal),
      top: .init(
        memory: reading.leads.memory.map { .init(name: $0.name, bytes: UInt64(max(0, $0.value))) },
        cpu: reading.leads.cpu.map { .init(name: $0.name, percent: round($0.value)) }),
      call: reading.call.map { .init(mic: $0.mic, camera: $0.camera, active: $0.mic || $0.camera) },
      thermal: .init(
        state: reading.thermal.rawValue,
        acting: input.tamebarPID != nil && record.map { AutoPausePlanner.isHeat($0.state) } == true),
      strain: strain(input),
      codexPlugins: input.state.codexTrim.flatMap { state in
        state.lastRun.map { run in
          .init(
            checkedAt: run.at, applied: run.applied, turnOff: run.turnOff, calls: run.calls,
            held: run.held, off: state.off.map(\.name))
        }
      },
      automatic: .init(
        endIdleSessions: input.safety.endIdleSessions,
        trimCodexPlugins: input.safety.trimCodexPlugins,
        protectedPorts: input.safety.protectedPorts,
        keptCodexServers: input.safety.keptCodexServers))
  }

  /// The strain as the running Tamebar judges it, with the sessions still waiting.
  static func strain(_ input: StatusInput) -> CLIStatus.Strain {
    let state = input.state
    let file = state.strain.flatMap { $0.writerRuns(startTime: input.startTime) ? $0 : nil }
    let waiting = state.waiting.filter {
      StartWait.isLive($0, startTime: input.startTime)
        && !StartWait.isReleased($0.waitPID, directory: input.directory)
    }
    return .init(
      struggling: file?.struggling, since: file?.since,
      signals: (file?.struggling == true ? file?.signals ?? [] : []).map {
        .init(kind: $0.kind.rawValue, value: $0.value.map(round), state: $0.state, text: $0.text)
      },
      waiting: waiting.map {
        .init(
          project: $0.project, tool: $0.tool, toolName: $0.toolName, directory: $0.directory,
          sessionId: $0.sessionID, agentPid: $0.agentPID, waitPid: $0.waitPID, since: $0.started,
          waitedSeconds: max(0, Int(input.now.timeIntervalSince($0.started))))
      })
  }

  static func riskName(_ risk: MemoryRisk) -> String {
    switch risk {
    case .normal: "normal"
    case .growing: "growing"
    case .warning: "warning"
    case .critical: "critical"
    }
  }

  static func limitName(_ limit: PressureLimit) -> String {
    switch limit {
    case .none: "none"
    case .memory: "memory"
    case .disk: "disk"
    case .cpu: "cpu"
    }
  }

  static func paused(_ entry: AutoPausePlanner.Entry, label: (String) -> String?)
    -> CLIStatus.Paused
  {
    if let directory = AutoPauseWiring.projectDirectory(entry.threadID) {
      return .init(
        id: entry.threadID, kind: "project", tool: nil, toolName: nil, pid: nil,
        project: URL(fileURLWithPath: directory).lastPathComponent, directory: directory,
        reason: entry.reason.rawValue, since: entry.since)
    }
    let parts = threadParts(entry.threadID)
    return .init(
      id: entry.threadID, kind: "session", tool: parts.map { toolKey($0.tool) },
      toolName: parts?.tool.title, pid: parts?.pid, project: label(entry.threadID),
      directory: nil, reason: entry.reason.rawValue, since: entry.since)
  }

  /// A row's name: `Claude Code · notes` for a session, the project for a project.
  static func rowLabel(_ id: String, label: (String) -> String?) -> String {
    if let directory = AutoPauseWiring.projectDirectory(id) {
      return URL(fileURLWithPath: directory).lastPathComponent
    }
    guard let parts = threadParts(id) else { return id }
    return [parts.tool.title, label(id)].compactMap { $0 }.joined(separator: " · ")
  }

  static func slowed(_ record: BackgroundPriority.Record?, label: (String) -> String?)
    -> [CLIStatus.Slowed]
  {
    let entries = record?.slowed ?? []
    var order: [String] = []
    var groups: [String: [BackgroundPriority.Entry]] = [:]
    for entry in entries {
      if groups[entry.group] == nil { order.append(entry.group) }
      groups[entry.group, default: []].append(entry)
    }
    return order.compactMap { group -> CLIStatus.Slowed? in
      guard let items = groups[group], let first = items.first else { return nil }
      let executables = items.map { URL(fileURLWithPath: $0.identity.executable).lastPathComponent }
      var seen: Set<String> = []
      let names = executables.filter { seen.insert($0).inserted }
      let thread = group.hasPrefix("ai:") ? String(group.dropFirst(3)) : nil
      let app = record?.app(group)
      let isApp = BackgroundPriority.isApp(group)
      let kind = thread != nil ? "session" : isApp ? "app" : "workload"
      let fallback = isApp ? String(group.dropFirst(4)) : names.joined(separator: ", ")
      let name: String = thread.map { rowLabel($0, label: label) } ?? app?.name ?? fallback
      let cpu: Double? = app.map { $0.cpuPercent.rounded() }
      return CLIStatus.Slowed(
        group: group, kind: kind, label: name, processIds: items.map(\.processID),
        executables: names, slowedAt: items.map(\.slowedAt).min() ?? first.slowedAt,
        bundleId: app?.bundleID, cpuPercent: cpu)
    }
  }

  // MARK: sessions

  struct SessionsInput {
    let scan: CLISessionScan
    let autopause: AutoPauseWiring.Record?
    let keeps: SessionKeeps
    /// Nil when unreadable: every folder then counts as Keep running, as in the app.
    let preferences: [WorkspacePreference]?
    let tamebarRunning: Bool
    let now: Date
    let all: Bool
  }

  static func sessions(_ input: SessionsInput) -> CLISessions {
    let ledger = Dictionary(
      (input.autopause?.state.ledger ?? []).map { ($0.threadID, $0) },
      uniquingKeysWith: { first, _ in first })
    var seen: Set<String> = []
    let rows = input.scan.threads.filter { seen.insert($0.id).inserted }
      .sorted {
        $0.memoryBytes == $1.memoryBytes ? $0.id < $1.id : $0.memoryBytes > $1.memoryBytes
      }
      .map { session($0, input: input, pausedBy: ledger[$0.id]) }
    let shown = input.all ? rows : rows.filter { $0.memoryBytes >= smallSession }
    return CLISessions(
      generatedAt: input.now, tamebarRunning: input.tamebarRunning, all: input.all,
      minBytes: input.all ? 0 : smallSession, total: rows.count, hidden: rows.count - shown.count,
      incomplete: input.scan.incomplete, sessions: shown)
  }

  static func session(
    _ thread: AIThread, input: SessionsInput, pausedBy entry: AutoPausePlanner.Entry?
  ) -> CLISessions.Session {
    var protections: [String] = []
    if input.keeps.contains(thread) { protections.append("kept") }
    if let directory = thread.directory,
      WorkspacePreferences.isKeptRunning(directory, preferences: input.preferences)
    {
      protections.append("kept_project")
    }
    if UnusedPolicy.serving(thread, listening: input.scan.listening) {
      protections.append("serving")
    }
    if BackgroundJobs.job(thread, records: input.scan.records) != nil {
      protections.append("background_job")
    }
    let agent = Set([thread.rootProcessID, thread.nativeProcessID].compactMap { $0 })
    let ports = thread.processIDs.filter { !agent.contains($0) || thread.tool == .codexDesktop }
      .flatMap { input.scan.ports[$0] ?? [] }
    let idle = UnusedPolicy.idleFor(thread, now: input.now)
    let state: String
    if thread.isPaused {
      state = "paused"
    } else {
      switch thread.agentStatus {
      case .busy, .shell: state = "busy"
      case .idle: state = "idle"
      case nil: state = "unknown"
      }
    }
    let pausedByTamebar = thread.isPaused ? entry : nil
    return .init(
      id: thread.id, tool: toolKey(thread.tool), toolName: thread.tool.title,
      project: thread.project, directory: thread.directory, title: thread.displayName,
      pid: thread.rootProcessID ?? thread.processIDs.first, memoryBytes: thread.memoryBytes,
      cpuPercent: round(thread.cpuPercent), state: state,
      agentStatus: thread.agentStatus?.rawValue, idleSeconds: idle.map { Int($0) },
      idleSince: idle == nil ? nil : thread.agentStatusSince,
      pausedBy: thread.isPaused ? (pausedByTamebar == nil ? "user" : "tamebar") : nil,
      pauseReason: pausedByTamebar?.reason.rawValue, pausedSince: pausedByTamebar?.since,
      protected: !protections.isEmpty, protections: protections,
      ports: Array(Set(ports)).sorted(), detached: thread.isDetached,
      sessionId: thread.sessionID,
      resumeCommand: EndPlan.entry(thread, now: input.now)?.resumeCommand)
  }

  // MARK: history

  struct HistoryInput {
    let files: CLIHistoryFiles
    let since: TimeInterval
    let now: Date
    let tamebarRunning: Bool
  }

  static func history(_ input: HistoryInput) -> CLIHistory {
    let start = input.now.addingTimeInterval(-input.since)
    let inWindow = { (date: Date) in date >= start && date <= input.now }
    let events = (input.files.memory?.events ?? [])
      .filter { $0.kind != "sample" && inWindow($0.date) }
      .sorted { $0.date < $1.date }
      .map(event)
    let samples = input.files.resources.filter { inWindow($0.date) }.sorted { $0.date < $1.date }
      .map { sample -> CLIHistory.Sample in
        .init(
          date: sample.date, memoryPercent: round(sample.memory * 100),
          cpuPercent: sample.cpu.map { round($0 * 100) },
          memoryLead: sample.memoryLead.map {
            .init(name: $0.name, bytes: UInt64(max(0, $0.value)))
          },
          cpuLead: sample.cpuLead.map { .init(name: $0.name, percent: round($0.value)) })
      }
    let formatter = ISO8601DateFormatter()
    let log = input.files.pressure.compactMap { entry -> CLIHistory.PressureEntry? in
      guard let at = entry["at"], let date = formatter.date(from: at), inWindow(date) else {
        return nil
      }
      return .init(
        date: date, risk: entry["risk"] ?? "", detail: entry["detail"] ?? "",
        action: entry["action"] ?? "", topProjects: loggedProjects(entry["projects"] ?? ""))
    }.sorted { $0.date < $1.date }
    return CLIHistory(
      generatedAt: input.now, since: start, windowSeconds: Int(input.since),
      tamebarRunning: input.tamebarRunning, notes: input.files.notes, events: events,
      samples: samples, pressureLog: log)
  }

  /// An event with the three apps and the three projects using the most memory at it.
  static func event(_ incident: MemoryIncident) -> CLIHistory.Event {
    let apps = incident.apps.sorted { $0.bytes > $1.bytes }.prefix(3)
      .map { CLIHistory.App(name: $0.name, bytes: $0.bytes) }
    var byProject: [String: UInt64] = [:]
    for group in incident.resources ?? [] {
      guard let project = group.project else { continue }
      byProject[project, default: 0] += group.memoryBytes
    }
    let largestFirst: (CLIHistory.Project, CLIHistory.Project) -> Bool = { left, right in
      left.bytes == right.bytes ? left.name < right.name : left.bytes > right.bytes
    }
    let projects = byProject.map { CLIHistory.Project(name: $0.key, bytes: $0.value) }
      .sorted(by: largestFirst).prefix(3)
    return .init(
      date: incident.date, kind: incident.kind, detail: incident.detail,
      pressure: incident.sample?.pressure.rawValue,
      availableBytes: incident.sample?.available, swapUsedBytes: incident.sample?.swapUsed,
      topApps: Array(apps), topProjects: Array(projects))
  }

  /// `web-frontend: 6 GB; dashboard-app: 2 GB`, as `PressureSentinel` writes it.
  static func loggedProjects(_ text: String) -> [CLIHistory.LoggedProject] {
    text.components(separatedBy: "; ").compactMap { part in
      guard let colon = part.range(of: ": ", options: .backwards) else { return nil }
      let name = String(part[..<colon.lowerBound])
      let memory = String(part[colon.upperBound...])
      return name.isEmpty ? nil : .init(name: name, memory: memory)
    }
  }
}

// MARK: stopped

/// The stores the Stopped list reads from Tamebar's settings, decoded entry by entry as the app
/// decodes them but without its backup of an unreadable value: Ended sessions and the apps quit
/// from the panel. Nil when a store holds something that isn't a list at all.
struct CLIStoppedStores {
  var ended: [EndedSession]? = []
  var quitApps: [QuitApp]? = []
  /// Dev servers ended with their session (Q20).
  var servers: [EndedServer]? = []

  static func read(_ defaults: UserDefaults) -> CLIStoppedStores {
    .init(
      ended: list(defaults, EndedSessionLog.defaultsKey),
      quitApps: list(defaults, QuitAppLog.defaultsKey),
      servers: list(defaults, EndedServerLog.defaultsKey))
  }

  static func list<Element: Decodable>(_ defaults: UserDefaults, _ key: String) -> [Element]? {
    guard let data = defaults.data(forKey: key) else { return [] }
    guard let entries = try? JSONDecoder().decode([Lossy<Element>].self, from: data) else {
      return nil
    }
    return entries.compactMap(\.value)
  }
}

struct CLIStopped: Encodable {
  let schema = CLIReport.schema
  let command = "stopped"
  let generatedAt: Date
  let tamebarRunning: Bool
  /// Files or settings that couldn't be read.
  let notes: [String]
  let total: Int
  /// What needs a command first (apps, then ended sessions), then what comes back on its own.
  let stopped: [Entry]

  struct Entry: Encodable, Equatable {
    let id: String
    /// `session`, `project`, `app`, `server` or `codex plugin`.
    let kind: String
    /// The project for a session or a project, the app's name for an app.
    let name: String
    @CLINullable var tool: String?
    @CLINullable var toolName: String?
    @CLINullable var directory: String?
    @CLINullable var sessionId: String?
    @CLINullable var bundleId: String?
    let stoppedAt: Date
    /// `paused`, `ended`, `quit` or `off`.
    let state: String
    /// `memory`, `call`, `heat`, `idle` or `unused` (with `idle_days`), or `by_you`.
    let reason: String
    @CLINullable var idleDays: Int?
    @CLINullable var memoryBytes: UInt64?
    /// The command that brings it back; null for what comes back on its own.
    @CLINullable var resumeCommand: String?
  }
}

extension CLIReport {
  struct StoppedInput {
    let scan: CLISessionScan
    let state: CLIState
    let stores: CLIStoppedStores
    let running: [String: Date?]
    let tamebarRunning: Bool
    let now: Date
    let label: (String) -> String?
  }

  static func stopped(_ input: StoppedInput) -> CLIStopped {
    var notes = input.state.notes
    if input.stores.ended == nil { notes.append("Ended sessions are unreadable") }
    if input.stores.quitApps == nil { notes.append("Apps quit from Tamebar are unreadable") }
    if input.stores.servers == nil { notes.append("Dev servers ended by Tamebar are unreadable") }
    var log = StoppedLog.Input(now: input.now)
    log.ledger = input.state.autopause?.state.ledger ?? []
    log.threads = input.scan.threads
    log.label = input.label
    log.ended = input.stores.ended ?? []
    log.appLedger = input.state.autopause?.apps.ledger ?? []
    log.quitApps = input.stores.quitApps ?? []
    log.running = input.running
    log.servers = input.stores.servers ?? []
    log.codexPlugins = input.state.codexTrim?.off ?? []
    let entries = StoppedLog.commandOrder(StoppedLog.entries(log)).map(stoppedEntry)
    return CLIStopped(
      generatedAt: input.now, tamebarRunning: input.tamebarRunning, notes: notes,
      total: entries.count, stopped: entries)
  }

  static func stoppedEntry(_ entry: StoppedEntry) -> CLIStopped.Entry {
    var idleDays: Int?
    if case .idle(let days) = entry.reason { idleDays = days }
    if case .unused(let days) = entry.reason { idleDays = days }
    return .init(
      id: entry.id, kind: entry.kind.rawValue, name: entry.name,
      tool: entry.tool.map(toolKey), toolName: entry.tool?.title, directory: entry.directory,
      sessionId: entry.sessionID, bundleId: entry.bundleID, stoppedAt: entry.stoppedAt,
      state: entry.state.rawValue, reason: entry.reason.key, idleDays: idleDays,
      memoryBytes: entry.memoryBytes, resumeCommand: entry.command)
  }
}
