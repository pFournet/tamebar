import SwiftUI

/// Live Activity: slowed and paused work restores automatically; quit apps and off plugins can
/// be brought back if needed. Ended sessions stay in the CLI recovery log, outside this panel.
struct CurrentActivityView: View {
  let entries: [StoppedEntry]
  var slowed: [CurrentActivity.Slowed] = []
  /// Rows whose button was clicked and that haven't left yet.
  var busy: Set<String> = []
  var now: Date = .now
  let bringBack: (StoppedEntry) -> Void
  let bringBackAll: () -> Void
  /// The entry whose command was just copied, and when; its ⧉ reads ✓ for 2 s.
  @State private var copied: (id: String, at: Date)?

  /// `copiedID` starts a row in its copied state, for design renders.
  init(
    entries: [StoppedEntry], slowed: [CurrentActivity.Slowed] = [],
    busy: Set<String> = [], now: Date = .now, copiedID: String? = nil,
    bringBack: @escaping (StoppedEntry) -> Void = { _ in },
    bringBackAll: @escaping () -> Void = {}
  ) {
    self.entries = entries
    self.slowed = slowed
    self.busy = busy
    self.now = now
    self.bringBack = bringBack
    self.bringBackAll = bringBackAll
    _copied = State(initialValue: copiedID.map { ($0, Date.now) })
  }

  private var activity: CurrentActivity { .init(stopped: entries, slowed: slowed) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Only when empty: above Resume and Reopen buttons it would contradict them.
      if activity.slowed.isEmpty && activity.paused.isEmpty && activity.quitApps.isEmpty
        && activity.pluginsOff.isEmpty
      {
        Text("Nothing needs your action").font(BlitzType.section)
          .foregroundStyle(BlitzUI.primaryText)
        Text("Tamebar is not slowing or pausing anything now.")
          .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      }
      if !activity.slowed.isEmpty {
        sectionTitle("Slowed now", detail: "Returns to normal automatically")
        slowedRows
      }
      if !activity.paused.isEmpty {
        HStack {
          sectionTitle("Paused now", detail: "Resumes automatically")
          Spacer(minLength: 8)
          if activity.paused.count > 1 {
            Button("Resume all", action: bringBackAll)
              .blitzButton(.secondary).controlSize(.small).fixedSize()
          }
        }
        rows(activity.paused)
      }
      if !activity.quitApps.isEmpty {
        sectionTitle("Apps quit · optional", detail: "Reopen only if needed")
        rows(activity.quitApps)
      }
      if !activity.pluginsOff.isEmpty {
        sectionTitle("Codex plugins off · optional", detail: "Turn on only if needed")
        rows(activity.pluginsOff)
      }
    }
  }

  private func sectionTitle(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(BlitzType.section).foregroundStyle(BlitzUI.primaryText)
      Text(detail).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
    }
  }

  private var slowedRows: some View {
    ScrollView {
      VStack(spacing: 0) {
        ForEach(activity.slowed) { item in
          HStack(spacing: 10) {
            Image(systemName: "tortoise.fill").font(.system(size: 11))
              .foregroundStyle(BlitzUI.secondaryText).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
              Text(item.name).font(BlitzType.body).foregroundStyle(BlitzUI.primaryText)
                .lineLimit(1).truncationMode(.middle)
              Text(item.kind.rawValue.capitalized + " · slowed now")
                .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
            }
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 10).frame(height: Self.rowHeight)
          if item.id != activity.slowed.last?.id { BlitzRowDivider(leading: 34) }
        }
      }
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(maxHeight: Self.listHeight(activity.slowed.count))
    .blitzCard(padding: 0)
  }

  private func rows(_ entries: [StoppedEntry]) -> some View {
    ScrollView {
      VStack(spacing: 0) {
        ForEach(entries) { entry in
          row(entry)
          if entry.id != entries.last?.id { BlitzRowDivider(leading: 34) }
        }
      }
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(maxHeight: Self.listHeight(entries.count))
    .blitzCard(padding: 0)
  }

  static let rowHeight: CGFloat = 48
  /// Every row up to eight, then it scrolls.
  static func listHeight(_ count: Int) -> CGFloat { rowHeight * CGFloat(min(max(count, 1), 8)) }

  private func row(_ entry: StoppedEntry) -> some View {
    HStack(spacing: 10) {
      Image(
        systemName: entry.state == .paused
          ? "pause.fill"
          : entry.state == .off
            ? "puzzlepiece.extension.fill" : "app.fill"
      )
      .font(.system(size: 9, weight: .bold)).foregroundStyle(BlitzUI.secondaryText)
      .frame(width: 14).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.name).font(BlitzType.body).foregroundStyle(BlitzUI.primaryText)
          .lineLimit(1).truncationMode(.middle)
        Text(entry.trayDetail(now: now)).font(BlitzType.caption)
          .foregroundStyle(BlitzUI.secondaryText).lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .help(entry.command ?? entry.name)
      Text(entry.memoryBytes.map(ByteText.compact) ?? "")
        .font(BlitzType.numeric).foregroundStyle(BlitzUI.supportingText).lineLimit(1)
        .fixedSize()
      if let title = entry.state == .paused ? "Resume now" : entry.actionTitle {
        let isBusy = busy.contains(entry.id)
        Button {
          bringBack(entry)
        } label: {
          // The widest title keeps every row's button one size.
          ZStack {
            Text("Run now").hidden()
            if isBusy { ProgressView().controlSize(.mini) } else { Text(title) }
          }
        }
        .blitzButton(.secondary).controlSize(.mini).fixedSize().disabled(isBusy)
        .accessibilityLabel("\(title) \(entry.name)")
      }
      copyButton(entry)
    }
    .padding(.leading, 10).padding(.trailing, 8).frame(height: Self.rowHeight)
  }

  /// ⧉ for an entry with a command; the same width without, so the buttons line up.
  @ViewBuilder private func copyButton(_ entry: StoppedEntry) -> some View {
    if let command = entry.command {
      let isCopied = copied?.id == entry.id
      Button {
        copy(command, for: entry.id)
      } label: {
        Image(systemName: isCopied ? "checkmark" : "square.on.square")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(isCopied ? BlitzUI.primaryText : BlitzUI.secondaryText)
          .frame(width: 22, height: 22).contentShape(Rectangle())
      }
      .buttonStyle(BlitzRowButtonStyle(radius: 5))
      .help(isCopied ? "Copied" : "Copy the command: \(command)")
      .accessibilityLabel("Copy the command for \(entry.name)")
    } else {
      Color.clear.frame(width: 22, height: 22)
    }
  }

  private func copy(_ command: String, for id: String) {
    Pasteboard.copy(command)
    let at = Date.now
    copied = (id, at)
    Task {
      try? await Task.sleep(for: .seconds(2))
      if copied?.id == id, copied?.at == at { copied = nil }
    }
  }
}
