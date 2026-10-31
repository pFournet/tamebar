import Foundation
import Testing

@testable import Tamebar

struct BrandTests {
  @Test func identityIsTamebar() {
    #expect(AppBrand.name == "Tamebar")
    #expect(AppBrand.bundleIdentifier == "com.tamebar.Tamebar")
    #expect(AppBrand.websiteURL.absoluteString == "https://github.com/pFournet/tamebar")
  }

  @Test func aboutCaptionCreditsBlitzClean() {
    #expect(
      AppBrand.aboutCaption
        == "Tamebar \(AppBrand.version). Based on BlitzClean (MIT). Your data stays on your Mac.")
  }

  @Test func licenseLinkFindsTheBundledNotice() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("BrandTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let withNotice = root.appendingPathComponent("WithNotice.bundle", isDirectory: true)
    let withoutNotice = root.appendingPathComponent("WithoutNotice.bundle", isDirectory: true)
    for bundle in [withNotice, withoutNotice] {
      try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    }
    let notice = withNotice.appendingPathComponent("LICENSE.txt")
    try Data("MIT License".utf8).write(to: notice)

    let present = try #require(Bundle(url: withNotice))
    let missing = try #require(Bundle(url: withoutNotice))
    let found = try #require(AppBrand.licenseURL(in: present))
    #expect(found.standardizedFileURL == notice.standardizedFileURL)
    #expect(AppBrand.licenseURL(in: missing) == nil)
  }

  @Test func ownProcessIsExcludedByBrandName() {
    let own = ResourceProcess.fixture(name: AppBrand.name)
    let consumers = ResourceConsumers.build(.init(threads: [], resources: [own], stopped: []))
    #expect(consumers.isEmpty)
  }

  @Test func sameProcessUnderAnotherNameIsListed() {
    let other = ResourceProcess.fixture(name: "Other")
    let consumers = ResourceConsumers.build(.init(threads: [], resources: [other], stopped: []))
    #expect(consumers.map(\.name) == ["Other"])
  }

  @Test func ownAppIsTheShippedIdOrTheIdThisBuildRunsAs() {
    let e2e = "com.tamebar.Tamebar.e2e"
    #expect(AppBrand.isOwn("com.tamebar.Tamebar", running: e2e))
    #expect(AppBrand.isOwn(e2e, running: e2e))
    #expect(!AppBrand.isOwn("com.example.Editor", running: e2e))
    #expect(!AppBrand.isOwn(nil, running: nil))
  }

  /// The installed app must never offer to quit or resume the e2e build or either Emergency helper.
  @Test func installedAppTreatsEveryTamebarIdAsOwn() {
    let installed = "com.tamebar.Tamebar"
    for id in [
      installed, "com.tamebar.Tamebar.e2e", "com.tamebar.Tamebar.Emergency",
      "com.tamebar.Tamebar.e2e.Emergency",
    ] {
      #expect(AppBrand.isOwn(id, running: installed), "\(id)")
    }
    #expect(!AppBrand.isOwn("com.tamebar.TamebarPro", running: installed))
    #expect(!AppBrand.isOwn("com.tamebar.Other", running: installed))
    #expect(!AppBrand.isOwn("com.example.Editor", running: installed))
  }

  @Test func installedBuildIsTheShippedIdOrE2EMode() {
    #expect(AppBrand.isInstalledBuild(running: "com.tamebar.Tamebar", e2e: false))
    #expect(AppBrand.isInstalledBuild(running: "com.tamebar.Tamebar.e2e", e2e: true))
    #expect(!AppBrand.isInstalledBuild(running: "com.tamebar.Tamebar.e2e", e2e: false))
    #expect(!AppBrand.isInstalledBuild(running: nil, e2e: false))
  }

  @Test func emergencyNotificationIsNamedAfterTheParentApp() {
    let installed = EmergencyControlsLauncher.notificationName(bundleID: "com.tamebar.Tamebar")
    #expect(installed.rawValue == "com.tamebar.Tamebar.emergency.show")
    #expect(
      EmergencyControlsLauncher.notificationName(bundleID: "com.tamebar.Tamebar.Emergency")
        == installed)
    let e2e = EmergencyControlsLauncher.notificationName(bundleID: "com.tamebar.Tamebar.e2e")
    #expect(e2e.rawValue == "com.tamebar.Tamebar.e2e.emergency.show")
    #expect(
      EmergencyControlsLauncher.notificationName(bundleID: "com.tamebar.Tamebar.e2e.Emergency")
        == e2e)
    #expect(EmergencyControlsLauncher.notificationName(bundleID: nil) == installed)
  }

  /// Memory Rescue lists apps to quit; neither copy may list the other.
  @Test func memoryRescueNeverOffersToQuitAnotherTamebar() {
    func reason(_ app: String, running: String) -> String? {
      MemoryAppProtection.reason(
        .init(
          processID: 200, bundleIdentifier: app, bundlePath: "/Users/me/dist/e2e/Tamebar.app",
          currentProcessID: 100, currentBundleIdentifier: running))
    }
    let installed = "com.tamebar.Tamebar"
    let e2e = "com.tamebar.Tamebar.e2e"
    #expect(reason(e2e, running: installed) == "Tamebar stays running during rescue")
    #expect(reason(installed, running: e2e) == "Tamebar stays running during rescue")
    #expect(reason("\(e2e).Emergency", running: installed) != nil)
    #expect(reason("com.example.Notes", running: installed) == nil)
  }
}
