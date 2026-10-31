import Foundation

/// Where Tamebar keeps its local files: `~/Library/Application Support/Tamebar`.
/// The e2e build keeps its own folder, so it never fills the release app's before the first copy.
/// A test host gets a fresh temporary folder per run, so no test ever writes the real one.
enum AppData {
  static var directory: URL {
    if let testDirectory { return testDirectory }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Application Support/\(directoryName(bundleIdentifier: Bundle.main.bundleIdentifier))",
        isDirectory: true)
  }

  /// This run's folder when the process is a test host, removed when the process exits.
  private static let testDirectory: URL? = {
    guard
      isTestHost(
        process: ProcessInfo.processInfo.processName,
        environment: ProcessInfo.processInfo.environment,
        xctestLoaded: NSClassFromString("XCTestCase") != nil,
        bundleIdentifier: Bundle.main.bundleIdentifier)
    else { return nil }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("TamebarTests-AppData-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    atexit { if let url = AppData.testDirectory { try? FileManager.default.removeItem(at: url) } }
    return url
  }()

  /// `swift test` runs Swift Testing in `swiftpm-testing-helper` and XCTest in `xctest`; Xcode
  /// sets `XCTestConfigurationFilePath`. Both load XCTest, which the app never does.
  /// The shipped app is never a test host: an app launched from a test run inherits
  /// `XCTestConfigurationFilePath`, and must still use the real folder.
  static func isTestHost(
    process: String, environment: [String: String], xctestLoaded: Bool,
    bundleIdentifier: String?
  ) -> Bool {
    if xctestLoaded || ["xctest", "swiftpm-testing-helper"].contains(process) { return true }
    return bundleIdentifier != AppBrand.bundleIdentifier
      && environment["XCTestConfigurationFilePath"] != nil
  }

  static func directoryName(bundleIdentifier: String?) -> String {
    isE2E(bundleIdentifier) ? "Tamebar-e2e" : "Tamebar"
  }

  static func isE2E(_ bundleIdentifier: String?) -> Bool {
    bundleIdentifier?.hasSuffix(".e2e") == true
  }

  /// BlitzClean's folder. Tamebar only reads it: BlitzClean may still be running and using it.
  static var previousDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/BlitzClean", isDirectory: true)
  }

  static func file(_ name: String) -> URL {
    directory.appendingPathComponent(name)
  }

  struct CopyInput {
    let previous: URL
    let current: URL
  }

  /// Copies files from the previous folder without replacing anything already in the current one.
  /// The previous folder is left exactly as it was. Lock files are skipped, and so is `reports/`:
  /// BlitzClean's cleanup reports fed the removal log, which N11 removed.
  static func copyPreviousFiles(_ input: CopyInput) {
    copyMissing(input, skipping: ["reports"])
  }

  private static func copyMissing(_ input: CopyInput, skipping: Set<String> = []) {
    let manager = FileManager.default
    guard
      let items = try? manager.contentsOfDirectory(
        at: input.previous, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    else { return }
    try? manager.createDirectory(at: input.current, withIntermediateDirectories: true)
    for item in items
    where item.pathExtension != "lock" && !skipping.contains(item.lastPathComponent) {
      let destination = input.current.appendingPathComponent(item.lastPathComponent)
      let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      if values?.isDirectory == true, values?.isSymbolicLink != true {
        copyMissing(.init(previous: item, current: destination))
      } else if (try? destination.checkResourceIsReachable()) != true,
        (try? manager.destinationOfSymbolicLink(atPath: destination.path)) == nil
      {
        try? manager.copyItem(at: item, to: destination)
      }
    }
  }
}
