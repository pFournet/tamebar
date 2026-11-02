import Foundation
import Testing

@testable import Tamebar

/// The hover usage card (N6, 2026-10-27: "when I hover the notch I want to see some info of
/// the usage"): what it says, when it opens and closes, and how it grows out of the notch.
struct IslandCardTests {
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  let gb: UInt64 = 1_000_000_000

  func snapshot(
    ramFree: UInt64 = 6_100_000_000, cpu: Double? = 0.34, diskFree: UInt64 = 88_000_000_000,
    pressure: MemoryPressureLevel = .normal
  ) -> SystemSnapshot {
    SystemSnapshot(
      .init(
        diskAvailable: diskFree, diskTotal: 494_000_000_000, ramAvailable: ramFree,
        ramTotal: 36_000_000_000, memoryPressure: pressure, cpuUsage: cpu,
        thermalStatus: .nominal, updatedAt: t0))
  }

  // MARK: Content

  /// N14 (2026-11-02): a green "Watching your Mac" while the scan is current; gray, with the age
  /// of the last check, once it is older than a minute; "Starting" before the first scan.
  @Test func theStatusLineSaysWhetherTamebarIsWatching() {
    #expect(UsageCardStatus(scannedAt: t0, now: t0) == .watching)
    #expect(UsageCardStatus(scannedAt: t0, now: t0 + 60) == .watching, "a slow scan still counts")
    let stale = UsageCardStatus(scannedAt: t0, now: t0 + 125)
    #expect(stale.text == "Not updating · last check 2m ago")
    #expect(!stale.live)
    #expect(UsageCardStatus(scannedAt: nil, now: t0) == .starting)
    #expect(UsageCardContent(snapshot: snapshot(), now: t0).status == .watching)
  }

  /// N11: memory free as the menu bar formats it, a dash when unknown.
  @Test func theMemoryLineReusesTheMenuBarFormatting() {
    let content = UsageCardContent(snapshot: snapshot(), now: t0)
    #expect(content.memory == "Memory \(ByteText.compact(6_100_000_000)) free")
    let empty = SystemSnapshot(
      .init(
        diskAvailable: 0, diskTotal: 0, ramAvailable: 0, ramTotal: 0, memoryPressure: .unknown,
        cpuUsage: nil, thermalStatus: .unknown, updatedAt: t0))
    #expect(UsageCardContent(snapshot: empty, now: t0).memory == "Memory —")
  }

  /// N12 (2026-10-31): real pressure isn't a line of its own; the memory line says it, in
  /// orange with ⚠ while struggling, in red at critical, and white with "Strain none" otherwise.
  /// Free memory shows once.
  @Test func theMemoryLineCarriesTheStrain() {
    let free = ByteText.compact(1_100_000_000)
    let low = snapshot(ramFree: 1_100_000_000, pressure: .warning)
    let none = CardStrain(struggling: false, signals: [])
    let fan = CardStrain(struggling: true, signals: ["fan 78%"])
    let normal = UsageCardContent(snapshot: low, now: t0, strain: none)
    #expect(normal.memory == "Memory \(free) free · Strain none", "warning alone: as normal")
    #expect(normal.memoryTone == .neutral)
    #expect(normal.line == nil)
    let struggling = UsageCardContent(snapshot: low, now: t0, strain: fan)
    #expect(struggling.memory == "Memory \(free) free · Struggling: fan 78%")
    #expect(struggling.memoryTone == .warning)
    let both = CardStrain(struggling: true, signals: ["fan 78%", "heat serious"])
    #expect(
      UsageCardContent(snapshot: low, now: t0, strain: both).memory
        == "Memory \(free) free · Struggling: fan 78%, heat serious")
    let critical = UsageCardContent(
      snapshot: low, now: t0,
      strain: .init(struggling: true, signals: ["memory critical"]), critical: true)
    #expect(critical.memory == "Memory \(free) free · Struggling: memory critical")
    #expect(critical.memoryTone == .critical)
    // Critical before the strain is judged so, or in a Tamebar that doesn't judge it.
    for strain in [none, nil] {
      let alone = UsageCardContent(snapshot: low, now: t0, strain: strain, critical: true)
      #expect(alone.memory == "Memory \(free) free · Critical")
      #expect(alone.memoryTone == .critical)
    }
    // The menu bar's pressure state gives the card no line of its own: free memory is once.
    for (state, isCritical): (IslandState, Bool) in [
      (.pressure(free: 1_100_000_000, critical: false, strain: ["fan 78%"]), false),
      (.pressure(free: 1_100_000_000, critical: true, strain: nil), true),
    ] {
      let content = UsageCardContent(
        snapshot: low, now: t0, line: state.cardLine, strain: fan, critical: isCritical)
      #expect(content.line == nil)
      let texts = [content.memory, content.today] + [content.line?.text].compactMap { $0 }
      #expect(texts.joined(separator: "\n").components(separatedBy: " free").count == 2)
    }
  }

  /// The card links only to current activity, never ended session history.
  @Test func theActivityLinesAndTheAsksOnlyWhenThereAreAny() {
    let none = UsageCardContent(snapshot: snapshot(), now: t0)
    #expect(none.activityLines.isEmpty)
    #expect(none.asks.isEmpty)
    #expect(none.today == "Today: nothing yet")
    let some = UsageCardContent(
      snapshot: snapshot(), now: t0,
      activity: .init(slowed: [.init(id: "ai:1", name: "Claude · project A", kind: .session)]),
      asks: [.claude])
    #expect(some.activityLines == ["Slowed now: Claude · project A"])
    #expect(some.asks == [.claude])
  }

  // MARK: The state line (2026-10-27: the card and the wings say the same thing)

  let free = UInt64(2_000_000_000)

  @Test func theStateLineForEachEvent() {
    #expect(IslandState.hidden.cardLine == nil, "nothing going on: no line")
    let call = IslandState.call(.calendar, paused: 2).cardLine
    #expect(call?.text == "In a call · 2 sessions paused")
    #expect(call?.symbol == "calendar")
    #expect(IslandState.call(.mic, paused: 1).cardLine?.text == "In a call · 1 session paused")
    #expect(IslandState.call(.mic, paused: 0).cardLine?.text == "In a call · nothing paused")
    #expect(IslandState.autoPaused(3).cardLine?.text == "3 paused for memory")
    // N12: pressure is said by the memory line, not a line of its own.
    #expect(IslandState.pressure(free: free, critical: false, strain: ["fan 78%"]).cardLine == nil)
    #expect(IslandState.pressure(free: free, critical: true, strain: nil).cardLine == nil)
    #expect(IslandState.resumed(6).cardLine?.text == "Resumed 6")
    #expect(
      IslandState.note("Paused 3 idle sessions · 2.4 GB").cardLine?.text
        == "Paused 3 idle sessions · 2.4 GB", "the note's whole text")
  }

  /// N12: the wings and the menu bar under real pressure. Struggling: "struggling · fan 78%" in
  /// the wings, "Struggling · fan 78%" in the menu bar, ⚠ in the warning tone; critical without
  /// strain: "Memory is critical · 1.1 GB" in the critical tone.
  @Test func pressureWords() {
    let small = UInt64(1_100_000_000)
    let fan = IslandState.pressure(
      free: small, critical: false, strain: ["fan 78%", "heat serious"])
    #expect(
      fan.wingText
        == .init(
          symbol: "exclamationmark.triangle.fill", label: "struggling", detail: "fan 78%",
          tone: .warning))
    #expect(
      fan.menuText
        == .init(
          symbol: "exclamationmark.triangle.fill", text: "Struggling · fan 78%", tone: .warning))
    let hot = IslandState.pressure(free: small, critical: true, strain: ["memory critical"])
    #expect(hot.menuText?.text == "Struggling · memory critical")
    #expect(hot.menuText?.tone == .critical && hot.wingText?.tone == .critical)
    #expect(
      IslandState.pressure(free: small, critical: false, strain: []).menuText?.text
        == "Struggling")
    let critical = IslandState.pressure(free: small, critical: true, strain: nil)
    #expect(critical.menuText?.text == "Memory is critical · \(ByteText.full(small))")
    #expect(critical.wingText?.detail == "\(ByteText.full(small)) free")
    #expect(critical.menuText?.tone == .critical)
  }

  /// One source for the three (N7): for every state, the card's line and the menu-bar label have
  /// the wings' symbol and tone, and say what the wings say (their numbers, their size, their
  /// note); all is well is no wings, no line and the icon alone. Pressure has wings and a label
  /// but no card line (N12).
  @Test func theWingsTheCardLineAndTheMenuBarAgreeForEveryState() {
    let states: [IslandState] = [
      .hidden, .call(.calendar, paused: 2), .call(.mic, paused: 0), .autoPaused(3),
      .pressure(free: free, critical: false, strain: ["fan 78%"]),
      .pressure(free: free, critical: true, strain: nil),
      .resumed(6), .note("Paused 3 idle sessions · 2.4 GB · resumes when memory recovers"),
      .note("Slowed 2 builds"),
    ]
    for state in states {
      let line = state.cardLine
      let menu = state.menuText
      guard let wings = state.wingText else {
        #expect(line == nil, "\(state): no wings, no line")
        #expect(menu == nil, "\(state): no wings, the icon alone")
        continue
      }
      guard let menu else {
        Issue.record("\(state): wings without a menu-bar label")
        continue
      }
      #expect(menu.symbol == wings.symbol, "\(state)")
      #expect(menu.tone == wings.tone, "\(state)")
      let numbers = wings.detail.split(whereSeparator: { !$0.isNumber && $0 != "," && $0 != "." })
      for number in numbers {
        #expect(menu.text.contains(number), "\(state): \(number) in \(menu.text)")
      }
      if case .pressure(_, _, let strain) = state {
        #expect(line == nil, "\(state): the memory line says it")
        if let reason = strain?.first {
          #expect(menu.text == "Struggling · \(reason)")
          #expect(wings.label == "struggling" && wings.detail == reason)
        }
        continue
      }
      guard let line else {
        Issue.record("\(state): wings without a line")
        continue
      }
      #expect(line.symbol == wings.symbol, "\(state)")
      #expect(line.tone == wings.tone, "\(state)")
      for number in numbers {
        #expect(line.text.contains(number), "\(state): \(number) in \(line.text)")
      }
      if case .note = state {
        #expect(line.text.hasPrefix(wings.detail))
        #expect(menu.text.hasPrefix(wings.detail))
        #expect(line.text.hasPrefix(menu.text))
      }
      if case .resumed = state { #expect(line.text == menu.text) }
    }
  }

  /// The menu-bar item, the wings and the card resolve from the same facts on one tick
  /// (`IslandController.show`): the item's label is the menu bar's state, the card's line is
  /// built from it, so the two can't drift apart.
  @Test func theMenuBarLabelAndTheCardLineComeFromTheSameState() {
    for state: IslandState in [
      .hidden, .call(.calendar, paused: 2), .autoPaused(3),
      .pressure(free: free, critical: true, strain: nil), .note("Slowed 2 builds"),
    ] {
      let label = MenuBarItemLabel(state, colored: true)
      #expect(label.text == state.menuText?.text)
      #expect(label.symbol == state.menuText?.symbol)
      #expect(
        label.accessibility
          == "\(AppBrand.name), "
          + (state.cardLine?.text ?? state.menuText?.text ?? "all is well"))
    }
  }

  @Test func theStateLineGoesFirst() {
    let content = UsageCardContent(
      snapshot: snapshot(), now: t0, line: IslandState.call(.calendar, paused: 2).cardLine)
    #expect(content.line?.text == "In a call · 2 sessions paused")
    #expect(UsageCardContent(snapshot: snapshot(), now: t0).line == nil)
  }

  // MARK: Hover timing

  @Test func opensAfterThePointerRestsOnTheNotch() {
    var hover = NotchHover()
    hover.enter(at: t0)
    #expect(hover.deadline == t0.addingTimeInterval(NotchHover.openAfter))
    #expect(hover.fire(at: t0.addingTimeInterval(0.29)) == nil, "not yet")
    #expect(!hover.isOpen)
    #expect(hover.fire(at: t0.addingTimeInterval(0.3)) == .open)
    #expect(hover.isOpen)
    #expect(hover.deadline == nil)
    #expect(hover.fire(at: t0.addingTimeInterval(5)) == nil, "opens once")
  }

  @Test func passingOverTheNotchOpensNothing() {
    var hover = NotchHover()
    hover.enter(at: t0)
    hover.leave(at: t0.addingTimeInterval(0.1))
    #expect(hover.deadline == nil)
    #expect(hover.fire(at: t0.addingTimeInterval(1)) == nil)
    #expect(!hover.isOpen)
  }

  @Test func closesAfterAGraceOnceThePointerLeaves() {
    var hover = NotchHover()
    hover.enter(at: t0)
    _ = hover.fire(at: t0.addingTimeInterval(0.3))
    hover.leave(at: t0.addingTimeInterval(1))
    #expect(hover.isOpen, "open during the grace")
    #expect(hover.deadline == t0.addingTimeInterval(1 + NotchHover.closeAfter))
    #expect(hover.fire(at: t0.addingTimeInterval(1.19)) == nil)
    #expect(hover.fire(at: t0.addingTimeInterval(1.2)) == .close)
    #expect(!hover.isOpen)
    #expect(hover.deadline == nil)
  }

  /// Moving from the notch down into the card, or back within the grace, keeps it open.
  @Test func comingBackWithinTheGraceKeepsItOpen() {
    var hover = NotchHover()
    hover.enter(at: t0)
    _ = hover.fire(at: t0.addingTimeInterval(0.3))
    hover.leave(at: t0.addingTimeInterval(1))
    hover.enter(at: t0.addingTimeInterval(1.1))
    #expect(hover.deadline == nil)
    #expect(hover.fire(at: t0.addingTimeInterval(2)) == nil)
    #expect(hover.isOpen)
  }

  @Test func cancellingForgetsTheHover() {
    var hover = NotchHover()
    hover.enter(at: t0)
    hover.cancel()
    #expect(hover.fire(at: t0.addingTimeInterval(1)) == nil)
    hover.enter(at: t0)
    _ = hover.fire(at: t0.addingTimeInterval(0.3))
    let wasOpen = hover.cancel()
    #expect(wasOpen, "it was open")
    #expect(!hover.isOpen)
    let again = hover.cancel()
    #expect(!again, "nothing left to cancel")
  }

  /// The user, 2026-10-27: "The expansion should not close and open." The pointer coming back while
  /// the card shrinks reopens it at once, from where it is: no new 0.3 s rest on the notch.
  @Test func comingBackWhileItClosesReopensAtOnce() {
    var hover = NotchHover()
    hover.enter(at: t0)
    _ = hover.fire(at: t0.addingTimeInterval(0.3))
    hover.leave(at: t0.addingTimeInterval(1))
    #expect(hover.fire(at: t0.addingTimeInterval(1.2)) == .close)
    hover.returned()
    #expect(hover.isOpen)
    #expect(hover.deadline == nil, "nothing to wait for")
    #expect(hover.fire(at: t0.addingTimeInterval(5)) == nil, "and it doesn't open again")
  }

  // MARK: Motion

  let notch = CGRect(x: 663.5, y: 950, width: 185, height: 32)

  /// Where the pointer counts as on the card: the frame it opens to, with the notch and the
  /// wings, and 6 pt around it, never the window's frame while it grows or shrinks.
  @Test func theHoverRegionIsTheTargetFrameWithAMargin() {
    let wings = NotchGeometry.collapsed(notch: notch, wing: 140).panel
    let region = IslandCardMotion.hoverRegion(card: card, start: wings)
    #expect(region.contains(CGPoint(x: card.midX, y: card.minY + 1)), "the bottom of the card")
    #expect(region.contains(CGPoint(x: card.midX, y: card.minY - 5)), "5 pt below: the margin")
    #expect(!region.contains(CGPoint(x: card.midX, y: card.minY - 7)), "7 pt below: out")
    #expect(region.contains(CGPoint(x: wings.minX - 5, y: wings.midY)), "beside wider wings")
    #expect(IslandCardMotion.hoverMargin == 6)
  }
  var card: CGRect { NotchGeometry.expanded(notch: notch, contentHeight: 150) }

  @Test func theCardGrowsOutOfTheNotch() {
    let step = IslandCardMotion.opening(notch: notch, card: card, reduceMotion: false)
    #expect(step.from == notch, "starts at the notch's size, on it")
    #expect(step.to == card)
    #expect(!step.fades, "the black is there from the first frame; the content fades in")
    #expect(step.duration == IslandController.motion, "the wings' and the panel's 0.3 s")
  }

  /// With the wings showing, the card grows from the notch-plus-wings shape, and goes back to it.
  @Test func withTheWingsItGrowsFromTheWings() {
    let wings = NotchGeometry.collapsed(notch: notch, wing: 120).panel
    #expect(IslandCardMotion.start(notch: notch, wing: 120, wingsShow: true) == wings)
    #expect(IslandCardMotion.start(notch: notch, wing: 120, wingsShow: false) == notch)
  }

  @Test func theCardShrinksBackQuicker() {
    let step = IslandCardMotion.closing(notch: notch, card: card, reduceMotion: false)
    #expect(step.from == card)
    #expect(step.to == notch)
    #expect(!step.fades)
    let opening = IslandCardMotion.opening(notch: notch, card: card, reduceMotion: false)
    #expect(step.duration < opening.duration)
  }

  @Test func reduceMotionOnlyFades() {
    for step in [
      IslandCardMotion.opening(notch: notch, card: card, reduceMotion: true),
      IslandCardMotion.closing(notch: notch, card: card, reduceMotion: true),
    ] {
      #expect(step.fades)
      #expect(step.from == card && step.to == card, "no frame change")
      #expect(step.duration <= 0.15)
    }
  }

  @Test func theCardIsAsWideAsThePanel() {
    // Same width rules as the panel: 360, or the wings when they are wider.
    let wide = IslandCardMotion.frame(
      notch: notch, contentHeight: 150, wing: 140,
      visible: CGRect(x: 0, y: 0, width: 1512, height: 949))
    #expect(wide == NotchGeometry.expanded(notch: notch, contentHeight: 150, wing: 140))
    // Never taller than the screen allows, as the panel.
    let short = IslandCardMotion.frame(
      notch: notch, contentHeight: 5_000, wing: 96,
      visible: CGRect(x: 0, y: 0, width: 1512, height: 949))
    #expect(short.maxY == notch.maxY)
    #expect(short.height == notch.height + 949 - 40)
  }
}
