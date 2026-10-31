import Foundation

/// What the island by the notch, or the menu-bar item where there's no notch, shows (N1, N2,
/// N4, N5, amendment A). Pure; one state at a time, by priority: a call, a note on what Tamebar
/// just did, an automatic pause under pressure (the menu bar only), real pressure, then the
/// resumed flash.
///
/// Real pressure (N12, 2026-10-31) is Q19's strain (the Mac struggling, with its reasons)
/// or macOS's memory critical, never "warning" alone, which this Mac reports nearly all day.
///
/// In full screen (N4) only a call and critical pressure show. The flashes are dropped, not
/// queued: each lasts its own few seconds from when it happened, full screen or not.
///
/// The menu-bar item shows pressure for as long as it lasts; the notch shows it as a 4 s flash
/// (N2 amendment, 2026-10-23), again only when it gets worse or comes back after it eased. Once
/// that flash is over, the notch shows what comes next, as if there were no pressure. The card
/// says it in its memory line, not a line of its own (N12).
enum IslandState: Equatable, Sendable {
  enum CallSource: String, Sendable { case calendar, mic }

  case hidden
  /// A call is on; `paused` is what Tamebar holds for it.
  case call(CallSource, paused: Int)
  /// Sessions and projects paused under memory pressure.
  case autoPaused(Int)
  /// Real pressure (N12), nothing paused for it: the Mac struggling (Q19), `strain` its
  /// reasons ("fan 78%"), or macOS's memory critical without strain (`strain` nil).
  case pressure(free: UInt64, critical: Bool, strain: [String]?)
  /// Tamebar resumed what it paused (the call ended, or pressure cleared).
  case resumed(Int)
  /// A brief line about an automatic action (amendment A), such as "Slowed 2 builds".
  case note(String)

  static let resumedFor: TimeInterval = 4
  static let noteFor: TimeInterval = 4
  /// How long the notch shows memory pressure (2026-10-23: "display it for few second and
  /// disappear").
  static let pressureFor: TimeInterval = 4

  /// The two surfaces: the menu-bar item (and its card), which shows pressure while it lasts,
  /// and the notch, which shows it as a flash.
  enum Surface: Sendable { case menuBar, notch }

  /// When the notch's pressure flash started, and whether this pressure episode has reached
  /// critical yet.
  struct PressureFlash: Equatable, Sendable {
    let at: Date
    let critical: Bool
  }

  /// The pressure flash after `previous`, for memory at `risk` and the strain now: none without
  /// real pressure (N12: neither struggling nor critical); a new one when pressure starts, or
  /// when it reaches critical for the first time since it last eased; otherwise the same one, so
  /// a level that holds, or goes down and back up, never shows again.
  static func pressureFlash(
    after previous: PressureFlash?, risk: MemoryRisk, struggling: Bool, now: Date
  ) -> PressureFlash? {
    guard struggling || risk >= .critical else { return nil }
    let critical = risk >= .critical
    if let previous, previous.critical || !critical { return previous }
    return PressureFlash(at: now, critical: critical)
  }

  struct Flash: Equatable, Sendable {
    let at: Date
    let count: Int
  }

  struct Note: Equatable, Sendable {
    let text: String
    let at: Date
  }

  struct Input: Sendable {
    let now: Date
    let meeting: Bool
    let callSource: CallSource
    /// Ledger entries paused for a call.
    let pausedForCall: Int
    /// Ledger entries paused under memory pressure.
    let pausedForPressure: Int
    let risk: MemoryRisk
    let freeBytes: UInt64
    /// The latest automatic resume (the model's `lastResume`).
    let resumed: Flash?
    /// The latest automatic action's line (the model's `note`).
    let note: Note?
    /// The frontmost app is full screen on the notched screen.
    let fullScreen: Bool
    /// The notch's pressure flash (`pressureFlash(after:risk:struggling:now:)`); without one
    /// the notch shows no pressure.
    var pressureFlash: PressureFlash? = nil
    /// The Mac is struggling (Q19), as the Tamebar that acts judges it; `strain` its reasons.
    var struggling = false
    var strain: [String] = []

    /// Real pressure (N12): struggling or critical, never warning alone.
    var underPressure: Bool { struggling || risk >= .critical }

    var pressure: IslandState {
      .pressure(free: freeBytes, critical: risk >= .critical, strain: struggling ? strain : nil)
    }
  }

  static func resolve(_ input: Input, on surface: Surface = .menuBar) -> IslandState {
    let pressureShows =
      switch surface {
      case .menuBar: true
      case .notch:
        input.pressureFlash.map { isLive($0.at, for: pressureFor, now: input.now) } ?? false
      }
    if input.meeting { return .call(input.callSource, paused: input.pausedForCall) }
    if input.fullScreen {
      return input.risk >= .critical && pressureShows ? input.pressure : .hidden
    }
    // What Tamebar just did comes first (no banners, 2026-10-27). The notch shows a pause only
    // as that note; the menu bar keeps "N paused" while it lasts.
    if let note = input.note, isLive(note.at, for: noteFor, now: input.now) {
      return .note(note.text)
    }
    if input.pausedForPressure > 0, surface == .menuBar {
      return .autoPaused(input.pausedForPressure)
    }
    if input.underPressure, pressureShows { return input.pressure }
    if let resumed = input.resumed, isLive(resumed.at, for: resumedFor, now: input.now) {
      return .resumed(resumed.count)
    }
    return .hidden
  }

  /// A flash shows from its time for `duration`, ends included; never before it.
  private static func isLive(_ at: Date, for duration: TimeInterval, now: Date) -> Bool {
    (0...duration).contains(now.timeIntervalSince(at))
  }

  /// Short name for the e2e state dump.
  var debugName: String {
    switch self {
    case .hidden: "hidden"
    case .call: "call"
    case .autoPaused: "autoPaused"
    case .pressure: "pressure"
    case .resumed: "resumed"
    case .note: "note"
    }
  }
}

// MARK: The model's state as input (Task 9.3)

extension IslandState.CallSource {
  /// The meeting monitor's source. A call with none (forced by the e2e control) reads as the
  /// calendar.
  init(_ source: MeetingMonitor.Source) {
    self = source == .mic ? .mic : .calendar
  }
}

extension IslandState {
  /// What the model knows, for `Input`. Full screen is the screen's part, read separately.
  struct Facts {
    let now: Date
    let meeting: Bool
    let source: MeetingMonitor.Source
    /// What Tamebar paused on its own: sessions and projects alike.
    let ledger: [AutoPausePlanner.Entry]
    let risk: MemoryRisk
    let freeBytes: UInt64
    let lastResume: (at: Date, count: Int)?
    let note: (text: String, at: Date)?
    /// The notch's pressure flash, which the controller carries from tick to tick.
    var pressureFlash: PressureFlash? = nil
    /// Q19's strain: struggling, with its reasons ("fan 78%").
    var struggling = false
    var strain: [String] = []
  }

  static func input(_ facts: Facts, fullScreen: Bool) -> Input {
    Input(
      now: facts.now, meeting: facts.meeting, callSource: CallSource(facts.source),
      pausedForCall: facts.ledger.filter { $0.reason == .meeting }.count,
      pausedForPressure: facts.ledger.filter { $0.reason == .pressure }.count, risk: facts.risk,
      freeBytes: facts.freeBytes,
      resumed: facts.lastResume.map { Flash(at: $0.at, count: $0.count) },
      note: facts.note.map { Note(text: $0.text, at: $0.at) }, fullScreen: fullScreen,
      pressureFlash: facts.pressureFlash, struggling: facts.struggling, strain: facts.strain)
  }

  /// Resolves, reading full screen only when it could change what shows: full screen only ever
  /// hides, and never hides a call or critical pressure, so the window list isn't read while all
  /// is well or while either of those shows.
  static func resolve(_ facts: Facts, on surface: Surface = .menuBar, fullScreen: () -> Bool)
    -> IslandState
  {
    let open = resolve(input(facts, fullScreen: false), on: surface)
    guard open != .hidden, !open.showsInFullScreen, fullScreen() else { return open }
    return resolve(input(facts, fullScreen: true), on: surface)
  }

  /// N4: the states full screen keeps as they are.
  var showsInFullScreen: Bool {
    switch self {
    case .call, .pressure(_, critical: true, _): true
    default: false
    }
  }
}

// MARK: What each surface says

/// The wings' content (N2): the left wing's symbol and word, the right wing's line.
struct IslandWingText: Equatable, Sendable {
  let symbol: String
  let label: String?
  let detail: String
  let tone: MetricTone
}

/// The menu-bar item's state (N5, N7): a symbol and a short text beside Tamebar's icon.
struct IslandMenuText: Equatable, Sendable {
  let symbol: String
  let text: String
  let tone: MetricTone
}

/// What every surface says about one state, from one place (N7): the wings, the menu-bar item
/// and the card's state line share the symbol and tone, and their words come from the same case,
/// so the three can never disagree. Pressure has no card line: the card says it in its memory
/// line (N12).
struct IslandStateText: Equatable, Sendable {
  let wings: IslandWingText
  let menu: IslandMenuText
  let card: IslandCardLine?
}

extension IslandState {
  /// The longest menu-bar text, ellipsis included.
  static let menuLimit = 24

  private var callSymbol: String {
    if case .call(.mic, _) = self { return "mic.fill" }
    return "calendar"
  }

  private static func free(_ bytes: UInt64) -> String { ByteText.full(bytes) }

  /// A note's first part and the rest: "Quit Loom · 1.2 GB · reopens later" is "Quit Loom" and
  /// "1.2 GB · reopens later".
  static func split(_ note: String) -> (headline: String, rest: String?) {
    guard let range = note.range(of: " · ") else { return (note, nil) }
    return (String(note[..<range.lowerBound]), String(note[range.upperBound...]))
  }

  var wingText: IslandWingText? { text?.wings }

  /// The menu-bar item's label beside the icon (N7); nil while all is well: the icon alone.
  var menuText: IslandMenuText? { text?.menu }

  /// The card's state line (2026-10-27: the card and the wings say the same thing). The
  /// card reads the menu bar's state, so a line stays for as long as its event lasts. Nil while
  /// nothing is going on, and under pressure, which the card's memory line says (N12).
  var cardLine: IslandCardLine? { text?.card }

  /// The one place each state's words are written (N7): the wings, the menu-bar label and the
  /// card's line, with one symbol and one tone. Nil while all is well.
  var text: IslandStateText? {
    let symbol: String
    let tone: MetricTone
    let wings: (label: String?, detail: String)
    let menu: String
    let card: String?
    switch self {
    case .hidden:
      return nil
    case .call(_, let paused):
      (symbol, tone) = (callSymbol, .neutral)
      wings = ("call", paused > 0 ? "\(paused) paused" : "")
      menu = paused > 0 ? "Call · \(paused) paused" : "Call"
      let held =
        switch paused {
        case 0: "nothing paused"
        case 1: "1 session paused"
        default: "\(paused) sessions paused"
        }
      card = "In a call · \(held)"
    case .autoPaused(let count):
      (symbol, tone) = ("exclamationmark.triangle.fill", .warning)
      wings = ("mem", "\(count) paused")
      menu = "\(count) paused"
      card = "\(count) paused for memory"
    case .pressure(let free, let critical, let strain):
      (symbol, tone) = ("exclamationmark.triangle.fill", critical ? .critical : .warning)
      if let strain {
        // N12: "Struggling · fan 78%"; the first reason, the card lists them all.
        let reason = strain.first
        wings = ("struggling", reason ?? "")
        menu = reason.map { "Struggling · \($0)" } ?? "Struggling"
      } else {
        wings = ("mem", "\(Self.free(free)) free")
        menu = "Memory is critical · \(Self.free(free))"
      }
      card = nil
    case .resumed(let count):
      (symbol, tone) = ("checkmark", .good)
      wings = (nil, "resumed \(count)")
      menu = "Resumed \(count)"
      card = menu
    case .note(let note):
      (symbol, tone) = ("circle.lefthalf.filled", .neutral)
      let parts = Self.split(note)
      wings = (nil, parts.headline)
      menu = Self.menuNote(parts)
      card = note
    }
    return .init(
      wings: .init(symbol: symbol, label: wings.label, detail: wings.detail, tone: tone),
      menu: .init(symbol: symbol, text: menu, tone: tone),
      card: card.map { .init(symbol: symbol, text: $0, tone: tone) })
  }

  /// A note in the menu bar (the approved mock: "Paused 3 idle sessions · 2.4 GB"): its headline,
  /// cut at `menuLimit`, then what Tamebar freed when the note says it, its second part when that
  /// starts with a figure. The rest ("resumes when memory recovers") is the card's.
  private static func menuNote(_ parts: (headline: String, rest: String?)) -> String {
    let headline = shortened(parts.headline)
    guard let figure = parts.rest.map({ split($0).headline }),
      figure.first?.isNumber == true
    else { return headline }
    return "\(headline) · \(figure)"
  }

  /// At most `menuLimit` characters: a longer text is cut after the last whole word that fits,
  /// then ends with an ellipsis ("Ended 2 sessions idle…"). One long word is cut at the limit.
  private static func shortened(_ text: String) -> String {
    guard text.count > menuLimit else { return text }
    let room = menuLimit - 1
    let head = text.prefix(room)
    let cut: Substring
    if text.dropFirst(room).first == " " {
      cut = head
    } else if let space = head.lastIndex(of: " ") {
      cut = head[..<space]
    } else {
      cut = head
    }
    return cut.trimmingCharacters(in: .whitespaces) + "…"
  }
}
