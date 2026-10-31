import Foundation

/// A throwaway defaults store for one test. It is a `UserDefaults` that keeps everything in
/// memory, so the code under test takes it as it is, and nothing reaches cfprefsd: no
/// `TamebarTests-*` plist is ever written to ~/Library/Preferences.
struct TestDefaults {
  /// A unique name, for the persistent-domain calls and for folders a test names after it.
  let suite: String
  let defaults: UserDefaults

  /// `suffix` lets a suite pass as a build id, e.g. `.e2e`; the name still starts `TamebarTests-`.
  init(_ prefix: String, suffix: String = "") {
    suite = "TamebarTests-\(prefix)-\(UUID().uuidString)\(suffix)"
    defaults = MemoryDefaults(name: suite)!
  }
}

/// `UserDefaults` in memory. Every read and write goes through the overrides below; none falls
/// through to the real domains.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Any] = [:]
  private var registered: [String: Any] = [:]
  private let name: String

  init?(name: String) {
    self.name = name
    super.init(suiteName: nil)
  }

  override func object(forKey defaultName: String) -> Any? {
    lock.withLock { values[defaultName] ?? registered[defaultName] }
  }

  override func set(_ value: Any?, forKey defaultName: String) {
    lock.withLock { values[defaultName] = value }
  }

  override func removeObject(forKey defaultName: String) {
    lock.withLock { values[defaultName] = nil }
  }

  override func register(defaults registrationDictionary: [String: Any]) {
    lock.withLock { registered.merge(registrationDictionary) { $1 } }
  }

  override func set(_ value: Int, forKey defaultName: String) {
    set(value as Any, forKey: defaultName)
  }
  override func set(_ value: Float, forKey defaultName: String) {
    set(value as Any, forKey: defaultName)
  }
  override func set(_ value: Double, forKey defaultName: String) {
    set(value as Any, forKey: defaultName)
  }
  override func set(_ value: Bool, forKey defaultName: String) {
    set(value as Any, forKey: defaultName)
  }
  override func set(_ url: URL?, forKey defaultName: String) {
    set(url as Any?, forKey: defaultName)
  }

  override func string(forKey defaultName: String) -> String? {
    switch object(forKey: defaultName) {
    case let string as String: string
    case let number as NSNumber: number.stringValue
    default: nil
    }
  }

  override func array(forKey defaultName: String) -> [Any]? {
    object(forKey: defaultName) as? [Any]
  }

  override func dictionary(forKey defaultName: String) -> [String: Any]? {
    object(forKey: defaultName) as? [String: Any]
  }

  override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }

  override func stringArray(forKey defaultName: String) -> [String]? {
    object(forKey: defaultName) as? [String]
  }

  override func integer(forKey defaultName: String) -> Int { number(defaultName)?.intValue ?? 0 }
  override func float(forKey defaultName: String) -> Float { number(defaultName)?.floatValue ?? 0 }
  override func double(forKey defaultName: String) -> Double {
    number(defaultName)?.doubleValue ?? 0
  }
  override func bool(forKey defaultName: String) -> Bool { number(defaultName)?.boolValue ?? false }

  override func url(forKey defaultName: String) -> URL? {
    switch object(forKey: defaultName) {
    case let url as URL: url
    case let path as String: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    default: nil
    }
  }

  override func dictionaryRepresentation() -> [String: Any] {
    lock.withLock { registered.merging(values) { $1 } }
  }

  override func persistentDomain(forName domainName: String) -> [String: Any]? {
    domainName == name ? lock.withLock { values } : nil
  }

  override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {
    guard domainName == name else { return }
    lock.withLock { values = domain }
  }

  override func removePersistentDomain(forName domainName: String) {
    guard domainName == name else { return }
    lock.withLock { values = [:] }
  }

  override func synchronize() -> Bool { true }

  /// As `NSUserDefaults` reads a number: an `NSNumber`, or a string such as "5" or "YES".
  private func number(_ key: String) -> NSNumber? {
    switch object(forKey: key) {
    case let number as NSNumber: number
    case let string as String:
      ["yes", "true"].contains(string.lowercased())
        ? 1 : ["no", "false"].contains(string.lowercased()) ? 0 : Double(string).map(NSNumber.init)
    default: nil
    }
  }
}
