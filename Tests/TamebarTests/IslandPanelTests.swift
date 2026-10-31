import AppKit
import Testing

@testable import Tamebar

/// The island's window (N3, Task 9.3): never in a shared screen, above the menu bar on every
/// Space and beside full-screen apps, and never the key or main window. None at all without a
/// notched screen.
@MainActor
struct IslandPanelTests {
  @Test func aCollapsedPanelStaysOutOfSharedScreensAndFocus() {
    let panel = IslandPanel.make()
    expectConfigured(panel)
  }

  @Test func withoutANotchedScreenThereIsNoWindow() throws {
    let controller = IslandController(
      monitor: SystemMonitor(), memory: MemoryRescueModel(),
      navigation: WindowNavigation(),
      processes: DevProcessModel())
    controller.place(nil)
    #expect(controller.window == nil, "no notched screen: no window is made")

    // A notch on this Mac's first screen. All is well, so the window is made but never shown.
    let screen = NotchGeometry.screen(try #require(NSScreen.screens.first))
    let notch = CGRect(
      x: screen.frame.midX - 92.5, y: screen.frame.maxY - 32, width: 185, height: 32)
    controller.place((screen, notch))
    let window = try #require(controller.window)
    #expect(!window.isVisible)
    expectConfigured(window)

    // The notched screen goes (the lid closes): the window goes with it.
    controller.place(nil)
    #expect(controller.window == nil)
    #expect(!window.isVisible)
  }

  /// The user, 2026-10-23: "I don't want it permanently display the mem error display it for few
  /// second and disappear." The notch shows pressure for 4 s, again when it gets worse or comes
  /// back; the menu-bar item (`menuState`) keeps it while it lasts.
  @Test func theNotchFlashesPressureWhileTheMenuBarKeepsIt() throws {
    final class Model {
      var now = Date(timeIntervalSince1970: 1_800_000_000)
      var risk = MemoryRisk.warning
    }
    let model = Model()
    let t0 = model.now
    let controller = IslandController(
      monitor: SystemMonitor(), memory: MemoryRescueModel(),
      navigation: WindowNavigation(),
      processes: DevProcessModel())
    controller.environment = .init(
      now: { model.now }, screens: { [Self.builtIn(at: Self.away)] },
      // Warning here comes with the fans: the Mac struggling (N12: warning alone shows nothing).
      facts: { now in
        .init(
          now: now, meeting: false, source: .none, ledger: [], risk: model.risk, freeBytes: 1,
          lastResume: nil, note: nil, struggling: model.risk == .warning,
          strain: model.risk == .warning ? ["fan 78%"] : [])
      },
      isFullScreen: { _ in false }, reduceMotion: { true })
    defer { controller.place(nil) }
    func at(_ second: TimeInterval, _ risk: MemoryRisk) {
      model.now = t0.addingTimeInterval(second)
      model.risk = risk
      controller.tick()
    }
    let warning = IslandState.pressure(free: 1, critical: false, strain: ["fan 78%"])
    let critical = IslandState.pressure(free: 1, critical: true, strain: nil)

    at(0, .warning)
    #expect(controller.state == warning && controller.menuState == warning)
    #expect(controller.window?.isVisible == true, "the wings show")
    at(4, .warning)
    #expect(controller.state == warning)
    at(5, .warning)
    #expect(controller.state == .hidden, "the notch flash is over")
    #expect(controller.menuState == warning, "the menu bar keeps it")
    at(30, .warning)
    #expect(controller.state == .hidden && controller.menuState == warning, "not shown again")
    at(31, .critical)
    #expect(controller.state == critical && controller.menuState == critical, "worse: again")
    at(36, .warning)
    #expect(controller.state == .hidden && controller.menuState == warning)
    at(37, .normal)
    #expect(controller.state == .hidden && controller.menuState == .hidden, "calm")
    at(40, .warning)
    #expect(controller.state == warning, "back after calm: again")
  }

  // MARK: Display changes (2026-10-23: "when I connect a screen or disconnect the bar is
  // block on the middle of the screen and don't resize")

  /// Far off every real screen, so a window placed on the screens below is never seen.
  static let away = CGPoint(x: -40_000, y: -40_000)

  /// The built-in screen with its bottom-left corner at `origin`: this Mac's default scale
  /// (Mac17,2: 1512 × 982, a 185 × 32 notch), or a larger scale with a wider, taller notch.
  static func builtIn(at origin: CGPoint, larger: Bool = false) -> NotchGeometry.Screen {
    let size = larger ? CGSize(width: 1800, height: 1169) : CGSize(width: 1512, height: 982)
    let safeTop: CGFloat = larger ? 38 : 32
    let side = (size.width - (larger ? 220 : 185)) / 2
    let frame = CGRect(origin: origin, size: size)
    return .init(
      frame: frame, safeTop: safeTop,
      leftArea: CGRect(x: frame.minX, y: frame.maxY - safeTop, width: side, height: safeTop),
      rightArea: CGRect(
        x: frame.maxX - side, y: frame.maxY - safeTop, width: side, height: safeTop),
      visibleFrame: CGRect(
        x: frame.minX, y: frame.minY, width: size.width, height: size.height - 33))
  }

  /// A 1080p display without a notch.
  static func external(at origin: CGPoint) -> NotchGeometry.Screen {
    .init(
      frame: CGRect(origin: origin, size: CGSize(width: 1920, height: 1080)), safeTop: 0,
      leftArea: nil, rightArea: nil)
  }

  final class Screens {
    var list: [NotchGeometry.Screen]
    init(_ list: [NotchGeometry.Screen]) { self.list = list }
  }

  /// A controller over `screens` during a call (the wings show), moving at once unless `motion`.
  func callController(_ screens: Screens, motion: Bool = false, name: String) -> IslandController {
    let controller = IslandController(
      monitor: SystemMonitor(), memory: MemoryRescueModel(),
      navigation: WindowNavigation(), processes: DevProcessModel())
    controller.environment = .init(
      screens: { screens.list },
      facts: { now in
        .init(
          now: now, meeting: true, source: .calendar, ledger: [], risk: .normal, freeBytes: 1,
          lastResume: nil, note: nil)
      },
      isFullScreen: { _ in false }, reduceMotion: { !motion })
    return controller
  }

  /// The wings' frame around the notch of `screen`, at the controller's wing width.
  func wings(on screen: NotchGeometry.Screen, _ controller: IslandController) throws -> CGRect {
    let notch = try #require(NotchGeometry.notchRect(screen))
    return NotchGeometry.collapsed(notch: notch, wing: controller.metrics.wingWidth).panel
  }

  /// Within a point: AppKit puts a window's frame on the backing grid.
  func expectAt(
    _ window: IslandPanel?, _ frame: CGRect, _ comment: Comment,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let actual = window?.frame ?? .null
    let close =
      abs(actual.minX - frame.minX) <= 1 && abs(actual.minY - frame.minY) <= 1
      && abs(actual.width - frame.width) <= 1 && abs(actual.height - frame.height) <= 1
    #expect(close, "\(comment): at \(actual), not \(frame)", sourceLocation: sourceLocation)
    #expect(window?.isVisible == true, comment, sourceLocation: sourceLocation)
  }

  /// The built-in screen alone, then an external display added as main on its left: the built-in
  /// screen's origin moves, so the island must follow at once. Then the display is removed.
  @Test func theIslandFollowsTheNotchWhenADisplayComesAndGoes() throws {
    let alone = Self.builtIn(at: Self.away)
    let screens = Screens([alone])
    let controller = callController(screens, name: "island-display-added")
    defer { controller.place(nil) }
    controller.tick()
    expectAt(controller.window, try wings(on: alone, controller), "the built-in screen alone")

    // The external display is main, so it holds the origin; the built-in screen moves right.
    let shifted = Self.builtIn(at: CGPoint(x: Self.away.x + 1920, y: Self.away.y - 98))
    screens.list = [Self.external(at: Self.away), shifted]
    controller.screensChanged()
    expectAt(controller.window, try wings(on: shifted, controller), "external display added")

    screens.list = [alone]
    controller.screensChanged()
    expectAt(controller.window, try wings(on: alone, controller), "external display removed")
  }

  /// The bug the user saw: a display change that leaves the built-in screen where it was (the
  /// built-in screen stays the main one, the external display beside it), while AppKit moved the
  /// window during it. The frame the controller works out is the one it had, so it used to stay
  /// where AppKit left it for good. The notification puts it back at once, and the tick within a
  /// second if the window moves after it.
  @Test func aWindowMovedDuringADisplayChangeGoesBackOnTheNotch() throws {
    let builtIn = Self.builtIn(at: Self.away)
    let screens = Screens([builtIn])
    let controller = callController(screens, name: "island-display-moved")
    defer { controller.place(nil) }
    controller.tick()
    let window = try #require(controller.window)
    let middle = CGRect(
      x: builtIn.frame.midX - 188, y: builtIn.frame.midY, width: 377, height: 32)

    screens.list = [Self.external(at: CGPoint(x: Self.away.x - 1920, y: Self.away.y)), builtIn]
    window.setFrame(middle, display: false)
    controller.screensChanged()
    expectAt(window, try wings(on: builtIn, controller), "back on the notch at once")

    // AppKit moves it again after the notification: the next tick puts it back.
    window.setFrame(middle, display: false)
    controller.tick()
    expectAt(window, try wings(on: builtIn, controller), "back on the notch on the next tick")

    // Or orders it out: the tick shows it again.
    window.orderOut(nil)
    controller.tick()
    expectAt(window, try wings(on: builtIn, controller), "shown again on the next tick")
  }

  /// The lid closes (no notched screen): no island, the menu-bar item carries the state. The lid
  /// opens: the island is back on the notch.
  @Test func closingTheLidRemovesTheIslandAndOpeningItBringsItBack() throws {
    let builtIn = Self.builtIn(at: Self.away)
    let external = Self.external(at: CGPoint(x: Self.away.x - 1920, y: Self.away.y))
    let screens = Screens([builtIn, external])
    let controller = callController(screens, name: "island-lid")
    defer { controller.place(nil) }
    controller.tick()
    let window = try #require(controller.window)

    screens.list = [external]
    controller.screensChanged()
    #expect(controller.window == nil, "lid closed: no island")
    #expect(!window.isVisible)
    #expect(controller.state == .call(.calendar, paused: 0), "the menu bar still has the call")

    screens.list = [builtIn, external]
    controller.screensChanged()
    expectAt(controller.window, try wings(on: builtIn, controller), "lid opened")
  }

  /// The built-in screen's resolution changes: the notch is wider and taller in points, and the
  /// wings size to it.
  @Test func theIslandResizesWithTheBuiltInScreensResolution() throws {
    let screens = Screens([Self.builtIn(at: Self.away)])
    let controller = callController(screens, name: "island-resolution")
    defer { controller.place(nil) }
    controller.tick()

    let larger = Self.builtIn(at: Self.away, larger: true)
    screens.list = [larger]
    controller.screensChanged()
    expectAt(controller.window, try wings(on: larger, controller), "the larger scale")
    #expect(controller.metrics.notchWidth == 220)
    #expect(controller.metrics.notchHeight == 38)

    let back = Self.builtIn(at: Self.away)
    screens.list = [back]
    controller.screensChanged()
    expectAt(controller.window, try wings(on: back, controller), "back to the default scale")
    #expect(controller.metrics.notchWidth == 185)
  }

  /// `start` reframes on AppKit's screen notification, not only on the tick.
  @Test func theScreenNotificationReframesAtOnce() throws {
    let builtIn = Self.builtIn(at: Self.away)
    let screens = Screens([builtIn])
    let controller = callController(screens, name: "island-notification")
    defer { controller.place(nil) }
    let center = NotificationCenter()
    controller.observeScreens(center)
    controller.tick()

    let shifted = Self.builtIn(at: CGPoint(x: Self.away.x + 1920, y: Self.away.y))
    screens.list = [Self.external(at: Self.away), shifted]
    center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    expectAt(controller.window, try wings(on: shifted, controller), "reframed on the notification")
  }

  /// The tick's check that the window is where it was sent waits for the easing: a tick while
  /// the wings still ease out of the notch leaves the motion alone instead of cutting it short.
  @Test func aTickDuringTheMotionLetsItRun() async throws {
    let builtIn = Self.builtIn(at: Self.away)
    let controller = callController(Screens([builtIn]), motion: true, name: "island-easing")
    defer { controller.place(nil) }
    controller.tick()
    let window = try #require(controller.window)
    let notch = try #require(NotchGeometry.notchRect(builtIn))
    controller.tick()
    #expect(window.frame.width < notch.width + 2, "still easing out of the notch")
    try await Task.sleep(for: .seconds(IslandController.motion + 0.3))
    controller.tick()
    expectAt(window, try wings(on: builtIn, controller), "the motion ended on the wings")
  }

  /// A display change while the wings are still easing out ends on the new notch, not where the
  /// easing was going.
  @Test func aDisplayChangeDuringTheMotionEndsOnTheNewNotch() async throws {
    let screens = Screens([Self.builtIn(at: Self.away)])
    let controller = callController(screens, motion: true, name: "island-motion")
    defer { controller.place(nil) }
    controller.tick()

    let shifted = Self.builtIn(at: CGPoint(x: Self.away.x + 1920, y: Self.away.y - 98))
    screens.list = [Self.external(at: Self.away), shifted]
    controller.screensChanged()
    let expected = try wings(on: shifted, controller)
    expectAt(controller.window, expected, "at once")
    try await Task.sleep(for: .seconds(IslandController.motion + 0.3))
    expectAt(controller.window, expected, "once the first motion would have ended")
  }

  private func expectConfigured(_ panel: IslandPanel) {
    #expect(panel.sharingType == .none, "N3: never in a shared screen")
    #expect(panel.level == NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3))
    #expect(
      panel.collectionBehavior == [
        .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
      ])
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(panel.styleMask.contains(.borderless))
    #expect(!panel.canBecomeMain)
    #expect(!panel.canBecomeKey, "keyboard focus stays with the user's app")
    #expect(!panel.hidesOnDeactivate)
    #expect(!panel.isReleasedWhenClosed)
  }
}
