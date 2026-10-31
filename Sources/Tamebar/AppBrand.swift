import AppKit
import SwiftUI

enum AppBrand {
  static let name = "Tamebar"
  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "Development"
  }
  /// The short commit build-app.sh stamps into Info.plist (`TamebarCommit`); nil outside a bundle.
  static var commit: String? {
    (Bundle.main.object(forInfoDictionaryKey: "TamebarCommit") as? String).flatMap {
      $0.isEmpty ? nil : $0
    }
  }
  static let accent = BlitzUI.mint
  static let bundleIdentifier = "com.tamebar.Tamebar"
  @MainActor static let icon = resourceImage("AppIcon.icns")
  @MainActor static let mark = resourceImage("Mark.svg")
  static let websiteURL = URL(string: "https://github.com/pFournet/tamebar")!
  static var aboutCaption: String {
    "\(name) \(version). Based on BlitzClean (MIT). Your data stays on your Mac."
  }

  /// The MIT notice that build-app.sh copies into Resources; absent outside the app bundle.
  static func licenseURL(in bundle: Bundle = .main) -> URL? {
    bundle.url(forResource: "LICENSE", withExtension: "txt")
  }

  /// Tamebar itself: the shipped id, any id under it (the e2e build and both Emergency helpers),
  /// or the id this build runs as, so no copy offers to quit or resume itself or another.
  static func isOwn(_ identifier: String?, running: String? = Bundle.main.bundleIdentifier) -> Bool
  {
    guard let identifier else { return false }
    return identifier == bundleIdentifier || identifier.hasPrefix(bundleIdentifier + ".")
      || identifier == running
  }

  /// The shipped app, or the e2e build in e2e mode, which runs the same code. Gates persistence
  /// and automatic work that `swift run` and test hosts must skip.
  static var isInstalledBuild: Bool {
    isInstalledBuild(running: Bundle.main.bundleIdentifier, e2e: E2EMode.current != nil)
  }

  static func isInstalledBuild(running: String?, e2e: Bool) -> Bool {
    running == bundleIdentifier || e2e
  }

  /// The shipped app only: never the e2e build. Gates what reaches the user or acts on its own,
  /// such as notifications and project auto-pause.
  static var isShippedApp: Bool { Bundle.main.bundleIdentifier == bundleIdentifier }

  /// An image bundled in the app's Resources; absent when running outside the app bundle.
  @MainActor static func resourceImage(_ file: String) -> NSImage? {
    let name = (file as NSString).deletingPathExtension
    let ext = (file as NSString).pathExtension
    return Bundle.main.url(forResource: name, withExtension: ext).flatMap(NSImage.init(contentsOf:))
  }
}
