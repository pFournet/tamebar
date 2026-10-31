import Darwin
import Foundation
import Testing

@testable import Tamebar

/// What the island, the menu-bar item and the event header say for each state (Task 9.3), and
/// how the model's state becomes the island's input.
struct IslandContentTests {
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  /// 1.2 GB in this Mac's locale ("1,2 GB" in French).
  let gb = ByteText.full(1_200_000_000)

  func facts(
    meeting: Bool = false, source: MeetingMonitor.Source = .none,
    ledger: [AutoPausePlanner.Entry] = [], risk: MemoryRisk = .normal,
    lastResume: (at: Date, count: Int)? = nil, note: (text: String, at: Date)? = nil,
    strain: [String]? = nil
  ) -> IslandState.Facts {
    .init(
      now: t0, meeting: meeting, source: source, ledger: ledger, risk: risk,
      freeBytes: 1_200_000_000, lastResume: lastResume, note: note, struggling: strain != nil,
      strain: strain ?? [])
  }

  func entry(_ id: String, _ reason: AutoPausePlanner.Reason) -> AutoPausePlanner.Entry {
    .init(threadID: id, reason: reason, since: t0)
  }

  // MARK: Input

  @Test func callSourceFromTheMeetingMonitor() {
    #expect(IslandState.CallSource(MeetingMonitor.Source.mic) == .mic)
    #expect(IslandState.CallSource(MeetingMonitor.Source.calendar) == .calendar)
    // A call forced by the e2e control has no source of its own.
    #expect(IslandState.CallSource(MeetingMonitor.Source.none) == .calendar)
  }

  @Test func ledgerCountsByReason() {
    let ledger = [
      entry("a", .meeting), entry("b", .meeting), entry("project:/web", .meeting),
      entry("c", .pressure),
    ]
    let input = IslandState.input(facts(ledger: ledger), fullScreen: false)
    #expect(input.pausedForCall == 3)
    #expect(input.pausedForPressure == 1)
  }

  @Test func inputCarriesTheModelsState() {
    let input = IslandState.input(
      facts(
        meeting: true, source: .mic, risk: .warning, lastResume: (t0, 6),
        note: ("Slowed 2 builds", t0), strain: ["fan 78%"]),
      fullScreen: true)
    #expect(input.struggling && input.strain == ["fan 78%"])
    #expect(input.meeting && input.callSource == .mic && input.fullScreen)
    #expect(input.risk == .warning && input.freeBytes == 1_200_000_000)
    #expect(input.resumed == .init(at: t0, count: 6))
    #expect(input.note == .init(text: "Slowed 2 builds", at: t0))
    #expect(input.now == t0)
  }

  @Test func fullScreenIsReadOnlyWhenSomethingWouldShow() {
    var reads = 0
    let hidden = IslandState.resolve(facts()) {
      reads += 1
      return true
    }
    #expect(hidden == .hidden && reads == 0)
    // N12: warning alone shows nothing, so the window list isn't read for it either.
    #expect(
      IslandState.resolve(facts(risk: .warning)) {
        reads += 1
        return true
      } == .hidden)
    #expect(reads == 0)
    let struggling = IslandState.resolve(facts(risk: .warning, strain: ["fan 78%"])) {
      reads += 1
      return true
    }
    #expect(struggling == .hidden && reads == 1)
    let shown = IslandState.resolve(facts(risk: .warning, strain: ["fan 78%"])) { false }
    #expect(shown == .pressure(free: 1_200_000_000, critical: false, strain: ["fan 78%"]))
    let call = IslandState.resolve(facts(meeting: true, ledger: [entry("a", .meeting)])) { true }
    #expect(call == .call(.calendar, paused: 1))
  }

  /// A call and critical pressure show in full screen too, so the window list isn't read for them.
  @Test func fullScreenIsNotReadForWhatShowsInFullScreenAnyway() {
    var reads = 0
    func read() -> Bool {
      reads += 1
      return true
    }
    let call = IslandState.resolve(
      facts(meeting: true, ledger: [entry("a", .meeting)]), fullScreen: read)
    #expect(call == .call(.calendar, paused: 1))
    let critical = IslandState.resolve(facts(risk: .critical), fullScreen: read)
    #expect(critical == .pressure(free: 1_200_000_000, critical: true, strain: nil))
    #expect(reads == 0)
    let paused = IslandState.resolve(
      facts(ledger: [entry("a", .pressure)], risk: .critical), fullScreen: read)
    #expect(paused == .pressure(free: 1_200_000_000, critical: true, strain: nil))
    #expect(reads == 1, "an automatic pause shows as critical pressure only in full screen")
    let note = IslandState.resolve(facts(note: ("Slowed 2 builds", t0)), fullScreen: read)
    #expect(note == .hidden && reads == 2)
  }

  /// Resume now confirms the click with the resumed flash, counting every entry it took, even
  /// one whose resume is still owed.
  @Test @MainActor func resumeNowFlashesResumed() {
    let model = DevProcessModel()
    var outcome = AutoPauseWiring.Outcome()
    outcome.taken = 2
    outcome.resumed = 1
    model.resumeNowLanded(outcome, now: t0)
    let state = IslandState.resolve(model.islandFacts(now: t0.addingTimeInterval(1), freeBytes: 1))
    {
      false
    }
    #expect(state == .resumed(2))
    // Nothing taken, nothing to confirm.
    let idle = DevProcessModel()
    idle.resumeNowLanded(.init(), now: t0)
    #expect(idle.lastResume == nil)
  }

  // MARK: Wings (N2)

  @Test func wingsPerState() {
    #expect(IslandState.hidden.wingText == nil)
    #expect(
      IslandState.call(.calendar, paused: 6).wingText
        == .init(symbol: "calendar", label: "call", detail: "6 paused", tone: .neutral))
    #expect(
      IslandState.call(.mic, paused: 0).wingText
        == .init(symbol: "mic.fill", label: "call", detail: "", tone: .neutral))
    #expect(
      IslandState.autoPaused(3).wingText
        == .init(
          symbol: "exclamationmark.triangle.fill", label: "mem", detail: "3 paused",
          tone: .warning))
    #expect(
      IslandState.pressure(free: 1_200_000_000, critical: false, strain: ["fan 78%"]).wingText
        == .init(
          symbol: "exclamationmark.triangle.fill", label: "struggling", detail: "fan 78%",
          tone: .warning))
    #expect(
      IslandState.pressure(free: 1_200_000_000, critical: true, strain: nil).wingText
        == .init(
          symbol: "exclamationmark.triangle.fill", label: "mem", detail: "\(gb) free",
          tone: .critical))
    #expect(
      IslandState.resumed(6).wingText
        == .init(symbol: "checkmark", label: nil, detail: "resumed 6", tone: .good))
    #expect(
      IslandState.note("Quit Loom · 1.2 GB · reopens later").wingText
        == .init(symbol: "circle.lefthalf.filled", label: nil, detail: "Quit Loom", tone: .neutral))
  }

  @Test func noteSplitsAtTheFirstDot() {
    #expect(
      IslandState.split("Quit Loom · 1.2 GB · reopens later") == (
        "Quit Loom", "1.2 GB · reopens later"
      ))
    #expect(IslandState.split("Slowed 2 builds") == ("Slowed 2 builds", nil))
    #expect(IslandState.split("Paused web for your call") == ("Paused web for your call", nil))
  }

  // MARK: Menu bar (N5, N7)

  /// N7 (2026-10-27): the item says what the notch says, in the wings' symbol and tone; all
  /// is well is the icon alone, with no text at all.
  @Test func menuBarPerState() {
    #expect(IslandState.hidden.menuText == nil, "all is well: the icon only")
    #expect(
      IslandState.call(.calendar, paused: 2).menuText
        == .init(symbol: "calendar", text: "Call · 2 paused", tone: .neutral))
    #expect(
      IslandState.call(.mic, paused: 0).menuText
        == .init(symbol: "mic.fill", text: "Call", tone: .neutral))
    #expect(
      IslandState.autoPaused(3).menuText
        == .init(symbol: "exclamationmark.triangle.fill", text: "3 paused", tone: .warning))
    #expect(
      IslandState.pressure(free: 1_200_000_000, critical: false, strain: ["fan 78%"]).menuText
        == .init(
          symbol: "exclamationmark.triangle.fill", text: "Struggling · fan 78%", tone: .warning))
    #expect(
      IslandState.pressure(free: 1_200_000_000, critical: true, strain: nil).menuText
        == .init(
          symbol: "exclamationmark.triangle.fill", text: "Memory is critical · \(gb)",
          tone: .critical))
    #expect(
      IslandState.resumed(6).menuText
        == .init(symbol: "checkmark", text: "Resumed 6", tone: .good))
    #expect(
      IslandState.note("Slowed 2 builds").menuText
        == .init(symbol: "circle.lefthalf.filled", text: "Slowed 2 builds", tone: .neutral))
  }

  /// The approved mock: "Paused 3 idle sessions · 2.4 GB", what Tamebar did and what it freed;
  /// the rest of the note ("resumes when memory recovers") is the card's and the panel's.
  @Test func aNoteKeepsWhatItFreedInTheMenuBar() {
    #expect(
      IslandState.note("Paused 3 idle sessions · 2.4 GB · resumes when memory recovers")
        .menuText?.text == "Paused 3 idle sessions · 2.4 GB")
    #expect(
      IslandState.note("Disk reserve low · 24 GB free").menuText?.text
        == "Disk reserve low · 24 GB free")
    #expect(
      IslandState.note("Paused 3 idle sessions · resumes when memory recovers").menuText?.text
        == "Paused 3 idle sessions", "no figure: the headline only")
    #expect(
      IslandState.note("Ended 2 sessions idle 9+ days · 1.1 GB").menuText?.text
        == "Ended 2 sessions idle… · 1.1 GB", "the headline is cut, the figure kept")
  }

  /// A note shows for 4 s in the menu bar too, then the state under it comes back, or the icon
  /// alone (N7).
  @Test func aNoteRevertsAfterFourSecondsInTheMenuBar() {
    let note = (text: "Slowed 2 builds", at: t0)
    func label(_ seconds: TimeInterval, risk: MemoryRisk = .normal, strain: [String] = [])
      -> String?
    {
      let at = IslandState.Facts(
        now: t0.addingTimeInterval(seconds), meeting: false, source: .none, ledger: [],
        risk: risk, freeBytes: 1_200_000_000, lastResume: nil, note: note,
        struggling: !strain.isEmpty, strain: strain)
      return IslandState.resolve(at, on: .menuBar) { false }.menuText?.text
    }
    #expect(label(0) == "Slowed 2 builds")
    #expect(label(4) == "Slowed 2 builds", "4 s, end included")
    #expect(label(4.5) == nil, "then the icon alone")
    #expect(label(4.5, risk: .warning) == nil, "warning alone: the icon alone (N12)")
    #expect(
      label(4.5, risk: .warning, strain: ["fan 78%"]) == "Struggling · fan 78%",
      "or the state under it")
  }

  @Test func longNoteIsShortenedInTheMenuBar() {
    let text = IslandState.note("Ended 12 sessions idle 9+ days while you were away").menuText?.text
    #expect(text == "Ended 12 sessions idle…")
    #expect(text.map { $0.count <= IslandState.menuLimit } == true)
  }

  /// The real notes, as their builders write them: a long one is cut at the last space that
  /// fits, never mid-word, and a short one is left alone.
  @Test func realNotesAreCutBetweenWordsInTheMenuBar() {
    func menu(_ note: String?) -> String? { note.flatMap { IslandState.note($0).menuText?.text } }
    let day = UnusedPolicy.day
    #expect(AutoEndScheduler.note([9 * day, 12 * day]) == "Ended 2 sessions idle 9+ days")
    #expect(menu(AutoEndScheduler.note([9 * day, 12 * day])) == "Ended 2 sessions idle…")
    // "30" fits but "30+" doesn't: the whole token goes.
    #expect(menu(AutoEndScheduler.note([30 * day])) == "Ended 1 session idle…")
    #expect(
      menu(
        AutoPauseWiring.note(
          paused: [.meeting, .meeting],
          projects: [.init(directory: "/code/web", name: "web", reason: .meeting)]))
        == "Paused 2 idle sessions…")
    #expect(
      menu(AutoPauseWiring.note(paused: [.pressure, .pressure])) == "Paused 2 idle sessions")
    #expect(
      menu(BackgroundPriority.note(builds: 0, tasks: [("Visual Studio Code", 3)]))
        == "Slowed 3 tasks of…")
    #expect(menu(BackgroundPriority.note(builds: 2, tasks: [])) == "Slowed 2 builds")
    #expect(
      menu(AppPressureWiring.note(.init(name: "Loom", memoryBytes: 1_200_000_000)))
        == "Quit Loom · \(gb)")
    // No space to cut at: cut at the limit.
    #expect(menu(String(repeating: "x", count: 30)) == String(repeating: "x", count: 23) + "…")
    let outlook = AppPressurePlanner.Entry(
      bundleID: "com.microsoft.Outlook", name: "Microsoft Outlook",
      bundleURL: URL(fileURLWithPath: "/Applications/Microsoft Outlook.app"), memoryBytes: 1,
      quitAt: t0)
    #expect(menu(AppPressureWiring.reopenFailedNote(outlook)) == "Couldn't reopen…")
    for note in [AutoEndScheduler.note([9 * day]), AppPressureWiring.reopenFailedNote(outlook)] {
      let text = menu(note) ?? ""
      #expect(text.count <= IslandState.menuLimit)
      #expect(!text.hasSuffix(" …") && !text.contains("  "))
    }
  }

  // MARK: Wing width

  @Test func wingsWidenForLongTextUpToALimit() {
    #expect(NotchGeometry.wingWidth(fitting: 20) == NotchGeometry.wingWidth)
    #expect(NotchGeometry.wingWidth(fitting: 100) == 100 + 2 * NotchGeometry.wingPadding)
    #expect(NotchGeometry.wingWidth(fitting: 900) == NotchGeometry.maxWingWidth)
    let notch = CGRect(x: 663.5, y: 950, width: 185, height: 32)
    let wide = NotchGeometry.collapsed(notch: notch, wing: 150)
    #expect(wide.left == CGRect(x: 513.5, y: 950, width: 150, height: 32))
    #expect(wide.right == CGRect(x: 848.5, y: 950, width: 150, height: 32))
    #expect(wide.panel == CGRect(x: 513.5, y: 950, width: 485, height: 32))
    #expect(
      NotchGeometry.collapsed(notch: notch) == NotchGeometry.collapsed(notch: notch, wing: 96))
    let expanded = NotchGeometry.expanded(notch: notch, contentHeight: 300, wing: 150)
    #expect(expanded == CGRect(x: 513.5, y: 650, width: 485, height: 332))
  }
}
