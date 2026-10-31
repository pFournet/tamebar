import AppKit
import SwiftUI
import Testing

@testable import Tamebar

/// The menu-bar item (N7): Tamebar's icon, the island's state beside it from the same source as
/// the wings and the card's line, and the notch's usage card under it on hover or click. Every
/// window here sits far off the real screens, and no status item is put in the menu bar.
@MainActor
struct MenuBarItemTests {
  // MARK: The icon

  /// The icon's pixels at @2x: alpha at a point in the icon's top-left space.
  static func alpha(_ image: NSImage, at point: CGPoint) throws -> CGFloat {
    let rep = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(TamebarIcon.size.width * 2),
        pixelsHigh: Int(TamebarIcon.size.height * 2), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = TamebarIcon.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: CGRect(origin: .zero, size: TamebarIcon.size))
    NSGraphicsContext.restoreGraphicsState()
    // Pixels count from the top-left, as the icon's space does.
    return rep.colorAt(x: Int(point.x * 2), y: Int(point.y * 2))?.alphaComponent ?? 0
  }

  @Test func theIconIsTheBrandMarkAndFollowsTheMenuBar() throws {
    let icon = TamebarIcon.make()
    #expect(icon.size == NSSize(width: 16, height: 16), "menu-bar size")
    #expect(icon.isTemplate, "the menu bar draws it light, dark or tinted")
    let square = TamebarIcon.square
    let dash = TamebarIcon.dash
    let dot = TamebarIcon.dot
    let middle = (dash.from.y + dot.midY) / 2
    #expect(
      try Self.alpha(icon, at: CGPoint(x: square.minX, y: square.midY)) > 0.9, "the square's side")
    #expect(
      try Self.alpha(icon, at: CGPoint(x: square.midX, y: square.minY)) > 0.9, "the square's top")
    #expect(
      try Self.alpha(icon, at: CGPoint(x: 0.3, y: 0.3)) < 0.5, "rounded corners, not square")
    #expect(
      try Self.alpha(icon, at: CGPoint(x: (dash.from.x + dash.to.x) / 2, y: middle)) > 0.9,
      "the dash")
    #expect(try Self.alpha(icon, at: CGPoint(x: dot.midX, y: dot.midY)) > 0.9, "the dot")
    #expect(
      try Self.alpha(icon, at: CGPoint(x: (dash.to.x + dot.minX) / 2 + 0.6, y: middle)) < 0.1,
      "a gap between dash and dot")
    #expect(
      try Self.alpha(icon, at: CGPoint(x: square.midX, y: square.minY + 3)) < 0.1,
      "hollow inside")
  }

  // MARK: The label

  @Test func allIsWellIsTheIconAlone() {
    let label = MenuBarItemLabel(.hidden, colored: true)
    #expect(label.iconOnly)
    #expect(label.symbol == nil)
    let button = NSButton(frame: .zero)
    label.apply(to: button)
    #expect(button.image === TamebarIcon.image)
    #expect(button.imagePosition == .imageOnly)
    #expect(button.attributedTitle.length == 0, "no text: never the RAM value")
    #expect(button.accessibilityLabel() == "\(AppBrand.name), all is well")
  }

  @Test func eachStateBesideTheIcon() {
    let gb = ByteText.full(2_000_000_000)
    let cases: [(IslandState, String)] = [
      (
        .pressure(free: 2_000_000_000, critical: false, strain: ["fan 78%"]), "Struggling · fan 78%"
      ),
      (.pressure(free: 2_000_000_000, critical: true, strain: nil), "Memory is critical · \(gb)"),
      (.call(.calendar, paused: 2), "Call · 2 paused"),
      (.call(.mic, paused: 0), "Call"),
      (.autoPaused(2), "2 paused"),
      (
        .note("Paused 3 idle sessions · 2.4 GB · resumes when memory recovers"),
        "Paused 3 idle sessions · 2.4 GB"
      ),
    ]
    for (state, text) in cases {
      let label = MenuBarItemLabel(state, colored: true)
      #expect(label.text == text, "\(state)")
      let button = NSButton(frame: .zero)
      label.apply(to: button)
      #expect(button.image === TamebarIcon.image, "the icon stays, \(state)")
      #expect(button.imagePosition == .imageLeading)
      #expect(button.attributedTitle.string.hasSuffix(text), "\(state)")
      #expect(button.attributedTitle.string.contains("\u{FFFC}"), "the symbol, \(state)")
    }
  }

  /// The icon stays a template; only the symbol carries the warning color, and only with status
  /// colors on. The text has no color of its own, so the menu bar draws it.
  @Test func onlyTheSymbolCarriesTheColor() throws {
    func symbol(_ label: MenuBarItemLabel) throws -> NSImage {
      let title = label.title()
      var image: NSImage?
      title.enumerateAttribute(.attachment, in: NSRange(location: 0, length: title.length)) {
        value, _, _ in
        if let attachment = value as? NSTextAttachment { image = attachment.image }
      }
      return try #require(image)
    }
    let pressure = IslandState.pressure(free: 2_000_000_000, critical: false, strain: ["fan 78%"])
    let colored = MenuBarItemLabel(pressure, colored: true)
    #expect(colored.tinted)
    #expect(try !symbol(colored).isTemplate, "warning: the symbol is orange")
    let plain = MenuBarItemLabel(pressure, colored: false)
    #expect(!plain.tinted)
    #expect(try symbol(plain).isTemplate, "status colors off: the menu bar's color")
    let call = MenuBarItemLabel(.call(.calendar, paused: 2), colored: true)
    #expect(!call.tinted, "a call isn't a warning")
    #expect(try symbol(call).isTemplate)
    for label in [colored, plain, call] {
      let title = label.title()
      title.enumerateAttribute(
        .foregroundColor, in: NSRange(location: 0, length: title.length)
      ) { value, _, _ in
        #expect(value == nil, "the text follows the menu bar")
      }
    }
    #expect(TamebarIcon.image.isTemplate)
  }

  @Test func theAccessibilityLabelIsTheWholeState() {
    let pressure = IslandState.pressure(free: 2_000_000_000, critical: false, strain: ["fan 78%"])
    #expect(
      MenuBarItemLabel(pressure, colored: true).accessibility
        == "\(AppBrand.name), Struggling · fan 78%", "pressure has no card line: the menu's text")
    #expect(
      MenuBarItemLabel(.call(.calendar, paused: 2), colored: true).accessibility
        == "\(AppBrand.name), In a call · 2 sessions paused")
  }

  // MARK: Where the card goes

  static let away = IslandPanelTests.away

  @Test func theCardHangsUnderTheItemOnAnyScreen() {
    let external = IslandPanelTests.external(at: CGPoint(x: -1920, y: 300))
    let builtIn = IslandPanelTests.builtIn(at: .zero)
    for screen in [external, builtIn] {
      let top = screen.frame.maxY
      let item = CGRect(x: screen.frame.minX + 900, y: top - 24, width: 60, height: 24)
      let card = MenuBarCardGeometry.frame(
        item: item, screen: screen, width: 360, contentHeight: 300)
      #expect(card.maxY == item.minY, "from the menu bar's bottom edge")
      #expect(card.midX == item.midX, "centred on the item")
      #expect(card.height == 300)
      #expect(screen.frame.contains(card), "on the item's screen")
    }
    // An item near the right edge: the card stays on its screen, still under the item.
    let right = CGRect(
      x: external.frame.maxX - 40, y: external.frame.maxY - 24, width: 30, height: 24)
    let card = MenuBarCardGeometry.frame(
      item: right, screen: external, width: 360, contentHeight: 200)
    #expect(card.maxX == external.frame.maxX - MenuBarCardGeometry.screenMargin)
    #expect(card.minX < right.minX && card.maxX > right.maxX, "under the item")
    // Near the left edge.
    let left = CGRect(
      x: external.frame.minX + 4, y: external.frame.maxY - 24, width: 30, height: 24)
    #expect(
      MenuBarCardGeometry.frame(item: left, screen: external, width: 360, contentHeight: 200).minX
        == external.frame.minX + MenuBarCardGeometry.screenMargin)
    // No taller than the screen allows.
    let tall = MenuBarCardGeometry.frame(
      item: left, screen: external, width: 360, contentHeight: 5_000)
    #expect(tall.height == external.frame.height - 40)
    #expect(MenuBarCardGeometry.start(item: left).maxY == left.minY, "grows from under the item")
  }

  // MARK: The controller

  @MainActor final class Rig {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var fullScreen = false
    var meeting = false
    var risk = MemoryRisk.normal
    /// Q19's strain reasons while the Mac struggles; nil, it doesn't.
    var strain: [String]?
    var note: (text: String, at: Date)?
    var pointer = CGPoint(x: -50_000, y: -50_000)
    var pending: [(at: Date, work: @MainActor () -> Void)] = []
    var opened: [WindowTab?] = []
    let screen = IslandPanelTests.external(at: MenuBarItemTests.away)
    var item: CGRect
    let island: IslandController
    let menuBar: MenuBarItemController

    init(name: String, motion: Bool = false) {
      item = CGRect(
        x: screen.frame.minX + 1200, y: screen.frame.maxY - 24, width: 40, height: 24)
      island = IslandController(
        monitor: SystemMonitor(), memory: MemoryRescueModel(),
        navigation: WindowNavigation(), processes: DevProcessModel())
      menuBar = MenuBarItemController(island: island)
      island.environment = .init(
        now: { [unowned self] in now }, screens: { [unowned self] in [screen] },
        facts: { [unowned self] now in
          .init(
            now: now, meeting: meeting, source: .calendar, ledger: [], risk: risk,
            freeBytes: 2_000_000_000, lastResume: nil, note: note, struggling: strain != nil,
            strain: strain ?? [])
        },
        isFullScreen: { _ in false }, reduceMotion: { !motion },
        openWindow: { [unowned self] _, tab in opened.append(tab) },
        after: { [unowned self] delay, work in
          pending.append((now.addingTimeInterval(delay), work))
        },
        pointer: { [unowned self] in pointer })
      menuBar.environment = .init(
        anchor: { [unowned self] in .init(item: item, screen: screen) },
        isFullScreen: { [unowned self] _ in fullScreen }, colored: { true })
    }

    func advance(_ seconds: TimeInterval) {
      now = now.addingTimeInterval(seconds)
      let due = pending.filter { $0.at <= now }
      pending.removeAll { $0.at <= now }
      for item in due { item.work() }
    }

    /// Ends any motion at once (a late animation completion would read this rig's environment
    /// after the test), then hides the card.
    func tearDown() {
      menuBar.openApp()
      menuBar.cardWindow?.orderOut(nil)
    }
  }

  func settle() async throws { try await Task.sleep(for: .seconds(0.4)) }

  @Test func theLabelFollowsTheMenuBarStateOnEachTick() {
    let rig = Rig(name: "menubar-label")
    defer { rig.tearDown() }
    rig.island.tick()
    rig.menuBar.refresh()
    #expect(rig.menuBar.label.iconOnly, "all is well")
    rig.risk = .warning
    rig.island.tick()
    rig.menuBar.refresh()
    #expect(rig.menuBar.label.iconOnly, "warning alone: the icon alone (N12)")
    rig.strain = ["fan 78%"]
    rig.island.tick()
    rig.menuBar.refresh()
    #expect(rig.menuBar.label.text == "Struggling · fan 78%")
    #expect(rig.island.state.wingText?.label == "struggling", "the notch flashes it")
    rig.advance(10)
    rig.island.tick()
    rig.menuBar.refresh()
    #expect(rig.island.state == .hidden, "the notch's flash is over")
    #expect(rig.menuBar.label.text == "Struggling · fan 78%", "the menu bar keeps it")
    rig.risk = .normal
    rig.strain = nil
    rig.note = ("Slowed 2 builds", rig.now)
    rig.island.tick()
    rig.menuBar.refresh()
    #expect(rig.menuBar.label.text == "Slowed 2 builds")
    rig.advance(4.5)
    rig.island.tick()
    rig.menuBar.refresh()
    #expect(rig.menuBar.label.iconOnly, "4 s, then back to the icon")
  }

  @Test func hoverOpensTheCardUnderTheItemAndLeavingClosesIt() async throws {
    let rig = Rig(name: "menubar-hover")
    defer { rig.tearDown() }
    rig.menuBar.pointerEntered()
    rig.advance(0.2)
    #expect(!rig.menuBar.isOpen, "not before 0.3 s")
    rig.advance(0.1)
    #expect(rig.menuBar.isOpen)
    let card = try #require(rig.menuBar.cardFrame)
    #expect(card.maxY == rig.item.minY, "under the item")
    #expect(card.midX == rig.item.midX)
    #expect(card.width == NotchGeometry.expandedWidth, "the notch card's width")
    let window = try #require(rig.menuBar.cardWindow)
    #expect(window.isVisible)
    #expect(!window.isKeyWindow)

    // Down into the card: the item's exit, the pointer in the region, keeps it.
    rig.pointer = CGPoint(x: card.midX, y: card.maxY - 10)
    rig.menuBar.pointerExited()
    rig.advance(1)
    #expect(rig.menuBar.isOpen, "the pointer is in the card")

    rig.pointer = CGPoint(x: card.minX - 100, y: card.midY)
    rig.menuBar.pointerExited()
    rig.advance(0.19)
    #expect(rig.menuBar.isOpen, "still in the grace")
    rig.advance(0.01)
    #expect(!rig.menuBar.isOpen)
    try await settle()
    #expect(!window.isVisible, "gone at rest")
    #expect(rig.menuBar.look == .init())
  }

  /// The user, 2026-10-27 (9aa678d): an exit while the card grows, with the pointer inside the frame
  /// it opens to, is no leave.
  @Test func anExitDuringTheMotionWithThePointerInsideIsIgnored() async throws {
    let rig = Rig(name: "menubar-motion", motion: true)
    defer { rig.tearDown() }
    rig.menuBar.pointerEntered()
    rig.advance(0.3)
    let card = try #require(rig.menuBar.cardFrame)
    let window = try #require(rig.menuBar.cardWindow)
    #expect(window.frame.height < card.height - 20, "grows from the item")
    rig.pointer = CGPoint(x: card.midX, y: card.minY + 20)
    rig.menuBar.pointerExited()
    rig.advance(0.25)
    #expect(rig.menuBar.isOpen, "no grace started")
    try await Task.sleep(for: .seconds(IslandController.motion + 0.2))
    #expect(rig.menuBar.isOpen)
    #expect(abs(window.frame.height - card.height) <= 1, "the motion ends on the card")
  }

  @Test func aClickOpensTheCardAndASecondClickClosesIt() async throws {
    let rig = Rig(name: "menubar-click")
    defer { rig.tearDown() }
    rig.menuBar.itemClicked()
    #expect(rig.menuBar.isOpen, "at once, with no rest")
    #expect(rig.menuBar.cardFrame?.maxY == rig.item.minY)
    rig.menuBar.itemClicked()
    #expect(!rig.menuBar.isOpen, "a second click closes it")
    try await settle()
    #expect(rig.menuBar.cardWindow?.isVisible == false)
    // The pointer still on the item: nothing reopens it until it comes back.
    rig.advance(1)
    #expect(!rig.menuBar.isOpen)
  }

  /// A click on the card's body opens Tamebar's window (N11), and the card closes at once.
  @Test func aClickOnTheCardOpensTheWindow() async throws {
    let rig = Rig(name: "menubar-window")
    defer { rig.tearDown() }
    rig.menuBar.itemClicked()
    rig.menuBar.cardClicked()
    #expect(rig.opened == [nil])
    #expect(!rig.menuBar.isOpen, "the card gives way")
    #expect(rig.menuBar.cardWindow?.isVisible == false)
  }

  /// The item's button targets its tracker, an `NSResponder`, so AppKit's target-action and the
  /// tracking area reach the controller.
  @Test func theTrackerForwardsTheClickAndThePointer() {
    let tracker = MenuBarItemTracker()
    var calls: [String] = []
    tracker.onClick = { calls.append("click") }
    tracker.onEnter = { calls.append("enter") }
    tracker.onExit = { calls.append("exit") }
    #expect(tracker.responds(to: #selector(MenuBarItemTracker.clicked)))
    _ = tracker.perform(#selector(MenuBarItemTracker.clicked))
    tracker.mouseEntered(with: NSEvent())
    tracker.mouseExited(with: NSEvent())
    #expect(calls == ["click", "enter", "exit"])
  }

  @Test func openOpensTheWindowAndStoppedOpensActivity() {
    let rig = Rig(name: "menubar-open")
    defer { rig.tearDown() }
    rig.menuBar.itemClicked()
    rig.menuBar.openApp()
    #expect(rig.opened == [nil], "the notch card's route")
    #expect(!rig.menuBar.isOpen)
    #expect(rig.menuBar.cardWindow?.isVisible == false, "at once, no fade")
    rig.menuBar.itemClicked()
    rig.menuBar.openStopped()
    #expect(rig.opened == [nil, .activity])
  }

  @Test func fullScreenShowsNoCardAndAClickOpensTheWindow() {
    let rig = Rig(name: "menubar-fullscreen")
    defer { rig.tearDown() }
    rig.fullScreen = true
    rig.menuBar.pointerEntered()
    rig.advance(1)
    #expect(!rig.menuBar.isOpen, "no card in full screen")
    rig.menuBar.itemClicked()
    #expect(!rig.menuBar.isOpen)
    #expect(rig.opened == [nil], "the click opens the window")
  }

  @Test func theCardStaysOutOfSharedScreensAndFocus() {
    let rig = Rig(name: "menubar-panels")
    defer { rig.tearDown() }
    rig.menuBar.itemClicked()
    let card = rig.menuBar.cardWindow
    #expect(card?.sharingType == NSWindow.SharingType.none, "never in a shared screen")
    #expect(card?.canBecomeKey == false, "never key before a click")
    #expect(card?.canBecomeMain == false)
    #expect(card?.styleMask.contains(.nonactivatingPanel) == true)
  }
}
