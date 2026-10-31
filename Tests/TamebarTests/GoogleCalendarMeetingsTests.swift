import Foundation
import Testing

@testable import Tamebar

/// Answers Google's endpoints from a handler and records every request. Nothing reaches the
/// network.
final class FakeGoogleHTTP: GoogleHTTP, @unchecked Sendable {
  private let lock = NSLock()
  private var sent: [URLRequest] = []
  var handler: @Sendable (URLRequest) throws -> (Data, Int)

  init(handler: @escaping @Sendable (URLRequest) throws -> (Data, Int)) {
    self.handler = handler
  }

  var requests: [URLRequest] { lock.withLock { sent } }
  func requests(to host: String) -> [URLRequest] { requests.filter { $0.url?.host == host } }

  func send(_ request: URLRequest) async throws -> (Data, Int) {
    lock.withLock { sent.append(request) }
    return try lock.withLock { handler }(request)
  }

  func respond(_ handler: @escaping @Sendable (URLRequest) throws -> (Data, Int)) {
    lock.withLock { self.handler = handler }
  }
}

/// The refresh token, in memory instead of the Keychain. Counts the reads of its data.
final class FakeSecretStore: SecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: String?
  private var dataReads = 0

  init(_ value: String? = nil) { stored = value }

  var value: String? { lock.withLock { stored } }
  var reads: Int { lock.withLock { dataReads } }
  func exists() -> Bool { lock.withLock { stored != nil } }
  func read() -> String? {
    lock.withLock {
      dataReads += 1
      return stored
    }
  }
  func write(_ value: String) -> Bool {
    lock.withLock { stored = value }
    return true
  }
  func delete() { lock.withLock { stored = nil } }
}

/// Holds every events request until it's released, without blocking a thread; the token
/// endpoints answer at once. Nothing reaches the network.
final class HeldGoogleHTTP: GoogleHTTP, @unchecked Sendable {
  private let lock = NSLock()
  private var held: [CheckedContinuation<Void, Never>] = []
  private var eventsSent = 0

  var events: Int { lock.withLock { eventsSent } }

  func send(_ request: URLRequest) async throws -> (Data, Int) {
    guard request.url?.host == "www.googleapis.com" else {
      return try GoogleCalendarMeetingsTests.google(request)
    }
    await withCheckedContinuation { continuation in
      lock.withLock {
        eventsSent += 1
        held.append(continuation)
      }
    }
    return (GoogleCalendarParsingTests.fixture, 200)
  }

  func releaseFirst() {
    lock.withLock { held.isEmpty ? nil : held.removeFirst() }?.resume()
  }

  func releaseAll() {
    for continuation in lock.withLock({ () -> [CheckedContinuation<Void, Never>] in
      defer { held = [] }
      return held
    }) {
      continuation.resume()
    }
  }
}

/// Plays the browser and Google's redirect: it answers with the given request target, built
/// from the authorization URL Tamebar opened.
struct FakeAuthorizer: GoogleAuthorizer {
  var redirectURI = "http://127.0.0.1:50123"
  var answer: @Sendable (URLComponents) throws -> String

  /// Google's real answer: the code, with the state it was sent.
  static func granting(_ code: String) -> FakeAuthorizer {
    FakeAuthorizer { url in
      let state = url.queryItems?.first { $0.name == "state" }?.value ?? ""
      return "/?state=\(state)&code=\(code)&scope=x"
    }
  }

  func authorize(state: String, _ makeURL: @escaping @Sendable (String) -> URL) async throws -> (
    redirectURI: String, target: String
  ) {
    let url = try #require(URLComponents(url: makeURL(redirectURI), resolvingAgainstBaseURL: false))
    return (redirectURI, try answer(url))
  }
}

struct GoogleCalendarMeetingsTests {
  let t0 = GoogleCalendarParsingTests.eight
  let client = GoogleOAuth.Client(id: "test-client.apps.googleusercontent.com", secret: nil)

  static func json(_ object: [String: Any], status: Int = 200) -> (Data, Int) {
    ((try? JSONSerialization.data(withJSONObject: object)) ?? Data(), status)
  }

  /// Google's token endpoint and the events list, the way they answer a good sign-in.
  static let google: @Sendable (URLRequest) throws -> (Data, Int) = { request in
    switch request.url?.host {
    case "oauth2.googleapis.com":
      return json(["access_token": "a1", "expires_in": 3_599, "refresh_token": "r1"])
    case "www.googleapis.com": return (GoogleCalendarParsingTests.fixture, 200)
    default: throw URLError(.unsupportedURL)
    }
  }

  func form(_ request: URLRequest) -> [String: String] {
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    var components = URLComponents()
    components.percentEncodedQuery = body
    return Dictionary(
      (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
  }

  func query(_ url: URL?) -> [String: String] {
    let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
    return Dictionary((items ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
  }

  func meetings(
    http: any GoogleHTTP, tokens: FakeSecretStore = .init(),
    authorizer: FakeAuthorizer = .granting("c1")
  ) -> GoogleCalendarMeetings {
    GoogleCalendarMeetings(client: client, http: http, tokens: tokens, authorizer: authorizer)
  }

  // MARK: OAuth pieces (pure)

  @Test func pkceMatchesRFC7636() {
    #expect(
      GoogleOAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let verifier = GoogleOAuth.randomToken()
    #expect(verifier.count == 43)
    #expect(!verifier.contains { "+/=".contains($0) })
    #expect(verifier != GoogleOAuth.randomToken())
  }

  @Test func theAuthorizationURLAsksForReadOnlyEventsWithPKCEAndState() {
    let url = GoogleOAuth.authorizationURL(
      client: client, redirectURI: "http://127.0.0.1:50123", challenge: "ch", state: "st")
    #expect(url.absoluteString.hasPrefix("https://accounts.google.com/o/oauth2/v2/auth?"))
    #expect(
      query(url) == [
        "client_id": client.id, "redirect_uri": "http://127.0.0.1:50123", "response_type": "code",
        "scope": "https://www.googleapis.com/auth/calendar.events.readonly",
        "code_challenge": "ch", "code_challenge_method": "S256", "state": "st",
        "access_type": "offline", "prompt": "consent",
      ])
  }

  @Test func theCallbackGivesTheCodeOnlyWithTheStateItWasSent() {
    #expect(
      GoogleOAuth.code(fromCallback: "/?state=st&code=4%2F0Ab", state: "st") == .success("4/0Ab"))
    #expect(
      GoogleOAuth.code(fromCallback: "/?state=forged&code=c", state: "st")
        == .failure(.stateMismatch))
    #expect(GoogleOAuth.code(fromCallback: "/?code=c", state: "st") == .failure(.stateMismatch))
    #expect(
      GoogleOAuth.code(fromCallback: "/?state=&code=c", state: "") == .failure(.stateMismatch))
    #expect(
      GoogleOAuth.code(fromCallback: "/?error=access_denied&state=st", state: "st")
        == .failure(.denied("access_denied")))
    #expect(
      GoogleOAuth.code(fromCallback: "/?error=access_denied&state=x", state: "st")
        == .failure(.stateMismatch))
    #expect(GoogleOAuth.code(fromCallback: "/?state=st", state: "st") == .failure(.noCode))
  }

  @Test func theLoopbackReadsTheRequestTarget() {
    #expect(
      GoogleOAuth.requestTarget(
        Data("GET /?code=a&state=b HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
        == "/?code=a&state=b")
    #expect(
      GoogleOAuth.requestTarget(Data("GET /?code=a&state=b HTTP/1.1".utf8)) == nil,
      "the request line hasn't fully arrived")
    #expect(GoogleOAuth.requestTarget(Data("garbage\r\n".utf8)) == nil)
    #expect(GoogleOAuth.requestTarget(Data()) == nil)
  }

  @Test func theListenerEndsOnlyOnACallbackWithItsState() {
    func reply(_ target: String) -> (page: Data, answer: String?) {
      LoopbackAuthorizer.reply(
        to: Data("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8), state: "st")
    }
    for answer in ["/?state=st&code=c", "/?error=access_denied&state=st", "/?state=st"] {
      #expect(reply(answer).answer == answer)
      #expect(reply(answer).page == LoopbackAuthorizer.closePage)
    }
    for foreign in [
      "/?state=forged&code=attacker", "/?code=c", "/?error=access_denied", "/favicon.ico", "/",
    ] {
      #expect(reply(foreign).answer == nil, "\(foreign)")
      #expect(reply(foreign).page == LoopbackAuthorizer.notFound)
    }
    #expect(
      LoopbackAuthorizer.reply(to: Data("GET /?state=st&code=c".utf8), state: "st").answer == nil)
    #expect(GoogleOAuth.answers("/?state=st&code=c", state: "st"))
    #expect(!GoogleOAuth.answers("/?state=st&code=c", state: ""))
  }

  @Test func everyRequestHasATimeout() {
    let requests = [
      GoogleOAuth.tokenRequest(
        code: "c", verifier: "v", redirectURI: "http://127.0.0.1:1", client: client),
      GoogleOAuth.refreshRequest(refreshToken: "r", client: client),
      GoogleOAuth.eventsRequest(accessToken: "a", now: t0),
      GoogleOAuth.revokeRequest(token: "r"),
    ]
    for request in requests {
      #expect(request.timeoutInterval == GoogleOAuth.requestTimeout)
    }
    #expect(GoogleOAuth.requestTimeout <= 15)
  }

  @Test func theTokenRequestsCarryNoSecretUnlessTheBuildHasOne() {
    let exchange = GoogleOAuth.tokenRequest(
      code: "4/0Ab", verifier: "v", redirectURI: "http://127.0.0.1:50123", client: client)
    #expect(exchange.httpMethod == "POST")
    #expect(exchange.url?.absoluteString == "https://oauth2.googleapis.com/token")
    #expect(
      form(exchange) == [
        "code": "4/0Ab", "client_id": client.id, "code_verifier": "v",
        "redirect_uri": "http://127.0.0.1:50123", "grant_type": "authorization_code",
      ])
    let refresh = GoogleOAuth.refreshRequest(
      refreshToken: "r", client: .init(id: "id", secret: "s"))
    #expect(
      form(refresh) == [
        "refresh_token": "r", "client_id": "id", "client_secret": "s",
        "grant_type": "refresh_token",
      ])
  }

  @Test func theEventsRequestAsksForTheNextHourAndThePastSix() {
    let request = GoogleOAuth.eventsRequest(accessToken: "a1", now: t0)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer a1")
    #expect(
      request.url?.absoluteString.hasPrefix(
        "https://www.googleapis.com/calendar/v3/calendars/primary/events?") == true)
    let items = query(request.url)
    #expect(items["timeMin"] == "2026-10-20T02:00:00Z")
    #expect(items["timeMax"] == "2026-10-20T09:00:00Z")
    #expect(items["singleEvents"] == "true")
    #expect(items["orderBy"] == "startTime")
    #expect(
      items["fields"]
        == "items(id,iCalUID,status,start,end,attendees(self,responseStatus),hangoutLink,location,description,transparency)"
    )
  }

  @Test func tokenAnswersAreReadAndInvalidGrantIsItsOwnCase() {
    #expect(
      GoogleOAuth.tokenResult(
        Self.json(["access_token": "a", "expires_in": 3_599, "refresh_token": "r"]))
        == .tokens(access: "a", expiresIn: 3_599, refresh: "r"))
    #expect(
      GoogleOAuth.tokenResult(Self.json(["access_token": "a", "expires_in": 3_599]))
        == .tokens(access: "a", expiresIn: 3_599, refresh: nil))
    #expect(
      GoogleOAuth.tokenResult(
        Self.json(
          ["error": "invalid_grant", "error_description": "Token has been expired"], status: 400))
        == .invalidGrant)
    #expect(
      GoogleOAuth.tokenResult(Self.json(["error": "invalid_client"], status: 401)) == .failed)
    #expect(GoogleOAuth.tokenResult((Data("<html>".utf8), 503)) == .failed)
  }

  // MARK: The source

  @Test func connectStoresTheRefreshTokenAndTheNextReadFetches() async throws {
    let http = FakeGoogleHTTP(handler: Self.google)
    let tokens = FakeSecretStore()
    let google = meetings(http: http, tokens: tokens)
    #expect(await google.status == .disconnected)
    await google.connect()
    #expect(await google.status == .connected)
    #expect(tokens.value == "r1")
    let exchange = try #require(http.requests(to: "oauth2.googleapis.com").first)
    let sent = form(exchange)
    #expect(sent["code"] == "c1")
    #expect(sent["redirect_uri"] == "http://127.0.0.1:50123")
    #expect(sent["code_verifier"].map { $0.count >= 43 } == true)
    await google.refreshIfDue(now: t0)
    #expect(await google.events(around: t0).map(\.id).count == 2)
    #expect(http.requests(to: "www.googleapis.com").count == 1)
    #expect(http.requests.allSatisfy { $0.timeoutInterval == GoogleOAuth.requestTimeout })
  }

  @Test func theVerifierSentMatchesTheChallengeOpened() async throws {
    final class Opened: @unchecked Sendable { var challenge: String? }
    let opened = Opened()
    let http = FakeGoogleHTTP(handler: Self.google)
    let authorizer = FakeAuthorizer { url in
      opened.challenge = url.queryItems?.first { $0.name == "code_challenge" }?.value
      let state = url.queryItems?.first { $0.name == "state" }?.value ?? ""
      return "/?state=\(state)&code=c1"
    }
    await meetings(http: http, authorizer: authorizer).connect()
    let exchange = try #require(http.requests.first)
    let verifier = try #require(form(exchange)["code_verifier"])
    #expect(opened.challenge == GoogleOAuth.challenge(for: verifier))
  }

  @Test func aCallbackWithAnotherStateIsRejectedBeforeAnyTokenRequest() async {
    let http = FakeGoogleHTTP(handler: Self.google)
    let tokens = FakeSecretStore()
    let forged = FakeAuthorizer { _ in "/?state=forged&code=attacker" }
    let google = meetings(http: http, tokens: tokens, authorizer: forged)
    await google.connect()
    #expect(http.requests.isEmpty)
    #expect(tokens.value == nil)
    guard case .failed = await google.status else {
      Issue.record("a forged callback must fail the sign-in")
      return
    }
  }

  @Test func invalidGrantDropsTheTokenAndAsksToSignInAgain() async {
    let http = FakeGoogleHTTP(handler: Self.google)
    let tokens = FakeSecretStore("r1")
    let google = meetings(http: http, tokens: tokens)
    #expect(await google.status == .connected)
    await google.refreshIfDue(now: t0)
    #expect(await google.events(around: t0).count == 2)
    http.respond { _ in Self.json(["error": "invalid_grant"], status: 400) }
    // The access token from the first refresh is an hour old: the next fetch refreshes it.
    await google.refreshIfDue(now: t0.addingTimeInterval(3_600))
    #expect(await google.status == .signInAgain)
    #expect(tokens.value == nil)
    #expect(await google.events(around: t0).isEmpty)
    let before = http.requests.count
    await google.refreshIfDue(now: t0.addingTimeInterval(7_200))
    #expect(http.requests.count == before, "signed out: no request")
  }

  @Test func aNetworkErrorKeepsTheLastResult() async {
    let http = FakeGoogleHTTP(handler: Self.google)
    let tokens = FakeSecretStore("r1")
    let google = meetings(http: http, tokens: tokens)
    await google.refreshIfDue(now: t0)
    let events = await google.events(around: t0)
    #expect(events.count == 2)
    http.respond { _ in throw URLError(.notConnectedToInternet) }
    await google.refreshIfDue(now: t0.addingTimeInterval(300))
    #expect(await google.events(around: t0) == events, "offline")
    http.respond { _ in (Data("busy".utf8), 503) }
    await google.refreshIfDue(now: t0.addingTimeInterval(600))
    #expect(await google.events(around: t0) == events, "the events list failed")
    await google.refreshIfDue(now: t0.addingTimeInterval(3_600))
    #expect(await google.events(around: t0) == events, "the token refresh failed")
    #expect(http.requests(to: "www.googleapis.com").count == 3)
    #expect(await google.status == .connected)
    #expect(tokens.value == "r1")
  }

  @Test func launchChecksTheTokenExistsWithoutReadingIt() async {
    let stored = FakeSecretStore("r1")
    let google = meetings(http: FakeGoogleHTTP(handler: Self.google), tokens: stored)
    let empty = FakeSecretStore()
    let none = meetings(http: FakeGoogleHTTP(handler: Self.google), tokens: empty)
    #expect(stored.reads == 0)
    #expect(empty.reads == 0)
    #expect(await google.status == .connected)
    #expect(await none.status == .disconnected)
    await google.refreshIfDue(now: t0)
    #expect(stored.reads == 1, "the fetch reads it, on the actor")
  }

  @Test func aFailedFetchAfterAWakeIsTriedAgainWithin30Seconds() async {
    let http = FakeGoogleHTTP(handler: Self.google)
    let google = meetings(http: http, tokens: .init("r1"))
    func fetches() -> Int { http.requests(to: "www.googleapis.com").count }
    await google.refreshIfDue(now: t0)
    #expect(fetches() == 1)
    await google.wake()
    http.respond { request in
      request.url?.host == "www.googleapis.com"
        ? (Data("busy".utf8), 503) : try Self.google(request)
    }
    await google.refreshIfDue(now: t0.addingTimeInterval(100))
    #expect(fetches() == 2, "on wake: failed")
    http.respond(Self.google)
    await google.refreshIfDue(now: t0.addingTimeInterval(129))
    #expect(fetches() == 2)
    await google.refreshIfDue(now: t0.addingTimeInterval(130))
    #expect(fetches() == 3, "30 s after the failure")
    #expect(await google.events(around: t0.addingTimeInterval(130)).count == 2)
    await google.refreshIfDue(now: t0.addingTimeInterval(429))
    #expect(fetches() == 3, "the 5 min slot counts from the success")
    await google.refreshIfDue(now: t0.addingTimeInterval(430))
    #expect(fetches() == 4)
  }

  @Test func retriesBackOffFrom30SecondsUpToThePollInterval() async {
    #expect(
      [1, 2, 3, 4, 5, 60].map(GoogleCalendarMeetings.retryDelay(failures:))
        == [30, 60, 120, 240, 300, 300])
    let http = FakeGoogleHTTP { _ in throw URLError(.notConnectedToInternet) }
    let google = meetings(http: http, tokens: .init("r1"))
    await google.refreshIfDue(now: t0)
    #expect(http.requests.count == 1, "the token refresh failed")
    await google.refreshIfDue(now: t0.addingTimeInterval(29))
    #expect(http.requests.count == 1)
    await google.refreshIfDue(now: t0.addingTimeInterval(30))
    #expect(http.requests.count == 2)
    await google.refreshIfDue(now: t0.addingTimeInterval(89))
    #expect(http.requests.count == 2)
    await google.refreshIfDue(now: t0.addingTimeInterval(90))
    #expect(http.requests.count == 3, "60 s after the second failure")
    #expect(await google.status == .connected)
  }

  @Test func a401DropsTheAccessTokenAndIsTriedAgainSoon() async {
    let http = FakeGoogleHTTP(handler: Self.google)
    let google = meetings(http: http, tokens: .init("r1"))
    func refreshes() -> Int { http.requests(to: "oauth2.googleapis.com").count }
    await google.refreshIfDue(now: t0)
    http.respond { request in
      request.url?.host == "www.googleapis.com" ? (Data(), 401) : try Self.google(request)
    }
    await google.refreshIfDue(now: t0.addingTimeInterval(300))
    #expect(refreshes() == 1)
    http.respond(Self.google)
    await google.refreshIfDue(now: t0.addingTimeInterval(329))
    #expect(refreshes() == 1)
    await google.refreshIfDue(now: t0.addingTimeInterval(330))
    #expect(refreshes() == 2, "30 s later, with a new access token")
    #expect(http.requests(to: "www.googleapis.com").count == 3)
  }

  @Test(.timeLimit(.minutes(1))) func aFetchFromBeforeASignOutLeavesTheNewOneInFlight()
    async throws
  {
    let http = HeldGoogleHTTP()
    defer { http.releaseAll() }
    let google = meetings(http: http, tokens: .init("r1"))
    func waitFor(_ condition: () -> Bool) async throws {
      for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }
    let first = Task { await google.refreshIfDue(now: t0) }
    try await waitFor { http.events == 1 }
    await google.disconnect()
    await google.connect()
    #expect(await google.status == .connected)
    let second = Task { await google.refreshIfDue(now: t0) }
    try await waitFor { http.events == 2 }
    http.releaseFirst()
    await first.value
    // The second fetch is still in flight: a read must not start a third, even after a wake.
    await google.wake()
    #expect(await google.events(around: t0).isEmpty, "the first fetch's answer is dropped")
    try await Task.sleep(for: .milliseconds(200))
    #expect(http.events == 2)
    http.releaseAll()
    await second.value
    // The wake during the second fetch still stands once it's done.
    #expect(await google.events(around: t0).count == 2)
    try await waitFor { http.events == 3 }
    #expect(http.events == 3)
    http.releaseAll()
  }

  @Test func itFetchesAtMostEveryFiveMinutesAndAgainOnWake() async {
    let http = FakeGoogleHTTP(handler: Self.google)
    let google = meetings(http: http, tokens: .init("r1"))
    func fetches() -> Int { http.requests(to: "www.googleapis.com").count }
    await google.refreshIfDue(now: t0)
    #expect(fetches() == 1, "at launch")
    await google.refreshIfDue(now: t0.addingTimeInterval(299))
    #expect(fetches() == 1)
    await google.refreshIfDue(now: t0.addingTimeInterval(300))
    #expect(fetches() == 2)
    await google.wake()
    await google.refreshIfDue(now: t0.addingTimeInterval(301))
    #expect(fetches() == 3, "on wake")
    await google.refreshIfDue(now: t0.addingTimeInterval(100))
    #expect(fetches() == 4, "a clock set back doesn't stall it")
    #expect(http.requests(to: "oauth2.googleapis.com").count == 1, "the access token is reused")
  }

  @Test func withoutATokenNothingIsSent() async {
    let http = FakeGoogleHTTP(handler: Self.google)
    let google = meetings(http: http)
    await google.refreshIfDue(now: t0)
    #expect(await google.events(around: t0).isEmpty)
    #expect(http.requests.isEmpty)
  }

  @Test(.timeLimit(.minutes(1))) func aReadNeverWaitsForTheNetwork() async {
    let gate = BlockingGate()
    gate.openAfter(seconds: 20)
    defer { gate.open() }
    let http = FakeGoogleHTTP { _ in
      gate.block()
      throw URLError(.timedOut)
    }
    let google = meetings(http: http, tokens: .init("r1"))
    let started = Date.now
    #expect(await google.events(around: t0).isEmpty)
    #expect(await google.events(around: t0).isEmpty)
    #expect(Date.now.timeIntervalSince(started) < 5)
  }

  @Test func disconnectDeletesTheTokenAndTheEvents() async {
    let http = FakeGoogleHTTP(handler: Self.google)
    let tokens = FakeSecretStore("r1")
    let google = meetings(http: http, tokens: tokens)
    await google.refreshIfDue(now: t0)
    await google.disconnect()
    #expect(tokens.value == nil)
    #expect(await google.status == .disconnected)
    #expect(await google.events(around: t0).isEmpty)
  }

  // MARK: Only the shipped app talks to Google

  @Test func onlyTheShippedAppWithAClientIDGetsASource() {
    final class Made: @unchecked Sendable { var clients: [GoogleOAuth.Client] = [] }
    let made = Made()
    let http = FakeGoogleHTTP(handler: Self.google)
    let make: @Sendable (GoogleOAuth.Client) -> GoogleCalendarMeetings = { client in
      made.clients.append(client)
      return GoogleCalendarMeetings(
        client: client, http: http, tokens: FakeSecretStore(),
        authorizer: FakeAuthorizer.granting("c"))
    }
    let info = ["TamebarGoogleClientID": "id.apps.googleusercontent.com"]
    #expect(GoogleCalendarMeetings.launch(shipped: false, info: info, make: make) == nil)
    #expect(GoogleCalendarMeetings.launch(shipped: true, info: [:], make: make) == nil)
    #expect(
      GoogleCalendarMeetings.launch(shipped: true, info: ["TamebarGoogleClientID": " "], make: make)
        == nil)
    #expect(made.clients.isEmpty)
    #expect(GoogleCalendarMeetings.launch(shipped: true, info: info, make: make) != nil)
    #expect(
      GoogleCalendarMeetings.launch(
        shipped: true, info: info.merging(["TamebarGoogleClientSecret": "s"]) { $1 }, make: make)
        != nil)
    #expect(
      made.clients == [
        .init(id: "id.apps.googleusercontent.com", secret: nil),
        .init(id: "id.apps.googleusercontent.com", secret: "s"),
      ])
    #expect(GoogleCalendarMeetings.shared == nil, "this test process isn't the shipped app")
    #expect(http.requests.isEmpty)
  }

  @MainActor @Test func theMeetingMonitorReadsGoogleOnlyInTheShippedApp() throws {
    let google = meetings(http: FakeGoogleHTTP(handler: Self.google))
    #expect(MeetingMonitor.launch(e2e: nil, shipped: false, google: google).sources.google == nil)
    #expect(MeetingMonitor.launch(e2e: nil, shipped: true, google: google).sources.google != nil)
    #expect(MeetingMonitor.launch(e2e: nil, shipped: true, google: nil).sources.google == nil)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tamebar-google-\(UUID().uuidString)", isDirectory: true)
    #expect(
      MeetingMonitor.launch(e2e: E2EMode(directory: dir), shipped: true, google: google).sources
        .google == nil)
    #expect(MeetingMonitor.launch().sources.google == nil)
  }

  @MainActor @Test func aGoogleMeetingIsAMeetingAndAMissedReadKeepsIt() async {
    let monitor = MeetingMonitor(sources: .none)
    let event = MeetingEvent(
      id: "g@google.com", start: t0.addingTimeInterval(120), end: t0.addingTimeInterval(1_800))
    #expect(monitor.tick(now: t0, observation: .init(google: [event], calls: CallReading())))
    #expect(monitor.source == .calendar)
    #expect(monitor.tick(now: t0.addingTimeInterval(60), observation: nil))
    let sources = MeetingMonitor.Sources(google: { _ in [event] })
    #expect(await MeetingMonitor.observe(sources, now: t0) == .init(google: [event]))
  }

  // MARK: The Settings row's model

  @MainActor @Test func theSettingsRowIsHiddenOutsideTheShippedAppAndSaysWhenUnconfigured() {
    #expect(GoogleCalendarModel(source: nil, shipped: false).row == .hidden)
    #expect(GoogleCalendarModel(source: nil, shipped: true).row == .notConfigured)
    #expect(GoogleCalendarModel().row == .hidden)
  }

  @MainActor @Test func theSettingsRowFollowsTheSource() async throws {
    let http = FakeGoogleHTTP { _ in Self.json(["error": "invalid_grant"], status: 400) }
    let google = meetings(http: http, tokens: .init("r1"))
    let model = GoogleCalendarModel(source: google, shipped: true)
    for _ in 0..<100 where model.row != .status(.connected) {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.row == .status(.connected))
    await google.refreshIfDue(now: t0)
    for _ in 0..<100 where model.row != .status(.signInAgain) {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.row == .status(.signInAgain))
  }
}
