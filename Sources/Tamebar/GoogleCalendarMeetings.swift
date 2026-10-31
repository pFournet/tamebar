import AppKit
import Foundation

/// Google Calendar's `events.list` answer as meetings (M1). Pure: the same rules as EventKit's
/// (`MeetingRules.qualifies`, `hasVideoLink`), read from Google's fields.
enum GoogleCalendarParsing {
  static func events(_ data: Data) -> [MeetingEvent] {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let items = root["items"] as? [[String: Any]]
    else { return [] }
    return items.compactMap(meeting)
  }

  /// The meeting an event is, if it qualifies. Attendees other than the user count; with none,
  /// a video link in `hangoutLink`, the location or the description does. Its id is the
  /// `iCalUID`, which EventKit's `calendarItemExternalIdentifier` shares for the same event.
  static func meeting(_ item: [String: Any]) -> MeetingEvent? {
    let start = item["start"] as? [String: Any]
    let end = item["end"] as? [String: Any]
    let attendees = item["attendees"] as? [[String: Any]] ?? []
    func isSelf(_ attendee: [String: Any]) -> Bool { attendee["self"] as? Bool == true }
    let text = ["hangoutLink", "location", "description"].compactMap { item[$0] as? String }
    let candidate = MeetingRules.Candidate(
      otherAttendees: attendees.filter { !isSelf($0) }.count,
      hasVideoLink: MeetingRules.hasVideoLink(text.joined(separator: " ")),
      allDay: start?["dateTime"] == nil,
      free: item["transparency"] as? String == "transparent",
      declined: attendees.first(where: isSelf)?["responseStatus"] as? String == "declined",
      canceled: item["status"] as? String == "cancelled")
    guard MeetingRules.qualifies(candidate), let from = date(start), let to = date(end) else {
      return nil
    }
    let id =
      item["iCalUID"] as? String ?? item["id"] as? String
      ?? "google:\(from.timeIntervalSince1970)-\(to.timeIntervalSince1970)"
    return MeetingEvent(id: id, start: from, end: to)
  }

  /// `dateTime` (RFC 3339), or an all-day event's `date`.
  static func date(_ value: [String: Any]?) -> Date? {
    let format = ISO8601DateFormatter()
    if let dateTime = value?["dateTime"] as? String {
      format.formatOptions = [.withInternetDateTime]
      if let date = format.date(from: dateTime) { return date }
      format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return format.date(from: dateTime)
    }
    guard let day = value?["date"] as? String else { return nil }
    format.formatOptions = [.withFullDate]
    return format.date(from: day)
  }
}

extension MeetingEvent {
  /// EventKit's meetings, then Google's that EventKit doesn't already have. The same event
  /// shares its id (the iCalUID) and its start; a recurring event's occurrences share the id.
  static func merged(local: [MeetingEvent], google: [MeetingEvent]) -> [MeetingEvent] {
    local
      + google.filter { event in !local.contains { $0.id == event.id && $0.start == event.start } }
  }
}

/// Meetings from a Google account's primary calendar, read-only (M1, Task 6.5), for an account
/// Calendar.app doesn't sync. Only the shipped app built with a client id has one (`launch`).
///
/// A read never waits for the network: `events(around:)` answers with the last result and starts
/// a fetch when one is due, at most every `pollInterval`, at once after launch, a sign-in or a
/// wake. A failed fetch keeps the last result and is tried again after `retryDelay` (30 s, then
/// 60 s, up to `pollInterval`); `invalid_grant` drops the token and asks to sign in again.
///
/// Launch only checks that the Keychain item exists. Its data is read on the actor, by a fetch
/// or a disconnect, never on the main thread.
actor GoogleCalendarMeetings {
  static let pollInterval: TimeInterval = 300
  static let firstRetry: TimeInterval = 30
  static let keychainService = "com.tamebar.Tamebar.google"
  static let clientIDKey = "TamebarGoogleClientID"
  static let clientSecretKey = "TamebarGoogleClientSecret"

  enum Status: Equatable, Sendable {
    case disconnected, connecting, connected
    /// Google refused the refresh token (`invalid_grant`); it was dropped.
    case signInAgain
    /// The last sign-in didn't finish, and why.
    case failed(String)
  }

  /// The app's source: nil outside the shipped app, or in a build without a client id.
  static let shared: GoogleCalendarMeetings? = launch()

  /// The shipped app with `TamebarGoogleClientID` in its Info.plist gets a source; tests, debug
  /// runs and the e2e build never do, so they never reach Google or the Keychain.
  static func launch(
    shipped: Bool = AppBrand.isShippedApp, info: [String: Any] = Bundle.main.infoDictionary ?? [:],
    make: (GoogleOAuth.Client) -> GoogleCalendarMeetings = GoogleCalendarMeetings.live
  ) -> GoogleCalendarMeetings? {
    func value(_ key: String) -> String? {
      (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    guard shipped, let id = value(clientIDKey) else { return nil }
    return make(.init(id: id, secret: value(clientSecretKey)))
  }

  /// The real network, Keychain and browser, and a fetch on wake.
  static func live(_ client: GoogleOAuth.Client) -> GoogleCalendarMeetings {
    let meetings = GoogleCalendarMeetings(
      client: client, http: URLSessionGoogleHTTP(),
      tokens: KeychainItem(service: keychainService, account: "refresh-token"),
      authorizer: LoopbackAuthorizer())
    _ = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
    ) { _ in Task { await meetings.wake() } }
    return meetings
  }

  let client: GoogleOAuth.Client
  private let http: any GoogleHTTP
  private let tokens: any SecretStore
  private let authorizer: any GoogleAuthorizer
  private(set) var status: Status
  private var cached: [MeetingEvent] = []
  /// When the next fetch is due; nil fetches on the next read. `distantFuture` while one is in
  /// flight, so a wake meanwhile (nil) survives its end.
  private var dueAt: Date?
  /// When the last fetch started, to spot a clock set back.
  private var attemptedAt: Date?
  /// Failed fetches in a row, for the retry delay.
  private var failures = 0
  /// The generation of the fetch in flight, if any. Only that fetch clears it: one from before a
  /// sign-out finishing late leaves a newer fetch's in place.
  private var fetching: Int?
  private var access: (token: String, expires: Date)?
  /// Bumped by a sign-in, a sign-out and `invalid_grant`: an answer from before is dropped.
  private var generation = 0
  private var observer: (@Sendable (Status) -> Void)?

  init(
    client: GoogleOAuth.Client, http: any GoogleHTTP, tokens: any SecretStore,
    authorizer: any GoogleAuthorizer
  ) {
    self.client = client
    self.http = http
    self.tokens = tokens
    self.authorizer = authorizer
    status = tokens.exists() ? .connected : .disconnected
  }

  /// Called with the status now and on every change, for the Settings row.
  func observe(_ observer: @escaping @Sendable (Status) -> Void) {
    self.observer = observer
    observer(status)
  }

  /// The last result. Starts a fetch when one is due, without waiting for it.
  func events(around now: Date) -> [MeetingEvent] {
    if isDue(now) {
      let session = begin(now)
      Task { await fetch(now: now, session: session) }
    }
    return cached
  }

  /// A fetch when one is due, waited for.
  func refreshIfDue(now: Date) async {
    guard isDue(now) else { return }
    await fetch(now: now, session: begin(now))
  }

  /// The Mac woke: fetch on the next read.
  func wake() { dueAt = nil }

  /// How long after the `failures`-th failure in a row the next try comes: 30 s, 60 s, and so
  /// on, never more than `pollInterval`.
  static func retryDelay(failures: Int) -> TimeInterval {
    guard failures > 0 else { return pollInterval }
    return min(firstRetry * pow(2, Double(min(failures, 16) - 1)), pollInterval)
  }

  /// The sign-in: the browser, then the code for tokens. Cancelling the calling task ends the
  /// wait for the browser.
  func connect() async {
    guard status != .connecting else { return }
    let before = status
    generation += 1
    let session = generation
    set(.connecting)
    let verifier = GoogleOAuth.randomToken()
    let state = GoogleOAuth.randomToken(bytes: 16)
    let challenge = GoogleOAuth.challenge(for: verifier)
    let client = client
    do {
      let callback = try await authorizer.authorize(state: state) {
        GoogleOAuth.authorizationURL(
          client: client, redirectURI: $0, challenge: challenge, state: state)
      }
      guard session == generation else { return }
      let code: String
      switch GoogleOAuth.code(fromCallback: callback.target, state: state) {
      case .success(let value): code = value
      case .failure(.stateMismatch):
        return set(.failed("The browser's answer didn't match this sign-in. Try again."))
      case .failure(.denied): return set(.failed("Google didn't give access."))
      case .failure(.noCode): return set(.failed("Google didn't finish the sign-in. Try again."))
      }
      let answer = try await http.send(
        GoogleOAuth.tokenRequest(
          code: code, verifier: verifier, redirectURI: callback.redirectURI, client: client))
      guard session == generation else { return }
      guard case .tokens(let token, let expiresIn, let refresh?) = GoogleOAuth.tokenResult(answer)
      else { return set(.failed("Google didn't finish the sign-in. Try again.")) }
      guard tokens.write(refresh) else {
        return set(.failed("The sign-in couldn't be saved to the Keychain."))
      }
      access = (token, Date.now.addingTimeInterval(expiresIn - 60))
      cached = []
      dueAt = nil
      failures = 0
      set(.connected)
    } catch {
      guard session == generation else { return }
      switch error {
      case is CancellationError, LoopbackAuthorizer.Failure.cancelled: set(before)
      case LoopbackAuthorizer.Failure.timedOut: set(.failed("The sign-in timed out. Try again."))
      default: set(.failed("Google couldn't be reached. Try again."))
      }
    }
  }

  /// Forgets the account: the token, the events, and the grant at Google (best effort).
  func disconnect() {
    generation += 1
    let refresh = tokens.read()
    signOut(.disconnected)
    if let refresh {
      let http = http
      Task.detached { _ = try? await http.send(GoogleOAuth.revokeRequest(token: refresh)) }
    }
  }

  private func isDue(_ now: Date) -> Bool {
    guard status == .connected, fetching == nil else { return false }
    guard let dueAt, let attemptedAt else { return true }
    return now >= dueAt || now < attemptedAt
  }

  /// Marks a fetch in flight, and returns its generation.
  private func begin(_ now: Date) -> Int {
    fetching = generation
    attemptedAt = now
    dueAt = .distantFuture
    return generation
  }

  /// One fetch. The next one is due `pollInterval` after a success, or `retryDelay` after a
  /// failure: a network error, a refresh that failed, or any answer but 200.
  private func fetch(now: Date, session: Int) async {
    let succeeded = await attempt(now: now, session: session)
    if fetching == session { fetching = nil }
    // Signed out or in again meanwhile: that reset the schedule, and stands.
    guard session == generation else { return }
    failures = succeeded ? 0 : failures + 1
    guard dueAt != nil else { return }
    dueAt = now.addingTimeInterval(
      succeeded ? Self.pollInterval : Self.retryDelay(failures: failures))
  }

  private func attempt(now: Date, session: Int) async -> Bool {
    guard session == generation, let token = await accessToken(now: now, session: session),
      let (data, code) = try? await http.send(
        GoogleOAuth.eventsRequest(accessToken: token, now: now)),
      session == generation
    else { return false }
    switch code {
    case 200:
      cached = GoogleCalendarParsing.events(data)
      return true
    case 401:
      access = nil
      return false
    default: return false
    }
  }

  private func accessToken(now: Date, session: Int) async -> String? {
    if let access, now < access.expires { return access.token }
    guard let refresh = tokens.read() else {
      signOut(.disconnected)
      return nil
    }
    guard
      let answer = try? await http.send(
        GoogleOAuth.refreshRequest(refreshToken: refresh, client: client)),
      session == generation
    else { return nil }
    switch GoogleOAuth.tokenResult(answer) {
    case .tokens(let token, let expiresIn, let rotated):
      if let rotated, rotated != refresh { _ = tokens.write(rotated) }
      access = (token, now.addingTimeInterval(expiresIn - 60))
      return token
    case .invalidGrant:
      signOut(.signInAgain)
      return nil
    case .failed: return nil
    }
  }

  private func signOut(_ next: Status) {
    generation += 1
    tokens.delete()
    access = nil
    cached = []
    dueAt = nil
    attemptedAt = nil
    failures = 0
    fetching = nil
    set(next)
  }

  private func set(_ next: Status) {
    guard next != status else { return }
    status = next
    observer?(next)
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
