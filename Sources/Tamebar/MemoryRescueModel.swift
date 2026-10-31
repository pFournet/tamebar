import AppKit
import Foundation

@MainActor
final class MemoryRescueModel: NSObject, ObservableObject {
  @Published private(set) var pressure: MemoryPressureLevel
  @Published private(set) var risk = MemoryRisk.normal
  @Published private(set) var capacity = PressureAssessment.checking
  @Published private(set) var apps: [MemoryApp] = []
  @Published private(set) var sample: MemoryGuardSample?
  @Published private(set) var isRefreshing = false
  private var refreshRequested = false
  @Published private(set) var statusMessage: String?
  @Published private(set) var scannedAt: Date?
  @Published private(set) var incidents: [MemoryIncident] = []

  let historyURL = AppData.file("memory-history.json")
  private let appProvider = MemoryAppProvider()
  private let scanner = NativeProcessMemoryScanner()
  private var timer: Timer?
  private var pressureSource: DispatchSourceMemoryPressure?
  private var evaluator = MemoryRiskEvaluator()
  private var policies: [String: MemoryAppPolicy] = [:]
  private var history = MemoryIncidentHistory()
  private var lastRecordedAt = Date.distantPast
  private var isSaving = false
  private var needsSave = false
  private var hasUnsavedHistory = false
  private var lastSavedAt = Date.distantPast
  /// Rewriting the history costs a full JSON encode, so routine samples batch into one write a minute.
  private static let saveInterval: TimeInterval = 60
  private lazy var store = MemoryIncidentStore(url: historyURL)
  /// The e2e build persists too, into its own `Tamebar-e2e` folder.
  private var persists: Bool { AppBrand.isInstalledBuild }

  override init() {
    pressure = MemoryPressureReader().current()
    policies =
      SavedSettings.dictionary(.init(key: MemoryAppPolicy.storageKey, defaults: .standard)) ?? [:]
    super.init()
    NotificationCenter.default.addObserver(
      self, selector: #selector(persistHistoryNow),
      name: NSApplication.willTerminateNotification, object: nil)
    Task { [weak self] in await self?.start() }
  }

  private func start() async {
    if persists { history = await store.load() }
    record(
      .init(
        kind: "started", detail: "Monitoring started; app exits do not establish a crash or OOM"))
    sampleMemory(event: nil)
    refresh()
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical], queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self, let source = self.pressureSource else { return }
        let level: MemoryPressureLevel =
          source.data.contains(.critical)
          ? .critical
          : source.data.contains(.warning) ? .warning : .normal
        self.sampleMemory(event: level)
        if !self.isRefreshing { self.refresh() }
      }
    }
    pressureSource = source
    source.resume()
    timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.sampleMemory(event: nil)
        self.persistHistoryIfDue(urgent: false)
        let interval: TimeInterval = NSApp.isActive ? 15 : 30
        if !self.isRefreshing,
          self.scannedAt.map({ Date.now.timeIntervalSince($0) >= interval }) ?? true
        {
          self.refresh()
        }
      }
    }
    if let timer { RunLoop.main.add(timer, forMode: .common) }
  }

  func refresh() {
    guard !isRefreshing else {
      refreshRequested = true
      return
    }
    isRefreshing = true
    let descriptors = appProvider.descriptors()
    let scanner = scanner
    Task { [weak self] in
      let scanned = await Task.detached(priority: .utility) { scanner.scan(descriptors) }.value
      guard let self else { return }
      let previousApps = apps
      apps = scanned
      for previous in previousApps where previous.protectionReason != nil {
        if !scanned.contains(where: { $0.id == previous.id && $0.launchDate == previous.launchDate }
        ) {
          record(
            .init(
              kind: "app-exit", detail: "\(previous.name) exited or restarted; cause unconfirmed"))
        }
      }
      scannedAt = .now
      isRefreshing = false
      if refreshRequested {
        refreshRequested = false
        refresh()
      }
    }
  }

  private func sampleMemory(event: MemoryPressureLevel?) {
    pressure = event ?? MemoryPressureReader().current()
    guard let next = MemoryGuardSample.read(pressure: pressure) else {
      statusMessage = "Memory readings unavailable; the last reading may be stale"
      return
    }
    sample = next
    let previousRisk = risk
    risk = evaluator.evaluate(next)
    capacity = ResourceSnapshotCache.pressure
    if risk != previousRisk {
      record(.init(kind: "pressure", detail: risk.title))
    } else if next.date.timeIntervalSince(lastRecordedAt) >= 60 {
      record(.init(kind: "sample", detail: risk.title))
    }
  }

  func recordShutdown() {
    record(.init(kind: "stopped", detail: "\(AppBrand.name) stopped normally"))
  }

  private struct RecordInput {
    let kind: String
    let detail: String
  }

  private func record(_ input: RecordInput) {
    let event = MemoryIncident(
      id: UUID(), date: .now, kind: input.kind, detail: input.detail, sample: sample,
      apps: apps.prefix(8).map { app in
        MemoryIncident.App(
          name: app.name, bytes: app.memoryBytes,
          protected: app.protectionReason != nil || policies[app.policyKey] == .keepRunning
            || app.isActive
        )
      }, resources: ResourceSnapshotCache.recentGroups
    )
    history.append(event)
    incidents = history.events.reversed().filter { $0.kind != "sample" }
    lastRecordedAt = event.date
    hasUnsavedHistory = true
    persistHistoryIfDue(urgent: input.kind == "pressure" && risk >= .critical)
  }

  private func persistHistoryIfDue(urgent: Bool) {
    guard hasUnsavedHistory,
      urgent || Date.now.timeIntervalSince(lastSavedAt) >= Self.saveInterval
    else { return }
    persistHistory()
  }

  @objc private func persistHistoryNow() {
    guard persists, hasUnsavedHistory else { return }
    hasUnsavedHistory = false
    try? MemoryIncidentStore.write(.init(history: history, url: historyURL))
  }

  private func persistHistory() {
    guard persists else { return }
    hasUnsavedHistory = false
    lastSavedAt = .now
    needsSave = true
    guard !isSaving else { return }
    isSaving = true
    Task { [weak self] in
      guard let self else { return }
      while needsSave {
        needsSave = false
        do {
          try await store.save(history)
          if statusMessage?.hasPrefix("Could not save memory history:") == true {
            statusMessage = nil
          }
        } catch {
          statusMessage = "Could not save memory history: \(error.localizedDescription)"
        }
      }
      isSaving = false
    }
  }
}
