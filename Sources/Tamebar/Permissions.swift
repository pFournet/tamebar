import AppKit
import SwiftUI

enum SystemSettingsPane: String {
  case calendars = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"

  @MainActor func open() {
    if let url = URL(string: rawValue) { NSWorkspace.shared.open(url) }
  }
}

/// The one permission Tamebar asks for since N11: Calendars, for M1's meetings. Accessibility
/// (Revive apps) and Full Disk Access (Storage) went with their pages.
@MainActor final class PermissionsModel: ObservableObject {
  /// Full calendar access. Reading the status never prompts.
  @Published private(set) var calendars: Bool
  private let calendar: CalendarMeetings
  private let calendarAuthorized: @Sendable () -> Bool
  private let openCalendarsPane: @MainActor () -> Void

  /// A test passes its own calendar, status and pane, so it never prompts or opens Settings.
  init(
    calendar: CalendarMeetings = .init(),
    calendarAuthorized: @escaping @Sendable () -> Bool = { CalendarMeetings.isAuthorized },
    openCalendarsPane: @escaping @MainActor () -> Void = { SystemSettingsPane.calendars.open() }
  ) {
    self.calendar = calendar
    self.calendarAuthorized = calendarAuthorized
    self.openCalendarsPane = openCalendarsPane
    calendars = calendarAuthorized()
  }

  func refresh() {
    let calendars = calendarAuthorized()
    if calendars != self.calendars { self.calendars = calendars }
  }

  /// The Calendars row's Allow…: the system prompt the first time; once denied, it answers no
  /// at once, so the Privacy pane opens instead.
  func requestCalendars() async {
    let granted = await calendar.requestAccess()
    calendars = granted
    if !granted { openCalendarsPane() }
  }
}

/// Settings → Meetings: the Calendars permission, then Google Calendar (M1). Calendars shows only
/// in an installed build: a debug run's bare binary has no usage string for the prompt, and no
/// meeting reads it. With neither row, no section.
struct MeetingsSection: View {
  @ObservedObject var permissions: PermissionsModel
  @StateObject private var google = GoogleCalendarModel()
  var installed = AppBrand.isInstalledBuild

  var body: some View {
    if installed || google.row != .hidden {
      VStack(alignment: .leading, spacing: 10) {
        BlitzSectionHeader(title: "Meetings", count: nil) { EmptyView() }
        VStack(spacing: 0) {
          if installed {
            CalendarsPermissionRow(granted: permissions.calendars) {
              Task { await permissions.requestCalendars() }
            }
          }
          if installed, google.row != .hidden { BlitzRowDivider(leading: 56) }
          if google.row != .hidden {
            GoogleCalendarRow(
              row: google.row, connect: google.connect, cancel: google.cancel,
              disconnect: google.disconnect)
          }
        }.blitzTable()
      }
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in permissions.refresh() }
    }
  }
}

/// The Calendars row: what it's for, and Allow… until it is allowed.
struct CalendarsPermissionRow: View {
  let granted: Bool
  var allow: () -> Void = {}

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "calendar").font(.system(size: 14))
        .foregroundStyle(BlitzUI.secondaryText).frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text("Calendars").font(BlitzType.rowTitle)
        Text("Quiet AI agents 2 minutes before a meeting. Nothing leaves your Mac.")
          .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      }
      Spacer(minLength: 12)
      if granted {
        Text("Allowed").font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      } else {
        Button("Allow…", action: allow).blitzButton(.secondary).controlSize(.small)
      }
    }.blitzRow()
  }
}
