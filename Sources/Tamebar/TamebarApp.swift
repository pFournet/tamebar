import AppKit
import SwiftUI

struct TamebarApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var monitor: SystemMonitor
  @StateObject private var launchAtLogin = LaunchAtLoginController()
  @StateObject private var memoryRescue: MemoryRescueModel
  @StateObject private var permissions = PermissionsModel()
  @StateObject private var devProcesses: DevProcessModel
  @StateObject private var navigation: WindowNavigation
  /// The notch island and the menu-bar state (N1–N5), over the same models as the window.
  @StateObject private var island: IslandController
  /// The menu-bar item (N7): Tamebar's icon and the island's state, and the usage card under it.
  @StateObject private var menuBar: MenuBarItemController

  init() {
    let monitor = SystemMonitor()
    let memory = MemoryRescueModel()
    let processes = DevProcessModel()
    let navigation = WindowNavigation()
    let agents = AskAgents()
    let island = IslandController(
      monitor: monitor, memory: memory, navigation: navigation, processes: processes,
      agents: agents)
    let menuBar = MenuBarItemController(island: island)
    _monitor = StateObject(wrappedValue: monitor)
    _memoryRescue = StateObject(wrappedValue: memory)
    _devProcesses = StateObject(wrappedValue: processes)
    _navigation = StateObject(wrappedValue: navigation)
    _island = StateObject(wrappedValue: island)
    _menuBar = StateObject(wrappedValue: menuBar)
    // The status item goes in once AppKit has launched.
    AppDelegate.didLaunch = { _ in
      // Which of Claude and Codex the card's Ask row offers (N8), read once off the main thread.
      agents.start()
      menuBar.install()
    }
  }

  var body: some Scene {
    // N11: one small window, Activity | Settings. Tamebar is an accessory app (`LSUIElement`):
    // no Dock icon, and closing the window leaves it running in the notch and the menu bar.
    Window(AppBrand.name, id: TamebarWindowView.id) {
      TamebarWindowView(
        navigation: navigation, processes: devProcesses,
        services: .init(
          permissions: permissions, launchAtLogin: launchAtLogin, updates: appDelegate.updates)
      )
      .task {
        monitor.refresh()
        memoryRescue.refresh()
      }
    }
    .windowToolbarStyle(.unified(showsTitle: false))
    .windowResizability(.contentMinSize)
    .defaultSize(TamebarWindowView.size)
    .opensOnlyOnRequest()
    .commands {
      CommandGroup(replacing: .sidebar) {}
      CommandGroup(replacing: .appTermination) {
        Button("Close window") { NSApp.terminate(nil) }.keyboardShortcut("q")
      }
      CommandGroup(replacing: .newItem) {}
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") { navigation.open(.settings) }.keyboardShortcut(",")
      }
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let updates = AppUpdateController()
  /// Run once AppKit has finished launching: the app puts its menu-bar item in.
  static var didLaunch: ((AppDelegate) -> Void)?

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard
      AppQuitPolicy.keepsMonitoring(
        .init(
          explicitStop: AppLifetime.explicitStop,
          event: NSAppleEventManager.shared().currentAppleEvent))
    else { return .terminateNow }
    AppLifetime.closeWindows(sender)
    return .terminateCancel
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    NotificationCenter.default.post(name: .openTamebarWindow, object: nil)
    return true
  }

  func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool {
    false
  }

  func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool {
    false
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // `LSUIElement` makes the installed app an accessory; a bare `swift run` binary has no
    // Info.plist, so it is set here too: no Dock icon either way.
    NSApp.setActivationPolicy(.accessory)
    Self.didLaunch?(self)
    updates.start()
    EmergencyControlsLauncher.start()
  }
}

extension Scene {
  fileprivate func opensOnlyOnRequest() -> some Scene {
    if #available(macOS 15.0, *) {
      return SceneBuilder.buildOptional(
        SceneBuilder.buildLimitedAvailability(
          defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)))
    } else {
      return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(self))
    }
  }
}

/// Whether a launch opens the window: a launch by hand does; a login item or the e2e build passes
/// `--background` and doesn't.
struct InitialWindowRequest {
  private var pending: Bool

  init(_ arguments: [String]) {
    pending = !arguments.contains("--background")
  }

  mutating func consume() -> Bool {
    defer { pending = false }
    return pending
  }
}

@MainActor
enum AppLaunch {
  static var initialWindow = InitialWindowRequest(CommandLine.arguments)
}
