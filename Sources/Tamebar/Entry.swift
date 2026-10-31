import Foundation

@main
enum TamebarEntry {
  @MainActor static func main() {
    // `tamebar status|sessions|history|trend|mark|help`: nothing of the app starts; only `mark`
    // writes, one line in usage-markers.jsonl.
    let arguments = Array(CommandLine.arguments.dropFirst())
    if CLI.wants(arguments) {
      exit(CLI.run(arguments, CLILive.environment()))
    }
    guard !CommandLine.arguments.contains("--purge-memory") else {
      return
    }
    // The helper's id is the app's plus `.Emergency`; build-app.sh can override the app's id.
    if CommandLine.arguments.contains("--emergency-controls")
      || Bundle.main.bundleIdentifier?.hasSuffix(".Emergency") == true
    {
      EmergencyControls.run()
      return
    }
    E2EMode.resetAtLaunch()
    // First: it tells a Tamebar that ran before by the brand migration's flag.
    SafeDefaultsMigration.run()
    BrandMigration.run()
    EmergencyControlsLauncher.start()
    TamebarApp.main()
  }
}
