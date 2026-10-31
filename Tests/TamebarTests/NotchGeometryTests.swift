import CoreGraphics
import Testing

@testable import Tamebar

struct NotchGeometryTests {
  /// This Mac's built-in screen (Mac17,2 at its default scale), as AppKit reports it.
  let builtIn = NotchGeometry.Screen(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeTop: 32,
    leftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
    rightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32))

  @Test func notchRectFromTheSafeAreaAndTheAuxiliaryAreas() {
    let plan = NotchGeometry.Screen(
      frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeTop: 32,
      leftArea: CGRect(x: 0, y: 950, width: 662, height: 32),
      rightArea: CGRect(x: 850, y: 950, width: 662, height: 32))
    #expect(NotchGeometry.notchRect(plan) == CGRect(x: 662, y: 950, width: 188, height: 32))
    #expect(NotchGeometry.notchRect(builtIn) == CGRect(x: 663.5, y: 950, width: 185, height: 32))
  }

  @Test func noNotchWithoutASafeAreaOrTheAuxiliaryAreas() {
    let flat = NotchGeometry.Screen(
      frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeTop: 0, leftArea: nil,
      rightArea: nil)
    #expect(NotchGeometry.notchRect(flat) == nil)
    let noTop = NotchGeometry.Screen(
      frame: builtIn.frame, safeTop: 0, leftArea: builtIn.leftArea, rightArea: builtIn.rightArea)
    #expect(NotchGeometry.notchRect(noTop) == nil)
    let noLeft = NotchGeometry.Screen(
      frame: builtIn.frame, safeTop: 32, leftArea: nil, rightArea: builtIn.rightArea)
    #expect(NotchGeometry.notchRect(noLeft) == nil)
    let noRight = NotchGeometry.Screen(
      frame: builtIn.frame, safeTop: 32, leftArea: builtIn.leftArea, rightArea: nil)
    #expect(NotchGeometry.notchRect(noRight) == nil)
  }

  /// The built-in screen beside an external main display sits away from the origin; the notch
  /// follows its frame whichever space the auxiliary areas are given in.
  @Test func notchOnAScreenAwayFromTheOrigin() {
    let frame = CGRect(x: 1920, y: -200, width: 1512, height: 982)
    let global = NotchGeometry.Screen(
      frame: frame, safeTop: 32, leftArea: CGRect(x: 1920, y: 750, width: 663.5, height: 32),
      rightArea: CGRect(x: 2768.5, y: 750, width: 663.5, height: 32))
    let local = NotchGeometry.Screen(
      frame: frame, safeTop: 32, leftArea: builtIn.leftArea, rightArea: builtIn.rightArea)
    let expected = CGRect(x: 2583.5, y: 750, width: 185, height: 32)
    #expect(NotchGeometry.notchRect(global) == expected)
    #expect(NotchGeometry.notchRect(local) == expected)
  }

  /// The notched screen is the built-in one wherever it is in the list (an external display that
  /// is main comes first), and there is none with the lid closed.
  @Test func theNotchedScreenIsTheBuiltInOneWhicheverIsMain() {
    let external = NotchGeometry.Screen(
      frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeTop: 0, leftArea: nil,
      rightArea: nil)
    let beside = NotchGeometry.Screen(
      frame: CGRect(x: 1920, y: -98, width: 1512, height: 982), safeTop: 32,
      leftArea: builtIn.leftArea, rightArea: builtIn.rightArea)
    let found = NotchGeometry.notchedScreen(in: [external, beside])
    #expect(found?.screen == beside)
    #expect(found?.notch == CGRect(x: 2583.5, y: 852, width: 185, height: 32))
    #expect(NotchGeometry.notchedScreen(in: [builtIn, external])?.screen == builtIn)
    #expect(NotchGeometry.notchedScreen(in: [external]) == nil, "lid closed")
    #expect(NotchGeometry.notchedScreen(in: []) == nil)
  }

  @Test func collapsedWingsFlankTheNotch() throws {
    let notch = try #require(NotchGeometry.notchRect(builtIn))
    let wings = NotchGeometry.collapsed(notch: notch)
    #expect(NotchGeometry.wingWidth == 96)
    #expect(wings.left == CGRect(x: 567.5, y: 950, width: 96, height: 32))
    #expect(wings.right == CGRect(x: 848.5, y: 950, width: 96, height: 32))
    #expect(wings.panel == CGRect(x: 567.5, y: 950, width: 377, height: 32))
  }

  @Test func expandedPanelHangsFromTheTopCentredOnTheNotch() throws {
    let notch = try #require(NotchGeometry.notchRect(builtIn))
    // 360 is narrower than the collapsed wings here (377), so the panel keeps the wings' width.
    #expect(
      NotchGeometry.expanded(notch: notch, contentHeight: 300)
        == CGRect(x: 567.5, y: 650, width: 377, height: 332))
    let narrow = CGRect(x: 700, y: 950, width: 100, height: 32)
    #expect(
      NotchGeometry.expanded(notch: narrow, contentHeight: 200)
        == CGRect(x: 570, y: 750, width: 360, height: 232))
    #expect(NotchGeometry.expandedWidth == 360)
  }

  // MARK: Full screen

  /// CoreGraphics window bounds: top-left origin on the primary display.
  func window(
    layer: Int = 0, x: CGFloat = 0, y: CGFloat, width: CGFloat = 1512, height: CGFloat
  ) -> NotchGeometry.Window {
    .init(layer: layer, bounds: CGRect(x: x, y: y, width: width, height: height))
  }

  func fullScreen(
    _ windows: [NotchGeometry.Window], screen: NotchGeometry.Screen? = nil,
    primaryHeight: CGFloat = 982
  ) -> Bool {
    NotchGeometry.isFullScreen(
      .init(screen: screen ?? builtIn, primaryHeight: primaryHeight, windows: windows))
  }

  /// A full-screen window on a notched screen sits below the camera housing; the menu bar is gone.
  @Test func fullScreenBelowTheNotch() {
    #expect(fullScreen([window(y: 32, height: 950)]))
    #expect(fullScreen([window(y: 0, height: 982)]))
  }

  /// A zoomed window under a showing menu bar isn't full screen, even with the Dock hidden.
  @Test func zoomedWindowWithTheMenuBarIsNot() {
    let menuBar = window(layer: NotchGeometry.menuBarLayer, y: 0, height: 33)
    #expect(!fullScreen([menuBar, window(y: 33, height: 949)]))
    #expect(!fullScreen([menuBar, window(y: 0, height: 982)]))
  }

  @Test func windowsThatDontCoverTheScreenAreNot() {
    #expect(!fullScreen([]))
    #expect(!fullScreen([window(x: 47, y: 33, width: 1465, height: 949)]))
    #expect(!fullScreen([window(y: 32, height: 900)]))
    #expect(!fullScreen([window(y: 40, height: 942)]))
    #expect(!fullScreen([window(y: 32, width: 1400, height: 950)]))
  }

  /// Only ordinary app windows count: the Dock's and other floating layers cover the screen too.
  @Test func onlyLayerZeroCounts() {
    #expect(!fullScreen([window(layer: 20, y: 0, height: 982)]))
    #expect(!fullScreen([window(layer: 5, y: 0, height: 982)]))
  }

  /// The built-in screen beside a taller external main display: windows are flipped through the
  /// primary display's height, and another screen's menu bar doesn't count.
  @Test func fullScreenOnASecondaryScreen() {
    let frame = CGRect(x: 1920, y: 0, width: 1512, height: 982)
    let secondary = NotchGeometry.Screen(
      frame: frame, safeTop: 32, leftArea: builtIn.leftArea, rightArea: builtIn.rightArea)
    let externalMenuBar = window(layer: NotchGeometry.menuBarLayer, y: 0, width: 1920, height: 25)
    let onBuiltIn = window(x: 1920, y: 1080 - 950, height: 950)
    #expect(fullScreen([externalMenuBar, onBuiltIn], screen: secondary, primaryHeight: 1080))
    let onExternal = window(x: 0, y: 25, width: 1920, height: 1055)
    #expect(!fullScreen([externalMenuBar, onExternal], screen: secondary, primaryHeight: 1080))
    let builtInMenuBar = window(layer: NotchGeometry.menuBarLayer, x: 1920, y: 98, height: 33)
    #expect(!fullScreen([builtInMenuBar, onBuiltIn], screen: secondary, primaryHeight: 1080))
  }

  /// Top edges aligned: the external menu bar shares the built-in's top band, but not its width.
  @Test func anotherScreensMenuBarAtTheSameHeightDoesntCount() {
    let topAligned = NotchGeometry.Screen(
      frame: CGRect(x: 1920, y: 98, width: 1512, height: 982), safeTop: 32,
      leftArea: builtIn.leftArea, rightArea: builtIn.rightArea)
    let externalMenuBar = window(layer: NotchGeometry.menuBarLayer, y: 0, width: 1920, height: 25)
    let onBuiltIn = window(x: 1920, y: 32, height: 950)
    #expect(fullScreen([externalMenuBar, onBuiltIn], screen: topAligned, primaryHeight: 1080))
  }

  @Test func flipsCoreGraphicsBoundsToAppKit() {
    #expect(
      NotchGeometry.appKitRect(CGRect(x: 10, y: 33, width: 100, height: 200), primaryHeight: 982)
        == CGRect(x: 10, y: 749, width: 100, height: 200))
  }
}
