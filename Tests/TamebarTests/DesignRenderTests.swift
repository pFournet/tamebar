import AppKit
import Darwin
import SwiftUI
import Testing

@testable import Tamebar

/// Writes screenshots for design review when `TAMEBAR_DESIGN_DIR` is set, each page in
/// light and dark (`<page>-light.png`, `<page>-dark.png`).
@MainActor
struct DesignRenderTests {
  /// N11: the window's two tabs at its default size, Activity with fixture Stopped entries and a
  /// week of trend, Settings with its sections; then the settings footer and the Meetings rows.
  @Test func rendersWindowWhenRequested() async throws {
    guard let output = ProcessInfo.processInfo.environment["TAMEBAR_DESIGN_DIR"] else { return }
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let now = Date.now
    let processes = DevProcessModel()
    var stored: [String] = []
    processes.appQuitStore = .init(read: { stored }, write: { stored = $0 })
    var optedOut: [String] = []
    processes.appSlowOptOutStore = .init(read: { optedOut }, write: { optedOut = $0 })
    processes.autoEndDefaults = TestDefaults("window-render").defaults
    processes.setAutoEnd(.init())
    func toolbar(_ tab: WindowTab) -> some View {
      Picker("View", selection: .constant(tab)) {
        ForEach(WindowTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
      }
      .pickerStyle(.segmented).labelsHidden().fixedSize()
      .frame(maxWidth: .infinity).frame(height: 38)
      .overlay(alignment: .bottom) { Rectangle().fill(BlitzUI.separator).frame(height: 1) }
    }
    let activity = VStack(spacing: 0) {
      toolbar(.activity)
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          CurrentActivityView(
            entries: Self.stoppedEntries(now: now),
            slowed: [.init(id: "ai:1", name: "Claude · project A", kind: .session)], now: now)
          UsageTrendCard(data: Self.trendData(now: now), now: now)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(WindowMetrics.padding)
      }
    }
    try await write(
      activity.background(BlitzUI.canvasBackground), named: "Window activity", in: directory,
      wait: .seconds(1), size: TamebarWindowView.size)
    let settings = VStack(spacing: 0) {
      toolbar(.settings)
      SettingsTab(
        processes: processes,
        permissions: PermissionsModel(
          calendar: .init(authorized: { false }), calendarAuthorized: { false },
          openCalendarsPane: {}),
        launchAtLogin: LaunchAtLoginController(), updates: AppUpdateController { _ in nil })
    }
    try await write(
      settings.background(BlitzUI.canvasBackground), named: "Window settings", in: directory,
      wait: .seconds(1), size: .init(width: TamebarWindowView.size.width, height: 1100))
    // Task 6.5: every state of the Google Calendar row, under the Calendars row. No source:
    // nothing here reaches Google.
    let googleRows: [GoogleCalendarModel.Row] = [
      .notConfigured, .status(.disconnected), .status(.connecting), .status(.connected),
      .status(.signInAgain), .status(.failed("The sign-in timed out. Try again.")),
    ]
    try await write(
      VStack(alignment: .leading, spacing: 20) {
        VStack(spacing: 0) {
          CalendarsPermissionRow(granted: false)
          CalendarsPermissionRow(granted: true)
        }.blitzTable()
        VStack(spacing: 0) {
          ForEach(googleRows.indices, id: \.self) { GoogleCalendarRow(row: googleRows[$0]) }
        }.blitzTable()
        VStack(alignment: .leading, spacing: 12) {
          SettingsQuitRow()
          SettingsAboutFooter(
            license: URL(fileURLWithPath: "/Applications/Tamebar.app/LICENSE.txt"))
        }
      }
      .padding(WindowMetrics.padding)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(BlitzUI.canvasBackground),
      named: "Settings meetings", in: directory, wait: .seconds(1),
      size: .init(width: TamebarWindowView.size.width, height: 640))
  }

  /// Task 7.3: Settings › Automatic actions, in Ask me with no app listed, then End after 7 days
  /// with three apps, one not installed. The setting and the list are kept in memory.
  @Test func rendersAutomaticActionsWhenRequested() async throws {
    guard let output = ProcessInfo.processInfo.environment["TAMEBAR_DESIGN_DIR"] else { return }
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let processes = DevProcessModel()
    var stored: [String] = []
    processes.appQuitStore = .init(read: { stored }, write: { stored = $0 })
    var optedOut: [String] = []
    processes.appSlowOptOutStore = .init(read: { optedOut }, write: { optedOut = $0 })
    processes.autoEndDefaults = TestDefaults("automatic-actions").defaults
    processes.setAutoEnd(.init())
    processes.safetyDefaults = TestDefaults("automatic-safety").defaults
    processes.setSafety(.init())
    for bundleID in processes.appQuitList.bundleIDs {
      processes.setQuitUnderPressure(bundleID, on: false)
    }
    for name in ["Settings automatic actions", "Settings automatic actions on"] {
      if name.hasSuffix("on") {
        processes.setAutoEnd(.init(mode: .auto, days: 7))
        for bundleID in ["com.apple.Preview", "com.apple.TextEdit", "com.loom.desktop"] {
          processes.setQuitUnderPressure(bundleID, on: true)
        }
        processes.setSlowInBackground("com.apple.TextEdit", on: false)
        processes.setSafety(
          .init(
            endIdleSessions: true, trimCodexPlugins: true, protectedPorts: [3000, 5173],
            keptCodexServers: ["chat"]))
      }
      try await write(
        AutomaticActionsSection(processes: processes).padding(WindowMetrics.padding)
          .frame(maxHeight: .infinity, alignment: .top).background(BlitzUI.canvasBackground),
        named: name, in: directory, wait: .seconds(1),
        size: .init(width: 860, height: name.hasSuffix("on") ? 620 : 520))
    }
  }

  /// N9: Settings › Show Tamebar in, both on; the menu bar off (Notch is the last one on); and
  /// with no notch screen (Notch greyed, the menu bar on).
  @Test func rendersShowTamebarInWhenRequested() async throws {
    guard let output = ProcessInfo.processInfo.environment["TAMEBAR_DESIGN_DIR"] else { return }
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cases: [(name: String, menuBar: Bool, notchScreen: Bool)] = [
      ("Settings show in", true, true), ("Settings show in notch only", false, true),
      ("Settings show in no notch", false, false),
    ]
    for (name, menuBar, notchScreen) in cases {
      let defaults = TestDefaults("show-in").defaults
      defaults.set(menuBar, forKey: ShowSurfaces.Key.menuBar)
      try await write(
        VStack(alignment: .leading, spacing: 12) {
          Text("Show Tamebar in").font(BlitzType.section)
          ShowTamebarInControls(notchScreen: notchScreen)
        }
        .frame(maxWidth: .infinity, alignment: .leading).panelCard(padding: 16)
        .defaultAppStorage(defaults)
        .padding(WindowMetrics.padding).frame(maxHeight: .infinity, alignment: .top)
        .background(BlitzUI.canvasBackground),
        named: name, in: directory, wait: .seconds(1), size: .init(width: 860, height: 230))
    }
  }

  /// Q16's Trend card: 7 days with a marker, and the empty state.
  @Test func rendersUsageTrendWhenRequested() async throws {
    guard let output = ProcessInfo.processInfo.environment["TAMEBAR_DESIGN_DIR"] else { return }
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let now = Date.now
    let full = Self.trendData(now: now)
    let cases: [(String, UsageTrendData)] = [
      ("Usage trend", full),
      ("Usage trend empty", .init(days: Array(full.days.suffix(1)), markers: [])),
    ]
    for (name, data) in cases {
      try await write(
        UsageTrendCard(data: data, now: now).padding(WindowMetrics.padding)
          .frame(maxHeight: .infinity, alignment: .top).background(BlitzUI.canvasBackground),
        named: name, in: directory, wait: .seconds(1),
        size: .init(width: 860, height: name.hasSuffix("empty") ? 140 : 300))
    }
  }

  /// Q15's list with the mock's four kinds, a paused project, and one row just copied; then
  /// the list with nothing left.
  @Test func rendersStoppedListWhenRequested() async throws {
    guard let output = ProcessInfo.processInfo.environment["TAMEBAR_DESIGN_DIR"] else { return }
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let now = Date.now
    let entries = Self.stoppedEntries(now: now)
    let renders: [(name: String, entries: [StoppedEntry], copied: String?, busy: Set<String>)] = [
      ("Activity", entries, nil, []), ("Activity copied", entries, "a", ["p"]),
      ("Activity empty", [], nil, []),
    ]
    for render in renders {
      let list = CurrentActivityView(
        entries: render.entries, busy: render.busy, now: now, copiedID: render.copied
      )
      .padding(12).frame(width: 480)
      try await write(
        list.frame(maxHeight: .infinity, alignment: .top).background(BlitzUI.canvasBackground),
        named: render.name, in: directory, wait: .seconds(1),
        size: .init(width: 480, height: render.entries.isEmpty ? 90 : 420))
    }
  }

  /// Task 9.3: the wings around this Mac's notch for each state.
  @Test func rendersIslandWhenRequested() async throws {
    guard let output = ProcessInfo.processInfo.environment["TAMEBAR_DESIGN_DIR"] else { return }
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let free = UInt64(1_200_000_000)
    let states: [(name: String, state: IslandState)] = [
      ("call", .call(.calendar, paused: 6)), ("call mic", .call(.mic, paused: 0)),
      ("auto-pause", .autoPaused(3)),
      ("pressure", .pressure(free: free, critical: false, strain: ["fan 78%"])),
      ("pressure critical", .pressure(free: free, critical: true, strain: nil)),
      ("resumed", .resumed(6)),
      ("note", .note("Quit Loom · 1.2 GB · reopens later")),
    ]
    // This Mac's notch (Task 9.2), and the wings as the controller sizes them.
    func metrics(_ state: IslandState) -> IslandController.Metrics {
      .init(
        notchWidth: 185, notchHeight: 32,
        wingWidth: state.wingText.map {
          NotchGeometry.wingWidth(fitting: IslandController.textWidth($0))
        } ?? NotchGeometry.wingWidth)
    }
    for (name, state) in states {
      let size = metrics(state)
      let width = size.notchWidth + 2 * size.wingWidth
      // A menu bar's height of canvas around the island, as at the top of the screen.
      let strip = IslandLayout(state: state, metrics: size, onClick: {})
        .frame(width: width, height: size.notchHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BlitzUI.canvasBackground)
      try await write(
        strip, named: "Island \(name)", in: directory, wait: .seconds(1),
        size: .init(width: 640, height: 56))
    }

  }

  /// N6, N11, N12: the hover usage card under the notch, as the controller sizes it: nothing done
  /// yet, a day's actions with stopped entries, a call with its wings, the Mac struggling during
  /// the notch's flash (the memory line orange, no line of its own), memory critical, the Mac
  /// struggling with sessions waiting, and a note.
  @Test func rendersIslandCardWhenRequested() async throws {
    guard let output = ProcessInfo.processInfo.environment["TAMEBAR_DESIGN_DIR"] else { return }
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let now = Date.now
    func snapshot(_ pressure: MemoryPressureLevel, free: UInt64) -> SystemSnapshot {
      SystemSnapshot(
        .init(
          diskAvailable: 88_000_000_000, diskTotal: 494_000_000_000, ramAvailable: free,
          ramTotal: 36_000_000_000, memoryPressure: pressure, cpuUsage: 0.34,
          thermalStatus: .nominal, updatedAt: now))
    }
    let calm = snapshot(.warning, free: 2_000_000_000)
    let call = IslandState.call(.calendar, paused: 2)
    let struggling = IslandState.pressure(
      free: 1_100_000_000, critical: false, strain: ["fan 78%"])
    let critical = IslandState.pressure(free: 600_000_000, critical: true, strain: nil)
    let note = IslandState.note("Paused 3 idle sessions · 2.4 GB")
    // The wings show the notch's state; the line comes from the menu bar's (none for pressure,
    // which the memory line says).
    var today = UsageActions()
    today.ended = 3
    today.slowed = 2
    today.freedBytes = 4_000_000_000
    let none = CardStrain(struggling: false, signals: [])
    let fan = CardStrain(struggling: true, signals: ["fan 78%"])
    let cases: [(name: String, state: IslandState, content: UsageCardContent)] = [
      (
        "Island card", .hidden,
        .init(snapshot: calm, now: now, strain: none, asks: [.claude, .codex])
      ),
      (
        "Island card today", .hidden,
        .init(
          snapshot: calm, now: now, strain: none, today: today,
          activity: .init(
            stopped: Self.stoppedEntries(now: now),
            slowed: [.init(id: "ai:1", name: "Claude · project A", kind: .session)]),
          asks: [.claude, .codex])
      ),
      (
        "Island card call", call,
        .init(
          snapshot: calm, now: now, line: call.cardLine, strain: none, today: today,
          activity: .init(stopped: Self.stoppedEntries(now: now)), asks: [.claude])
      ),
      (
        "Island card pressure", struggling,
        .init(
          snapshot: snapshot(.warning, free: 1_100_000_000), now: now,
          line: struggling.cardLine, strain: fan, today: today,
          activity: .init(stopped: Self.stoppedEntries(now: now)),
          asks: [.claude, .codex])
      ),
      (
        "Island card critical", critical,
        .init(
          snapshot: snapshot(.critical, free: 600_000_000), now: now, line: critical.cardLine,
          strain: nil, critical: true, today: today,
          activity: .init(stopped: Self.stoppedEntries(now: now)), asks: [.claude, .codex])
      ),
      (
        "Island card waiting", .hidden,
        .init(
          snapshot: snapshot(.warning, free: 900_000_000), now: now, strain: fan, today: today,
          activity: .init(stopped: Self.stoppedEntries(now: now)), asks: [.claude, .codex],
          waiting: [
            .init(
              waitPID: 4250, tool: "claude", project: "dashboard-app",
              started: now.addingTimeInterval(-64)),
            .init(
              waitPID: 4251, tool: "codex", project: "platform",
              started: now.addingTimeInterval(-20)),
          ])
      ),
      (
        "Island card note", note,
        .init(
          snapshot: calm, now: now, line: note.cardLine, strain: none, today: today,
          asks: [.claude, .codex])
      ),
    ]
    for (name, state, content) in cases {
      // This Mac's notch, and the wings as the controller sizes them.
      let metrics = IslandController.Metrics(
        notchWidth: 185, notchHeight: 32,
        wingWidth: state.wingText.map {
          NotchGeometry.wingWidth(fitting: IslandController.textWidth($0))
        } ?? NotchGeometry.wingWidth)
      let notch = CGRect(x: 0, y: 0, width: metrics.notchWidth, height: metrics.notchHeight)
      let width = NotchGeometry.expanded(notch: notch, contentHeight: 0, wing: metrics.wingWidth)
        .width
      let height = NSHostingView(rootView: UsageCardView(content: content).frame(width: width))
        .fittingSize.height
      let size = CGSize(width: width, height: metrics.notchHeight + height)
      let card = IslandCardLayout(
        state: state, metrics: metrics, size: size,
        look: .init(fill: 1, content: 1, radius: 14, live: true)
      ) { UsageCardView(content: content) }
      .frame(width: size.width, height: size.height)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(BlitzUI.canvasBackground)
      try await write(
        card, named: name, in: directory, wait: .seconds(1),
        size: .init(width: max(480, size.width + 40), height: size.height + 40))
    }
  }

  /// N7: the menu-bar item on a menu bar with no notch (the icon alone, pressure, a call, a note),
  /// then the card anchored under it, where `MenuBarCardGeometry` puts it.
  @Test func rendersMenuBarItemWhenRequested() async throws {
    guard let output = ProcessInfo.processInfo.environment["TAMEBAR_DESIGN_DIR"] else { return }
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let call = IslandState.call(.calendar, paused: 2)
    let states: [(name: String, state: IslandState)] = [
      ("Menu bar icon", .hidden),
      ("Menu bar pressure", .pressure(free: 1_100_000_000, critical: false, strain: ["fan 78%"])),
      ("Menu bar critical", .pressure(free: 600_000_000, critical: true, strain: nil)),
      ("Menu bar call", call),
      ("Menu bar note", .note("Paused 3 idle sessions · 2.4 GB · resumes when memory recovers")),
    ]
    for (name, state) in states {
      try await write(
        MenuBarStripRender(
          item: try await MenuBarStripRender.capture(.init(state, colored: true)),
          itemX: 140),
        named: name, in: directory, wait: .seconds(1), size: .init(width: 620, height: 24))
    }

    let now = Date.now
    let snapshot = SystemSnapshot(
      .init(
        diskAvailable: 31_000_000_000, diskTotal: 494_000_000_000, ramAvailable: 6_100_000_000,
        ramTotal: 36_000_000_000, memoryPressure: .normal, cpuUsage: 0.34,
        thermalStatus: .nominal, updatedAt: now))
    var today = UsageActions()
    today.ended = 3
    today.slowed = 2
    today.freedBytes = 4_000_000_000
    let content = UsageCardContent(
      snapshot: snapshot, now: now, line: call.cardLine,
      strain: .init(struggling: false, signals: []), today: today,
      activity: .init(stopped: Self.stoppedEntries(now: now)),
      asks: [.claude, .codex])
    let label = MenuBarItemLabel(call, colored: true)
    // A 900-point screen whose menu bar is 24 points tall, the item 520 points in.
    let screenSize = CGSize(width: 900, height: 440)
    let itemX: CGFloat = 520
    let captured = try await MenuBarStripRender.capture(label)
    let screen = NotchGeometry.Screen(
      frame: CGRect(origin: .zero, size: screenSize), safeTop: 0, leftArea: nil, rightArea: nil)
    let item = CGRect(
      x: itemX, y: screenSize.height - 24, width: captured.light.size.width, height: 24)
    let height = NSHostingView(
      rootView: UsageCardView(content: content).frame(width: NotchGeometry.expandedWidth)
    ).fittingSize.height
    let card = MenuBarCardGeometry.frame(
      item: item, screen: screen, width: NotchGeometry.expandedWidth, contentHeight: height)
    let view = VStack(alignment: .leading, spacing: screenSize.height - 24 - card.maxY) {
      MenuBarStripRender(item: captured, itemX: itemX).frame(height: 24)
      MenuBarCardLayout(
        size: card.size, look: .init(fill: 1, content: 1, radius: 14, live: true)
      ) { UsageCardView(content: content) }
      .frame(width: card.width, height: card.height)
      .padding(.leading, card.minX)
      Spacer(minLength: 0)
    }
    .background(BlitzUI.canvasBackground)
    try await write(
      view, named: "Menu bar card", in: directory, wait: .seconds(1),
      size: .init(width: screenSize.width, height: 24 + card.height + 40))
  }

  /// Q15's mock's kinds, Q20's server and Q21's Codex plugin.
  static func stoppedEntries(now: Date) -> [StoppedEntry] {
    [
      StoppedEntry(
        id: "q", kind: .session, name: "web-frontend", tool: .claudeCode,
        stoppedAt: now - 1_320, state: .paused, reason: .heat, memoryBytes: 1_000_000_000,
        target: .ledger("q")),
      StoppedEntry(
        id: "p", kind: .session, name: "Agent", tool: .claudeCode, stoppedAt: now - 1_140,
        state: .paused, reason: .call, memoryBytes: 600_000_000, target: .ledger("p")),
      StoppedEntry(
        id: "e", kind: .session, name: "Atlas", tool: .claudeCode, stoppedAt: now - 2_000,
        state: .ended, reason: .idle(days: 3), memoryBytes: 2_000_000_000,
        command: "cd '/Users/test/Atlas' && claude --resume 601f93df-0000-4000-8000-000000000001",
        target: .ended("601f93df-0000-4000-8000-000000000001")),
      StoppedEntry(
        id: "a", kind: .app, name: "Docker Desktop", bundleID: "com.docker.docker",
        stoppedAt: now - 60, state: .quit, reason: .byYou, memoryBytes: 9_000_000_000,
        command: "open -a Docker",
        target: .app(
          bundleID: "com.docker.docker", bundleURL: URL(fileURLWithPath: "/Applications/Docker.app")
        )),
      StoppedEntry(
        id: "s", kind: .server, name: "web-frontend :5180", stoppedAt: now - 30,
        state: .ended, reason: .unused(days: 2), memoryBytes: 40_000_000,
        command: "cd '/Users/test/web-frontend/apps/web' && npm run dev -- --port 5180",
        target: .server("s")),
      StoppedEntry(
        id: "c", kind: .codexPlugin, name: "context7", stoppedAt: now - 20, state: .off,
        reason: .unused(days: 30), target: .codexPlugin("server:context7")),
    ]
  }

  /// Ten days of usage, a version marker four days ago: the before and after the card compares.
  static func trendData(now: Date) -> UsageTrendData {
    let calendar = Calendar.autoupdatingCurrent
    var days: [UsageDay] = []
    for offset in 0..<10 {
      guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
      var day = UsageDay(day: UsageCalendar.key(date, calendar))
      let after = offset < 4
      day.awakeSeconds = 9 * 3_600
      day.inUseSeconds = offset == 5 ? 0 : 8 * 3_600
      let share = (after ? 0.17 : 0.35) * (0.7 + 0.6 * Double((offset * 7) % 10) / 10)
      day.warningSeconds = day.inUseSeconds * share * 0.8
      day.criticalSeconds = day.inUseSeconds * share * 0.2
      day.swapPeakBytes = after ? 15_000_000_000 : 24_000_000_000
      days.append(day)
    }
    let marker = UsageMarker(
      at: calendar.date(byAdding: .day, value: -4, to: now) ?? now, kind: .version,
      text: "0.2 · 4f3a2b1", version: "0.2", commit: "4f3a2b1")
    return .init(days: days.reversed(), markers: [marker])
  }

  /// Renders `view` twice, as `<name>-light.png` and `<name>-dark.png`, in the window's appearance.
  private func write(
    _ view: some View, named name: String, in directory: URL, wait: Duration = .seconds(2),
    size: CGSize = .init(width: 1080, height: 760)
  ) async throws {
    for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
      host.frame = NSRect(origin: .zero, size: size)
      let window = NSWindow(
        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.appearance = NSAppearance(named: appearance)
      window.contentView = host
      window.orderFrontRegardless()
      try await Task.sleep(for: wait)
      host.layoutSubtreeIfNeeded()
      let rep = try #require(
        NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
      rep.size = size
      host.cacheDisplay(in: host.bounds, to: rep)
      window.orderOut(nil)
      let data = try #require(rep.representation(using: .png, properties: [:]))
      try data.write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
    }
  }
}

/// A menu bar for the renders: the item as AppKit draws it, then a few neighbours and a clock.
private struct MenuBarStripRender: View {
  /// The item's button, light and dark.
  let item: (light: NSImage, dark: NSImage)
  let itemX: CGFloat
  @Environment(\.colorScheme) private var scheme

  /// The item as the menu bar draws it: a real status item for a moment, set by
  /// `MenuBarItemLabel.apply` in the menu bar's vibrant light or dark look, drawn from its own
  /// backing store, then removed. Only an explicit render run (`TAMEBAR_DESIGN_DIR`) does this.
  @MainActor static func capture(_ label: MenuBarItemLabel) async throws -> (
    light: NSImage, dark: NSImage
  ) {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    defer { NSStatusBar.system.removeStatusItem(item) }
    let button = try #require(item.button)
    label.apply(to: button)
    // Until the menu bar has placed it, its window has no height and nothing draws right.
    try await Task.sleep(for: .seconds(1))
    func draw(_ name: NSAppearance.Name) throws -> NSImage {
      button.appearance = NSAppearance(named: name)
      button.layoutSubtreeIfNeeded()
      let rep = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
      button.cacheDisplay(in: button.bounds, to: rep)
      let image = NSImage(size: button.bounds.size)
      image.addRepresentation(rep)
      return image
    }
    return (try draw(.vibrantLight), try draw(.vibrantDark))
  }

  var body: some View {
    HStack(spacing: 14) {
      Image(nsImage: scheme == .dark ? item.dark : item.light)
      ForEach(["circle.hexagongrid", "power", "sparkle"], id: \.self) { symbol in
        Image(systemName: symbol).font(.system(size: 13))
      }
      Text("Tue 27 Oct 15:09").font(.system(size: 13))
      Spacer(minLength: 0)
    }
    .padding(.leading, itemX)
    .frame(maxWidth: .infinity, alignment: .leading).frame(height: 24)
    .background(Color(nsColor: .underPageBackgroundColor))
    .overlay(alignment: .bottom) { Rectangle().fill(BlitzUI.separator).frame(height: 1) }
    .frame(maxHeight: .infinity, alignment: .top)
  }
}
