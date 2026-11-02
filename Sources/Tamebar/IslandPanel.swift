import AppKit
import SwiftUI

/// The island's window: borderless, above the menu bar, on every Space and beside full-screen
/// apps, and never in a shared screen (N3). It holds the wings only (N11 removed the panel under
/// the notch), so it never takes key focus and never activates Tamebar.
final class IslandPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// A configured panel, with no content yet. `IslandPanelTests` pins every setting here.
  static func make() -> IslandPanel {
    let panel = IslandPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    configure(panel)
    return panel
  }

  static func configure(_ panel: IslandPanel) {
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
    panel.collectionBehavior = [
      .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
    ]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    // N3: never in a shared screen.
    panel.sharingType = .none
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
  }
}

/// Owns the notch island (N1–N4) and the island state the menu-bar item shows (N5). Every second,
/// and at once on a display change, it resolves the state from the model and places the window:
/// hidden while all is well, wings around the notch while something shows. A click on the wings
/// opens Tamebar's window (N11). With no notched screen it has no window; the menu-bar item is then
/// the only surface.
@MainActor
final class IslandController: ObservableObject {
  struct Metrics: Equatable {
    var notchWidth: CGFloat = 185
    var notchHeight: CGFloat = 32
    var wingWidth: CGFloat = NotchGeometry.wingWidth
  }

  /// What the notch shows: pressure only as a 4 s flash (`IslandState.Surface.notch`).
  @Published private(set) var state: IslandState = .hidden
  /// What the menu-bar item and its card show (N5): pressure for as long as it lasts.
  @Published private(set) var menuState: IslandState = .hidden
  @Published private(set) var metrics = Metrics()
  /// A screen with a notch is connected, whether the notch is on or off in Settings: the
  /// menu-bar item shows whenever the notch can't (N9).
  @Published private(set) var notchScreen = false

  let monitor: SystemMonitor
  let memory: MemoryRescueModel
  let navigation: WindowNavigation
  let processes: DevProcessModel
  /// The tools the card's Ask row offers (N8).
  let agents: AskAgents

  /// The motion of the wings (N2) and the card (N6): ease-out, no bounce or pulse.
  nonisolated static let motion: TimeInterval = 0.3

  /// What the controller reads from the Mac and the model. Tests replace it, so they never read
  /// this Mac's screens or windows nor take key focus from the user's app.
  struct Environment {
    var now: @MainActor () -> Date = { .now }
    /// The screens as they are now. The notched one is picked from them on every placement.
    var screens: @MainActor () -> [NotchGeometry.Screen] = { NotchGeometry.screens() }
    /// The model's facts at a time; nil reads `processes` and `monitor`.
    var facts: (@MainActor (Date) -> IslandState.Facts)? = nil
    /// Whether an app is full screen on the notched screen, or on the main one when it's nil.
    var isFullScreen: @MainActor (NotchGeometry.Screen?) -> Bool = {
      NotchGeometry.isFullScreen(on: $0)
    }
    /// Reduce Motion: the window moves at once.
    var reduceMotion: @MainActor () -> Bool = {
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    /// The card's Open › and Activity links, and a click on the wings: Tamebar's window, on a tab
    /// when given, Tamebar in front (N11).
    var openWindow: @MainActor (IslandController, WindowTab?) -> Void = { $0.navigation.open($1) }
    /// The hover card's Ask Claude / Ask Codex (N8): Terminal running the tool.
    var ask: @MainActor (AskAgent) -> Void = { AskAgents.launch($0) }
    /// Settings → Show Tamebar in → Notch (N9). Off, the controller has no window, as with no
    /// notched screen; the menu bar's state still resolves every tick.
    var notchShown: @MainActor () -> Bool = { ShowSurfaces.load().notch }
    /// Runs `work` once after a delay: the hover card's open and close (N6). Tests run it by hand.
    var after: @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void = {
      delay, work in
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(delay))
        work()
      }
    }
    /// Where the pointer is, in screen coordinates: the hover card trusts it over a tracking
    /// area's exit, which fires while the window is still growing.
    var pointer: @MainActor () -> CGPoint = { NSEvent.mouseLocation }
  }

  /// The notched screen and its notch.
  typealias Notched = (screen: NotchGeometry.Screen, notch: CGRect)

  var environment = Environment()
  /// The hover usage card under the notch (N6).
  let card = IslandCardController()

  private var panel: IslandPanel?
  private var timer: Timer?
  private var screenObserver: NSObjectProtocol?
  private var settingsObserver: NSObjectProtocol?
  /// Settings → Show Tamebar in → Notch, as last read.
  private var notchShown = true
  /// Where the window is going; nil while it is hidden or hiding.
  private var target: CGRect?
  /// Until when the window is easing to `target`; it isn't there yet before then.
  private var easedBy: ContinuousClock.Instant?
  /// The notch the window was last placed around.
  private var notch: CGRect?
  /// The notch's current pressure flash, carried from tick to tick; nil while memory is calm.
  private var pressureFlash: IslandState.PressureFlash?

  init(
    monitor: SystemMonitor, memory: MemoryRescueModel, navigation: WindowNavigation,
    processes: DevProcessModel, agents: AskAgents = AskAgents()
  ) {
    self.monitor = monitor
    self.memory = memory
    self.navigation = navigation
    self.processes = processes
    self.agents = agents
    card.attach(self)
  }

  /// Starts the one-second tick. Called once the menu-bar item appears; a second call does
  /// nothing.
  func start() {
    guard timer == nil else { return }
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    observeScreens()
    observeNotchSetting()
    tick()
  }

  /// Settings → Show Tamebar in → Notch switches at once, not on the next tick.
  private func observeNotchSetting() {
    guard settingsObserver == nil else { return }
    notchShown = environment.notchShown()
    settingsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.environment.notchShown() != self.notchShown else { return }
        self.tick()
      }
    }
  }

  func tick() {
    let notched = notchedScreen()
    show(resolve(on: notched))
    place(notched)
  }

  /// A display came, went or changed (connected, disconnected, the lid, the arrangement or a
  /// resolution): the window is placed again at once from the screens as they are now. It is
  /// placed even when that gives the frame it had and the state is unchanged, since AppKit may
  /// have moved the window during the change.
  func screensChanged() {
    let notched = notchedScreen()
    show(resolve(on: notched))
    place(notched, reframe: true)
  }

  /// Calls `screensChanged` on AppKit's screen notification. `start` does this; a second call
  /// does nothing.
  func observeScreens(_ center: NotificationCenter = .default) {
    guard screenObserver == nil else { return }
    screenObserver = center.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.screensChanged() }
    }
  }

  /// The model's state now for each surface, full screen read on the notched screen (or the
  /// main one), at most once. Carries the notch's pressure flash forward.
  private func resolve(on notched: Notched?) -> (menuBar: IslandState, notch: IslandState) {
    let now = environment.now()
    var facts =
      environment.facts?(now)
      ?? {
        let snapshot = monitor.snapshot
        return processes.islandFacts(
          now: now, freeBytes: min(snapshot.ramAvailable, snapshot.ramTotal))
      }()
    pressureFlash = IslandState.pressureFlash(
      after: pressureFlash, risk: facts.risk, struggling: facts.struggling, now: now)
    facts.pressureFlash = pressureFlash
    var fullScreen: Bool?
    let isFullScreen = { [environment] () -> Bool in
      // The e2e build never reads this Mac's windows, so its states don't depend on them.
      guard E2EMode.current == nil else { return false }
      if let fullScreen { return fullScreen }
      let read = environment.isFullScreen(notched?.screen)
      fullScreen = read
      return read
    }
    return (
      IslandState.resolve(facts, on: .menuBar, fullScreen: isFullScreen),
      IslandState.resolve(facts, on: .notch, fullScreen: isFullScreen)
    )
  }

  /// The notched screen among the screens as they are now; nil while the notch is off in
  /// Settings (N9), so the island and the card have no window, as with no notch.
  private func notchedScreen() -> Notched? {
    let notched = NotchGeometry.notchedScreen(in: environment.screens())
    if (notched != nil) != notchScreen { notchScreen = notched != nil }
    notchShown = environment.notchShown()
    return notchShown ? notched : nil
  }

  /// Shows `resolved`: the menu bar's state and the notch's.
  private func show(_ resolved: (menuBar: IslandState, notch: IslandState)) {
    if resolved.menuBar != menuState { menuState = resolved.menuBar }
    guard resolved.notch != state else { return }
    state = resolved.notch
    if let mode = E2EMode.current { writeImage(to: mode.directory) }
  }

  /// E2E only (Task 9.4): `<dir>/island.png`, the window's view drawn once the motion is over,
  /// from its own backing store, so no screen-recording permission is needed. None without a
  /// window (no notch); the state dump still carries the state.
  private func writeImage(to directory: URL) {
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(Self.motion + 0.2))
      guard let view = self?.panel?.contentView, !view.bounds.isEmpty,
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
      else { return }
      view.cacheDisplay(in: view.bounds, to: rep)
      guard let data = rep.representation(using: .png, properties: [:]) else { return }
      try? data.write(to: directory.appendingPathComponent("island.png"), options: .atomic)
    }
  }

  /// A click on the wings: Tamebar's window on Activity, where what Tamebar did is (N11).
  func wingsClicked() {
    environment.openWindow(self, .activity)
  }

  // MARK: Placement

  /// The island's window, while there is one. For tests.
  var window: IslandPanel? { panel }

  /// Places the wings around `notched`'s notch for the current state, making the window on first
  /// need;
  /// with no notched screen, removes it. The frame is worked out afresh from `notched` every
  /// time, never from a frame or screen kept from before. `reframe` sets it at once even when it
  /// is the frame the window was given before (a display change).
  func place(_ notched: Notched?, reframe: Bool = false) {
    guard let notched else {
      removePanel()
      card.place(nil)
      return
    }
    let wing = state.wingText.map { NotchGeometry.wingWidth(fitting: Self.textWidth($0)) }
    let next = Metrics(
      notchWidth: notched.notch.width, notchHeight: notched.notch.height,
      wingWidth: wing ?? metrics.wingWidth)
    if next != metrics { metrics = next }
    notch = notched.notch
    let frame =
      state == .hidden
      ? nil : NotchGeometry.collapsed(notch: notched.notch, wing: next.wingWidth).panel
    move(panel ?? makePanel(), to: frame, notch: notched.notch, reframe: reframe)
    card.place(notched, reframe: reframe)
  }

  /// The wider of the two wings' content, in the wings' font.
  static func textWidth(_ text: IslandWingText) -> CGFloat {
    let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    func width(_ string: String) -> CGFloat {
      (string as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }
    // The symbol takes about a glyph's width, then the 5 pt gap before the word.
    let left = 16 + (text.label.map { 5 + width($0) } ?? 0)
    return max(left, width(text.detail))
  }

  private func makePanel() -> IslandPanel {
    let panel = IslandPanel.make()
    let host = NSHostingView(rootView: IslandView(controller: self))
    // The controller sizes the window; the view must not.
    host.sizingOptions = []
    panel.contentView = host
    self.panel = panel
    return panel
  }

  private func removePanel() {
    panel?.orderOut(nil)
    panel = nil
    target = nil
    easedBy = nil
  }

  /// Eases the wings to `frame`, out of the notch when they appear, back into it when they hide.
  /// Under Reduce Motion it moves at once.
  ///
  /// The frame asked for before isn't trusted to be where the window is: a display change can
  /// move the window (or order it out) while the notch, and so the frame, stay the same. Such a
  /// window is put back at once (`jump`), as is every window on `reframe`.
  private func move(_ panel: IslandPanel, to frame: CGRect?, notch: CGRect, reframe: Bool) {
    if reframe || (frame == target && frame.map { isOff($0, panel) } == true) {
      target = frame
      jump(panel, to: frame)
      return
    }
    guard frame != target else { return }
    let appearing = target == nil
    target = frame
    let still = environment.reduceMotion()
    guard let frame else {
      animate(panel, to: notch, still: still) { [weak self] in
        guard let self, target == nil else { return }
        self.panel?.orderOut(nil)
      }
      return
    }
    if appearing {
      panel.setFrame(still ? frame : notch, display: false)
      panel.orderFrontRegardless()
    }
    animate(panel, to: frame, still: still)
  }

  /// The window should be at `frame` and has finished easing there, yet it isn't: it is hidden,
  /// or more than a point away (AppKit puts frames on the backing grid).
  private func isOff(_ frame: CGRect, _ panel: IslandPanel) -> Bool {
    if let easedBy, ContinuousClock.now < easedBy { return false }
    let actual = panel.frame
    return !panel.isVisible || abs(actual.minX - frame.minX) > 1
      || abs(actual.minY - frame.minY) > 1 || abs(actual.width - frame.width) > 1
      || abs(actual.height - frame.height) > 1
  }

  /// Puts the window at `frame` and shows it, or hides it with none, at once. The zero-length
  /// motion replaces one still under way, so that one can't carry the window back to where it
  /// was going.
  private func jump(_ panel: IslandPanel, to frame: CGRect?) {
    easedBy = nil
    guard let frame else {
      panel.orderOut(nil)
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      panel.animator().setFrame(frame, display: true)
    }
    if !panel.isVisible { panel.orderFrontRegardless() }
  }

  private func animate(
    _ panel: IslandPanel, to frame: CGRect, still: Bool,
    then done: (@MainActor () -> Void)? = nil
  ) {
    guard !still else {
      panel.setFrame(frame, display: true)
      done?()
      return
    }
    easedBy = .now + .seconds(Self.motion + 0.1)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.motion
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().setFrame(frame, display: true)
    } completionHandler: {
      Task { @MainActor in done?() }
    }
  }
}
