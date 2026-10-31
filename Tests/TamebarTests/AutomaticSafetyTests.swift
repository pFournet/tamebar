import Foundation
import Testing

@testable import Tamebar

/// P2: what ends or edits on its own is off on a new install, with empty lists; an install from
/// before P2 keeps both switches on. Every test uses its own in-memory defaults.
struct AutomaticSafetyTests {
  @Test func aNewInstallStartsOffWithEmptyLists() {
    let defaults = TestDefaults("safety-new").defaults
    #expect(AutomaticSafety.load(defaults) == AutomaticSafety())
    #expect(!SafeDefaultsMigration.migrate(defaults))
    let safety = AutomaticSafety.load(defaults)
    #expect(!safety.endIdleSessions && !safety.trimCodexPlugins)
    #expect(safety.protectedPorts.isEmpty && safety.keptCodexServers.isEmpty)
  }

  @Test func anInstallFromBeforeKeepsBothSwitchesOnOnce() {
    let defaults = TestDefaults("safety-old").defaults
    defaults.set(true, forKey: BrandMigration.copiedKey)
    #expect(SafeDefaultsMigration.migrate(defaults))
    var safety = AutomaticSafety.load(defaults)
    #expect(safety.endIdleSessions && safety.trimCodexPlugins)
    // Switched off later: a second launch doesn't switch it back on.
    safety.trimCodexPlugins = false
    safety.save(defaults)
    #expect(!SafeDefaultsMigration.migrate(defaults))
    #expect(!AutomaticSafety.load(defaults).trimCodexPlugins)
  }

  @Test func aValueAlreadyWrittenIsKept() {
    let defaults = TestDefaults("safety-kept").defaults
    defaults.set(true, forKey: BrandMigration.copiedKey)
    defaults.set(false, forKey: AutomaticSafety.Key.endIdleSessions)
    SafeDefaultsMigration.migrate(defaults)
    let safety = AutomaticSafety.load(defaults)
    #expect(!safety.endIdleSessions && safety.trimCodexPlugins)
  }

  @Test func listsRoundTripAndReadTolerantly() {
    let defaults = TestDefaults("safety-lists").defaults
    var safety = AutomaticSafety()
    safety.endIdleSessions = true
    safety.protectedPorts = [3000, 5173]
    safety.keptCodexServers = ["chat"]
    safety.save(defaults)
    #expect(AutomaticSafety.load(defaults) == safety)
    defaults.set(["8080", 0, 70_000, 8080, "x", 22], forKey: AutomaticSafety.Key.protectedPorts)
    defaults.set(["chat", "", 3, " inbox "], forKey: AutomaticSafety.Key.keptCodexServers)
    defaults.set("YES", forKey: AutomaticSafety.Key.trimCodexPlugins)
    let read = AutomaticSafety.load(defaults)
    #expect(read.protectedPorts == [8080, 22])
    #expect(read.keptCodexServers == ["chat", "inbox"])
    #expect(read.trimCodexPlugins)
    #expect(read.keptCodexKeys == ["server:chat", "server:inbox"])
  }

  @Test func settingsTextIsParsedAndShownBack() {
    #expect(AutomaticSafety.ports("3000, 5173 abc 0 3000,8080") == [3000, 5173, 8080])
    #expect(AutomaticSafety.names(" chat,inbox  chat ") == ["chat", "inbox"])
    #expect(AutomaticSafety.text([3000, 5173]) == "3000, 5173")
    #expect(AutomaticSafety.text([String]()) == "")
  }

  @Test func theProtectedPortsAreTheListPlusPortless() throws {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("tamebar-safety-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(ProtectedPorts.current(home: home, listed: []) == ProtectedPorts.proxy)
    let folder = home.appendingPathComponent(".portless")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(#"[{"hostname": "my-app", "port": 4100, "pid": 1}]"#.utf8)
      .write(to: folder.appendingPathComponent("routes.json"))
    #expect(
      ProtectedPorts.current(home: home, listed: [3000])
        == ProtectedPorts.proxy.union([3000, 4100]))
  }

  @Test func switchingIsMarkedOnTheTrend() {
    let old = UsageSettings(
      autoEnd: "ask", autoEndDays: 7, quitApps: [], autoPauseProjects: [],
      endIdleSessions: false, trimCodexPlugins: true)
    var new = old
    new.endIdleSessions = true
    new.trimCodexPlugins = false
    #expect(
      UsageSettings.changes(from: old, to: new, name: { $0 })
        == ["End idle sessions: on", "Turn off unused Codex plugins: off"])
    // A record from before P2 marks nothing.
    var before = old
    before.endIdleSessions = nil
    #expect(UsageSettings.changes(from: before, to: new, name: { $0 }).count == 1)
  }

  @Test func statusShowsTheSwitchesAndLists() {
    #expect(CLIText.automatic(.init()) == "watches and slows only")
    #expect(
      CLIText.automatic(
        .init(
          endIdleSessions: true, trimCodexPlugins: true, protectedPorts: [3000],
          keptCodexServers: ["chat"]))
        == "ends idle sessions · turns off unused Codex plugins · never ports 3000 · never Codex chat"
    )
  }
}
