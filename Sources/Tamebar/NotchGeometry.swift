import AppKit

/// Where the notch is, where the island's wings and panel go, and whether an app is full screen
/// on the notched screen (N1, N4). The math is pure and takes plain values; the two adapters at
/// the bottom only read `NSScreen` and the window list.
///
/// Rects are in AppKit's global space (bottom-left origin on the primary display), except
/// `Window.bounds`, which is CoreGraphics' (top-left origin) as the window list gives it.
enum NotchGeometry {
  /// Each collapsed wing's width beside the notch.
  static let wingWidth: CGFloat = 96
  /// The expanded panel's width, unless the collapsed wings are wider.
  static let expandedWidth: CGFloat = 360
  /// The menu bar's window layer, to tell whether the menu bar shows on a screen.
  static let menuBarLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
  /// Window edges within this of the screen's count as touching it.
  static let tolerance: CGFloat = 1

  struct Screen: Equatable, Sendable {
    let frame: CGRect
    /// `safeAreaInsets.top`: the camera housing's height, 0 without a notch.
    let safeTop: CGFloat
    /// `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`: the menu bar beside the notch.
    let leftArea: CGRect?
    let rightArea: CGRect?
    /// The frame less the menu bar and the Dock; nil reads as the whole frame.
    var visibleFrame: CGRect? = nil
  }

  /// The first screen with a notch, and the notch's rect: the built-in screen, whichever display
  /// is main or first. Nil with the lid closed or no notch.
  static func notchedScreen(in screens: [Screen]) -> (screen: Screen, notch: CGRect)? {
    for screen in screens {
      if let notch = notchRect(screen) { return (screen, notch) }
    }
    return nil
  }

  /// The camera housing, from the screen's top edge down `safeTop`, between the two auxiliary
  /// areas. Only their widths are used, so it holds whichever space AppKit gives them in.
  static func notchRect(_ screen: Screen) -> CGRect? {
    guard screen.safeTop > 0, let left = screen.leftArea, let right = screen.rightArea else {
      return nil
    }
    let width = screen.frame.width - left.width - right.width
    guard width > 0 else { return nil }
    return CGRect(
      x: screen.frame.minX + left.width, y: screen.frame.maxY - screen.safeTop, width: width,
      height: screen.safeTop)
  }

  struct Wings: Equatable, Sendable {
    let left: CGRect
    let right: CGRect
    /// Both wings and the notch between them: the collapsed panel's frame.
    let panel: CGRect
  }

  /// The widest a wing grows for its text.
  static let maxWingWidth: CGFloat = 200
  /// The space between a wing's text and its edges.
  static let wingPadding: CGFloat = 14

  /// Both wings take the width the wider text needs, between `wingWidth` and `maxWingWidth`, so
  /// the island stays centred on the notch.
  static func wingWidth(fitting textWidth: CGFloat) -> CGFloat {
    min(maxWingWidth, max(wingWidth, (textWidth + 2 * wingPadding).rounded(.up)))
  }

  /// The collapsed island: a wing on each side of the notch, at its height.
  static func collapsed(notch: CGRect, wing width: CGFloat = wingWidth) -> Wings {
    let wing = CGSize(width: width, height: notch.height)
    return Wings(
      left: CGRect(origin: CGPoint(x: notch.minX - width, y: notch.minY), size: wing),
      right: CGRect(origin: CGPoint(x: notch.maxX, y: notch.minY), size: wing),
      panel: notch.insetBy(dx: -width, dy: 0))
  }

  /// The expanded panel: centred on the notch, hanging from the screen's top edge, the notch
  /// height plus the content's. Never narrower than the collapsed wings.
  static func expanded(notch: CGRect, contentHeight: CGFloat, wing: CGFloat = wingWidth)
    -> CGRect
  {
    let width = max(expandedWidth, collapsed(notch: notch, wing: wing).panel.width)
    let height = notch.height + contentHeight
    return CGRect(x: notch.midX - width / 2, y: notch.maxY - height, width: width, height: height)
  }

  // MARK: Full screen

  /// An on-screen window, as the window list reports it.
  struct Window: Equatable, Sendable {
    let layer: Int
    /// CoreGraphics bounds: top-left origin on the primary display.
    let bounds: CGRect
  }

  struct FullScreenInput: Sendable {
    let screen: Screen
    /// The primary display's height, to flip CoreGraphics bounds into AppKit's space.
    let primaryHeight: CGFloat
    let windows: [Window]
  }

  /// True when an app window covers the whole screen, up to at least the camera housing (where
  /// macOS puts a full-screen window on a notched screen), and the screen's menu bar isn't
  /// showing. The menu bar tells full screen from a zoomed window with the Dock hidden.
  ///
  /// `behindMenuBar` reads a full-screen app whose menu bar the pointer has brought in (the
  /// menu-bar item can only be reached so): the window still covers the screen to its top edge,
  /// where a zoomed window stops at the menu bar.
  static func isFullScreen(_ input: FullScreenInput, behindMenuBar: Bool = false) -> Bool {
    let frame = input.screen.frame
    let flipped = input.windows.map {
      (layer: $0.layer, rect: appKitRect($0.bounds, primaryHeight: input.primaryHeight))
    }
    let menuBarShows = flipped.contains { window in
      window.layer == menuBarLayer && window.rect.minX < frame.maxX
        && window.rect.maxX > frame.minX && window.rect.maxY >= frame.maxY - tolerance
        && window.rect.minY < frame.maxY
    }
    guard !menuBarShows || behindMenuBar else { return false }
    let coveredTop = frame.maxY - input.screen.safeTop - tolerance
    return flipped.contains { window in
      window.layer == 0 && window.rect.minX <= frame.minX + tolerance
        && window.rect.maxX >= frame.maxX - tolerance
        && window.rect.minY <= frame.minY + tolerance && window.rect.maxY >= coveredTop
    }
  }

  /// CoreGraphics window bounds in AppKit's space.
  static func appKitRect(_ bounds: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(
      x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
  }

  // MARK: Adapters

  @MainActor static func screen(_ screen: NSScreen) -> Screen {
    Screen(
      frame: screen.frame, safeTop: screen.safeAreaInsets.top,
      leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea,
      visibleFrame: screen.visibleFrame)
  }

  /// The screens as AppKit reports them now, read afresh on every call: no `NSScreen` is kept,
  /// so a display change never leaves a stale frame behind.
  @MainActor static func screens() -> [Screen] { NSScreen.screens.map(screen) }

  /// The notched screen now (see `notchedScreen(in:)`).
  @MainActor static func notchedScreen() -> (screen: Screen, notch: CGRect)? {
    notchedScreen(in: screens())
  }

  /// True when an app is full screen on `screen`, or on the main screen when it's nil (see
  /// `isFullScreen`).
  @MainActor static func isFullScreen(on screen: Screen?, behindMenuBar: Bool = false) -> Bool {
    guard let screen = screen ?? NSScreen.main.map(self.screen),
      let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
      let primary = NSScreen.screens.first
    else { return false }
    let windows = list.compactMap { info -> Window? in
      guard let layer = info[kCGWindowLayer as String] as? Int,
        let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
        let bounds = CGRect(dictionaryRepresentation: dictionary)
      else { return nil }
      return Window(layer: layer, bounds: bounds)
    }
    return isFullScreen(
      .init(screen: screen, primaryHeight: primary.frame.height, windows: windows),
      behindMenuBar: behindMenuBar)
  }
}
