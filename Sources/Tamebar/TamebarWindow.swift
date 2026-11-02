import AppKit
import SwiftUI

// N11 (2026-10-30: "we should threat it as a bg app who manage the usage"): Tamebar has no
// Dock icon, and one small window with two tabs, opened from the card's Open › and Activity links.
//
//   [ Activity | Settings ]
//   Activity: current slowed, paused and optional recovery items, then the 7-day trend (Q16)
//   Settings: automatic actions and the apps list (Q10, Q11, Q17), Show Tamebar in (N9),
//             meetings (M1), launch at login, updates, Quit (N10)

/// The window's two tabs.
enum WindowTab: String, CaseIterable, Identifiable {
  case activity = "Activity"
  case settings = "Settings"
  var id: Self { self }
}

/// Which tab the window shows, and the way to open it from anywhere: the card, the menu-bar item,
/// a relaunch. The tab isn't saved: a launch starts on Activity.
@MainActor final class WindowNavigation: ObservableObject {
  @Published var tab: WindowTab = .activity

  /// Opens the window, on `tab` when given, with Tamebar in front.
  func open(_ tab: WindowTab? = nil) {
    if let tab { self.tab = tab }
    NotificationCenter.default.post(name: .openTamebarWindow, object: nil)
  }
}

extension Notification.Name {
  /// Opens Tamebar's window (`MenuBarRouter`, which holds SwiftUI's `openWindow`).
  static let openTamebarWindow = Notification.Name("Tamebar.openWindow")
}

@MainActor
extension OpenWindowAction {
  /// Opens the window and brings it to the front. Tamebar is an accessory app (no Dock icon), so
  /// it is activated explicitly and its window ordered front over the app in use.
  func tamebarWindow() {
    callAsFunction(id: TamebarWindowView.id)
    NSApp.activate(ignoringOtherApps: true)
    Task { @MainActor in
      for window in NSApp.windows where window.identifier?.rawValue == TamebarWindowView.id {
        window.makeKeyAndOrderFront(nil)
      }
    }
  }
}

/// What Settings needs beyond the process model.
struct WindowServices {
  let permissions: PermissionsModel
  let launchAtLogin: LaunchAtLoginController
  let updates: AppUpdateController
}

/// The window: a segmented Activity | Settings in the toolbar, the tab below.
struct TamebarWindowView: View {
  static let id = "tamebar"
  static let size = CGSize(width: 520, height: 600)

  @ObservedObject var navigation: WindowNavigation
  @ObservedObject var processes: DevProcessModel
  let services: WindowServices

  var body: some View {
    Group {
      switch navigation.tab {
      case .activity: ActivityTab(processes: processes)
      case .settings:
        SettingsTab(
          processes: processes, permissions: services.permissions,
          launchAtLogin: services.launchAtLogin, updates: services.updates)
      }
    }
    .frame(
      minWidth: 460, idealWidth: Self.size.width, maxWidth: .infinity, minHeight: 420,
      idealHeight: Self.size.height, maxHeight: .infinity, alignment: .top
    )
    .background(BlitzUI.canvasBackground)
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("View", selection: $navigation.tab) {
          ForEach(WindowTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
      }
    }
    .navigationTitle(AppBrand.name)
    .blitzTheme()
  }
}

/// Activity: what Tamebar is affecting now, then the last 7 days under pressure.
struct ActivityTab: View {
  @ObservedObject var processes: DevProcessModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        CurrentActivityView(
          entries: processes.stopped, slowed: processes.slowedNow,
          busy: Set(processes.bringingBack.keys),
          bringBack: { processes.bringBack($0) }, bringBackAll: { processes.resumeAutoPaused() })
        UsageTrendCard(data: processes.usageTrend)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(WindowMetrics.padding)
    }
  }
}

enum WindowMetrics {
  /// The small window's margin.
  static let padding: CGFloat = 20
}

/// Settings: the automatic actions and the apps list, where Tamebar shows, meetings, launch at
/// login, updates, then Quit and the about line.
struct SettingsTab: View {
  @ObservedObject var processes: DevProcessModel
  @ObservedObject var permissions: PermissionsModel
  @ObservedObject var launchAtLogin: LaunchAtLoginController
  @ObservedObject var updates: AppUpdateController

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        AutomaticActionsSection(processes: processes)
        VStack(alignment: .leading, spacing: 12) {
          Text("Show Tamebar in").font(BlitzType.section)
          ShowTamebarInControls()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard(padding: 16)
        MeetingsSection(permissions: permissions)
        Toggle(
          "Launch at login",
          isOn: Binding(get: { launchAtLogin.enabled }, set: { launchAtLogin.setEnabled($0) })
        )
        .panelCard(padding: 16)
        SettingsUpdatesSection(updates: updates)
        VStack(alignment: .leading, spacing: 12) {
          SettingsQuitRow()
          SettingsAboutFooter()
        }
      }
      .font(BlitzType.callout).toggleStyle(BlitzSwitchStyle())
      .frame(maxWidth: .infinity, alignment: .leading).padding(WindowMetrics.padding)
    }
  }
}

/// Updates: the state in words and Check, and the automatic checks switch when updates work.
struct SettingsUpdatesSection: View {
  @ObservedObject var updates: AppUpdateController

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 16) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Updates").font(BlitzType.section)
          Text(updates.detail).font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        HStack(spacing: 8) {
          if updates.status == .checking || updates.isWaitingForUpdater {
            ProgressView().controlSize(.small)
          }
          Button(updates.actionTitle) { updates.check() }
            .blitzButton(updates.version == nil ? .secondary : .accent).controlSize(.small)
            .disabled(!updates.canCheck)
        }
      }
      if updates.isAvailable {
        Toggle(
          "Check for updates automatically",
          isOn: Binding(get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
      }
    }.panelCard(padding: 16)
  }
}

/// Quit Tamebar at the bottom of Settings (N10): `AppLifetime.stopMonitoringAndQuit`, so Tamebar
/// can be quit with the menu bar off (N9).
struct SettingsQuitRow: View {
  static let title = "Quit \(AppBrand.name)"
  static let caption = "Closing the window or pressing ⌘Q keeps monitoring."

  var body: some View {
    HStack(spacing: 10) {
      Button(Self.title) { AppLifetime.stopMonitoringAndQuit() }
        .blitzButton(.secondary).controlSize(.small).fixedSize()
      Text(Self.caption).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
    }
  }
}

/// The last line of Settings: the version, the BlitzClean credit, and the bundled MIT notice.
struct SettingsAboutFooter: View {
  var license: URL? = AppBrand.licenseURL()

  var body: some View {
    HStack(spacing: 6) {
      Text(AppBrand.aboutCaption)
        .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      if let license {
        Link("License", destination: license).buttonStyle(.plain)
          .font(BlitzType.caption).underline().foregroundStyle(BlitzUI.supportingText)
          .blitzPointingHand()
      }
    }
  }
}
