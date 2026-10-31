import Foundation

enum BrandMigration {
  struct CopyInput {
    let previous: [String: Any]
    let target: UserDefaults
  }

  static let previousDomain = "com.blitzreels.BlitzClean"
  static let copiedKey = "tamebar.copiedFromBlitzClean"
  static let copiedFilesKey = "tamebar.copiedFilesFromBlitzClean"
  private static let systemPrefixes = ["NS", "SU", "Apple", "com.apple."]
  /// BlitzClean's own migration flag and its storage scan caches.
  private static let skippedKeys: Set<String> = [
    "blitzclean.migrated", "storage-scan-result-v5", "storage-scan-result-v6",
  ]

  /// Only the installed app copies: the e2e build starts clean, and a bare `swift run` (no bundle
  /// id) never touches the real folders.
  static func shouldRun(bundleIdentifier: String?) -> Bool {
    bundleIdentifier != nil && !AppData.isE2E(bundleIdentifier)
  }

  /// Copies BlitzClean's settings and files once. BlitzClean keeps its own, so both apps can run
  /// side by side.
  static func run() {
    guard shouldRun(bundleIdentifier: Bundle.main.bundleIdentifier) else { return }
    let defaults = UserDefaults.standard
    copyPreviousSettings(
      .init(previous: defaults.persistentDomain(forName: previousDomain) ?? [:], target: defaults))
    guard !defaults.bool(forKey: copiedFilesKey) else { return }
    AppData.copyPreviousFiles(
      .init(previous: AppData.previousDirectory, current: AppData.directory))
    // Set even after a partial copy: the copy is one-time and best-effort.
    defaults.set(true, forKey: copiedFilesKey)
  }

  /// Copies BlitzClean's settings once without replacing any Tamebar already has.
  static func copyPreviousSettings(_ input: CopyInput) {
    guard !input.target.bool(forKey: copiedKey) else { return }
    for (key, value) in input.previous
    where !skippedKeys.contains(key) && !systemPrefixes.contains(where: { key.hasPrefix($0) }) {
      if input.target.object(forKey: key) == nil { input.target.set(value, forKey: key) }
    }
    input.target.set(true, forKey: copiedKey)
  }
}
