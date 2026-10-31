import Foundation
import Testing

@testable import Tamebar

struct IslandStateTests {
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  /// Flash and note times are seconds after t0; `now` too. `strain` makes the Mac struggling
  /// (Q19) with those reasons; nil, it isn't.
  func input(
    meeting: Bool = false, source: IslandState.CallSource = .calendar, pausedForCall: Int = 0,
    pausedForPressure: Int = 0, risk: MemoryRisk = .normal, resumed: (TimeInterval, Int)? = nil,
    note: (TimeInterval, String)? = nil, fullScreen: Bool = false, now: TimeInterval = 0,
    strain: [String]? = nil
  ) -> IslandState.Input {
    .init(
      now: t0.addingTimeInterval(now), meeting: meeting, callSource: source,
      pausedForCall: pausedForCall, pausedForPressure: pausedForPressure, risk: risk,
      freeBytes: 1_200_000_000,
      resumed: resumed.map { .init(at: t0.addingTimeInterval($0.0), count: $0.1) },
      note: note.map { .init(text: $0.1, at: t0.addingTimeInterval($0.0)) },
      fullScreen: fullScreen, struggling: strain != nil, strain: strain ?? [])
  }

  func resolve(_ input: IslandState.Input) -> IslandState { IslandState.resolve(input) }

  let fan = ["fan 78%"]
  let struggling = IslandState.pressure(free: 1_200_000_000, critical: false, strain: ["fan 78%"])
  let critical = IslandState.pressure(free: 1_200_000_000, critical: true, strain: nil)

  @Test func hiddenWhenNothingHappens() {
    #expect(resolve(input()) == .hidden)
    #expect(resolve(input(risk: .growing)) == .hidden)
  }

  /// N12 (2026-10-31): macOS's "warning", which this Mac reports nearly all day, shows
  /// nothing on its own, on either surface; only Q19's strain or critical does.
  @Test func warningAloneShowsNothing() {
    #expect(resolve(input(risk: .warning)) == .hidden)
    #expect(IslandState.resolve(input(risk: .warning), on: .notch) == .hidden)
    #expect(resolve(input(risk: .warning, resumed: (0, 6), now: 1)) == .resumed(6))
    #expect(
      IslandState.pressureFlash(after: nil, risk: .warning, struggling: false, now: t0) == nil)
  }

  @Test func eachStateAlone() {
    #expect(resolve(input(meeting: true, source: .mic, pausedForCall: 6)) == .call(.mic, paused: 6))
    #expect(resolve(input(meeting: true)) == .call(.calendar, paused: 0))
    #expect(resolve(input(pausedForPressure: 3)) == .autoPaused(3))
    #expect(resolve(input(risk: .warning, strain: fan)) == struggling)
    // Struggling with memory normal (the fans alone) is pressure too.
    #expect(resolve(input(strain: fan)) == struggling)
    #expect(resolve(input(risk: .critical)) == critical)
    #expect(
      resolve(input(risk: .critical, strain: ["memory critical"]))
        == .pressure(free: 1_200_000_000, critical: true, strain: ["memory critical"]))
    #expect(resolve(input(resumed: (0, 6), now: 1)) == .resumed(6))
    #expect(resolve(input(note: (0, "Slowed 2 builds"), now: 1)) == .note("Slowed 2 builds"))
  }

  /// Every state present at once, then the top one removed in turn: each step shows the next.
  @Test func priorityOrder() {
    let note = (TimeInterval(0), "Quit Loom")
    #expect(
      resolve(
        input(
          meeting: true, pausedForCall: 6, pausedForPressure: 3, risk: .critical,
          resumed: (0, 6), note: note, now: 1)) == .call(.calendar, paused: 6))
    // What Tamebar just did comes before what lasts (no banners, 2026-10-27).
    #expect(
      resolve(input(pausedForPressure: 3, risk: .critical, resumed: (0, 6), note: note, now: 1))
        == .note("Quit Loom"))
    #expect(
      resolve(input(pausedForPressure: 3, risk: .critical, resumed: (0, 6), now: 1))
        == .autoPaused(3))
    #expect(resolve(input(risk: .critical, resumed: (0, 6), now: 1)) == critical)
    #expect(resolve(input(risk: .warning, resumed: (0, 6), now: 1, strain: fan)) == struggling)
    #expect(resolve(input(resumed: (0, 6), now: 1)) == .resumed(6))
    #expect(resolve(input(note: note, now: 1)) == .note("Quit Loom"))
  }

  /// No banners (2026-10-27): Tamebar acts, then says so in a 4 s note. The note shows
  /// over the pause it reports, on both surfaces; after it the menu bar keeps "3 paused" while
  /// the notch hides, as it does for pressure.
  @Test func anAutomaticPauseIsAFourSecondNoteInTheNotch() {
    let text = "Paused 3 idle sessions · 2.4 GB · resumes when memory recovers"
    let fresh = input(pausedForPressure: 3, risk: .warning, note: (0, text), now: 1)
    #expect(IslandState.resolve(fresh, on: .notch) == .note(text))
    #expect(IslandState.resolve(fresh, on: .menuBar) == .note(text))
    let later = input(pausedForPressure: 3, risk: .warning, note: (0, text), now: 5)
    #expect(IslandState.resolve(later, on: .notch) == .hidden)
    #expect(IslandState.resolve(later, on: .menuBar) == .autoPaused(3))
  }

  /// A pause for a call that outlives the call is not a pressure pause: it shows nothing.
  @Test func callPausesDontShowAsAutoPause() {
    #expect(resolve(input(pausedForCall: 2)) == .hidden)
  }

  @Test func resumedLastsFourSeconds() {
    #expect(IslandState.resumedFor == 4)
    #expect(resolve(input(resumed: (0, 6), now: 0)) == .resumed(6))
    #expect(resolve(input(resumed: (0, 6), now: 3)) == .resumed(6))
    #expect(resolve(input(resumed: (0, 6), now: 4)) == .resumed(6))
    #expect(resolve(input(resumed: (0, 6), now: 4.1)) == .hidden)
  }

  @Test func noteLastsFourSeconds() {
    #expect(IslandState.noteFor == 4)
    #expect(resolve(input(note: (0, "Slowed 2 builds"), now: 4)) == .note("Slowed 2 builds"))
    #expect(resolve(input(note: (0, "Slowed 2 builds"), now: 4.1)) == .hidden)
  }

  /// An expired resumed flash gives way to a later, live note.
  @Test func expiredResumedFallsThroughToLiveNote() {
    #expect(
      resolve(input(resumed: (0, 6), note: (3, "Slowed 2 builds"), now: 5))
        == .note("Slowed 2 builds"))
  }

  /// A flash stamped after `now` (a clock change) never shows.
  @Test func flashesFromTheFutureDontShow() {
    #expect(resolve(input(resumed: (2, 6), now: 0)) == .hidden)
    #expect(resolve(input(note: (2, "Slowed 2 builds"), now: 0)) == .hidden)
  }

  @Test func fullScreenShowsOnlyCallAndCritical() {
    #expect(resolve(input(risk: .warning, fullScreen: true)) == .hidden)
    // N4 as before: struggling short of critical waits for full screen to end.
    #expect(resolve(input(risk: .warning, fullScreen: true, strain: fan)) == .hidden)
    #expect(resolve(input(risk: .critical, fullScreen: true)) == critical)
    #expect(resolve(input(meeting: true, fullScreen: true)) == .call(.calendar, paused: 0))
    #expect(
      resolve(input(meeting: true, pausedForCall: 2, risk: .critical, fullScreen: true))
        == .call(.calendar, paused: 2))
  }

  @Test func fullScreenDropsAutoPauseUnlessCritical() {
    #expect(resolve(input(pausedForPressure: 3, risk: .warning, fullScreen: true)) == .hidden)
    #expect(resolve(input(pausedForPressure: 3, risk: .critical, fullScreen: true)) == critical)
  }

  @Test func fullScreenDropsFlashes() {
    #expect(resolve(input(resumed: (0, 2), fullScreen: true, now: 1)) == .hidden)
    #expect(resolve(input(note: (0, "Quit Loom"), fullScreen: true, now: 1)) == .hidden)
    // Dropped, not queued: once its time is up, it never shows after full screen ends.
    #expect(resolve(input(resumed: (0, 2), now: 5)) == .hidden)
  }

  // MARK: Pressure flashes in the notch (2026-10-23: "I don't want it permanently display
  // the mem error display it for few second and disappear")

  /// Where the Mac is at a second: calm, macOS's warning alone, struggling (warning and the
  /// fans), or memory critical.
  enum Level { case calm, warning, struggling, critical }

  /// The Mac's level over time, a second apart from t0: what the notch and the menu bar show at
  /// each second, the pressure flash carried from one second to the next as the controller does.
  func run(
    _ levels: [Level], fullScreen: Bool = false, note: (TimeInterval, String)? = nil
  ) -> [(notch: IslandState, menuBar: IslandState)] {
    var flash: IslandState.PressureFlash?
    return levels.enumerated().map { second, level in
      let now = t0.addingTimeInterval(TimeInterval(second))
      let risk: MemoryRisk =
        switch level {
        case .calm: .normal
        case .warning, .struggling: .warning
        case .critical: .critical
        }
      let strain = level == .struggling ? fan : nil
      flash = IslandState.pressureFlash(
        after: flash, risk: risk, struggling: strain != nil, now: now)
      var input = input(
        risk: risk, note: note, fullScreen: fullScreen, now: TimeInterval(second), strain: strain)
      input.pressureFlash = flash
      return (IslandState.resolve(input, on: .notch), IslandState.resolve(input, on: .menuBar))
    }
  }

  /// Shown from the second it starts for `pressureFor` (4 s, both ends included as for the other
  /// flashes), then hidden in the notch; the menu bar keeps it while it lasts.
  @Test func pressureFlashesForFourSecondsInTheNotch() {
    #expect(IslandState.pressureFor == 4)
    let shown = run(Array(repeating: .struggling, count: 8))
    #expect(
      shown.map(\.notch) == Array(repeating: struggling, count: 5) + [.hidden, .hidden, .hidden])
    #expect(shown.map(\.menuBar) == Array(repeating: struggling, count: 8))
    // The pure rule, with the flash given: at 0 and 4 s it shows, past 4 s it doesn't.
    for (second, expected) in [(0.0, struggling), (4, struggling), (4.1, .hidden), (60, .hidden)] {
      var input = input(risk: .warning, now: second, strain: fan)
      input.pressureFlash = .init(at: t0, critical: false)
      #expect(IslandState.resolve(input, on: .notch) == expected, "at \(second) s")
      #expect(IslandState.resolve(input, on: .menuBar) == struggling, "at \(second) s")
    }
    // A day at warning never flashes nor shows (N12).
    let warning = run(Array(repeating: .warning, count: 8))
    #expect(warning.allSatisfy { $0.notch == .hidden && $0.menuBar == .hidden })
  }

  /// Getting worse (struggling to critical) shows it again for 4 s.
  @Test func pressureShowsAgainWhenItGetsWorse() {
    let shown = run(Array(repeating: .struggling, count: 7) + [.critical, .critical])
    #expect(shown[5].notch == .hidden)
    #expect(shown[6].notch == .hidden)
    #expect(shown[7].notch == critical, "critical: shown again")
    #expect(shown[8].notch == critical)
  }

  /// Staying at a level never shows it again, nor does going back up to a level already shown
  /// since the pressure last eased: critical, struggling, critical again flashes once, at the
  /// start.
  @Test func pressureDoesntShowAgainAtTheSameLevel() {
    let steady = run(Array(repeating: .critical, count: 30))
    #expect(steady[5...].allSatisfy { $0.notch == .hidden })
    let flapping = run(
      [.critical] + Array(repeating: .critical, count: 5)
        + [.struggling, .critical, .struggling, .critical])
    #expect(flapping[0].notch == critical)
    #expect(flapping[6...].allSatisfy { $0.notch == .hidden }, "\(flapping.map(\.notch))")
    #expect(flapping[6].menuBar == struggling, "the menu bar follows the level")
    #expect(flapping[7].menuBar == critical)
  }

  /// The pressure eases (warning alone counts as eased, N12) and comes back later: a new flash.
  @Test func pressureShowsAgainAfterItClearsAndReturns() {
    let shown = run(
      Array(repeating: .struggling, count: 6) + [.warning, .calm] + [.struggling, .struggling])
    #expect(shown[5].notch == .hidden)
    #expect(shown[6].notch == .hidden && shown[6].menuBar == .hidden, "eased")
    #expect(shown[8].notch == struggling, "back: shown again")
    #expect(
      IslandState.pressureFlash(
        after: .init(at: t0, critical: true), risk: .warning, struggling: false,
        now: t0.addingTimeInterval(1)) == nil)
  }

  /// N4: in full screen only critical shows, as a 4 s flash too; the menu bar keeps critical.
  @Test func fullScreenShowsCriticalPressureAsAFlash() {
    let shown = run(Array(repeating: .critical, count: 7), fullScreen: true)
    #expect(shown.map(\.notch) == Array(repeating: critical, count: 5) + [.hidden, .hidden])
    #expect(shown.map(\.menuBar) == Array(repeating: critical, count: 7))
    let quiet = run(Array(repeating: .struggling, count: 3), fullScreen: true)
    #expect(quiet.allSatisfy { $0.notch == .hidden && $0.menuBar == .hidden })
    // Struggling, then critical while full screen: the escalation flashes there.
    let worse = run(Array(repeating: .struggling, count: 6) + [.critical], fullScreen: true)
    #expect(worse[6].notch == critical)
  }

  /// Once the pressure flash is over, the notch shows what comes after it: a note on what
  /// Tamebar did, on the menu bar too for its 4 s, then the menu bar has the pressure again. An
  /// automatic pause stays on the menu bar only (no banners, 2026-10-27); a call is as before.
  @Test func afterThePressureFlashTheNotchShowsTheNextState() {
    let shown = run(Array(repeating: .struggling, count: 8), note: (6, "Quit Loom · 1.2 GB"))
    #expect(shown[6].notch == .note("Quit Loom · 1.2 GB"))
    #expect(shown[6].menuBar == .note("Quit Loom · 1.2 GB"))
    var paused = input(pausedForPressure: 3, risk: .warning, now: 30, strain: fan)
    paused.pressureFlash = .init(at: t0, critical: false)
    #expect(IslandState.resolve(paused, on: .notch) == .hidden)
    #expect(IslandState.resolve(paused, on: .menuBar) == .autoPaused(3))
    var call = input(meeting: true, risk: .critical, now: 30)
    call.pressureFlash = .init(at: t0, critical: true)
    #expect(IslandState.resolve(call, on: .notch) == .call(.calendar, paused: 0))
    // No flash recorded: the notch never shows pressure on its own.
    #expect(IslandState.resolve(input(risk: .critical), on: .notch) == .hidden)
  }

  @Test func debugNames() {
    #expect(IslandState.hidden.debugName == "hidden")
    #expect(IslandState.call(.mic, paused: 1).debugName == "call")
    #expect(IslandState.autoPaused(1).debugName == "autoPaused")
    #expect(IslandState.pressure(free: 1, critical: false, strain: []).debugName == "pressure")
    #expect(IslandState.resumed(1).debugName == "resumed")
    #expect(IslandState.note("x").debugName == "note")
  }
}
