import Foundation

/// Sessions the user pinned with Keep: never unused, never in a bulk action, never paused automatically (Q7).
struct SessionKeeps: Codable, Equatable, Sendable {
  static let defaultsKey = "sessions.kept.v1"
  private(set) var keys: Set<String> = []

  /// The agent's own session ID survives a restart of its process; the thread ID is the fallback.
  static func key(_ thread: AIThread) -> String {
    thread.sessionID.map { "session:" + $0 } ?? thread.id
  }

  func contains(_ key: String) -> Bool { keys.contains(key) }

  /// A pin made before the agent reported its session ID is stored under the thread ID, so either
  /// key keeps the thread.
  func contains(_ thread: AIThread) -> Bool {
    keys.contains(Self.key(thread)) || keys.contains(thread.id)
  }

  mutating func toggle(_ key: String) {
    if keys.remove(key) == nil { keys.insert(key) }
  }

  /// Unkeeping removes both keys; keeping adds the key the thread has now.
  mutating func toggle(_ thread: AIThread) {
    if contains(thread) {
      keys.remove(Self.key(thread))
      keys.remove(thread.id)
    } else {
      keys.insert(Self.key(thread))
    }
  }

  /// Drops thread-ID pins whose process is gone; a thread ID never comes back. Session pins stay,
  /// since the session can be resumed. Run on a user action after a complete scan only, so a
  /// missed scan loses no pin.
  mutating func prune(liveThreadIDs: Set<String>) {
    keys = keys.filter { $0.hasPrefix("session:") || liveThreadIDs.contains($0) }
  }

  static func load(_ defaults: UserDefaults = .standard) -> Self {
    Self(keys: Set(defaults.stringArray(forKey: defaultsKey) ?? []))
  }

  func save(_ defaults: UserDefaults = .standard) {
    defaults.set(keys.sorted(), forKey: Self.defaultsKey)
  }
}
