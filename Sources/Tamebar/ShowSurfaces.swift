import Foundation

/// Where Tamebar shows (N9, 2026-10-29: "I want to activate or desactivate the notch
/// option"): the notch (wings, notes and the hover card) and the menu bar (the icon, the state and
/// its card). Both on by default. Settings → Show Tamebar in keeps at least one on; with no notch
/// screen the notch can't show, so the menu bar does, whatever it is set to.
struct ShowSurfaces: Equatable, Sendable {
  enum Key {
    static let notch = "show.notch"
    static let menuBar = "show.menuBar"
  }

  var notch = true
  var menuBar = true

  static func load(_ defaults: UserDefaults = .standard) -> Self {
    .init(
      notch: defaults.object(forKey: Key.notch) as? Bool ?? true,
      menuBar: defaults.object(forKey: Key.menuBar) as? Bool ?? true)
  }

  /// What shows: the notch only with a notch screen; the menu bar whenever the notch doesn't, so
  /// Tamebar is never nowhere.
  func shown(notchScreen: Bool) -> Self {
    let notch = notch && notchScreen
    return .init(notch: notch, menuBar: menuBar || !notch)
  }

  /// One row of Settings → Show Tamebar in.
  struct Row: Equatable, Sendable {
    let isOn: Bool
    let enabled: Bool
    let help: String?
  }

  static let lastOneHelp = "Tamebar shows in at least one place."
  static let noNotchHelp = "No screen with a notch is connected, so Tamebar shows in the menu bar."

  /// The Notch row: as set, greyed out with no notch screen, and while it is the only place on.
  func notchRow(notchScreen: Bool) -> Row {
    let shown = shown(notchScreen: notchScreen)
    guard notchScreen else { return .init(isOn: notch, enabled: false, help: Self.noNotchHelp) }
    let last = shown.notch && !shown.menuBar
    return .init(isOn: notch, enabled: !last, help: last ? Self.lastOneHelp : nil)
  }

  /// The Menu bar row: as it shows (on, with no notch screen), greyed out while it is the only
  /// place Tamebar shows.
  func menuBarRow(notchScreen: Bool) -> Row {
    let shown = shown(notchScreen: notchScreen)
    let last = shown.menuBar && !shown.notch
    return .init(
      isOn: shown.menuBar, enabled: !last,
      help: last ? (notchScreen ? Self.lastOneHelp : Self.noNotchHelp) : nil)
  }
}
