import Foundation

/// The automatic actions that end or edit something on their own, and the two lists that keep
/// things out of them (decisions P2). On a new install the switches are off and the lists empty:
/// watching, slowing busy background work, the notes and the Stopped log stay on, and nothing is
/// ended or edited until it is switched on in Settings. Kept in the app's defaults domain:
///
/// - `automatic.endIdleSessions` (Bool): Q18, end a session idle 12 h under memory pressure held
///   2 min, and Q20, end a session idle 24 h with its dev server unused 24 h.
/// - `automatic.trimCodexPlugins` (Bool): Q21, turn off the Codex MCP servers no session called
///   in 30 days (`enabled = false` in `~/.codex/config.toml`, after a backup).
/// - `protection.ports` ([Int]): Q20 never ends a server on these ports. Portless routes and the
///   portless proxy are found on their own.
/// - `protection.codexServers` ([String]): Q21 never turns these servers off.
///
/// Q10's "End after N days" and Q11's per-app quit list have their own opt-in controls.
struct AutomaticSafety: Equatable, Sendable {
  enum Key {
    static let endIdleSessions = "automatic.endIdleSessions"
    static let trimCodexPlugins = "automatic.trimCodexPlugins"
    static let protectedPorts = "protection.ports"
    static let keptCodexServers = "protection.codexServers"
  }

  /// Q18 and Q20.
  var endIdleSessions = false
  /// Q21.
  var trimCodexPlugins = false
  /// Ports Q20 never ends, in the order they were typed.
  var protectedPorts: [Int] = []
  /// Codex MCP server names Q21 never turns off.
  var keptCodexServers: [String] = []

  /// The servers' keys as Q21's modes name them: `server:<name>`.
  var keptCodexKeys: Set<String> { Set(keptCodexServers.map { "server:\($0)" }) }

  /// Tolerant: a missing or unreadable switch is off; a list keeps its valid entries (numbers or
  /// digit strings for the ports, non-empty strings for the servers).
  static func load(_ defaults: UserDefaults) -> Self {
    let ports = (defaults.array(forKey: Key.protectedPorts) ?? []).compactMap { value -> Int? in
      if let number = value as? NSNumber { return number.intValue }
      return (value as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
    let servers = (defaults.array(forKey: Key.keptCodexServers) ?? []).compactMap {
      ($0 as? String)?.trimmingCharacters(in: .whitespaces)
    }
    return Self(
      endIdleSessions: flag(defaults.object(forKey: Key.endIdleSessions)),
      trimCodexPlugins: flag(defaults.object(forKey: Key.trimCodexPlugins)),
      protectedPorts: unique(ports.filter(validPort)),
      keptCodexServers: unique(servers.filter { !$0.isEmpty }))
  }

  func save(_ defaults: UserDefaults) {
    defaults.set(endIdleSessions, forKey: Key.endIdleSessions)
    defaults.set(trimCodexPlugins, forKey: Key.trimCodexPlugins)
    defaults.set(protectedPorts, forKey: Key.protectedPorts)
    defaults.set(keptCodexServers, forKey: Key.keptCodexServers)
  }

  /// A Bool, or the "YES", "true" or "1" that `defaults write` or a launch argument gives.
  static func flag(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    guard let text = (value as? String)?.lowercased() else { return false }
    return ["yes", "true", "1"].contains(text)
  }

  static func validPort(_ port: Int) -> Bool { (1...65_535).contains(port) }

  /// "3000, 5173 8080": the valid ports, each once, in order; anything else is dropped.
  static func ports(_ text: String) -> [Int] {
    unique(words(text).compactMap(Int.init).filter(validPort))
  }

  /// "chat, courier": the names, each once, in order.
  static func names(_ text: String) -> [String] { unique(words(text)) }

  /// A list as Settings shows it: comma-separated.
  static func text<T: CustomStringConvertible>(_ list: [T]) -> String {
    list.map(\.description).joined(separator: ", ")
  }

  private static func words(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
  }

  private static func unique<T: Hashable>(_ list: [T]) -> [T] {
    var seen = Set<T>()
    return list.filter { seen.insert($0).inserted }
  }
}

/// P2's migration, once: an install that ran Tamebar before P2 keeps what it did then. Before
/// P2, ending idle sessions (Q18, Q20) and trimming Codex plugins (Q21) were always on, so such
/// an install gets both switches written on; a new install writes nothing and starts with them
/// off. It runs before `BrandMigration`, whose flag marks a Tamebar that has run before.
enum SafeDefaultsMigration {
  static let doneKey = "automatic.safeDefaults.v1"

  /// Runs in the installed app only, as `BrandMigration`: never in the e2e build or a bare
  /// `swift run`.
  static func run() {
    guard BrandMigration.shouldRun(bundleIdentifier: Bundle.main.bundleIdentifier) else { return }
    migrate(.standard)
  }

  /// Returns whether it wrote the pre-P2 values.
  @discardableResult
  static func migrate(_ defaults: UserDefaults) -> Bool {
    guard defaults.object(forKey: doneKey) == nil else { return false }
    defaults.set(true, forKey: doneKey)
    // Tamebar ran before P2: its brand migration has set this flag at each launch since.
    guard defaults.object(forKey: BrandMigration.copiedKey) != nil else { return false }
    // A value already written (a newer build ran, then an older one) is kept.
    for key in [AutomaticSafety.Key.endIdleSessions, AutomaticSafety.Key.trimCodexPlugins]
    where defaults.object(forKey: key) == nil {
      defaults.set(true, forKey: key)
    }
    return true
  }
}
