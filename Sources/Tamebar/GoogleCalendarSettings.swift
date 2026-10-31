import SwiftUI

/// The Settings row's state, from the app's Google source (Task 6.5).
@MainActor final class GoogleCalendarModel: ObservableObject {
  enum Row: Equatable {
    /// Not the shipped app: no Google source, and no row.
    case hidden
    /// The shipped app built without a client id.
    case notConfigured
    case status(GoogleCalendarMeetings.Status)
  }

  @Published private(set) var row: Row
  private let source: GoogleCalendarMeetings?
  private var connecting: Task<Void, Never>?

  init(
    source: GoogleCalendarMeetings? = GoogleCalendarMeetings.shared,
    shipped: Bool = AppBrand.isShippedApp
  ) {
    self.source = source
    row = source == nil ? (shipped ? .notConfigured : .hidden) : .status(.disconnected)
    guard let source else { return }
    let update: @Sendable (GoogleCalendarMeetings.Status) -> Void = { [weak self] status in
      Task { @MainActor in self?.row = .status(status) }
    }
    Task { await source.observe(update) }
  }

  func connect() {
    guard let source, connecting == nil else { return }
    connecting = Task {
      await source.connect()
      connecting = nil
    }
  }

  /// Stops waiting for the browser.
  func cancel() { connecting?.cancel() }

  func disconnect() {
    guard let source else { return }
    Task { await source.disconnect() }
  }
}

/// Settings → Meetings: the Google Calendar row, laid out like the Calendars row: symbol, title,
/// one caption line, actions. Hidden outside the shipped app (`MeetingsSection`).
struct GoogleCalendarRow: View {
  let row: GoogleCalendarModel.Row
  var connect: () -> Void = {}
  var cancel: () -> Void = {}
  var disconnect: () -> Void = {}

  static func caption(_ row: GoogleCalendarModel.Row) -> String {
    switch row {
    case .hidden, .notConfigured: "Not configured in this build."
    case .status(.disconnected):
      "Quiet AI agents before meetings in a Google account Calendar doesn't sync. Read-only."
    case .status(.connecting): "Finish signing in in your browser."
    case .status(.connected): "Connected, read-only. Checked every 5 minutes."
    case .status(.signInAgain): "Google ended the sign-in. Test sign-ins last 7 days."
    case .status(.failed(let reason)): reason
    }
  }

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "calendar.badge.clock").font(.system(size: 14))
        .foregroundStyle(BlitzUI.secondaryText).frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text("Google Calendar").font(BlitzType.rowTitle)
          if row == .status(.signInAgain) {
            BlitzStatusBadge(title: "Sign in again", tone: .warning)
          }
        }
        Text(Self.caption(row)).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      }
      Spacer(minLength: 12)
      actions
    }.blitzRow()
  }

  @ViewBuilder private var actions: some View {
    switch row {
    case .hidden, .notConfigured: EmptyView()
    case .status(.connecting):
      ProgressView().controlSize(.small)
      Button("Cancel", action: cancel).blitzButton(.quiet).controlSize(.small)
    case .status(.connected):
      Button("Disconnect", action: disconnect).blitzButton(.secondary).controlSize(.small)
    case .status(.signInAgain):
      Button("Sign in…", action: connect).blitzButton(.secondary).controlSize(.small)
    case .status(.disconnected), .status(.failed):
      Button("Connect…", action: connect).blitzButton(.secondary).controlSize(.small)
    }
  }
}
