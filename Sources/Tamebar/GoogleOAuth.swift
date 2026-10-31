import AppKit
import CryptoKit
import Foundation
import Network
import os

/// Google's OAuth for an installed app, and the Calendar requests (M1, Task 6.5). The pieces
/// are pure: they build requests and read answers. `GoogleCalendarMeetings` sends them through
/// `GoogleHTTP`, so tests never reach the network.
///
/// The sign-in is the loopback flow with PKCE: the browser comes back to a one-shot listener on
/// 127.0.0.1, and the `state` sent out must come back unchanged before the code is used.
enum GoogleOAuth {
  static let scope = "https://www.googleapis.com/auth/calendar.events.readonly"
  static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
  static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
  static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
  static let eventsEndpoint = URL(
    string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
  /// The event fields the rules read, and `iCalUID` to match EventKit's copy.
  static let fields =
    "items(id,iCalUID,status,start,end,attendees(self,responseStatus),hangoutLink,location,description,transparency)"
  /// Every request gives up after this long.
  static let requestTimeout: TimeInterval = 15

  /// The OAuth client from the build's Info.plist. Google issues a "secret" to Desktop app
  /// clients that isn't one (it ships in the app); a build passes it only when Google asks.
  struct Client: Equatable, Sendable {
    let id: String
    let secret: String?
  }

  /// `bytes` random bytes, base64url without padding: the PKCE verifier and the state.
  static func randomToken(bytes: Int = 32) -> String {
    var generator = SystemRandomNumberGenerator()
    return base64URL(
      Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
  }

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  /// `code_challenge = base64url(SHA256(verifier))` (RFC 7636, S256).
  static func challenge(for verifier: String) -> String {
    base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  static func authorizationURL(
    client: Client, redirectURI: String, challenge: String, state: String
  )
    -> URL
  {
    var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      .init(name: "client_id", value: client.id), .init(name: "redirect_uri", value: redirectURI),
      .init(name: "response_type", value: "code"), .init(name: "scope", value: scope),
      .init(name: "code_challenge", value: challenge),
      .init(name: "code_challenge_method", value: "S256"), .init(name: "state", value: state),
      .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
    ]
    return components.url!
  }

  enum CallbackError: Error, Equatable {
    /// The `state` isn't the one sent: another page, not Google's answer to this sign-in.
    case stateMismatch
    /// Google answered with an error, such as `access_denied`.
    case denied(String)
    case noCode
  }

  /// The code from the redirect's request target (`/?state=…&code=…`). The state is checked
  /// first: a callback with any other state is never used, whatever else it carries.
  static func code(fromCallback target: String, state: String) -> Result<String, CallbackError> {
    let items = URLComponents(string: target)?.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    guard !state.isEmpty, value("state") == state else { return .failure(.stateMismatch) }
    if let error = value("error") { return .failure(.denied(error)) }
    guard let code = value("code"), !code.isEmpty else { return .failure(.noCode) }
    return .success(code)
  }

  /// Whether a callback answers this sign-in: anything but a state mismatch (a code, Google's
  /// error, or neither) ends the wait. Other pages and stray requests are ignored.
  static func answers(_ target: String, state: String) -> Bool {
    code(fromCallback: target, state: state) != .failure(.stateMismatch)
  }

  static let lineEnd = Data("\r\n".utf8)

  /// The request target of an HTTP request's first line, `GET <target> HTTP/1.1\r\n`. Nil until
  /// the whole line has arrived.
  static func requestTarget(_ data: Data) -> String? {
    guard let end = data.range(of: lineEnd) else { return nil }
    let line = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
    let parts = line.split(separator: " ")
    guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/") else { return nil }
    return String(parts[1])
  }

  static func tokenRequest(code: String, verifier: String, redirectURI: String, client: Client)
    -> URLRequest
  {
    form(
      tokenEndpoint,
      [
        ("code", code), ("client_id", client.id), ("client_secret", client.secret),
        ("code_verifier", verifier), ("redirect_uri", redirectURI),
        ("grant_type", "authorization_code"),
      ])
  }

  static func refreshRequest(refreshToken: String, client: Client) -> URLRequest {
    form(
      tokenEndpoint,
      [
        ("refresh_token", refreshToken), ("client_id", client.id),
        ("client_secret", client.secret), ("grant_type", "refresh_token"),
      ])
  }

  /// Disconnect's best effort to end the grant at Google too.
  static func revokeRequest(token: String) -> URLRequest {
    form(revokeEndpoint, [("token", token)])
  }

  /// Primary calendar events from 6 h before `now` to 1 h after, the window EventKit reads.
  static func eventsRequest(accessToken: String, now: Date) -> URLRequest {
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime]
    var components = URLComponents(url: eventsEndpoint, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      .init(name: "timeMin", value: format.string(from: now.addingTimeInterval(-6 * 3_600))),
      .init(name: "timeMax", value: format.string(from: now.addingTimeInterval(3_600))),
      .init(name: "singleEvents", value: "true"), .init(name: "orderBy", value: "startTime"),
      .init(name: "maxResults", value: "250"), .init(name: "fields", value: fields),
    ]
    var request = URLRequest(url: components.url!, timeoutInterval: requestTimeout)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    return request
  }

  enum TokenResult: Equatable, Sendable {
    case tokens(access: String, expiresIn: TimeInterval, refresh: String?)
    /// The refresh token is dead (revoked, or Testing mode's 7 days are up): sign in again.
    case invalidGrant
    case failed
  }

  static func tokenResult(_ answer: (data: Data, status: Int)) -> TokenResult {
    let object = (try? JSONSerialization.jsonObject(with: answer.data)) as? [String: Any]
    if object?["error"] as? String == "invalid_grant" { return .invalidGrant }
    guard answer.status == 200, let access = object?["access_token"] as? String else {
      return .failed
    }
    return .tokens(
      access: access, expiresIn: (object?["expires_in"] as? NSNumber)?.doubleValue ?? 3_600,
      refresh: object?["refresh_token"] as? String)
  }

  private static func form(_ url: URL, _ fields: [(String, String?)]) -> URLRequest {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    var request = URLRequest(url: url, timeoutInterval: requestTimeout)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(
      fields.compactMap { name, value in
        value.map { "\(name)=\($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
      }.joined(separator: "&").utf8)
    return request
  }
}

/// How requests reach Google: `URLSession` in the app, a fake in tests.
protocol GoogleHTTP: Sendable {
  /// The body and the HTTP status. Throws on a network error or a timeout.
  func send(_ request: URLRequest) async throws -> (Data, Int)
}

struct URLSessionGoogleHTTP: GoogleHTTP {
  let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = GoogleOAuth.requestTimeout
    configuration.timeoutIntervalForResource = GoogleOAuth.requestTimeout * 2
    configuration.waitsForConnectivity = false
    return URLSession(configuration: configuration)
  }()

  func send(_ request: URLRequest) async throws -> (Data, Int) {
    let (data, response) = try await session.data(for: request)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }
}

/// Where the sign-in happens: the browser and a loopback listener in the app, a fake in tests.
protocol GoogleAuthorizer: Sendable {
  /// Listens on loopback, opens the URL `makeURL` builds for its redirect URI, and returns that
  /// redirect URI with the request target of the first callback that carries `state`
  /// (`GoogleOAuth.answers`). Any other request gets a 404, and the wait goes on.
  func authorize(state: String, _ makeURL: @escaping @Sendable (String) -> URL) async throws -> (
    redirectURI: String, target: String
  )
}

/// The sign-in in the browser, back to a one-shot `NWListener` on 127.0.0.1 with a port the
/// system picks. It ends at the first callback, on cancel, or after `timeout`.
struct LoopbackAuthorizer: GoogleAuthorizer {
  enum Failure: Error { case noPort, timedOut, cancelled }

  var timeout: TimeInterval = 300

  static let closePage = Data(
    """
    HTTP/1.1 200 OK\r
    Content-Type: text/html; charset=utf-8\r
    Connection: close\r
    \r
    <!doctype html><meta charset="utf-8"><title>Tamebar</title>\
    <body style="font: 15px -apple-system; margin: 48px">\
    Tamebar has your answer. You can close this tab.</body>
    """.utf8)
  static let notFound = Data("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n".utf8)
  /// The most read from one request; a longer request line gets a 404.
  static let maximumRequest = 16_384

  /// The reply to one request on the listener, and the target when it ends the sign-in. Pure:
  /// only a request carrying this sign-in's `state` ends it.
  static func reply(to request: Data, state: String) -> (page: Data, answer: String?) {
    guard let target = GoogleOAuth.requestTarget(request),
      GoogleOAuth.answers(target, state: state)
    else { return (notFound, nil) }
    return (closePage, target)
  }

  func authorize(state: String, _ makeURL: @escaping @Sendable (String) -> URL) async throws -> (
    redirectURI: String, target: String
  ) {
    try Task.checkCancellation()
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let listener = try NWListener(using: parameters)
    let queue = DispatchQueue(label: "com.tamebar.Tamebar.google-signin")
    let once = OnceResult<(redirectURI: String, target: String)>()
    let redirect = OSAllocatedUnfairLock<String?>(initialState: nil)
    let timeout = timeout
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        // Cancelled before the listener started: nothing to start.
        guard once.set(continuation, cleanup: { listener.cancel() }) else { return }
        listener.stateUpdateHandler = { update in
          switch update {
          case .ready:
            guard let port = listener.port?.rawValue else { return once.fail(Failure.noPort) }
            let uri = "http://127.0.0.1:\(port)"
            redirect.withLock { $0 = uri }
            let url = makeURL(uri)
            Task { @MainActor in NSWorkspace.shared.open(url) }
          case .failed(let error): once.fail(error)
          default: break
          }
        }
        listener.newConnectionHandler = { connection in
          connection.start(queue: queue)
          Self.readRequestLine(connection) { request in
            let reply = Self.reply(to: request, state: state)
            connection.send(
              content: reply.page, completion: .contentProcessed { _ in connection.cancel() })
            if let target = reply.answer, let uri = redirect.withLock({ $0 }) {
              once.succeed((uri, target))
            }
          }
        }
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { once.fail(Failure.timedOut) }
      }
    } onCancel: {
      once.fail(Failure.cancelled)
    }
  }

  /// Reads until the request line's `\r\n` has arrived, the peer stops, or `maximumRequest`
  /// bytes, whichever comes first.
  private static func readRequestLine(
    _ connection: NWConnection, received: Data = Data(),
    done: @escaping @Sendable (Data) -> Void
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: maximumRequest) {
      data, _, isComplete, error in
      var request = received
      if let data { request.append(data) }
      if request.range(of: GoogleOAuth.lineEnd) != nil || isComplete || error != nil
        || request.count >= maximumRequest
      {
        return done(request)
      }
      readRequestLine(connection, received: request, done: done)
    }
  }
}

/// Resumes a continuation once, whichever of the callback, the timeout or a cancel comes first,
/// and runs the cleanup then.
private final class OnceResult<Value: Sendable>: Sendable {
  private struct State {
    var continuation: CheckedContinuation<Value, any Error>?
    var cleanup: (@Sendable () -> Void)?
    var early: (any Error)?
  }

  private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

  /// False when a cancel came first: the continuation is already resumed and the cleanup has
  /// run, so the caller must not start anything.
  func set(
    _ continuation: CheckedContinuation<Value, any Error>, cleanup: @escaping @Sendable () -> Void
  ) -> Bool {
    let early = state.withLockUnchecked { state in
      state.continuation = continuation
      state.cleanup = cleanup
      return state.early
    }
    guard let early else { return true }
    fail(early)
    return false
  }

  func succeed(_ value: Value) { finish(.success(value)) }

  func fail(_ error: any Error) {
    let pending = state.withLockUnchecked { state in
      if state.continuation == nil, state.early == nil { state.early = error }
      return state.continuation != nil
    }
    if pending { finish(.failure(error)) }
  }

  private func finish(_ result: Result<Value, any Error>) {
    let taken = state.withLockUnchecked { state in
      defer {
        state.continuation = nil
        state.cleanup = nil
      }
      return (state.continuation, state.cleanup)
    }
    guard let continuation = taken.0 else { return }
    taken.1?()
    continuation.resume(with: result)
  }
}
