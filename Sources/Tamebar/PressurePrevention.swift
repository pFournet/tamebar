import Darwin
import Foundation

enum PressureLimit: Equatable, Sendable {
  case none, memory, disk, cpu
}

struct PressureAssessment: Equatable, Sendable {
  let risk: MemoryRisk
  let limit: PressureLimit
  let title: String
  let detail: String
  let action: String
  let date: Date
  /// The CPU has been at 90 % or more for 15 s, whatever the bottleneck shown: memory pressure
  /// can hide it from `limit`. Background priority keys on it (Q9, Q12).
  var cpuStrained = false
  /// macOS's thermal state at this reading. Acting on heat keys on it (Q13).
  var thermal: ThermalStatus = .nominal

  /// What automatic pause plans from (Q9, decided 2026-10-20): the risk while memory is the
  /// bottleneck, normal otherwise. Stopping a server under a CPU or disk bottleneck frees
  /// nothing; the CPU has background priority instead.
  var memoryRisk: MemoryRisk { limit == .memory ? risk : .normal }

  struct PublishInput {
    let next: PressureAssessment
    let active: Bool
  }

  /// Each published reading redraws every open view, so in the background only a changed
  /// verdict or a 6-second-old reading is shown. Protection itself still samples every 2 seconds.
  func publishes(_ input: PublishInput) -> Bool {
    input.active || input.next.risk != risk || input.next.limit != limit
      || input.next.title != title || input.next.cpuStrained != cpuStrained
      || input.next.thermal != thermal
      || input.next.date.timeIntervalSince(date) >= 6
  }

  /// The same reading at a risk an e2e test forces; at warning or above, memory is the limit.
  func forcing(_ forced: MemoryRisk) -> PressureAssessment {
    PressureAssessment(
      risk: forced, limit: forced >= .warning ? .memory : limit, title: title, detail: detail,
      action: action, date: date, cpuStrained: cpuStrained, thermal: thermal)
  }

  /// What an e2e test's control forces, each on its own: its memory risk, and CPU strain when
  /// `cpu` is set (then CPU is also the bottleneck at warning if memory isn't), and its thermal
  /// state. A control that forces any of them also hides this Mac's real CPU strain and heat.
  func forcing(_ control: E2EMode.Control) -> PressureAssessment {
    var assessment = control.pressure.map(forcing) ?? self
    if control.pressure != nil || control.cpu != nil || control.thermal != nil {
      assessment.cpuStrained = control.cpu == true
      assessment.thermal = control.thermal ?? .nominal
    }
    if control.cpu == true, assessment.risk < .warning {
      assessment = PressureAssessment(
        risk: .warning, limit: .cpu, title: "CPU is the bottleneck",
        detail: assessment.detail, action: assessment.action, date: assessment.date,
        cpuStrained: true, thermal: assessment.thermal)
    }
    return assessment
  }

  static let checking = Self(
    risk: .normal, limit: .none, title: "Checking capacity",
    detail: "Reading memory, swap, CPU and disk reserve",
    action: "", date: .distantPast)
}

struct PressureEvaluator {
  struct Input {
    let memory: MemoryGuardSample
    let disk: DiskGuardSample
    let cpu: Double?
    var thermal: ThermalStatus = .nominal
  }

  private var memoryEvaluator = MemoryRiskEvaluator()
  private var diskEvaluator = DiskRiskEvaluator()
  private var busySince: Date?

  mutating func evaluate(_ input: Input) -> PressureAssessment {
    let memory = input.memory
    let disk = diskEvaluator.evaluate(input.disk)
    let memoryRisk = memoryEvaluator.evaluate(memory)
    let swap = memory.swapUsed ?? 0
    let gib: UInt64 = 1_024 * 1_024 * 1_024
    if input.cpu.map({ $0 >= 0.9 }) == true {
      if busySince == nil { busySince = memory.date }
    } else {
      busySince = nil
    }
    let cpuStrained = busySince.map { memory.date.timeIntervalSince($0) >= 15 } ?? false
    let swapConstrained =
      swap >= max(8 * gib, memory.total / 3)
      && (memory.compressed >= memory.total / 5 || memory.available < memory.total / 8)
    let bottleneck: (MemoryRisk, PressureLimit, String, String)
    if disk.risk >= .critical && (swapConstrained || memoryRisk >= .warning) {
      bottleneck = (
        .critical, .memory, "Memory and disk under pressure",
        "Avoid starting new threads or builds. Quit unused projects; swap is competing with a low disk reserve."
      )
    } else if memoryRisk >= .warning || swapConstrained {
      bottleneck = (
        max(memoryRisk, .warning), .memory, "Memory is the bottleneck",
        "Avoid starting new threads or builds. Quit an unused project to release RAM; Pause only slows it."
      )
    } else if disk.risk > .normal {
      bottleneck = (
        disk.risk >= .critical ? .critical : .warning, .disk, "Disk reserve is the bottleneck",
        "Avoid large downloads and builds until some disk space is free."
      )
    } else if memoryRisk == .growing {
      bottleneck = (
        .growing, .memory, "Swap activity is rising",
        "Avoid starting new threads or builds while memory moves to swap."
      )
    } else if cpuStrained {
      bottleneck = (
        .warning, .cpu, "CPU is the bottleneck", "Pause unused projects to let active work finish."
      )
    } else {
      bottleneck = (.normal, .none, "Capacity available", "")
    }
    let memoryMetrics =
      "\(ByteText.compact(memory.available)) RAM available · \(ByteText.compact(swap)) swap"
    return PressureAssessment(
      risk: bottleneck.0, limit: bottleneck.1, title: bottleneck.2,
      detail: bottleneck.1 == .disk
        ? "\(disk.detail) · \(memoryMetrics)"
        : "\(memoryMetrics) · \(ByteText.compact(input.disk.available)) disk free",
      action: bottleneck.3,
      date: memory.date, cpuStrained: cpuStrained, thermal: input.thermal)
  }
}

struct ProjectPauseTarget: Sendable {
  let directory: String
  let name: String
  let cpuPercent: Double
  let memoryBytes: UInt64
  var identities: [DevProcessIdentity]
  let capturedAt: Date
  var keepRunning = false
  /// Each pausable process's memory, by PID.
  var processBytes: [Int32: UInt64] = [:]

  var isPaused: Bool { !identities.isEmpty && identities.allSatisfy { $0.process.stopped } }
  /// The memory of the processes a pause would stop: its identities only, so tools and sessions
  /// in the same folder never count.
  var pausableBytes: UInt64 {
    identities.reduce(0) { $0 + (processBytes[$1.process.processID] ?? 0) }
  }
}

enum ProjectPausePolicy {
  static let key = "pressure.autoPauseProjects.v1"

  struct Input {
    let project: WorkspaceProject
    let identities: [Int32: DevProcessIdentity]
    let excludedIDs: Set<Int32>
    let date: Date
  }

  static func target(_ input: Input) -> ProjectPauseTarget? {
    let allowed = input.project.resources.filter {
      !$0.isTool && !input.excludedIDs.contains($0.id)
        && [
          "node", "bun", "deno", "npm", "pnpm", "pnpm-native", "yarn", "next-server", "tsx",
          "ffmpeg", "tsc", "tsgo", "workerd", "esbuild", "python", "python3", "ruby", "java",
          "go", "cargo", "rustc", "swift", "swift-frontend", "clang", "clang++",
        ].contains(
          $0.name)
    }
    let identities = allowed.compactMap { input.identities[$0.id] }.filter {
      !$0.executable.contains(".app/") && $0.process.owner == getuid()
        && $0.process.processID != getpid()
    }
    guard !identities.isEmpty else { return nil }
    return ProjectPauseTarget(
      directory: input.project.directory, name: input.project.preference.name,
      cpuPercent: input.project.cpuPercent, memoryBytes: input.project.memoryBytes,
      identities: identities, capturedAt: input.date,
      keepRunning: input.project.preference.keepRunning,
      processBytes: Dictionary(
        allowed.map { ($0.id, $0.memoryBytes ?? 0) }, uniquingKeysWith: { first, _ in first }))
  }

  struct SignalRequest: Sendable {
    let target: ProjectPauseTarget
    let resume: Bool
  }

  static func signal(_ request: SignalRequest) -> Int {
    let target = request.target
    guard
      request.resume
        || (!target.keepRunning && !WorkspacePreferences.isKeptRunning(target.directory)),
      request.resume || Date.now.timeIntervalSince(target.capturedAt) < 20
    else { return 0 }
    var changed: [DevProcessIdentity] = []
    for expected in target.identities {
      guard let current = DevProcessIdentity.read(expected.process.processID),
        expected.matches(current),
        request.resume ? current.process.stopped : !current.process.stopped
      else { continue }
      if case .sent(let signaled) = ProcessSignal.send(
        .init(expected: expected, signal: request.resume ? SIGCONT : SIGSTOP))
      {
        changed.append(signaled)
      }
    }
    return changed.count
  }

  static func stop(_ target: ProjectPauseTarget) -> Int {
    guard !target.keepRunning, !WorkspacePreferences.isKeptRunning(target.directory),
      Date.now.timeIntervalSince(target.capturedAt) < 20
    else { return 0 }
    var count = 0
    for expected in target.identities
    where ProcessSignal.send(.init(expected: expected, signal: SIGTERM)).wasSent {
      count += 1
    }
    return count
  }

  static func remaining(_ target: ProjectPauseTarget) -> Int {
    target.identities.filter { expected in
      DevProcessIdentity.read(expected.process.processID).map(expected.matches) == true
    }.count
  }
}

struct PressureUpdate: Sendable {
  let assessment: PressureAssessment
  /// Free space on the data volume at this sample, for the low-disk note.
  var diskFree: UInt64? = nil
  /// The memory reading and the CPU (0–1) behind it, for the usage record (Q16).
  var memory: MemoryGuardSample? = nil
  var cpu: Double? = nil
  /// What Q19's strain is judged on, read only by the Tamebar that acts.
  var strain: StrainReading? = nil
  /// An e2e test's control forces the strain on or off.
  var forcedStrain: Bool? = nil
}

/// Samples pressure every 2 seconds and keeps the pressure log. It posts no notification (no
/// banners, 2026-10-27) and pauses nothing itself: opted-in projects pause and resume through
/// `AutoPauseController` with the sessions (D6.4, Task 5.4), and the model logs those actions here.
final class PressureSentinel: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "com.tamebar.Tamebar.pressure", qos: .userInitiated)
  private var timer: DispatchSourceTimer?
  private var evaluator = PressureEvaluator()
  private let metrics = SystemMetricsProvider()
  /// The projects the log lists by memory.
  private var targets: [ProjectPauseTarget] = []
  /// An automatic action the model reported, for the next log entry.
  private var action: String?
  private var lastSaved = Date.distantPast
  private var events: [[String: String]] = []
  /// Saves the pressure log; the e2e build saves into its own folder.
  private let installed = AppBrand.isInstalledBuild
  /// Reads the fans and the strain (Q19); set by `start` in the Tamebar that acts.
  private var readsStrain = false
  private let fan = FanReader()

  deinit { timer?.cancel() }

  /// `strain`: also read the fans and the swap-ins for Q19's strain, in the Tamebar that acts.
  func start(strain: Bool = false, _ receive: @escaping @Sendable (PressureUpdate) -> Void) {
    queue.async { [self] in
      guard timer == nil else { return }
      readsStrain = strain
      if installed {
        let url = AppData.file("pressure-latest.json")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 524_288,
          let data = try? Data(contentsOf: url),
          let saved = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        {
          events = Array(saved.suffix(239))
        }
      }
      let source = DispatchSource.makeTimerSource(queue: queue)
      source.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(200))
      source.setEventHandler { [weak self] in self?.sample(receive) }
      timer = source
      source.resume()
    }
  }

  func update(_ targets: [ProjectPauseTarget]) {
    queue.async { [self] in self.targets = targets }
  }

  /// Records an automatic pause or resume in the next log entry, which is written at once.
  func log(_ action: String) {
    queue.async { [self] in
      self.action = [self.action, action].compactMap { $0 }.joined(separator: "; ")
    }
  }

  func stop() {
    queue.async { [self] in
      timer?.cancel()
      timer = nil
    }
  }

  private func sample(_ receive: @Sendable (PressureUpdate) -> Void) {
    guard let memory = MemoryGuardSample.read(pressure: MemoryPressureReader().current()),
      let disk = DiskGuardSample.read(memory: memory)
    else { return }
    let cpu = metrics.snapshot().cpuUsage
    let thermal = ThermalStatus.current
    var assessment = evaluator.evaluate(
      .init(memory: memory, disk: disk, cpu: cpu, thermal: thermal))
    let control = E2EMode.current?.control()
    if let control {
      assessment = assessment.forcing(control)
    }
    let strain =
      readsStrain
      ? StrainReading(
        date: memory.date, swapIns: memory.swapInPages, pressure: memory.pressure,
        fanPercent: fan.percent(), thermal: thermal) : nil
    let action = self.action
    self.action = nil
    if installed {
      if action != nil || memory.date.timeIntervalSince(lastSaved) >= 60 {
        lastSaved = memory.date
        events.append([
          "at": ISO8601DateFormatter().string(from: memory.date), "risk": assessment.title,
          "detail": assessment.detail, "action": action ?? "",
          "projects": targets.largest(.init(count: 8, key: \.memoryBytes))
            .map { "\($0.name): \(ByteText.compact($0.memoryBytes))" }.joined(separator: "; "),
        ])
        if events.count > 240 { events.removeFirst(events.count - 240) }
        let url = AppData.file("pressure-latest.json")
        try? FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if var data = try? JSONSerialization.data(withJSONObject: events) {
          while data.count > 524_288 && events.count > 1 {
            events.removeFirst(max(1, events.count / 4))
            data = (try? JSONSerialization.data(withJSONObject: events)) ?? Data("[]".utf8)
          }
          try? data.write(to: url, options: .atomic)
          try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
      }
    }
    receive(
      PressureUpdate(
        assessment: assessment, diskFree: disk.available, memory: memory, cpu: cpu,
        strain: strain, forcedStrain: control?.strain))
  }
}
