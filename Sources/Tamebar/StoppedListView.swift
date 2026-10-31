import SwiftUI

/// The Stopped list (Q15, approved as mocked): everything Tamebar stopped that isn't back, one row
/// each with one button, and Resume all. Since N11 it leads the window's Activity tab, reached from
/// "N stopped ›" on the card.
///
/// ```
/// Stopped · 5                                Resume all
/// ╭──────────────────────────────────────────────────╮
/// │ ⏸ web-frontend             1 GB   [Resume]        │
/// │   paused · call                                   │
/// │ ■ Atlas                    2 GB   [Resume]  ⧉     │
/// │   ended · idle 3d                                 │
/// │ ■ web-frontend :5180     40 MB   [Resume]  ⧉     │
/// │   ended · unused 2d                               │
/// │ ■ context7                        [Undo]          │
/// │   off · unused 30d                                │
/// ╰──────────────────────────────────────────────────╯
/// ⧉ copies the command
/// ```
struct StoppedListView: View {
  let entries: [StoppedEntry]
  /// Rows whose button was clicked and that haven't left yet.
  var busy: Set<String> = []
  var now: Date = .now
  let bringBack: (StoppedEntry) -> Void
  let bringBackAll: () -> Void
  /// The entry whose command was just copied, and when; its ⧉ reads ✓ for 2 s.
  @State private var copied: (id: String, at: Date)?

  /// `copiedID` starts a row in its copied state, for design renders.
  init(
    entries: [StoppedEntry], busy: Set<String> = [], now: Date = .now, copiedID: String? = nil,
    bringBack: @escaping (StoppedEntry) -> Void = { _ in },
    bringBackAll: @escaping () -> Void = {}
  ) {
    self.entries = entries
    self.busy = busy
    self.now = now
    self.bringBack = bringBack
    self.bringBackAll = bringBackAll
    _copied = State(initialValue: copiedID.map { ($0, Date.now) })
  }

  /// Resume all resumes what's paused and reopens apps; ended sessions are resumed one
  /// by one, so it shows only when there is something else.
  private var canBringBackAll: Bool {
    entries.contains { $0.state != .ended && $0.state != .off && !busy.contains($0.id) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      if entries.isEmpty {
        Text("Nothing stopped.").font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
          .padding(.leading, 4)
      } else {
        rows
        if entries.contains(where: { $0.command != nil }) {
          Text(StoppedRows.copyCaption).font(BlitzType.caption)
            .foregroundStyle(BlitzUI.secondaryText).padding(.leading, 4)
        }
      }
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      Text(StoppedRows.header(count: entries.count)).font(BlitzType.section)
        .foregroundStyle(BlitzUI.primaryText)
      Spacer(minLength: 8)
      if canBringBackAll {
        Button("Resume all", action: bringBackAll)
          .blitzButton(.secondary).controlSize(.small).fixedSize()
          .help(
            "Resumes the paused sessions and reopens the apps. Ended sessions resume one by one.")
      }
    }
  }

  private var rows: some View {
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
      Image(systemName: entry.state == .paused ? "pause.fill" : "stop.fill")
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
      if let title = entry.actionTitle {
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
