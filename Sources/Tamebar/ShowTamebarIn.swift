import AppKit
import SwiftUI

/// A saved choice from the old "Show in menu bar" switches that something still reads. N9 replaced
/// the switches with Show Tamebar in (`ShowSurfaces`); this keeps a value saved before it, with no
/// switch now: Status colors, the item's warning symbol in its color.
enum MenuBarPreferenceKey {
  static let showHealth = "menuBar.showHealth"
}

/// Free memory as the card says it: "6 GB free", "—" before the first reading.
enum MemoryFreeText {
  static func make(_ snapshot: SystemSnapshot) -> String {
    guard snapshot.ramTotal > 0 else { return "—" }
    return ByteText.compact(min(snapshot.ramAvailable, snapshot.ramTotal)) + " free"
  }
}

/// Settings → Show Tamebar in (N9, approved as mocked): the notch (the wings and the hover card)
/// and the menu bar (the icon, the state and its card). At least one stays on; with no notch
/// screen connected the Notch row is greyed out and the menu bar shows. Both switch live.
struct ShowTamebarInControls: View {
  @AppStorage(ShowSurfaces.Key.notch) private var notch = true
  @AppStorage(ShowSurfaces.Key.menuBar) private var menuBar = true
  @State private var notchScreen: Bool
  private let fixedScreens: Bool

  /// `notchScreen` fixes whether a notch screen is connected (the renders); nil reads the screens,
  /// again on every display change.
  init(notchScreen: Bool? = nil) {
    _notchScreen = State(
      initialValue: notchScreen ?? (NotchGeometry.notchedScreen(in: NotchGeometry.screens()) != nil)
    )
    fixedScreens = notchScreen != nil
  }

  var body: some View {
    let surfaces = ShowSurfaces(notch: notch, menuBar: menuBar)
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 0) {
        row("Notch", detail: "wings and hover card", surfaces.notchRow(notchScreen: notchScreen)) {
          notch = $0
        }
        row(
          "Menu bar", detail: "icon, state and card",
          surfaces.menuBarRow(notchScreen: notchScreen)
        ) { menuBar = $0 }
      }
      if !notchScreen {
        Text(ShowSurfaces.noNotchHelp).font(BlitzType.caption)
          .foregroundStyle(BlitzUI.secondaryText)
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: NSApplication.didChangeScreenParametersNotification)
    ) { _ in
      guard !fixedScreens else { return }
      notchScreen = NotchGeometry.notchedScreen(in: NotchGeometry.screens()) != nil
    }
  }

  private func row(
    _ title: String, detail: String, _ row: ShowSurfaces.Row, set: @escaping (Bool) -> Void
  ) -> some View {
    Toggle(isOn: Binding(get: { row.isOn }, set: set)) {
      HStack(spacing: 0) {
        Text(title).font(BlitzType.body).foregroundStyle(BlitzUI.primaryText)
          .frame(width: 84, alignment: .leading)
        Text(detail).font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
      }
    }
    .toggleStyle(BlitzCheckboxStyle())
    .disabled(!row.enabled)
    .help(row.help ?? "")
  }
}
