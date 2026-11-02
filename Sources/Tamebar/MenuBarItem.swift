import AppKit
import Combine
import SwiftUI

/// The menu-bar item (N7, 2026-10-27: "on display without notch I want an icon in the tab
/// bar, but not only the RAM … the same info as the notch"). Tamebar's icon, then the state the
/// notch shows, from the same resolution; hovering or clicking it opens the notch's usage card
/// under it, on whichever menu bar it is.

// MARK: The icon

/// Tamebar's menu-bar icon: the brand mark (`assets/brand/Tamebar.icon/Assets/Mark.svg`), a
/// rounded square with a dash and a dot inside, scaled from its 1024 pt drawing. A template
/// image, so the menu bar draws it in its light, dark or tinted look; drawn by a handler, so it
/// is sharp at every scale.
enum TamebarIcon {
  static let size = NSSize(width: 16, height: 16)
  /// The mark's outer edge in the SVG (the square's 200…824 path plus half its 88 stroke).
  private static let markOrigin: CGFloat = 156
  private static let scale: CGFloat = 16 / 712
  private static func pt(_ svg: CGFloat) -> CGFloat { (svg - markOrigin) * scale }
  /// The square's path (its stroke centre), corner radius and stroke width.
  static let square = CGRect(x: pt(200), y: pt(200), width: 624 * scale, height: 624 * scale)
  static let squareRadius = 152 * scale
  static let squareStroke = 88 * scale
  /// The dash: its centre line from 338 to 486 at 512, with round caps.
  static let dash = (from: CGPoint(x: pt(338), y: pt(512)), to: CGPoint(x: pt(486), y: pt(512)))
  static let dashStroke = 96 * scale
  /// The dot at 670, 512, radius 64.
  static let dot = CGRect(
    x: pt(670 - 64), y: pt(512 - 64), width: 128 * scale, height: 128 * scale)

  @MainActor static let image: NSImage = make()

  static func make() -> NSImage {
    let image = NSImage(size: size, flipped: true) { _ in
      NSColor.black.set()
      let outline = NSBezierPath(
        roundedRect: square, xRadius: squareRadius, yRadius: squareRadius)
      outline.lineWidth = squareStroke
      outline.stroke()
      let line = NSBezierPath()
      line.move(to: dash.from)
      line.line(to: dash.to)
      line.lineWidth = dashStroke
      line.lineCapStyle = .round
      line.stroke()
      NSBezierPath(ovalIn: dot).fill()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = AppBrand.name
    return image
  }
}

// MARK: The label

/// What the item shows: the icon, then the state's symbol and short text (`IslandState.menuText`,
/// the words the wings and the card's line come from), or the icon alone while all is well. Its
/// accessibility label is the card's whole line, or the menu's text where the card has none.
struct MenuBarItemLabel: Equatable {
  let symbol: String?
  let text: String?
  let tone: MetricTone
  /// The symbol carries the state's color: status colors on, and a warning or a critical state.
  /// The icon and the text always follow the menu bar.
  let tinted: Bool
  let accessibility: String

  init(_ state: IslandState, colored: Bool) {
    let menu = state.menuText
    symbol = menu?.symbol
    text = menu?.text
    tone = menu?.tone ?? .neutral
    tinted = colored && tone.isAlert
    accessibility =
      "\(AppBrand.name), " + (state.cardLine?.text ?? menu?.text ?? "all is well")
  }

  var iconOnly: Bool { text == nil }

  /// The title beside the icon: the symbol, its color when `tinted`, then the text.
  @MainActor func title() -> NSAttributedString {
    guard let text else { return NSAttributedString() }
    let font = NSFont.monospacedDigitSystemFont(
      ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    let title = NSMutableAttributedString(string: " ", attributes: [.font: font])
    if let symbol, let image = Self.symbolImage(symbol, tone: tinted ? tone : nil, font: font) {
      let attachment = NSTextAttachment()
      attachment.image = image
      attachment.bounds = CGRect(
        x: 0, y: ((font.capHeight - image.size.height) / 2).rounded(), width: image.size.width,
        height: image.size.height)
      title.append(NSAttributedString(attachment: attachment))
      title.append(NSAttributedString(string: " ", attributes: [.font: font]))
    }
    // No color: the menu bar draws the text as its own.
    title.append(NSAttributedString(string: text, attributes: [.font: font]))
    return title
  }

  /// The SF Symbol at the text's size: a template, unless `tone` colors it.
  @MainActor static func symbolImage(_ name: String, tone: MetricTone?, font: NSFont) -> NSImage? {
    var configuration = NSImage.SymbolConfiguration(
      pointSize: font.pointSize - 2, weight: .semibold)
    if let tone {
      configuration = configuration.applying(.init(paletteColors: [NSColor(tone.color)]))
    }
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(configuration)
  }

  /// Sets the item's button, or any button drawn as it (the renders).
  @MainActor func apply(to button: NSButton) {
    button.image = TamebarIcon.image
    // The title first: setting it moves the image beside it.
    button.attributedTitle = title()
    button.imagePosition = iconOnly ? .imageOnly : .imageLeading
    button.toolTip = nil
    button.setAccessibilityLabel(accessibility)
  }
}

// MARK: Where the card goes

/// Where the card hangs under the item: its top `gap` below the menu bar's bottom edge (the
/// item's), as a macOS menu sits (N15), centred on the item, inside the item's screen, no taller than the screen's
/// visible frame allows. Rects are in AppKit's global space, as `NotchGeometry`'s.
enum MenuBarCardGeometry {
  /// The closest the card comes to the screen's side edges.
  static let screenMargin: CGFloat = 8
  /// Between the menu bar and the card's rounded top (N15). The hover region spans it.
  static let gap: CGFloat = 4

  static func frame(
    item: CGRect, screen: NotchGeometry.Screen, width: CGFloat, contentHeight: CGFloat
  ) -> CGRect {
    let visible = screen.visibleFrame ?? screen.frame
    let height = max(0, min(contentHeight, visible.height - 40))
    let lowest = screen.frame.minX + screenMargin
    let highest = screen.frame.maxX - screenMargin - width
    let x = max(lowest, min(item.midX - width / 2, highest))
    return CGRect(x: x, y: item.minY - gap - height, width: width, height: height)
  }

  /// The sliver under the item the card grows out of and goes back to: its width, where the
  /// card's top is.
  static func start(item: CGRect) -> CGRect {
    CGRect(x: item.minX, y: item.minY - gap - 2, width: item.width, height: 2)
  }
}

// MARK: The controller

/// Owns the status item: its label and the hover card under it. The card follows the notch
/// card's rules (N6): it opens after the pointer rests 0.3 s on the item (or at once on a click),
/// closes 0.2 s after the pointer has left both, reads "left"
/// from where the pointer is against the frame the card opens to, never takes the keyboard, never
/// shows in a shared screen or in full screen, and grows out of the item as the notch card grows
/// out of the notch.
@MainActor
final class MenuBarItemController: ObservableObject {
  /// Where the item is: its window's frame on the menu bar, and the screen that menu bar is on.
  struct Anchor: Equatable {
    let item: CGRect
    let screen: NotchGeometry.Screen
  }

  /// What the controller reads from the Mac; the rest comes from the island's `Environment`.
  /// Tests replace it.
  struct Environment {
    /// The item now; nil while it isn't on a menu bar.
    var anchor: @MainActor () -> Anchor? = { nil }
    /// An app is full screen on the item's screen, its menu bar shown or not.
    var isFullScreen: @MainActor (Anchor) -> Bool = {
      NotchGeometry.isFullScreen(on: $0.screen, behindMenuBar: true)
    }
    /// Status colors, as saved before N9 removed its switch; on by default.
    var colored: @MainActor () -> Bool = {
      UserDefaults.standard.object(forKey: MenuBarPreferenceKey.showHealth) as? Bool ?? true
    }
    /// Settings → Show Tamebar in (N9): whether the item shows, given whether a notch screen is
    /// connected. With none, it always does.
    var shown: @MainActor (_ notchScreen: Bool) -> Bool = {
      ShowSurfaces.load().shown(notchScreen: $0).menuBar
    }
  }

  @Published private(set) var look = IslandCardController.Look()
  /// The open card's size; its content is laid out at it from the first frame.
  @Published private(set) var size = CGSize(width: NotchGeometry.expandedWidth, height: 0)
  private(set) var label: MenuBarItemLabel

  let island: IslandController
  var environment = Environment()

  private(set) var hover = NotchHover()
  private(set) var cardWindow: IslandCardPanel?
  /// The card's frame while it is open or opening.
  private(set) var cardFrame: CGRect?
  /// The item the card opened under.
  private var opened: Anchor?
  private var statusItem: NSStatusItem?
  /// Whether the item was last asked to show (`applyVisibility`).
  private var visible: Bool?
  private var tracker: MenuBarItemTracker?
  private var motion = 0
  private var animating = false
  private var closing = false
  private var check = 0
  private var observers: [NSObjectProtocol] = []
  private var subscriptions: Set<AnyCancellable> = []

  init(island: IslandController) {
    self.island = island
    label = MenuBarItemLabel(.hidden, colored: true)
  }

  var isOpen: Bool { hover.isOpen }

  // MARK: The item

  /// Starts the island's tick and puts the item in the menu bar; hidden when Settings → Show
  /// Tamebar in has the menu bar off and the notch shows (N9). The item exists either way: it
  /// holds the window's router. A second call does nothing.
  func install() {
    guard statusItem == nil else { return }
    // The first tick reads the screens, so the item's visibility is known before it appears.
    island.start()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let shown = environment.shown(island.notchScreen)
    visible = shown
    item.isVisible = shown
    statusItem = item
    if let button = item.button {
      let tracker = MenuBarItemTracker()
      tracker.onEnter = { [weak self] in self?.pointerEntered() }
      tracker.onExit = { [weak self] in self?.pointerExited() }
      tracker.onClick = { [weak self] in self?.itemClicked() }
      button.target = tracker
      button.action = #selector(MenuBarItemTracker.clicked)
      button.sendAction(on: [.leftMouseDown, .rightMouseDown])
      button.addTrackingArea(
        NSTrackingArea(
          rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
          owner: tracker))
      self.tracker = tracker
      // Opens the window on request, which needs SwiftUI's `openWindow`.
      let router = PassThroughHostingView(rootView: MenuBarRouter())
      router.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
      button.addSubview(router)
    }
    environment.anchor = { [weak self] in self?.itemAnchor() }
    island.$menuState.sink { [weak self] state in self?.refresh(state) }.store(in: &subscriptions)
    island.$notchScreen.removeDuplicates().sink { [weak self] notchScreen in
      self?.applyVisibility(notchScreen: notchScreen)
    }.store(in: &subscriptions)
    observers.append(
      NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.refresh()
          self?.applyVisibility()
        }
      })
    refresh()
  }

  /// Shows or hides the item as Settings → Show Tamebar in says, live (N9). Hidden, its card
  /// closes.
  func applyVisibility(notchScreen: Bool? = nil) {
    guard let item = statusItem else { return }
    let shown = environment.shown(notchScreen ?? island.notchScreen)
    // What was asked last, not `isVisible`: its setter saves the visibility in the defaults, and
    // the change notification it posts comes back here before the setter has returned.
    guard shown != visible else { return }
    visible = shown
    if !shown {
      hover.cancel()
      finish()
    }
    item.isVisible = shown
  }

  /// The item's frame and screen, read afresh: it moves to whichever menu bar is active.
  private func itemAnchor() -> Anchor? {
    guard let window = statusItem?.button?.window, let screen = window.screen else { return nil }
    return Anchor(item: window.frame, screen: NotchGeometry.screen(screen))
  }

  /// The label for the menu bar's state now; the button only changes when it does.
  func refresh(_ state: IslandState? = nil) {
    let next = MenuBarItemLabel(state ?? island.menuState, colored: environment.colored())
    guard next != label || statusItem?.button?.image == nil else { return }
    label = next
    if let button = statusItem?.button { next.apply(to: button) }
  }

  // MARK: Hover

  /// The pointer is on the item or the card.
  func pointerEntered() {
    check += 1
    if closing { return reopen() }
    if !hover.isOpen, let anchor = environment.anchor(), environment.isFullScreen(anchor) {
      return
    }
    hover.enter(at: island.environment.now())
    schedule()
  }

  /// The pointer left the item or the card window. While the card is opening or open the window
  /// may still be growing, so the pointer decides, not the event (as the notch card, 9aa678d).
  func pointerExited() {
    if hover.isOpen, cardFrame != nil { return recheck() }
    hover.leave(at: island.environment.now())
    schedule()
  }

  /// Where the pointer counts as on the card while it opens, shows or closes: the frame it opens
  /// to, the item, and the margin; nil at rest.
  var hoverRegion: CGRect? {
    guard let cardFrame, let opened else { return nil }
    return IslandCardMotion.hoverRegion(card: cardFrame, start: opened.item)
  }

  private func recheck() {
    guard let window = cardWindow, let region = hoverRegion, hover.isOpen else { return }
    let pointer = island.environment.pointer()
    guard region.contains(pointer) else {
      hover.leave(at: island.environment.now())
      return schedule()
    }
    hover.enter(at: island.environment.now())
    let onItem = opened.map { $0.item.contains(pointer) } ?? false
    guard !window.frame.contains(pointer), !onItem else { return }
    check += 1
    let id = check
    island.environment.after(IslandCardController.recheckEvery) { [weak self] in
      guard let self, check == id else { return }
      recheck()
    }
  }

  private func reopen() {
    closing = false
    hover.returned()
    open(reversing: true)
  }

  private func schedule() {
    guard let deadline = hover.deadline else { return }
    let delay = max(0, deadline.timeIntervalSince(island.environment.now()))
    island.environment.after(delay) { [weak self] in self?.due() }
  }

  private func due() {
    switch hover.fire(at: island.environment.now()) {
    case .open: open()
    case .close: close()
    case nil: break
    }
  }

  // MARK: Clicks

  /// A click on the item: closes the card when it is open; otherwise opens it at once, or the
  /// window in full screen, where no card shows.
  func itemClicked() {
    if cardFrame != nil, !closing {
      hover.cancel()
      return close()
    }
    if let anchor = environment.anchor(), environment.isFullScreen(anchor) {
      return island.environment.openWindow(island, nil)
    }
    hover.cancel()
    hover.returned()
    // A card still shrinking grows again from where it is.
    let reversing = closing
    closing = false
    open(reversing: reversing)
  }

  /// A click on the card's body: the window, as Open › does (N11).
  func cardClicked() {
    guard hover.isOpen else { return }
    openApp()
  }

  /// Open ›: as on the notch card, Tamebar's window with Tamebar in front; the card closes at once.
  func openApp() {
    hover.cancel()
    finish()
    island.environment.openWindow(island, nil)
  }

  /// A card Activity link opens the window on Activity.
  func openStopped() {
    hover.cancel()
    finish()
    island.environment.openWindow(island, .activity)
  }

  /// Ask Claude / Ask Codex (N8): as on the notch card, Terminal opens running the tool and the
  /// card closes at once.
  func ask(_ agent: AskAgent) {
    island.environment.ask(agent)
    hover.cancel()
    finish()
  }

  /// On a row whose buttons take their own click: the last row (Ask and Open), Activity links
  /// while it shows, or the waiting block while something waits.
  func isOnOpenRow(_ point: CGPoint, in bounds: CGRect) -> Bool {
    hover.isOpen && look.live
      && IslandCardMotion.isOnButtonRow(
        point, in: bounds, card: size,
        activityRows: island.processes.currentActivity.cardLines.count,
        waiting: island.processes.waitingStarts.count)
  }

  // MARK: The card's motion

  private func open(reversing: Bool = false) {
    guard let anchor = environment.anchor() else { return }
    island.agents.refresh()
    let window = cardWindow ?? makeCardWindow()
    let width = NotchGeometry.expandedWidth
    let frame = MenuBarCardGeometry.frame(
      item: anchor.item, screen: anchor.screen, width: width,
      contentHeight: island.cardContentHeight(width: width))
    opened = anchor
    cardFrame = frame
    let step = IslandCardMotion.opening(
      notch: MenuBarCardGeometry.start(item: anchor.item), card: frame,
      reduceMotion: island.environment.reduceMotion())
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      size = frame.size
      if !reversing {
        look = .init(
          fill: step.fades ? 0 : 1, content: 0, radius: step.fades ? 14 : 10, live: true)
      }
    }
    window.ignoresMouseEvents = false
    if !reversing || !window.isVisible { window.setFrame(step.from, display: false) }
    if !window.isVisible { window.orderFrontRegardless() }
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    run(step, to: .init(fill: 1, content: 1, radius: 14, live: true)) { [weak self] in
      self?.recheck()
    }
  }

  private func close() {
    guard let opened, let frame = cardFrame else { return finish() }
    let step = IslandCardMotion.closing(
      notch: MenuBarCardGeometry.start(item: opened.item), card: frame,
      reduceMotion: island.environment.reduceMotion())
    closing = true
    run(
      step,
      to: .init(fill: step.fades ? 0 : 1, content: 0, radius: step.fades ? 14 : 10, live: true)
    ) { [weak self] in self?.finish() }
  }

  /// Nothing drawn, the window gone: the item is the hover area at rest.
  private func finish() {
    motion += 1
    animating = false
    closing = false
    check += 1
    cardFrame = nil
    opened = nil
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) { look = .init() }
    cardWindow?.orderOut(nil)
  }

  private func run(
    _ step: IslandCardMotion.Step, to target: IslandCardController.Look,
    then done: (@MainActor () -> Void)? = nil
  ) {
    guard let window = cardWindow else { return }
    motion += 1
    let id = motion
    animating = true
    NSAnimationContext.runAnimationGroup { context in
      context.duration = step.duration
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      if window.frame != step.to { window.animator().setFrame(step.to, display: true) }
      withAnimation(.easeOut(duration: step.duration)) { look = target }
    } completionHandler: { [weak self] in
      Task { @MainActor in
        guard let self, self.motion == id else { return }
        self.animating = false
        done?()
      }
    }
  }

  /// The open card's content changed height: the window follows at once, its top kept.
  func contentHeight(_ height: CGFloat) {
    guard let opened, let window = cardWindow, hover.isOpen, !animating, let frame = cardFrame
    else { return }
    let next = MenuBarCardGeometry.frame(
      item: opened.item, screen: opened.screen, width: frame.width, contentHeight: height)
    guard abs(next.height - frame.height) > 1 else { return }
    cardFrame = next
    size = next.size
    window.setFrame(next, display: true)
  }

  private func makeCardWindow() -> IslandCardPanel {
    let window = IslandCardPanel.make()
    let tracking = IslandCardTrackingView(frame: .zero)
    tracking.onEnter = { [weak self] in self?.pointerEntered() }
    tracking.onExit = { [weak self] in self?.pointerExited() }
    tracking.onClick = { [weak self] in self?.cardClicked() }
    tracking.isOnOpenRow = { [weak self] point, bounds in
      self?.isOnOpenRow(point, in: bounds) ?? false
    }
    let host = NSHostingView(rootView: MenuBarCardRoot(island: island, item: self))
    host.sizingOptions = []
    host.autoresizingMask = [.width, .height]
    tracking.addSubview(host)
    window.contentView = tracking
    cardWindow = window
    return window
  }
}

/// The item's hover area, a tracking area on its button (which needs no Accessibility
/// permission), and its click's target.
final class MenuBarItemTracker: NSResponder {
  var onEnter: (() -> Void)?
  var onExit: (() -> Void)?
  var onClick: (() -> Void)?

  override func mouseEntered(with event: NSEvent) { onEnter?() }
  override func mouseExited(with event: NSEvent) { onExit?() }
  @objc func clicked() { onClick?() }
}

/// A hosting view that takes no click: the router inside the item's button.
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: Views

/// Opens Tamebar's window when asked (`openTamebarWindow`, the launch request), with SwiftUI's
/// `openWindow`. It lives in the item, which is there for the app's whole life.
struct MenuBarRouter: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear.frame(width: 1, height: 1)
      .task {
        if AppLaunch.initialWindow.consume() { openWindow.tamebarWindow() }
      }
      .onReceive(NotificationCenter.default.publisher(for: .openTamebarWindow)) { _ in
        openWindow.tamebarWindow()
      }
  }
}

/// The card under the item: the notch card's view and data (`UsageCardLive`), on the island's
/// black, a few points under the menu bar and round at all four corners, as a macOS menu (N15).
/// The notch card keeps its square top: it grows out of the notch.
struct MenuBarCardLayout<Content: View>: View {
  let size: CGSize
  let look: IslandCardController.Look
  @ViewBuilder let content: () -> Content

  var body: some View {
    content().fixedSize(horizontal: false, vertical: true).opacity(look.content)
      .frame(width: size.width, height: size.height, alignment: .top)
      .background(BlitzUI.notchFill)
      .environment(\.colorScheme, .dark)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .clipShape(RoundedRectangle(cornerRadius: look.radius, style: .continuous))
      .opacity(look.fill)
  }
}

struct MenuBarCardRoot: View {
  @ObservedObject var island: IslandController
  @ObservedObject var item: MenuBarItemController

  var body: some View {
    MenuBarCardLayout(size: item.size, look: item.look) {
      if item.look.live {
        UsageCardLive(
          island: island, monitor: island.monitor, processes: island.processes,
          openApp: item.openApp, openStopped: item.openStopped, ask: item.ask
        )
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: { height in
          Task { @MainActor in item.contentHeight(height) }
        }
      }
    }
  }
}
