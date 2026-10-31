import AppKit
import Foundation
import os

/// The glue between the model and `AppPressurePlanner` (Q11, Task 5.5). The planner runs inside
/// `AutoPauseController.run`, so its ledger lives in `autopause.json` and only the lock holder
/// acts.
enum AppPressureWiring {
  /// What a scan brings the app planner.
  struct Scan {
    /// Running apps Tamebar may act on: in e2e mode, only those in a target's tree.
    var apps: [AppPressurePlanner.App] = []
    /// Every running bundle id, to see the user reopen a ledger app.
    var running: Set<String> = []
    var list = AppQuitList()
    var selfBundleID: String? = Bundle.main.bundleIdentifier
  }

  /// How the controller quits and reopens: the live paths in the app, a recorder in tests.
  /// `inert` is the default, so nothing built without the live actions can end an app.
  struct Actions {
    /// Asks the app to quit, the normal way (`PoliteAppQuit`). Nil when the request wasn't sent
    /// (the app changed, or e2e mode refuses it); the task answers whether it ended within
    /// `AppPressurePlanner.quitTimeout`. Never forced.
    var quit: @MainActor (AppPressurePlanner.App) -> Task<Bool, Never>?
    /// Reopens a ledger app in the background, without taking focus; the task answers how it
    /// ended.
    var reopen:
      @MainActor (AppPressurePlanner.Entry) -> Task<AppPressurePlanner.ReopenResult, Never>
    /// On the way out: hands the app to `/usr/bin/open -g -b <bundle id>`, detached and not waited
    /// on, so the reopen outlives Tamebar. True when it was started.
    var openOnQuit: @MainActor (AppPressurePlanner.Entry) -> Bool

    static let inert = Actions(
      quit: { _ in nil }, reopen: { _ in Task { .opened } }, openOnQuit: { _ in false })
  }

  /// The line a reopen that kept failing leaves for the island.
  static func reopenFailedNote(_ entry: AppPressurePlanner.Entry) -> String {
    "Couldn't reopen \(entry.name)"
  }

  /// A quit that ended its app, for the note.
  struct QuitApp: Equatable, Sendable {
    let name: String
    let memoryBytes: UInt64
  }

  /// The brief line a quit leaves for the island. A reopen leaves none.
  static func note(_ quit: QuitApp) -> String {
    "Quit \(quit.name) · \(ByteText.full(quit.memoryBytes)) · reopens later"
  }

  /// What the probes say. The e2e control stands in for the front app ("" for none) and names
  /// the apps known to hold neither the microphone nor the camera; the shipped app reads
  /// `CallSignals` instead.
  struct Probes {
    var frontmost: String?
    /// From the e2e control: apps that hold neither.
    var micCameraFree: Set<String> = []
    /// `CallSignals`, in the shipped app only. Nil (no probe, or a read that failed) leaves
    /// every app unknown, so held, unless the e2e control frees it.
    var calls: CallReading?

    /// The e2e control when there is one, the real front app and the call probe otherwise. The
    /// e2e build never reads a real probe.
    static func live(control: E2EMode.Control?, frontmost: String?, calls: CallReading?)
      -> Probes
    {
      guard let control else { return .init(frontmost: frontmost, calls: calls) }
      return .init(
        frontmost: control.frontmost ?? frontmost, micCameraFree: Set(control.micCameraFree ?? []))
    }

    /// Each app's answer, by bundle id: false free, true held, nil unknown (counts as held).
    /// A camera in use, or a recording no running app owns, holds every app.
    func usesMicOrCamera(running: [Running], parents: [Int32: Int32]) -> (String) -> Bool? {
      guard let calls else { return { micCameraFree.contains($0) ? false : nil } }
      let apps = running.filter { !$0.isTerminated }.compactMap { app in
        app.bundleID.map { CallReading.App(processID: app.processID, bundleID: $0) }
      }
      guard let holders = calls.holders(apps, parents: parents) else { return { _ in nil } }
      return { holders.contains($0) }
    }
  }

  struct Running {
    let bundleID: String?
    let name: String?
    let processID: Int32
    let launchDate: Date?
    let bundleURL: URL?
    let isTerminated: Bool
    let prohibited: Bool
  }

  struct ScanInput {
    let running: [Running]
    let list: AppQuitList
    /// Memory by PID: each app row's total, keyed by every PID of the row.
    let memory: [Int32: UInt64]
    let probes: Probes
    /// Policy keys (bundle id, else bundle path) the user set to Keep running.
    var keepRunning: Set<String> = []
    /// The e2e targets; nil outside e2e mode.
    let scope: Set<Int32>?
    /// Parents by PID: for the e2e scope, and to tie a recording process to its app.
    let parents: [Int32: Int32]
    let selfBundleID: String?
    let selfProcessID: Int32
    /// AI apps quiet long enough to quit (Q17.3, `AppCPUWatch.isQuiet`). An AI app missing from
    /// it is never quit.
    var quietAIApps: Set<String> = []
  }

  /// The planner's view of the running apps. Mic and camera use comes from `probes`; without
  /// a probe (tests, a debug run) every app counts as in use and nothing is quit.
  static func scan(_ input: ScanInput) -> Scan {
    var scan = Scan(list: input.list, selfBundleID: input.selfBundleID)
    let usesMicOrCamera = input.probes.usesMicOrCamera(
      running: input.running, parents: input.parents)
    for app in input.running where !app.isTerminated && !app.prohibited {
      guard let bundleID = app.bundleID, let url = app.bundleURL else { continue }
      scan.running.insert(bundleID)
      if let scope = input.scope {
        guard
          E2EMode.allows(.init(processID: app.processID, targets: scope, parents: input.parents))
        else { continue }
      }
      // ChatGPT and Claude are no longer kept open as AI apps: once listed, Q17.3's quiet rule
      // stands in for that protection. Tamebar, macOS's apps and terminals still are.
      let protected =
        MemoryAppProtection.reason(
          .init(
            processID: app.processID, bundleIdentifier: bundleID, bundlePath: url.path,
            currentProcessID: input.selfProcessID, currentBundleIdentifier: input.selfBundleID))
        != nil && !AppSlow.isAIApp(bundleID)
      scan.apps.append(
        .init(
          bundleID: bundleID, name: app.name ?? url.deletingPathExtension().lastPathComponent,
          processID: app.processID, launchDate: app.launchDate, bundleURL: url,
          memoryBytes: input.memory[app.processID] ?? 0,
          isFrontmost: input.probes.frontmost == bundleID,
          usesMicOrCamera: usesMicOrCamera(bundleID),
          isProtected: protected,
          keepRunning: input.keepRunning.contains(bundleID)
            || input.keepRunning.contains(url.path),
          quiet: !AppSlow.isAIApp(bundleID) || input.quietAIApps.contains(bundleID)))
    }
    return scan
  }

  fileprivate static let log = Logger(subsystem: AppBrand.bundleIdentifier, category: "autopause")
}

extension AppPressureWiring.Actions {
  private static var log: Logger { AppPressureWiring.log }

  /// The app's own paths: the polite quit, and a background reopen.
  @MainActor static let live = Self(
    quit: { app in
      guard
        let running = PoliteAppQuit.running(
          .init(processID: app.processID, launchDate: app.launchDate, bundleURL: app.bundleURL)),
        E2EMode.allowsSignal(to: app.processID), running.terminate()
      else { return nil }
      return Task { @MainActor in
        let deadline = Date.now.addingTimeInterval(AppPressurePlanner.quitTimeout)
        while !running.isTerminated, Date.now < deadline {
          try? await Task.sleep(for: .milliseconds(250))
        }
        return running.isTerminated
      }
    },
    reopen: { entry in
      let url =
        FileManager.default.fileExists(atPath: entry.bundleURL.path)
        ? entry.bundleURL
        : NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID)
      guard let url else {
        log.error("Can't reopen \(entry.bundleID, privacy: .public): not found")
        return Task { .gone }
      }
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = false
      configuration.addsToRecentItems = false
      configuration.promptsUserIfNeeded = false
      return Task {
        await withCheckedContinuation { continuation in
          NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
              log.error(
                "Reopening \(entry.bundleID, privacy: .public) failed: \(error, privacy: .public)")
            }
            continuation.resume(returning: error == nil ? .opened : .failed)
          }
        }
      }
    },
    openOnQuit: { entry in
      AppPressureWiring.spawnDetached(
        "/usr/bin/open",
        AppPressureWiring.openArguments(
          entry, bundleExists: FileManager.default.fileExists(atPath: entry.bundleURL.path)))
    })
}

extension AppPressureWiring {
  /// Starts `tool` in its own process group and doesn't wait for it, so it outlives Tamebar.
  /// It inherits no descriptor of Tamebar's (`POSIX_SPAWN_CLOEXEC_DEFAULT`); 0–2 are /dev/null.
  static func spawnDetached(_ tool: String, _ arguments: [String]) -> Bool {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(
      &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawnattr_setpgroup(&attributes, 0)
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDWR, 0)
    posix_spawn_file_actions_adddup2(&actions, 0, 1)
    posix_spawn_file_actions_adddup2(&actions, 0, 2)
    let argv = ([tool] + arguments).map { strdup($0) } + [nil]
    defer { for argument in argv { free(argument) } }
    var pid: pid_t = 0
    return posix_spawn(&pid, tool, &actions, &attributes, argv, environ) == 0
  }

  /// `open`'s arguments on the way out: by the recorded bundle, so the very app that was quit
  /// comes back, or by bundle id when that bundle is gone. `-g` keeps it in the background.
  static func openArguments(_ entry: AppPressurePlanner.Entry, bundleExists: Bool) -> [String] {
    bundleExists ? ["-g", entry.bundleURL.path] : ["-g", "-b", entry.bundleID]
  }

  /// The bundle ids an `autopause.json` names in its app ledger, for the log when it can't be
  /// read as a whole.
  static func ledgerBundleIDs(_ data: Data) -> [String] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let apps = json["apps"] as? [String: Any], let ledger = apps["ledger"] as? [Any]
    else { return [] }
    return ledger.compactMap { ($0 as? [String: Any])?["bundleID"] as? String }
  }
}

/// The polite Quit every app row uses: the app is still the instance that was scanned, then it is
/// asked to quit (`NSRunningApplication.terminate`). Never `forceTerminate`.
enum PoliteAppQuit {
  struct Expected {
    let processID: Int32
    let launchDate: Date?
    let bundleURL: URL
  }

  /// The running app, only while it is still the scanned instance.
  @MainActor static func running(_ expected: Expected) -> NSRunningApplication? {
    guard let app = NSRunningApplication(processIdentifier: expected.processID),
      app.launchDate == expected.launchDate, app.bundleURL == expected.bundleURL
    else { return nil }
    return app
  }
}
