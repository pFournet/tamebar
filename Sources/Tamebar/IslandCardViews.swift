import SwiftUI

/// The hover usage card's views (N6, N11). `IslandCardController` owns the window; these only
/// draw. All of it is the island's black and white (`notchFill`, `onNotch`), with the panel's
/// divider and no accent fill.

/// The approved layout (N11): the event going on, the memory and strain line and what Tamebar did
/// today, the sessions waiting for memory when any, current Activity links, then Ask Claude / Ask Codex and
/// Open ›.
struct UsageCardView: View {
  let content: UsageCardContent
  /// Open ›: the window; the renders leave it empty.
  var openApp: @MainActor () -> Void = {}
  /// A current Activity line's action: the window on Activity.
  var openStopped: @MainActor () -> Void = {}
  /// Ask Claude / Ask Codex's action (N8): Terminal running the tool, then the card closes.
  var ask: @MainActor (AskAgent) -> Void = { _ in }
  /// Start now on a session waiting for memory (Q19), by its `tamebar wait`'s pid.
  var startNow: @MainActor (Int32) -> Void = { _ in }

  static let openTitle = "Open"
  /// The last row's height, Ask and Open: the card's last points, where the row's buttons take the
  /// click instead of the card (`IslandCardMotion.actionRow`).
  nonisolated static let actionRowHeight: CGFloat = 40
  /// Each current Activity line's height, right above the last row's divider.
  nonisolated static let activityRowHeight: CGFloat = 30
  /// The "Waiting for memory" block (Q19): its title, one row per session, and its last line,
  /// right above the Activity links (`IslandCardMotion.waitingBlock`).
  nonisolated static let waitingTitleHeight: CGFloat = 26
  nonisolated static let waitingRowHeight: CGFloat = 28
  nonisolated static let waitingFooterHeight: CGFloat = 26

  nonisolated static func waitingHeight(_ rows: Int) -> CGFloat {
    waitingTitleHeight + CGFloat(rows) * waitingRowHeight + waitingFooterHeight
  }

  var body: some View {
    VStack(spacing: 0) {
      usage
      if !content.waiting.isEmpty {
        UsageCardWaitingBlock(rows: content.waiting, action: startNow)
        Rectangle().fill(BlitzUI.separator).frame(height: 1)
      }
      ForEach(content.activityLines, id: \.self) { line in
        UsageCardActivityRow(text: line, action: openStopped)
        Rectangle().fill(BlitzUI.separator).frame(height: 1)
      }
      UsageCardActionRow(agents: content.asks, ask: ask, open: openApp)
    }
    .frame(maxWidth: .infinity)
  }

  private var usage: some View {
    VStack(alignment: .leading, spacing: 0) {
      UsageCardStatusLine(status: content.status).padding(.top, 8)
      if let line = content.line {
        IslandCardStateLine(line: line).padding(.top, 8).padding(.bottom, 10)
        Rectangle().fill(BlitzUI.separator).frame(height: 1)
      }
      VStack(alignment: .leading, spacing: 4) {
        UsageCardMemoryLine(text: content.memory, tone: content.memoryTone)
        Text(content.today).font(BlitzType.caption).monospacedDigit()
          .foregroundStyle(BlitzUI.secondaryText).lineLimit(1).truncationMode(.tail)
      }
      .padding(.top, content.line == nil ? 6 : 10).padding(.bottom, 10)
      Rectangle().fill(BlitzUI.separator).frame(height: 1)
    }
    .padding(.horizontal, NotchGeometry.wingPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

/// The card's top line (N14): a green dot and "Watching your Mac" while the scan is current, a
/// gray dot and "Not updating · last check 2m ago" once it isn't.
struct UsageCardStatusLine: View {
  let status: UsageCardStatus

  var body: some View {
    HStack(spacing: 6) {
      BlitzStatusDot(tone: status.live ? .good : .muted, diameter: 7)
      Text(status.text).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
        .lineLimit(1).truncationMode(.tail)
    }
  }
}

/// The memory line (N11, N12): white while all is well; under real pressure it turns orange
/// (red at critical) with the wings' ⚠, and may take a second line for its reasons.
struct UsageCardMemoryLine: View {
  let text: String
  let tone: MetricTone

  var body: some View {
    if tone.isAlert {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill").font(
          .system(size: 12, weight: .semibold)
        )
        .accessibilityHidden(true)
        Text(text).font(BlitzType.label).monospacedDigit().lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
      .foregroundStyle(tone.color)
    } else {
      Text(text).font(BlitzType.label).monospacedDigit()
        .foregroundStyle(BlitzUI.onNotch).lineLimit(1).minimumScaleFactor(0.8)
    }
  }
}

/// The card's last row (N8, N11): Ask Claude and Ask Codex, small secondary buttons from the
/// card's left text edge, one per installed tool, each opening Terminal running its tool with the
/// pressure prompt; then, on the right, a quiet "Open ›" opening the window.
struct UsageCardActionRow: View {
  let agents: [AskAgent]
  let ask: @MainActor (AskAgent) -> Void
  let open: @MainActor () -> Void

  var body: some View {
    HStack(spacing: 8) {
      ForEach(agents) { agent in
        Button(agent.title) { ask(agent) }
          .blitzButton(.secondary).controlSize(.small).fixedSize()
          .help("Open Terminal running \(agent.executable) to look at what to end or quit")
      }
      Spacer(minLength: 8)
      Button(action: open) {
        HStack(spacing: 4) {
          Text(UsageCardView.openTitle).foregroundStyle(BlitzUI.onNotch)
          Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(BlitzUI.secondaryText).accessibilityHidden(true)
        }
        .font(.system(size: BlitzControlMetrics.fontSize(.regular), weight: .semibold))
        .lineLimit(1).padding(.horizontal, 8).frame(height: 26).contentShape(Rectangle())
      }
      .buttonStyle(BlitzRowButtonStyle(radius: 6))
      .help("Open \(AppBrand.name)'s window")
      .accessibilityLabel("Open \(AppBrand.name)")
    }
    .padding(.leading, NotchGeometry.wingPadding).padding(.trailing, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: UsageCardView.actionRowHeight)
  }
}

/// "Waiting for memory" (Q19, approved as mocked): the new sessions held at start while the Mac
/// is struggling, each with how long it has waited and a small Start now, then the line saying
/// they start on their own. Shown only while something waits; the notch doesn't change.
struct UsageCardWaitingBlock: View {
  let rows: [UsageCardContent.Waiting]
  let action: @MainActor (Int32) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(UsageCardContent.waitingTitle).font(BlitzType.captionEmphasis)
        .foregroundStyle(BlitzUI.onNotch)
        .frame(height: UsageCardView.waitingTitleHeight, alignment: .bottom)
      ForEach(rows) { row in
        HStack(spacing: 8) {
          Text(row.label).font(BlitzType.body).foregroundStyle(BlitzUI.onNotch)
            .lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 8)
          Text(row.waited).font(BlitzType.caption).monospacedDigit()
            .foregroundStyle(BlitzUI.secondaryText).lineLimit(1)
          Button("Start now") { action(row.id) }
            .blitzButton(.secondary).controlSize(.small).fixedSize()
            .help("Start \(row.label) now, without waiting for memory")
        }
        .frame(height: UsageCardView.waitingRowHeight)
      }
      Text(UsageCardContent.waitingFooter).font(BlitzType.caption)
        .foregroundStyle(BlitzUI.secondaryText).lineLimit(1)
        .frame(height: UsageCardView.waitingFooterHeight, alignment: .center)
    }
    .padding(.horizontal, NotchGeometry.wingPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(height: UsageCardView.waitingHeight(rows.count), alignment: .top)
  }
}

/// A live Activity status, linking to the details in the window.
struct UsageCardActivityRow: View {
  let text: String
  let action: @MainActor () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text(text).font(BlitzType.label).monospacedDigit().foregroundStyle(BlitzUI.onNotch)
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
          .foregroundStyle(BlitzUI.secondaryText).accessibilityHidden(true)
      }
      .lineLimit(1)
      .padding(.horizontal, NotchGeometry.wingPadding)
      .frame(maxWidth: .infinity).frame(height: UsageCardView.activityRowHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(BlitzRowButtonStyle())
    .accessibilityLabel("\(text), show Activity")
  }
}

/// The event going on, as the wings show it: their symbol, in their tone only where they color
/// it (warning, critical, good), and the line in white.
struct IslandCardStateLine: View {
  let line: IslandCardLine

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: line.symbol).font(.system(size: 12, weight: .semibold))
        .foregroundStyle(line.tone == .neutral ? BlitzUI.onNotch : line.tone.color)
        .accessibilityHidden(true)
      Text(line.text).font(BlitzType.label).monospacedDigit().foregroundStyle(BlitzUI.onNotch)
        .lineLimit(1).truncationMode(.tail)
    }
  }
}

/// The card over the models: values refresh as the monitor and the process scan publish, at
/// their own cadence; the card adds no scanning.
struct UsageCardLive: View {
  /// For the state line: the island's state, the one the wings come from.
  @ObservedObject var island: IslandController
  @ObservedObject var monitor: SystemMonitor
  @ObservedObject var processes: DevProcessModel
  /// Open ›: the notch card's, unless the menu-bar item's card gives its own (the same route,
  /// closing that card).
  var openApp: (@MainActor () -> Void)? = nil
  /// Current Activity links' action: the notch card's, unless the menu-bar item's card gives
  /// its own.
  var openStopped: (@MainActor () -> Void)? = nil
  /// Ask Claude / Ask Codex: the notch card's, unless the menu-bar item's card gives its own.
  var ask: (@MainActor (AskAgent) -> Void)? = nil
  /// The installed tools, for the Ask buttons.
  @ObservedObject var agents: AskAgents

  init(
    island: IslandController, monitor: SystemMonitor, processes: DevProcessModel,
    openApp: (@MainActor () -> Void)? = nil, openStopped: (@MainActor () -> Void)? = nil,
    ask: (@MainActor (AskAgent) -> Void)? = nil
  ) {
    self.island = island
    self.monitor = monitor
    self.processes = processes
    self.openApp = openApp
    self.openStopped = openStopped
    self.ask = ask
    agents = island.agents
  }

  var body: some View {
    // Ticks on its own so a stalled scan turns the status gray without any other publish.
    TimelineView(.periodic(from: .now, by: 10)) { context in
      card(now: context.date)
    }
  }

  private func card(now: Date) -> some View {
    UsageCardView(
      content: .init(
        snapshot: monitor.snapshot, now: now,
        status: .init(scannedAt: processes.scannedAt, now: now), line: island.card.cardLine,
        strain: processes.strain, critical: processes.pressure.memoryRisk >= .critical,
        today: processes.usageTrend.actions(on: now),
        activity: processes.currentActivity, asks: agents.installed,
        waiting: processes.waitingStarts),
      openApp: openApp ?? island.card.openApp,
      openStopped: openStopped ?? island.card.openStopped,
      ask: ask ?? island.card.ask,
      startNow: { [processes] pid in
        if let waiting = processes.waitingStarts.first(where: { $0.waitPID == pid }) {
          processes.startNow(waiting)
        }
      })
  }
}

/// The card's shape: the island's black strip with the wings as they show (so the card covers
/// them with the same drawing), the content below it, all at the card's own size, centred and
/// clipped by the window as it grows out of the notch.
struct IslandCardLayout<Content: View>: View {
  let state: IslandState
  let metrics: IslandController.Metrics
  let size: CGSize
  let look: IslandCardController.Look
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(spacing: 0) {
      IslandWings(
        text: state.wingText, notchWidth: metrics.notchWidth, wingWidth: metrics.wingWidth,
        height: metrics.notchHeight
      )
      .frame(maxWidth: .infinity).frame(height: metrics.notchHeight)
      content().fixedSize(horizontal: false, vertical: true).opacity(look.content)
    }
    .frame(width: size.width, height: size.height, alignment: .top)
    .background(BlitzUI.notchFill)
    .environment(\.colorScheme, .dark)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .clipShape(IslandShape(radius: look.radius))
    .opacity(look.fill)
  }
}

/// What the card's window holds, from the two controllers. The live content is there only while
/// the card shows, so a resting hover area never redraws on a scan.
struct IslandCardRoot: View {
  @ObservedObject var island: IslandController
  @ObservedObject var card: IslandCardController

  var body: some View {
    IslandCardLayout(
      state: island.state, metrics: island.metrics, size: card.size, look: card.look
    ) {
      if card.look.live {
        UsageCardLive(island: island, monitor: island.monitor, processes: island.processes)
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: { height in
            Task { @MainActor in card.contentHeight(height) }
          }
      }
    }
  }
}
