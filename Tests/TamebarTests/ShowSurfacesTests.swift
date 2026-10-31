import Foundation
import Testing

@testable import Tamebar

/// N9: Settings → Show Tamebar in. Which surfaces show, and how the two rows read.
struct ShowSurfacesTests {
  @Test func bothAreOnByDefault() {
    let defaults = TestDefaults("show-surfaces").defaults
    #expect(ShowSurfaces.load(defaults) == .init(notch: true, menuBar: true))
    defaults.set(false, forKey: ShowSurfaces.Key.notch)
    #expect(ShowSurfaces.load(defaults) == .init(notch: false, menuBar: true))
    defaults.set(true, forKey: ShowSurfaces.Key.notch)
    defaults.set(false, forKey: ShowSurfaces.Key.menuBar)
    #expect(ShowSurfaces.load(defaults) == .init(notch: true, menuBar: false))
  }

  @Test func whatShowsWithANotchScreen() {
    #expect(
      ShowSurfaces(notch: true, menuBar: true).shown(notchScreen: true)
        == .init(notch: true, menuBar: true))
    #expect(
      ShowSurfaces(notch: false, menuBar: true).shown(notchScreen: true)
        == .init(notch: false, menuBar: true))
    #expect(
      ShowSurfaces(notch: true, menuBar: false).shown(notchScreen: true)
        == .init(notch: true, menuBar: false))
    #expect(
      ShowSurfaces(notch: false, menuBar: false).shown(notchScreen: true)
        == .init(notch: false, menuBar: true), "never nowhere")
  }

  @Test func withNoNotchScreenTheMenuBarShows() {
    for notch in [true, false] {
      for menuBar in [true, false] {
        #expect(
          ShowSurfaces(notch: notch, menuBar: menuBar).shown(notchScreen: false)
            == .init(notch: false, menuBar: true))
      }
    }
  }

  @Test func theLastOneOnIsGreyedOut() {
    let both = ShowSurfaces(notch: true, menuBar: true)
    #expect(both.notchRow(notchScreen: true) == .init(isOn: true, enabled: true, help: nil))
    #expect(both.menuBarRow(notchScreen: true) == .init(isOn: true, enabled: true, help: nil))

    let notchOnly = ShowSurfaces(notch: true, menuBar: false)
    #expect(!notchOnly.notchRow(notchScreen: true).enabled)
    #expect(notchOnly.notchRow(notchScreen: true).help == ShowSurfaces.lastOneHelp)
    #expect(notchOnly.menuBarRow(notchScreen: true) == .init(isOn: false, enabled: true, help: nil))

    let menuOnly = ShowSurfaces(notch: false, menuBar: true)
    #expect(menuOnly.notchRow(notchScreen: true) == .init(isOn: false, enabled: true, help: nil))
    #expect(
      menuOnly.menuBarRow(notchScreen: true)
        == .init(isOn: true, enabled: false, help: ShowSurfaces.lastOneHelp))
  }

  @Test func withNoNotchScreenTheNotchIsGreyedAndTheMenuBarOn() {
    for stored in [
      ShowSurfaces(notch: true, menuBar: true), .init(notch: true, menuBar: false),
      .init(notch: false, menuBar: true),
    ] {
      let notch = stored.notchRow(notchScreen: false)
      #expect(notch == .init(isOn: stored.notch, enabled: false, help: ShowSurfaces.noNotchHelp))
      let menuBar = stored.menuBarRow(notchScreen: false)
      #expect(menuBar == .init(isOn: true, enabled: false, help: ShowSurfaces.noNotchHelp))
    }
  }

  /// N10: Quit Tamebar at the bottom of Settings, so quitting never needs the menu bar on.
  @Test func quittingIsInSettingsWithoutTheMenuBar() {
    #expect(SettingsQuitRow.title == "Quit Tamebar")
    #expect(SettingsQuitRow.caption == "Closing the window or pressing ⌘Q keeps monitoring.")
    #expect(!SettingsQuitRow.caption.localizedCaseInsensitiveContains("menu bar"))
  }
}
