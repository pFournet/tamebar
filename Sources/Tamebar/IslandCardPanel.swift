import AppKit
import SwiftUI

/// The hover card's window (N6). At rest it is a transparent area exactly on the notch rect,
/// where nothing on screen can be clicked, so it never takes a click from anything else; it sees
/// the pointer through a tracking area, which needs no Accessibility permission. Opened, the same
/// window grows into the card. Like the island it is above the menu bar on every Space and never
/// in a shared screen (N3), and it never takes key focus.
final class IslandCardPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// A configured panel, with no content yet. `IslandCardPanelTests` pins every setting here.
  static func make() -> IslandCardPanel {
    let panel = IslandCardPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    configure(panel)
    return panel
  }

  static func configure(_ panel: IslandCardPanel) {
    // Above the island's window (main menu + 3), so the card covers its wings with the same
    // drawing and the notch's clicks reach the card's area.
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
    panel.collectionBehavior = [
      .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
    ]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    // N3, N6: never in a shared screen.
    panel.sharingType = .none
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    // A clear window lets the pointer through unless told otherwise; the hover area must see it.
    panel.ignoresMouseEvents = false
    panel.becomesKeyOnlyIfNeeded = true
  }
}

/// The card window's view: the tracking area over its whole frame (the notch at rest, the card
/// open), and every click, which goes to the controller, except on the rows whose buttons take
/// their own (Ask and Open, "N stopped ›", Start now). Otherwise the SwiftUI content draws only.
final class IslandCardTrackingView: NSView {
  var onEnter: (() -> Void)?
  var onExit: (() -> Void)?
  var onClick: (() -> Void)?
  /// Whether a point, in this view of the given bounds, is on a row whose buttons take the click.
  var isOnOpenRow: ((NSPoint, NSRect) -> Bool)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    // `.inVisibleRect` follows the view's bounds as the window grows and shrinks.
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self))
  }

  required init?(coder: NSCoder) { nil }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard frame.contains(point) else { return nil }
    guard isOnOpenRow?(convert(point, from: superview), bounds) == true else { return self }
    return super.hitTest(point) ?? self
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseEntered(with event: NSEvent) { onEnter?() }
  override func mouseExited(with event: NSEvent) { onExit?() }
  override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Owns the hover card (N6): the hover area on the notch, the delays, and the card's motion out
/// of the notch and back. The island controller places it with its own window. Nothing here runs
/// while nobody hovers: no timer, no full-screen read, and the
/// card's live content is in the view only while it shows.
@MainActor
final class IslandCardController: ObservableObject {
  /// What the card draws: the black, the content's opacity, and the corner radius.
  struct Look: Equatable {
    var fill: Double = 0
    var content: Double = 0
    var radius: CGFloat = 10
    /// The live content is in the view: from the start of the opening to the end of the closing.
    var live = false
  }

  @Published private(set) var look = Look()
  /// The open card's size; its content is laid out at it from the first frame.
  @Published private(set) var size = CGSize(width: NotchGeometry.expandedWidth, height: 0)

  private(set) var hover = NotchHover()
  private(set) var window: IslandCardPanel?
  /// The card's frame while it is open or opening.
  private(set) var cardFrame: CGRect?
  private weak var island: IslandController?
  private var notched: IslandController.Notched?
  /// Bumped by each motion, so a finished one that was replaced does nothing.
  private var motion = 0
  private var animating = false
  /// The card is shrinking back after the pointer left; a return reverses it.
  private var closing = false
  /// Bumped by each pointer check and by every event, so only the latest check runs.
  private var check = 0

  /// How often the pointer is checked while it is in the hover region but outside the window,
  /// where no tracking event would say when it leaves.
  static let recheckEvery: TimeInterval = 0.1

  var isOpen: Bool { hover.isOpen }

  func attach(_ island: IslandController) { self.island = island }

  // MARK: Placement

  /// Puts the hover area on `notched`'s notch, making the window on first need; with no notched
  /// screen, removes it. A display change (`reframe`) closes an open card at once. Otherwise only
  /// a window AppKit moved or hid is put back, so a tick costs a frame comparison.
  func place(_ notched: IslandController.Notched?, reframe: Bool = false) {
    guard let notched else {
      remove()
      return
    }
    let moved = self.notched?.notch != notched.notch
    self.notched = notched
    let window = self.window ?? makeWindow()
    if moved || reframe {
      if hover.cancel() || cardFrame != nil { settle() }
      rest(window, on: notched.notch)
      return
    }
    guard cardFrame == nil, !animating, isOff(window, notched.notch) else { return }
    rest(window, on: notched.notch)
  }

  private func remove() {
    hover.cancel()
    settle()
    window?.orderOut(nil)
    window = nil
    notched = nil
  }

  private func rest(_ window: IslandCardPanel, on notch: CGRect) {
    window.ignoresMouseEvents = false
    // A zero-length motion replaces one still under way (Open or Ask clicked while the
    // card grows or fades in), which would otherwise carry the empty window back to the card's
    // frame, over whatever is under it.
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      window.animator().setFrame(notch, display: false)
    }
    if !window.isVisible { window.orderFrontRegardless() }
  }

  private func isOff(_ window: IslandCardPanel, _ frame: CGRect) -> Bool {
    let actual = window.frame
    return !window.isVisible || abs(actual.minX - frame.minX) > 1
      || abs(actual.minY - frame.minY) > 1 || abs(actual.width - frame.width) > 1
      || abs(actual.height - frame.height) > 1
  }

  /// Back to rest at once: no card, nothing drawn, any motion replaced.
  private func settle() {
    motion += 1
    animating = false
    closing = false
    check += 1
    cardFrame = nil
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) { look = Look() }
  }

  private func makeWindow() -> IslandCardPanel {
    let window = IslandCardPanel.make()
    let tracking = IslandCardTrackingView(frame: .zero)
    tracking.onEnter = { [weak self] in self?.pointerEntered() }
    tracking.onExit = { [weak self] in self?.pointerExited() }
    tracking.onClick = { [weak self] in self?.click() }
    tracking.isOnOpenRow = { [weak self] point, bounds in
      self?.isOnOpenRow(point, in: bounds) ?? false
    }
    if let island {
      let host = NSHostingView(rootView: IslandCardRoot(island: island, card: self))
      // The controller sizes the window; the view must not.
      host.sizingOptions = []
      host.autoresizingMask = [.width, .height]
      tracking.addSubview(host)
    }
    window.contentView = tracking
    self.window = window
    return window
  }

  // MARK: Hover

  /// The pointer is on the notch or the card. Full screen is read here, once per hover, before
  /// the menu bar slides in (which makes the screen read as not full screen).
  func pointerEntered() {
    guard let island, let notched, window != nil else { return }
    check += 1
    if closing { return reopen() }
    if !hover.isOpen, E2EMode.current == nil, island.environment.isFullScreen(notched.screen) {
      return
    }
    hover.enter(at: island.environment.now())
    schedule()
  }

  /// The tracking area says the pointer left the window. While the card is opening or open the
  /// window may still be growing, smaller than the card, so the pointer decides, not the event
  /// (2026-10-27: "The expansion should not close and open").
  func pointerExited() {
    guard let island else { return }
    if hover.isOpen, cardFrame != nil { return recheck() }
    hover.leave(at: island.environment.now())
    schedule()
  }

  /// Where the pointer counts as on the card while it opens, shows or closes; nil at rest.
  var hoverRegion: CGRect? {
    guard let cardFrame, let notched else { return nil }
    return IslandCardMotion.hoverRegion(card: cardFrame, start: start(notched.notch))
  }

  /// Out of the hover region, the grace starts. In it but outside the window (still growing,
  /// or the pointer skims the margin), no tracking event will say when it leaves, so it looks
  /// again shortly; in the window, the tracking area will.
  private func recheck() {
    guard let island, let window, let region = hoverRegion, hover.isOpen else { return }
    let pointer = island.environment.pointer()
    guard region.contains(pointer) else {
      hover.leave(at: island.environment.now())
      return schedule()
    }
    hover.enter(at: island.environment.now())
    guard !window.frame.contains(pointer) else { return }
    check += 1
    let id = check
    island.environment.after(Self.recheckEvery) { [weak self] in
      guard let self, check == id else { return }
      recheck()
    }
  }

  /// The pointer came back while the card shrank: it grows again from where it is, at once.
  private func reopen() {
    closing = false
    hover.returned()
    open(reversing: true)
  }

  private func schedule() {
    guard let island, let deadline = hover.deadline else { return }
    let delay = max(0, deadline.timeIntervalSince(island.environment.now()))
    island.environment.after(delay) { [weak self] in self?.due() }
  }

  /// A delay ran out; `NotchHover` says whether it still means something.
  private func due() {
    guard let island else { return }
    switch hover.fire(at: island.environment.now()) {
    case .open: open()
    case .close: close()
    case nil: break
    }
  }

  /// A click on the card's body, or on the notch while the wings or the card show: the window
  /// opens (N11), as Open › does. The bare notch, with no card and no wings, does nothing (N3).
  func click() {
    guard let island else { return }
    guard hover.isOpen || island.state != .hidden else { return }
    openApp()
  }

  /// Open ›: the window, with Tamebar in front (the only thing from the card that activates it).
  /// The card closes at once, with no grace and no fade.
  func openApp() {
    guard let island else { return }
    hover.cancel()
    finish()
    island.environment.openWindow(island, nil)
  }

  /// The card's "N stopped ›" line (Q15): the window on Activity, where the Stopped list is.
  func openStopped() {
    guard let island else { return }
    hover.cancel()
    finish()
    island.environment.openWindow(island, .activity)
  }

  /// Ask Claude / Ask Codex (N8): Terminal opens running the tool, then the card closes at once,
  /// as for Open, whatever its motion.
  func ask(_ agent: AskAgent) {
    guard let island else { return }
    island.environment.ask(agent)
    hover.cancel()
    finish()
  }

  /// Whether `point`, in the card window's view of `bounds`, is on a row of the open card whose
  /// buttons take their own click: the last row (Ask and Open), "N stopped ›" above it while it
  /// shows, or the waiting block while something waits.
  func isOnOpenRow(_ point: CGPoint, in bounds: CGRect) -> Bool {
    hover.isOpen && look.live
      && IslandCardMotion.isOnButtonRow(
        point, in: bounds, card: size, stopped: (island?.processes.stoppedCount ?? 0) > 0,
        waiting: island?.processes.waitingStarts.count ?? 0)
  }

  // MARK: Motion

  /// Opens the card; `reversing`, it was shrinking and grows again from where it is, its look
  /// carried on from there rather than reset to the first frame.
  private func open(reversing: Bool = false) {
    guard let island, let notched, let window else { return }
    // A tool installed since the last look shows on a later open; the look is off the main thread.
    island.agents.refresh()
    let wing = island.metrics.wingWidth
    let width = NotchGeometry.expanded(notch: notched.notch, contentHeight: 0, wing: wing).width
    let frame = IslandCardMotion.frame(
      notch: notched.notch, contentHeight: island.cardContentHeight(width: width), wing: wing,
      visible: notched.screen.visibleFrame ?? notched.screen.frame)
    cardFrame = frame
    let step = IslandCardMotion.opening(
      notch: start(notched.notch), card: frame, reduceMotion: island.environment.reduceMotion())
    // The first frame: the black on the notch (or nothing, for a fade), the content laid out at
    // the card's size and transparent, the window where the motion starts.
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      size = frame.size
      if !reversing {
        look = Look(
          fill: step.fades ? 0 : 1, content: 0, radius: step.fades ? 14 : 10, live: true)
      }
    }
    // Reversing a close: it grows again from where it is.
    if !reversing { window.setFrame(step.from, display: false) }
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    // Once it is open, the pointer may have left while it grew, past the window's edge, where no
    // tracking event fires: it is checked then.
    run(step, to: Look(fill: 1, content: 1, radius: 14, live: true)) { [weak self] in
      self?.recheck()
    }
  }

  private func close() {
    guard let island, let notched, let frame = cardFrame else { return settle() }
    let step = IslandCardMotion.closing(
      notch: start(notched.notch), card: frame, reduceMotion: island.environment.reduceMotion())
    let target = Look(
      fill: step.fades ? 0 : 1, content: 0, radius: step.fades ? 14 : 10, live: true)
    closing = true
    run(step, to: target) { [weak self] in self?.finish() }
  }

  /// The notch, or the notch and the wings while they show.
  private func start(_ notch: CGRect) -> CGRect {
    IslandCardMotion.start(
      notch: notch, wing: island?.metrics.wingWidth ?? NotchGeometry.wingWidth,
      wingsShow: island.map { $0.state != .hidden } ?? false)
  }

  /// The card's state line: from the menu bar's state, resolved on the same tick and from the
  /// same facts as the wings' (`IslandController.show`), unfiltered by the notch's pressure
  /// flash, so it stays while the event goes on. Pressure has none: the memory line says it
  /// (N12).
  var cardLine: IslandCardLine? { island?.menuState.cardLine }

  /// A closing motion ended: nothing drawn, back on the notch.
  private func finish() {
    settle()
    if let window, let notched { rest(window, on: notched.notch) }
  }

  /// The window's frame and the SwiftUI look move together: one animation group, the same curve
  /// and length, and nothing runs once it has ended.
  private func run(
    _ step: IslandCardMotion.Step, to target: Look, then done: (@MainActor () -> Void)? = nil
  ) {
    guard let window else { return }
    motion += 1
    let id = motion
    animating = true
    let curve = CAMediaTimingFunction(name: .easeOut)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = step.duration
      context.timingFunction = curve
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

  /// The open card's content changed height (sessions came or went): the window follows at once.
  func contentHeight(_ height: CGFloat) {
    guard let island, let notched, let window, hover.isOpen, !animating, let frame = cardFrame
    else { return }
    let next = IslandCardMotion.frame(
      notch: notched.notch, contentHeight: height, wing: island.metrics.wingWidth,
      visible: notched.screen.visibleFrame ?? notched.screen.frame)
    guard abs(next.height - frame.height) > 1 else { return }
    cardFrame = next
    size = next.size
    window.setFrame(next, display: true)
  }
}

extension IslandController {
  /// The card's content height at `width`, measured off screen when it opens.
  func cardContentHeight(width: CGFloat) -> CGFloat {
    NSHostingView(
      rootView: UsageCardLive(island: self, monitor: monitor, processes: processes)
        .frame(width: width)
    ).fittingSize.height
  }
}
