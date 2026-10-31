import AppKit
import SwiftUI
import Testing

@testable import Tamebar

/// The hover card's window (N6): a transparent hover area on the notch rect that grows into the
/// card. Never in a shared screen, never key or main, never shown in full screen, and none at all
/// without a notched screen. Every window here sits far off the real screens.
@MainActor
struct IslandCardPanelTests {
  @Test func theCardStaysOutOfSharedScreensAndFocus() {
    let panel = IslandCardPanel.make()
    expectConfigured(panel)
  }

  /// A rig over injected screens, clock and delays: nothing waits on real time but the motion.
  @MainActor final class Rig {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var screens: [NotchGeometry.Screen]
    var fullScreen = false
    var fullScreenReads = 0
    var meeting = false
    var risk = MemoryRisk.normal
    /// Q19's strain reasons while the Mac struggles; nil, it doesn't.
    var strain: [String]?
    /// Where the pointer is, in screen coordinates: far from every window unless a test moves it.
    var pointer = CGPoint(x: -50_000, y: -50_000)
    var pending: [(at: Date, work: @MainActor () -> Void)] = []
    let controller: IslandController

    /// What Ask Claude / Ask Codex launched (N8): never a real Terminal.
    var asked: [AskAgent] = []
    /// What opened Tamebar's window (N11), and on which tab: never the real window.
    var opened: [WindowTab?] = []
    var notchShown = true

    init(
      _ screens: [NotchGeometry.Screen], name: String, motion: Bool = false,
      agents: [AskAgent] = []
    ) {
      self.screens = screens
      controller = IslandController(
        monitor: SystemMonitor(), memory: MemoryRescueModel(),
        navigation: WindowNavigation(), processes: DevProcessModel(),
        agents: AskAgents(installed: agents))
      controller.environment = .init(
        now: { [unowned self] in now }, screens: { [unowned self] in self.screens },
        facts: { [unowned self] now in
          .init(
            now: now, meeting: meeting, source: .calendar, ledger: [], risk: risk,
            freeBytes: 2_000_000_000, lastResume: nil, note: nil, struggling: strain != nil,
            strain: strain ?? [])
        },
        isFullScreen: { [unowned self] _ in
          fullScreenReads += 1
          return fullScreen
        },
        reduceMotion: { !motion },
        after: { [unowned self] delay, work in
          pending.append((now.addingTimeInterval(delay), work))
        },
        pointer: { [unowned self] in pointer })
      controller.environment.ask = { [unowned self] in asked.append($0) }
      controller.environment.openWindow = { [unowned self] _, tab in opened.append(tab) }
      controller.environment.notchShown = { [unowned self] in notchShown }
    }

    var card: IslandCardController { controller.card }

    /// Moves the clock on and runs every delay that has come.
    func advance(_ seconds: TimeInterval) {
      now = now.addingTimeInterval(seconds)
      let due = pending.filter { $0.at <= now }
      pending.removeAll { $0.at <= now }
      for item in due { item.work() }
    }

    func notch() throws -> CGRect {
      try #require(NotchGeometry.notchedScreen(in: screens)?.notch)
    }
  }

  static let away = IslandPanelTests.away
  static func builtIn() -> NotchGeometry.Screen { IslandPanelTests.builtIn(at: away) }

  /// Lets the short fade (Reduce Motion) end.
  func settle() async throws { try await Task.sleep(for: .seconds(0.4)) }

  func expectNear(
    _ actual: CGRect?, _ frame: CGRect, _ comment: Comment,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let actual = actual ?? .null
    let close =
      abs(actual.minX - frame.minX) <= 1 && abs(actual.minY - frame.minY) <= 1
      && abs(actual.width - frame.width) <= 1 && abs(actual.height - frame.height) <= 1
    #expect(close, "\(comment): at \(actual), not \(frame)", sourceLocation: sourceLocation)
  }

  // MARK: Where the hover area is

  @Test func withoutANotchedScreenThereIsNoHoverWindow() throws {
    let external = IslandPanelTests.external(at: Self.away)
    let rig = Rig([external], name: "card-no-notch")
    defer { rig.controller.place(nil) }
    rig.controller.tick()
    #expect(rig.card.window == nil, "no notch: no window is made")
    rig.card.pointerEntered()
    rig.advance(1)
    #expect(!rig.card.isOpen, "nothing happens")

    // The lid opens: the hover area sits on the notch, the notch rect only.
    rig.screens = [Self.builtIn(), external]
    rig.controller.screensChanged()
    let window = try #require(rig.card.window)
    expectNear(window.frame, try rig.notch(), "on the notch rect")
    #expect(window.isVisible)

    // The lid closes again: the window goes.
    rig.screens = [external]
    rig.controller.screensChanged()
    #expect(rig.card.window == nil)
    #expect(!window.isVisible)
  }

  /// N9: with the notch off in Settings, neither the island nor the card has a window, and the
  /// menu bar's state still resolves; turned back on, both come back, live.
  @Test func turningTheNotchOffRemovesItsWindows() throws {
    let rig = Rig([Self.builtIn()], name: "card-notch-off")
    defer { rig.controller.place(nil) }
    rig.risk = .warning
    rig.strain = ["fan 78%"]
    rig.controller.tick()
    #expect(rig.card.window != nil && rig.controller.window != nil)
    #expect(rig.controller.notchScreen)

    rig.notchShown = false
    rig.controller.tick()
    #expect(rig.card.window == nil, "no hover area")
    #expect(rig.controller.window == nil, "no wings")
    #expect(rig.controller.notchScreen, "the notch screen is still there")
    #expect(rig.controller.menuState.debugName == "pressure", "the menu bar still has the state")
    rig.card.pointerEntered()
    rig.advance(1)
    #expect(!rig.card.isOpen)

    rig.notchShown = true
    rig.controller.tick()
    let window = try #require(rig.card.window)
    expectNear(window.frame, try rig.notch(), "back on the notch")
    #expect(rig.controller.window != nil)
  }

  @Test func theHoverAreaFollowsTheNotchThroughDisplayChanges() throws {
    let rig = Rig([Self.builtIn()], name: "card-display")
    defer { rig.controller.place(nil) }
    rig.controller.tick()
    let window = try #require(rig.card.window)
    expectNear(window.frame, try rig.notch(), "on the notch")

    let shifted = IslandPanelTests.builtIn(
      at: CGPoint(x: Self.away.x + 1920, y: Self.away.y - 98), larger: true)
    rig.screens = [IslandPanelTests.external(at: Self.away), shifted]
    rig.controller.screensChanged()
    expectNear(window.frame, try rig.notch(), "moved and resized with the notch")

    // AppKit moves it during a change that keeps the notch: the next tick puts it back.
    window.setFrame(CGRect(x: Self.away.x, y: Self.away.y, width: 300, height: 40), display: false)
    rig.controller.tick()
    expectNear(window.frame, try rig.notch(), "back on the notch")
  }

  // MARK: Opening and closing

  @Test func restingOnTheNotchOpensTheCardAndLeavingClosesItAfterAGrace() async throws {
    let rig = Rig([Self.builtIn()], name: "card-hover")
    defer { rig.controller.place(nil) }
    rig.controller.tick()
    #expect(rig.controller.state == .hidden, "works with the island hidden")
    let window = try #require(rig.card.window)

    rig.card.pointerEntered()
    rig.advance(0.2)
    #expect(!rig.card.isOpen, "not before 0.3 s")
    rig.advance(0.1)
    #expect(rig.card.isOpen)
    let card = try #require(rig.card.cardFrame)
    let panelWidth = NotchGeometry.expanded(
      notch: try rig.notch(), contentHeight: 0, wing: rig.controller.metrics.wingWidth
    ).width
    #expect(card.width == panelWidth, "the panel's width")
    #expect(abs(card.midX - (try rig.notch()).midX) < 0.5, "centred on the notch")
    #expect(card.maxY == (try rig.notch()).maxY, "hangs from the top edge")
    expectNear(window.frame, card, "Reduce Motion: at its frame at once, fading in")

    // Down into the card: the pointer never leaves the window. Out, and back within the grace.
    rig.card.pointerExited()
    rig.advance(0.1)
    rig.card.pointerEntered()
    rig.advance(1)
    #expect(rig.card.isOpen, "back within the grace")

    rig.card.pointerExited()
    rig.advance(0.19)
    #expect(rig.card.isOpen, "still in the grace")
    rig.advance(0.01)
    #expect(!rig.card.isOpen)
    try await settle()
    expectNear(window.frame, try rig.notch(), "back to the notch rect")
    #expect(window.isVisible, "the hover area stays")
  }

  @Test func withTheWingsShowingTheCardOpensUnderThem() throws {
    let rig = Rig([Self.builtIn()], name: "card-wings")
    rig.meeting = true
    defer { rig.controller.place(nil) }
    rig.controller.tick()
    #expect(rig.controller.state == .call(.calendar, paused: 0))
    rig.card.pointerEntered()
    rig.advance(0.3)
    #expect(rig.card.isOpen)
    let card = try #require(rig.card.cardFrame)
    let wings = NotchGeometry.collapsed(
      notch: try rig.notch(), wing: rig.controller.metrics.wingWidth
    ).panel
    #expect(card.width >= wings.width)
    #expect(abs(card.midX - wings.midX) < 0.5)
    #expect(card.height > wings.height)
  }

  /// With motion the card grows out of the notch: the window starts on the notch rect, never at
  /// the card's size before the motion, and ends on the card's frame; closing shrinks it back.
  @Test func theCardGrowsOutOfTheNotchAndShrinksBack() async throws {
    let rig = Rig([Self.builtIn()], name: "card-motion", motion: true)
    defer { rig.controller.place(nil) }
    rig.controller.tick()
    let window = try #require(rig.card.window)
    let notch = try rig.notch()
    rig.card.pointerEntered()
    rig.advance(0.3)
    let card = try #require(rig.card.cardFrame)
    #expect(window.frame.width < card.width - 20, "still near the notch: \(window.frame)")
    #expect(window.frame.height < card.height - 20, "no frame at the final size first")
    #expect(rig.card.look.fill == 1, "the island's black from the first frame")
    try await Task.sleep(for: .seconds(IslandController.motion + 0.2))
    expectNear(window.frame, card, "the motion ends on the card")
    #expect(rig.card.look == .init(fill: 1, content: 1, radius: 14, live: true))

    rig.card.pointerExited()
    rig.advance(NotchHover.closeAfter)
    try await Task.sleep(for: .seconds(IslandCardMotion.close + 0.2))
    expectNear(window.frame, notch, "back into the notch")
    #expect(rig.card.look == .init(), "nothing drawn at rest")
  }

  /// The user, 2026-10-27: the wings stay while the card is open, and the card grows from them.
  @Test func theWingsStayAndTheCardGrowsFromThem() async throws {
    let rig = Rig([Self.builtIn()], name: "card-wings-motion", motion: true)
    rig.meeting = true
    defer { rig.controller.place(nil) }
    rig.controller.tick()
    try await Task.sleep(for: .seconds(IslandController.motion + 0.2))
    let island = try #require(rig.controller.window)
    let wings = island.frame
    rig.card.pointerEntered()
    rig.advance(0.3)
    let window = try #require(rig.card.window)
    expectNear(window.frame, wings, "starts on the notch-plus-wings shape")
    #expect(rig.card.cardLine?.text == "In a call · nothing paused")
    try await Task.sleep(for: .seconds(IslandController.motion + 0.2))
    #expect(island.isVisible, "the wings stay up")
    expectNear(island.frame, wings, "and where they were")
    #expect(rig.controller.state == .call(.calendar, paused: 0))

    rig.card.pointerExited()
    rig.advance(NotchHover.closeAfter)
    try await Task.sleep(for: .seconds(IslandCardMotion.close + 0.2))
    #expect(rig.card.look == .init(), "closed")
    try await Task.sleep(for: .seconds(0.1))
    #expect(island.isVisible)
  }

  /// N12: real pressure has no state line on the card (its memory line says it, so free memory
  /// shows once), during the wings' 4 s flash and after it, while the menu bar keeps it. Warning
  /// alone shows nothing anywhere.
  @Test func pressureHasNoStateLineOnTheCard() throws {
    let rig = Rig([Self.builtIn()], name: "card-pressure-line")
    rig.risk = .warning
    defer { rig.controller.place(nil) }
    rig.controller.tick()
    #expect(rig.controller.state == .hidden && rig.controller.menuState == .hidden)
    #expect(rig.card.cardLine == nil)
    rig.strain = ["fan 78%"]
    rig.advance(1)
    rig.controller.tick()
    let struggling = IslandState.pressure(
      free: 2_000_000_000, critical: false, strain: ["fan 78%"])
    #expect(rig.controller.state == struggling, "the wings flash it")
    #expect(rig.card.cardLine == nil, "the memory line says it")
    rig.advance(5)
    rig.controller.tick()
    #expect(rig.controller.state == .hidden, "the wings' flash is over")
    #expect(rig.controller.menuState == struggling, "the menu bar keeps it")
    #expect(rig.card.cardLine == nil)
    rig.meeting = true
    rig.controller.tick()
    #expect(rig.card.cardLine?.text == "In a call · nothing paused", "a call keeps its line")
  }

  // MARK: Full screen

  /// Full screen is read only once the pointer is on the notch, never while all is quiet.
  @Test func fullScreenShowsNoCardAndCostsNothingWhileNotHovering() throws {
    let rig = Rig([Self.builtIn()], name: "card-full-screen")
    defer { rig.controller.place(nil) }
    rig.fullScreen = true
    for _ in 0..<5 {
      rig.controller.tick()
      rig.advance(1)
    }
    #expect(rig.fullScreenReads == 0, "not read while nobody hovers")
    rig.card.pointerEntered()
    rig.advance(1)
    #expect(!rig.card.isOpen, "no card in full screen")
    #expect(rig.fullScreenReads == 1)
    expectNear(rig.card.window?.frame, try rig.notch(), "the hover area stays on the notch")

    rig.card.pointerExited()
    rig.fullScreen = false
    rig.card.pointerEntered()
    rig.advance(0.3)
    #expect(rig.card.isOpen, "out of full screen it opens")
  }

  // MARK: Focus

  @Test func theCardNeverTakesTheKeyboard() throws {
    let rig = Rig([Self.builtIn()], name: "card-key")
    defer { rig.controller.place(nil) }
    rig.controller.tick()
    let keyBefore = NSApplication.shared.keyWindow
    rig.card.pointerEntered()
    rig.advance(0.3)
    let window = try #require(rig.card.window)
    #expect(rig.card.isOpen)
    #expect(!window.isKeyWindow && !window.isMainWindow)
    #expect(NSApplication.shared.keyWindow === keyBefore)
    window.makeKey()
    #expect(!window.isKeyWindow, "refuses key status even when asked")
  }

  // MARK: A click opens the window (N11)

  @Test func aClickOnTheCardOpensTheWindowAndClosesTheCard() async throws {
    let rig = Rig([Self.builtIn()], name: "card-click")
    defer { rig.controller.place(nil) }
    rig.controller.tick()
    rig.card.pointerEntered()
    rig.advance(0.3)
    #expect(rig.card.isOpen)
    rig.card.click()
    #expect(rig.opened == [nil], "Tamebar's window")
    #expect(!rig.card.isOpen, "the card closes")
    try await settle()
    expectNear(rig.card.window?.frame, try rig.notch(), "the hover area is back on the notch")
    #expect(rig.card.window?.ignoresMouseEvents == false)
  }

  /// N3 holds: the bare notch, with no wings and no card yet, does nothing on a click.
  @Test func aClickOnTheBareNotchDoesNothing() throws {
    let rig = Rig([Self.builtIn()], name: "card-bare-click")
    defer { rig.controller.place(nil) }
    rig.controller.tick()
    rig.card.click()
    #expect(rig.opened.isEmpty)
    // With the wings showing, the notch opens the window, as the wings' button does.
    rig.meeting = true
    rig.controller.tick()
    rig.card.click()
    #expect(rig.opened == [nil])
  }

  // MARK: Moving while it grows (2026-10-27: "The expansion should not close and open.")

  /// The pointer moves down to where the card is going while the window is still small: the
  /// tracking area reports an exit, but the pointer is inside the frame the card opens to.
  @Test func movingBelowTheNotchWhileTheCardGrowsKeepsItOpening() async throws {
    let rig = Rig([Self.builtIn()], name: "card-move-grow", motion: true)
    defer { rig.controller.place(nil) }
    rig.controller.tick()
    let window = try #require(rig.card.window)
    let notch = try rig.notch()
    rig.pointer = CGPoint(x: notch.midX, y: notch.midY)
    rig.card.pointerEntered()
    rig.advance(0.3)
    let card = try #require(rig.card.cardFrame)
    try await Task.sleep(for: .seconds(0.05))
    rig.pointer = CGPoint(x: card.midX, y: card.minY + 20)
    #expect(!window.frame.contains(rig.pointer), "the window isn't there yet")
    rig.card.pointerExited()
    rig.advance(NotchHover.closeAfter + 0.1)
    #expect(rig.card.isOpen, "no grace started: it keeps opening")
    try await Task.sleep(for: .seconds(IslandController.motion + 0.2))
    expectNear(window.frame, card, "and it finishes opening")
    rig.advance(1)
    #expect(rig.card.isOpen)
    #expect(rig.card.look == .init(fill: 1, content: 1, radius: 14, live: true))
  }

  /// An exit fired mid-motion while the pointer is in the region (here the 6 pt margin below the
  /// card) is ignored. When the pointer then really leaves, with no event left to say so, the
  /// card notices and closes after the grace.
  @Test func anExitDuringTheMotionWithThePointerInsideIsIgnored() async throws {
    let rig = Rig([Self.builtIn()], name: "card-exit-mid-motion", motion: true)
    defer { rig.controller.place(nil) }
    rig.controller.tick()
    let window = try #require(rig.card.window)
    let notch = try rig.notch()
    rig.pointer = CGPoint(x: notch.midX, y: notch.midY)
    rig.card.pointerEntered()
    rig.advance(0.3)
    let card = try #require(rig.card.cardFrame)
    try await Task.sleep(for: .seconds(0.1))
    rig.pointer = CGPoint(x: card.midX, y: card.minY - 4)
    rig.card.pointerExited()
    rig.advance(0.5)
    #expect(rig.card.isOpen, "ignored")
    try await Task.sleep(for: .seconds(IslandController.motion + 0.1))
    expectNear(window.frame, card, "opened")
    rig.advance(0.5)
    #expect(rig.card.isOpen, "skimming the edge keeps it")

    rig.pointer = CGPoint(x: card.midX, y: card.minY - 200)
    rig.advance(0.1)
    #expect(rig.card.isOpen, "the grace")
    rig.advance(NotchHover.closeAfter)
    #expect(!rig.card.isOpen, "then it closes")
  }

  /// The pointer leaves while the window is still moving and no exit arrives (a tracking area's
  /// events aren't trusted mid-motion): the card checks the pointer once it is open.
  @Test func aPointerThatLeftDuringTheMotionIsCaughtWhenItEnds() async throws {
    let rig = Rig([Self.builtIn()], name: "card-lost-exit", motion: true)
    defer { rig.controller.place(nil) }
    rig.controller.tick()
    let notch = try rig.notch()
    rig.pointer = CGPoint(x: notch.midX, y: notch.midY)
    rig.card.pointerEntered()
    rig.advance(0.3)
    try await Task.sleep(for: .seconds(0.1))
    rig.pointer = CGPoint(x: notch.midX, y: notch.minY - 600)
    try await Task.sleep(for: .seconds(IslandController.motion + 0.1))
    #expect(rig.card.isOpen, "the grace")
    rig.advance(NotchHover.closeAfter)
    #expect(!rig.card.isOpen, "then it closes")
  }

  @Test func leavingForRealClosesAfterTheGrace() throws {
    let rig = Rig([Self.builtIn()], name: "card-leave")
    defer { rig.controller.place(nil) }
    rig.controller.tick()
    let notch = try rig.notch()
    rig.pointer = CGPoint(x: notch.midX, y: notch.midY)
    rig.card.pointerEntered()
    rig.advance(0.3)
    let card = try #require(rig.card.cardFrame)
    rig.pointer = CGPoint(x: card.midX, y: card.minY - 50)
    rig.card.pointerExited()
    rig.advance(NotchHover.closeAfter - 0.01)
    #expect(rig.card.isOpen, "the grace")
    rig.advance(0.01)
    #expect(!rig.card.isOpen)
  }

  /// Back in while the card shrinks: it grows again from where it is, at once, never from the
  /// notch after a new rest.
  @Test func comingBackWhileTheCardClosesReversesIt() async throws {
    let rig = Rig([Self.builtIn()], name: "card-reverse", motion: true)
    defer { rig.controller.place(nil) }
    rig.controller.tick()
    let window = try #require(rig.card.window)
    let notch = try rig.notch()
    rig.pointer = CGPoint(x: notch.midX, y: notch.midY)
    rig.card.pointerEntered()
    rig.advance(0.3)
    let card = try #require(rig.card.cardFrame)
    try await Task.sleep(for: .seconds(IslandController.motion + 0.2))
    expectNear(window.frame, card, "open")

    rig.pointer = CGPoint(x: card.midX, y: card.minY - 200)
    rig.card.pointerExited()
    rig.advance(NotchHover.closeAfter)
    #expect(!rig.card.isOpen, "closing")
    try await Task.sleep(for: .seconds(0.06))
    let shrinking = window.frame
    #expect(shrinking.height < card.height - 1, "on its way back: \(shrinking)")

    rig.pointer = CGPoint(x: card.midX, y: card.maxY - notch.height - 10)
    rig.card.pointerEntered()
    #expect(rig.card.isOpen, "at once, with no new rest on the notch")
    #expect(window.frame.height >= shrinking.height - 1, "from where it is, not the notch")
    try await Task.sleep(for: .seconds(IslandController.motion + 0.2))
    // The card's frame now: its height follows this Mac's live sessions.
    expectNear(window.frame, try #require(rig.card.cardFrame), "open again")
    #expect(window.frame.height > notch.height + 40, "a card, not the notch")
    #expect(rig.card.look == .init(fill: 1, content: 1, radius: 14, live: true))
    rig.advance(1)
    #expect(rig.card.isOpen)
  }

  // MARK: Open ›

  /// N11: every card ends with Open ›, whatever it shows: with or without the state line, with
  /// the asks or none.
  @Test func everyCardEndsWithOpen() async throws {
    let snapshot = SystemSnapshot(
      .init(
        diskAvailable: 88_000_000_000, diskTotal: 494_000_000_000, ramAvailable: 6_100_000_000,
        ramTotal: 36_000_000_000, memoryPressure: .normal, cpuUsage: 0.34,
        thermalStatus: .nominal, updatedAt: .now))
    let call = IslandState.call(.calendar, paused: 2).cardLine
    let variants: [(String, UsageCardContent)] = [
      ("plain", .init(snapshot: snapshot, now: .now)),
      ("asks", .init(snapshot: snapshot, now: .now, asks: [.claude, .codex])),
      ("state line", .init(snapshot: snapshot, now: .now, line: call)),
      ("everything", .init(snapshot: snapshot, now: .now, line: call, stopped: 2, asks: [.codex])),
    ]
    #expect(UsageCardView.openTitle == "Open")
    for (name, content) in variants {
      #expect(try await Self.clicksOnOpen(of: content) == 1, "\(name)")
    }
  }

  /// Open › opens the window and closes the card at once: no grace, no fade.
  @Test func openOpensTheWindowAndClosesTheCardAtOnce() throws {
    let rig = Rig([Self.builtIn()], name: "card-open-app")
    defer { rig.controller.place(nil) }
    rig.controller.tick()
    rig.card.pointerEntered()
    rig.advance(0.3)
    #expect(rig.card.isOpen)

    rig.card.openApp()
    #expect(rig.opened == [nil], "the window, on its last tab")
    #expect(!rig.card.isOpen, "the card closes")
    #expect(rig.card.look == .init(), "at once, nothing left drawn")
    #expect(rig.card.cardFrame == nil)
    expectNear(rig.card.window?.frame, try rig.notch(), "back on the notch, with no motion")
    #expect(rig.card.window?.ignoresMouseEvents == false, "the hover area works again")
    rig.advance(1)
    #expect(rig.opened == [nil])
    #expect(!rig.card.isOpen, "no grace delay reopens or closes it later")

    rig.card.pointerEntered()
    rig.advance(0.3)
    rig.card.openStopped()
    #expect(rig.opened == [nil, .activity], "N stopped › opens Activity")
  }

  /// The last row's buttons take their own clicks; the rest of the card is the card's click,
  /// which opens the window too. Real mouse events, sent to the card's window as AppKit would.
  @Test func theLastRowTakesItsOwnClick() async throws {
    let rig = Rig([Self.builtIn()], name: "card-open-click")
    defer { rig.controller.place(nil) }
    rig.controller.tick()
    let window = try #require(rig.card.window)
    let tracking = try #require(window.contentView as? IslandCardTrackingView)
    let bottom = CGPoint(x: tracking.bounds.midX, y: 4)
    #expect(tracking.hitTest(bottom) === tracking, "closed: the notch is the card's own")

    rig.card.pointerEntered()
    rig.advance(0.3)
    try await settle()
    let card = try #require(rig.card.cardFrame)
    expectNear(window.frame, card, "open")
    let row = IslandCardMotion.actionRow(in: tracking.bounds, card: rig.card.size)
    let open = CGPoint(x: row.maxX - 30, y: row.midY)
    let above = CGPoint(x: tracking.bounds.midX, y: row.maxY + 12)
    #expect(tracking.hitTest(open) !== tracking, "the row's button takes its click")
    #expect(tracking.hitTest(above) === tracking, "the rest of the card is the card's click")

    try Self.click(window, at: open)
    #expect(rig.opened == [nil], "Open › ran")
    #expect(!rig.card.isOpen, "the card closed")

    rig.card.pointerEntered()
    rig.advance(0.3)
    try await settle()
    try Self.click(window, at: above)
    #expect(rig.opened == [nil, nil], "a click elsewhere on the card opens the window too")
  }

  /// Q15: "N stopped ›" sits right above the last row's divider, and only while it shows does
  /// its strip take its own click.
  @Test func theStoppedLineIsAButtonRowAboveTheLastRow() {
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    let card = CGSize(width: 360, height: 300)
    let row = IslandCardMotion.stoppedRow(in: bounds, card: card)
    #expect(row.minY == UsageCardView.actionRowHeight + 1)
    #expect(row.height == UsageCardView.stoppedRowHeight)
    #expect(row.minX == 20 && row.width == 360)
    let point = CGPoint(x: 200, y: row.midY)
    #expect(IslandCardMotion.isOnButtonRow(point, in: bounds, card: card, stopped: true))
    #expect(!IslandCardMotion.isOnButtonRow(point, in: bounds, card: card, stopped: false))
    #expect(
      IslandCardMotion.isOnButtonRow(
        CGPoint(x: 200, y: 10), in: bounds, card: card, stopped: false))
  }

  /// N8, N11: Ask Claude / Ask Codex share the last row with Open ›, the card's bottom strip.
  @Test func theAsksAndOpenAreTheLastRow() {
    let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
    let card = CGSize(width: 360, height: 300)
    let row = IslandCardMotion.actionRow(in: bounds, card: card)
    #expect(row.minY == 0 && row.height == UsageCardView.actionRowHeight)
    #expect(row.minX == 20 && row.width == 360)
    let point = CGPoint(x: 200, y: row.midY)
    #expect(IslandCardMotion.isOnButtonRow(point, in: bounds, card: card, stopped: false))
    let above = CGPoint(x: 200, y: row.maxY + 5)
    #expect(!IslandCardMotion.isOnButtonRow(above, in: bounds, card: card, stopped: false))
  }

  /// N8: a click on Ask Claude while the card is still fading in launches it once and closes the
  /// card at once; the window doesn't open and nothing reopens the card.
  @Test func askingClosesTheCardWithoutOpeningTheWindow() async throws {
    let rig = Rig([Self.builtIn()], name: "card-ask", agents: [.claude, .codex])
    defer { rig.controller.place(nil) }
    rig.controller.tick()
    let window = try #require(rig.card.window)
    let tracking = try #require(window.contentView as? IslandCardTrackingView)
    rig.card.pointerEntered()
    rig.advance(0.3)
    #expect(rig.card.isOpen)
    try await Task.sleep(for: .seconds(0.05))
    let row = IslandCardMotion.actionRow(in: tracking.bounds, card: rig.card.size)
    // Ask Claude is the row's first button, from the card's left padding.
    let claude = CGPoint(x: row.minX + NotchGeometry.wingPadding + 20, y: row.minY + 14)
    #expect(tracking.hitTest(claude) !== tracking, "the button takes its click")

    try Self.click(window, at: claude)
    #expect(rig.asked == [.claude])
    #expect(!rig.card.isOpen && rig.card.cardFrame == nil, "the card closed")
    #expect(rig.opened.isEmpty, "the window didn't open")
    try await settle()
    rig.advance(1)
    #expect(!rig.card.isOpen, "and nothing opened it again")
    expectNear(window.frame, try rig.notch(), "back to rest on the notch")
  }

  /// The line is in the card only while something is stopped, and its click runs its action.
  @Test func theStoppedLineOpensTheStoppedList() async throws {
    let snapshot = SystemSnapshot(
      .init(
        diskAvailable: 1, diskTotal: 2, ramAvailable: 1, ramTotal: 2, memoryPressure: .normal,
        cpuUsage: 0.1, thermalStatus: .nominal, updatedAt: .now))
    #expect(UsageCardContent(snapshot: snapshot, now: .now).stopped == nil)
    let content = UsageCardContent(snapshot: snapshot, now: .now, stopped: 5)
    #expect(content.stopped == "5 stopped")
    var opened = 0
    var stopped = 0
    let view = UsageCardView(
      content: content, openApp: { opened += 1 }, openStopped: { stopped += 1 }
    )
    .background(BlitzUI.notchFill).environment(\.colorScheme, .dark)
    let host = NSHostingView(rootView: view.frame(width: NotchGeometry.expandedWidth))
    let window = IslandCardPanel.make()
    window.setFrame(CGRect(origin: Self.away, size: host.fittingSize), display: false)
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    try await Task.sleep(for: .seconds(0.1))
    let line = UsageCardView.actionRowHeight + 1 + UsageCardView.stoppedRowHeight / 2
    try Self.click(window, at: CGPoint(x: host.bounds.midX, y: line))
    #expect(stopped == 1 && opened == 0)
  }

  /// A left click at `point`, in `window`'s coordinates, sent as AppKit sends it.
  private static func click(_ window: NSWindow, at point: CGPoint) throws {
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = try #require(
        NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: [], timestamp: ProcessInfo().systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: type == .leftMouseDown ? 1 : 0))
      window.sendEvent(event)
    }
  }

  /// Clicks Open ›, at the right end of a card's bottom `UsageCardView.actionRowHeight` points,
  /// with real mouse events, in the card's own kind of window (never key), and counts its runs.
  private static func clicksOnOpen(of content: UsageCardContent) async throws -> Int {
    var opened = 0
    let view = UsageCardView(content: content, openApp: { opened += 1 })
      .background(BlitzUI.notchFill).environment(\.colorScheme, .dark)
    let host = NSHostingView(rootView: view.frame(width: NotchGeometry.expandedWidth))
    let window = IslandCardPanel.make()
    window.setFrame(CGRect(origin: away, size: host.fittingSize), display: false)
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    try await Task.sleep(for: .seconds(0.1))
    try click(
      window, at: CGPoint(x: host.bounds.maxX - 30, y: UsageCardView.actionRowHeight / 2))
    return opened
  }

  private func expectConfigured(_ panel: IslandCardPanel) {
    #expect(panel.sharingType == .none, "N3, N6: never in a shared screen")
    #expect(panel.level.rawValue > NSWindow.Level.mainMenu.rawValue + 3, "above the island")
    #expect(
      panel.collectionBehavior == [
        .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
      ])
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(panel.styleMask.contains(.borderless))
    #expect(!panel.canBecomeKey, "the keyboard stays with the user's app")
    #expect(!panel.canBecomeMain)
    #expect(!panel.ignoresMouseEvents, "the hover area must see the pointer")
    #expect(!panel.hasShadow)
    #expect(!panel.isOpaque)
    #expect(!panel.hidesOnDeactivate)
    #expect(!panel.isReleasedWhenClosed)
  }
}
