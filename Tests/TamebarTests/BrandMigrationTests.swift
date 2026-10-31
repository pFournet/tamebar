import Foundation
import Testing

@testable import Tamebar

struct BrandMigrationTests {
  private let manager = FileManager.default

  @Test func copiesBlitzCleanSettingsOnceWithoutOverwriting() throws {
    let source = TestDefaults("blitz-src")
    let target = TestDefaults("tamebar-dst")
    source.defaults.set(["/code/app"], forKey: "pressure.autoPauseProjects.v1")
    source.defaults.set("memory", forKey: "navigation.page")
    source.defaults.set("{0, 0, 10, 10}", forKey: "NSWindow Frame TamebarTest")
    source.defaults.set(true, forKey: "SUTamebarTestKey")
    source.defaults.set("en", forKey: "AppleTamebarTestKey")
    source.defaults.set(1, forKey: "com.apple.tamebar.test")
    source.defaults.set(true, forKey: "blitzclean.migrated")
    source.defaults.set(Data([1]), forKey: "storage-scan-result-v6")
    target.defaults.set("cpu", forKey: "navigation.page")
    let previous = try #require(source.defaults.persistentDomain(forName: source.suite))
    let input = BrandMigration.CopyInput(previous: previous, target: target.defaults)

    BrandMigration.copyPreviousSettings(input)

    #expect(target.defaults.stringArray(forKey: "pressure.autoPauseProjects.v1") == ["/code/app"])
    #expect(target.defaults.string(forKey: "navigation.page") == "cpu")
    #expect(target.defaults.object(forKey: "NSWindow Frame TamebarTest") == nil)
    #expect(target.defaults.object(forKey: "SUTamebarTestKey") == nil)
    #expect(target.defaults.object(forKey: "AppleTamebarTestKey") == nil)
    #expect(target.defaults.object(forKey: "com.apple.tamebar.test") == nil)
    #expect(target.defaults.object(forKey: "blitzclean.migrated") == nil)
    #expect(target.defaults.object(forKey: "storage-scan-result-v6") == nil)
    #expect(source.defaults.string(forKey: "navigation.page") == "memory")
    target.defaults.removeObject(forKey: "pressure.autoPauseProjects.v1")
    BrandMigration.copyPreviousSettings(input)
    #expect(target.defaults.object(forKey: "pressure.autoPauseProjects.v1") == nil)
  }

  @Test func copiesPreviousFilesWithoutOverwritingOrChangingThePreviousFolder() throws {
    let root = manager.temporaryDirectory.appendingPathComponent(
      "tamebar-brand-\(UUID().uuidString)", isDirectory: true)
    defer { try? manager.removeItem(at: root) }
    let previous = root.appendingPathComponent("BlitzClean", isDirectory: true)
    let current = root.appendingPathComponent("Tamebar", isDirectory: true)
    try manager.createDirectory(
      at: previous.appendingPathComponent("reports"), withIntermediateDirectories: true)
    try manager.createDirectory(at: current, withIntermediateDirectories: true)
    try Data("old history".utf8).write(to: previous.appendingPathComponent("cleanup-history.json"))
    try Data("old chart".utf8).write(to: previous.appendingPathComponent("resource-history.json"))
    try Data("{}".utf8).write(to: previous.appendingPathComponent("reports/agent.json"))
    try manager.createDirectory(
      at: previous.appendingPathComponent("charts"), withIntermediateDirectories: true)
    try Data("week".utf8).write(to: previous.appendingPathComponent("charts/week.json"))
    try Data("".utf8).write(to: previous.appendingPathComponent("cleanup-history.json.lock"))
    try Data("".utf8).write(to: previous.appendingPathComponent("charts/week.json.lock"))
    try Data("new chart".utf8).write(to: current.appendingPathComponent("resource-history.json"))
    let before = try snapshot(previous)

    AppData.copyPreviousFiles(.init(previous: previous, current: current))

    #expect(try text(current.appendingPathComponent("cleanup-history.json")) == "old history")
    #expect(try text(current.appendingPathComponent("resource-history.json")) == "new chart")
    #expect(try text(current.appendingPathComponent("charts/week.json")) == "week")
    #expect(!manager.fileExists(atPath: current.appendingPathComponent("reports").path))
    #expect(
      !manager.fileExists(atPath: current.appendingPathComponent("cleanup-history.json.lock").path))
    #expect(
      !manager.fileExists(atPath: current.appendingPathComponent("charts/week.json.lock").path))
    #expect(try snapshot(previous) == before)
  }

  @Test func copyingFromAMissingFolderCreatesNothing() throws {
    let root = manager.temporaryDirectory.appendingPathComponent(
      "tamebar-brand-\(UUID().uuidString)", isDirectory: true)
    defer { try? manager.removeItem(at: root) }
    let current = root.appendingPathComponent("Tamebar")
    AppData.copyPreviousFiles(
      .init(previous: root.appendingPathComponent("BlitzClean"), current: current))
    #expect(!manager.fileExists(atPath: current.path))
  }

  @Test func onlyTheInstalledAppMigratesAndTheE2EBuildKeepsItsOwnFolder() {
    #expect(BrandMigration.shouldRun(bundleIdentifier: "com.tamebar.Tamebar"))
    #expect(!BrandMigration.shouldRun(bundleIdentifier: "com.tamebar.Tamebar.e2e"))
    #expect(!BrandMigration.shouldRun(bundleIdentifier: nil))
    #expect(AppData.directoryName(bundleIdentifier: "com.tamebar.Tamebar") == "Tamebar")
    #expect(AppData.directoryName(bundleIdentifier: "com.tamebar.Tamebar.e2e") == "Tamebar-e2e")
    #expect(AppData.directoryName(bundleIdentifier: nil) == "Tamebar")
  }

  @Test func testsNeverResolveTheRealAppDataFolder() {
    let support = manager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support").resolvingSymlinksInPath().path
    for url in [AppData.directory, AppData.file("drive-breakdown.json")] {
      let path = url.resolvingSymlinksInPath().path
      #expect(!path.hasPrefix(support + "/Tamebar"), "\(path)")
      #expect(!path.hasPrefix(support + "/BlitzClean"), "\(path)")
    }
    #expect(AppData.directory == AppData.directory, "one folder for the whole run")
    func isTestHost(
      _ process: String, _ environment: [String: String] = [:], xctest: Bool = false,
      id: String? = nil
    ) -> Bool {
      AppData.isTestHost(
        process: process, environment: environment, xctestLoaded: xctest, bundleIdentifier: id)
    }
    #expect(isTestHost("swiftpm-testing-helper"))
    #expect(isTestHost("xctest"))
    #expect(isTestHost("Tamebar", ["XCTestConfigurationFilePath": "/x"]))
    #expect(isTestHost("Tamebar", ["XCTestConfigurationFilePath": "/x"], id: "com.tamebar.e2e"))
    #expect(isTestHost("Tamebar", xctest: true))
    #expect(!isTestHost("Tamebar"))
  }

  @Test func theShippedAppIgnoresAnInheritedTestConfiguration() {
    let inherited = ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]
    #expect(
      !AppData.isTestHost(
        process: "Tamebar", environment: inherited, xctestLoaded: false,
        bundleIdentifier: AppBrand.bundleIdentifier))
    #expect(
      !AppData.isTestHost(
        process: "Tamebar", environment: [:], xctestLoaded: false,
        bundleIdentifier: AppBrand.bundleIdentifier))
    #expect(
      AppData.isTestHost(
        process: "Tamebar", environment: inherited, xctestLoaded: false,
        bundleIdentifier: AppBrand.bundleIdentifier + ".e2e"),
      "only the shipped id is exempt")
  }

  private func text(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
  }

  /// Relative path of every file and folder under `root`, with each file's bytes.
  private func snapshot(_ root: URL) throws -> [String: Data?] {
    var result: [String: Data?] = [:]
    for item in try manager.subpathsOfDirectory(atPath: root.path) {
      let url = root.appendingPathComponent(item)
      var isDirectory: ObjCBool = false
      _ = manager.fileExists(atPath: url.path, isDirectory: &isDirectory)
      result.updateValue(isDirectory.boolValue ? nil : try Data(contentsOf: url), forKey: item)
    }
    return result
  }
}
