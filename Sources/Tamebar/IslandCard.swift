import Foundation

/// The hover usage card under the notch (N6, 2026-10-27: "when I hover the notch I want to
/// see some info of the usage"). Pure: what the card says, when it opens and closes, and how it
/// grows out of the notch. `IslandCardController` owns the window; `UsageCardView` draws it.

/// What the card says (N11, N12, approved as mocked):
///
/// ```
/// │ Memory 2 GB free · Strain none        │
/// │ Today: ended 3 · slowed 2 · 4 GB back │
/// │ Waiting for memory (when any)         │
/// │ 3 stopped ›                           │
/// │ [Ask Claude] [Ask Codex]       Open › │
/// ```
///
/// The event going on (a call, a pause, a note) leads it, as the wings say it. Real pressure
/// isn't a line of its own: the memory line turns orange (red at critical) with ⚠ and says it,
/// so free memory shows once (N12).
struct UsageCardContent: Equatable, Sendable {
  /// What is going on, first: the island's state as a line (`IslandState.cardLine`); nil when
  /// nothing is.
  let line: IslandCardLine?
  /// "Memory 2 GB free · Strain none": free memory as the menu bar formats it, then whether the
  /// Mac is struggling (Q19), with its signals when it is: "Memory 1.1 GB free · Struggling: fan
  /// 78%". No strain part in a Tamebar that doesn't judge it.
  let memory: String
  /// The memory line's tone (N12): warning while struggling, critical at macOS's critical (with
  /// ⚠, line and symbol in that color); neutral otherwise.
  let memoryTone: MetricTone
  /// "Today: ended 3 · slowed 2 · 4 GB back": what Tamebar did on its own today and the memory it
  /// freed, from the usage record (Q16); "Today: nothing yet" before anything.
  let today: String
  /// "5 stopped", while Tamebar has stopped something that isn't back (Q15); nil otherwise.
  let stopped: String?
  /// Ask Claude, Ask Codex, left of Open: the tools installed (N8).
  let asks: [AskAgent]
  /// The new sessions waiting for memory at start (Q19), oldest first, each with Start now;
  /// none, no block.
  let waiting: [Waiting]

  /// One session waiting at start: "dashboard-app · Claude", how long, and Start now.
  struct Waiting: Equatable, Sendable, Identifiable {
    /// The `tamebar wait` holding it.
    let id: Int32
    let label: String
    let waited: String
  }

  static let waitingTitle = "Waiting for memory"
  static let waitingFooter = "They start on their own when it eases."
  static let nothingToday = "Today: nothing yet"

  init(
    snapshot: SystemSnapshot, now: Date, line: IslandCardLine? = nil, strain: CardStrain? = nil,
    critical: Bool = false, today: UsageActions? = nil, stopped: Int = 0, asks: [AskAgent] = [],
    waiting: [StartWait.Registration] = []
  ) {
    self.line = line
    self.waiting = waiting.map {
      Waiting(
        id: $0.waitPID, label: $0.label, waited: StartWait.waited(now.timeIntervalSince($0.started))
      )
    }
    self.stopped = stopped > 0 ? StoppedRows.line(count: stopped) : nil
    self.asks = asks
    let struggling = strain?.struggling == true
    let state =
      critical && !struggling ? CardStrain.criticalText : strain?.text
    memory = "Memory \(MemoryFreeText.make(snapshot))" + (state.map { " · \($0)" } ?? "")
    memoryTone = critical ? .critical : struggling ? .warning : .neutral
    self.today = Self.today(today)
  }

  /// The day's actions, a count of zero left out, then the memory they freed.
  static func today(_ actions: UsageActions?) -> String {
    guard let actions else { return nothingToday }
    let counts: [(String, Int)] = [
      ("ended", actions.ended), ("quit", actions.quit), ("paused", actions.paused),
      ("slowed", actions.slowed),
    ]
    var parts = counts.filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }
    if actions.freedBytes > 0 { parts.append("\(ByteText.compact(actions.freedBytes)) back") }
    return parts.isEmpty ? nothingToday : "Today: " + parts.joined(separator: " · ")
  }
}

/// The strain as the card says it (Q19, N12): "Strain none", or "Struggling: fan 78%" with what
/// makes the Mac struggle.
struct CardStrain: Equatable, Sendable {
  let struggling: Bool
  let signals: [String]

  /// macOS's memory critical without the strain judged so: a Tamebar that doesn't act, or the
  /// moment before its next reading.
  static let criticalText = "Critical"

  var text: String {
    guard struggling else { return "Strain none" }
    return signals.isEmpty ? "Struggling" : "Struggling: " + signals.joined(separator: ", ")
  }
}

/// The card's first line: the event going on, with the wings' symbol and tone.
struct IslandCardLine: Equatable, Sendable {
  let symbol: String
  let text: String
  let tone: MetricTone
}

/// When the card opens and closes: after the pointer rests on the notch for `openAfter`, and once
/// it has left both the notch and the card for `closeAfter`, so moving down into the card, or
/// back within the grace, keeps it open. The controller calls `fire` at `deadline`.
struct NotchHover: Equatable, Sendable {
  static let openAfter: TimeInterval = 0.3
  static let closeAfter: TimeInterval = 0.2

  enum Action: Equatable, Sendable { case open, close }

  private enum Phase: Equatable, Sendable {
    case away
    case resting(since: Date)
    case open
    case leaving(since: Date)
  }

  private var phase = Phase.away

  var isOpen: Bool {
    switch phase {
    case .open, .leaving: true
    case .away, .resting: false
    }
  }

  /// When `fire` next has something to do; nil while nothing is pending.
  var deadline: Date? {
    switch phase {
    case .resting(let since): since.addingTimeInterval(Self.openAfter)
    case .leaving(let since): since.addingTimeInterval(Self.closeAfter)
    case .away, .open: nil
    }
  }

  /// The pointer is on the notch or the card.
  mutating func enter(at now: Date) {
    switch phase {
    case .away: phase = .resting(since: now)
    case .leaving: phase = .open
    case .resting, .open: break
    }
  }

  /// The pointer has left both.
  mutating func leave(at now: Date) {
    switch phase {
    case .resting: phase = .away
    case .open: phase = .leaving(since: now)
    case .away, .leaving: break
    }
  }

  /// Opens or closes once the deadline has come; nothing before it.
  mutating func fire(at now: Date) -> Action? {
    guard let deadline, now >= deadline else { return nil }
    switch phase {
    case .resting:
      phase = .open
      return .open
    case .leaving:
      phase = .away
      return .close
    case .away, .open:
      return nil
    }
  }

  /// The pointer came back while the card was closing: open again at once, with no new rest
  /// (2026-10-27: "The expansion should not close and open").
  mutating func returned() { phase = .open }

  /// Forgets the hover (a click opened the panel, full screen, a display change). True when the
  /// card was open.
  @discardableResult
  mutating func cancel() -> Bool {
    defer { phase = .away }
    return isOpen
  }
}

/// How the card opens and closes. With motion it grows out of the notch, in the island's black
/// from the first frame, to the card's frame, its content fading in over the same 0.3 s ease-out
/// as the wings and the panel; it shrinks back into the notch a little quicker. Under Reduce
/// Motion the frame doesn't move: the card only fades, as the island does without motion.
enum IslandCardMotion {
  static let close: TimeInterval = 0.2
  static let fade: TimeInterval = 0.15

  struct Step: Equatable, Sendable {
    let from: CGRect
    let to: CGRect
    let duration: TimeInterval
    /// Everything fades, the black included; otherwise only the content does.
    let fades: Bool
  }

  /// The shape the card grows from and goes back to: the notch, or the notch and the wings
  /// while they show, which stay up under the card.
  static func start(notch: CGRect, wing: CGFloat, wingsShow: Bool) -> CGRect {
    wingsShow ? NotchGeometry.collapsed(notch: notch, wing: wing).panel : notch
  }

  static func opening(notch: CGRect, card: CGRect, reduceMotion: Bool) -> Step {
    reduceMotion
      ? .init(from: card, to: card, duration: fade, fades: true)
      : .init(from: notch, to: card, duration: IslandController.motion, fades: false)
  }

  static func closing(notch: CGRect, card: CGRect, reduceMotion: Bool) -> Step {
    reduceMotion
      ? .init(from: card, to: card, duration: fade, fades: true)
      : .init(from: card, to: notch, duration: close, fades: false)
  }

  /// How far around the card the pointer still counts as on it, so skimming the edge doesn't
  /// flicker.
  static let hoverMargin: CGFloat = 6

  /// Where the pointer counts as on the card while it opens, shows or closes: the frame it opens
  /// to with the shape it grows from (the notch, or the notch and the wings), and the margin.
  /// Never the window's frame, which is smaller while it grows or shrinks.
  static func hoverRegion(card: CGRect, start: CGRect) -> CGRect {
    card.union(start).insetBy(dx: -hoverMargin, dy: -hoverMargin)
  }

  /// Where the card's last row, Ask Claude / Ask Codex and Open › (N8, N11), is in the card
  /// window's view (`bounds`, bottom-left origin): the card's content is laid out at `card`,
  /// centred and hanging from the top, so the row is its bottom strip, wherever the window is in
  /// its motion.
  static func actionRow(in bounds: CGRect, card: CGSize) -> CGRect {
    CGRect(
      x: bounds.midX - card.width / 2, y: bounds.maxY - card.height, width: card.width,
      height: UsageCardView.actionRowHeight)
  }

  /// Where the "N stopped ›" line is: above its divider, over the last row.
  static func stoppedRow(in bounds: CGRect, card: CGSize) -> CGRect {
    let below = actionRow(in: bounds, card: card)
    return CGRect(
      x: below.minX, y: below.maxY + 1, width: below.width,
      height: UsageCardView.stoppedRowHeight)
  }

  /// Where the "Waiting for memory" block is (Q19): above its divider, over the stopped line
  /// when the card shows it, else over the last row.
  static func waitingBlock(in bounds: CGRect, card: CGSize, stopped: Bool, count: Int) -> CGRect {
    let below =
      stopped ? stoppedRow(in: bounds, card: card) : actionRow(in: bounds, card: card)
    return CGRect(
      x: below.minX, y: below.maxY + 1, width: below.width,
      height: UsageCardView.waitingHeight(count))
  }

  /// On the last row (Ask and Open), on the stopped line when the card shows it, or on the
  /// waiting block (its Start now buttons) while something waits: their buttons take the click.
  static func isOnButtonRow(
    _ point: CGPoint, in bounds: CGRect, card: CGSize, stopped: Bool, waiting: Int = 0
  ) -> Bool {
    actionRow(in: bounds, card: card).contains(point)
      || (stopped && stoppedRow(in: bounds, card: card).contains(point))
      || (waiting > 0
        && waitingBlock(in: bounds, card: card, stopped: stopped, count: waiting)
          .contains(point))
  }

  /// The card's frame: the panel's width rules (`NotchGeometry.expanded`), hanging from the
  /// screen's top edge, no taller than the screen's visible frame allows, as the panel.
  static func frame(notch: CGRect, contentHeight: CGFloat, wing: CGFloat, visible: CGRect)
    -> CGRect
  {
    NotchGeometry.expanded(
      notch: notch, contentHeight: min(contentHeight, visible.height - 40), wing: wing)
  }
}
