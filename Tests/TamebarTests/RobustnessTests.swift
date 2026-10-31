import Foundation
import Testing

@testable import Tamebar

struct RobustnessTests {
  @Test
  func unreadableSettingEntriesKeepTheRestAndAreBackedUp() throws {
    let temporary = TestDefaults("saved-settings")
    let key = "workspace.preferences.v1"
    let stored = Data(
      """
      [{"directory":"/a","name":"A","keepRunning":true},{"directory":"/b"}]
      """.utf8)
    temporary.defaults.set(stored, forKey: key)
    let read: [WorkspacePreference]? = SavedSettings.list(
      .init(key: key, defaults: temporary.defaults))
    #expect(read?.map(\.directory) == ["/a"])
    #expect(temporary.defaults.data(forKey: key + ".unreadable") == stored)
  }

  @Test
  func settingsThatAreNotAListReadAsUnknown() {
    let temporary = TestDefaults("saved-settings")
    temporary.defaults.set(Data("{}".utf8), forKey: "list")
    let read: [WorkspacePreference]? = SavedSettings.list(
      .init(key: "list", defaults: temporary.defaults))
    #expect(read == nil)
    let empty: [WorkspacePreference]? = SavedSettings.list(
      .init(key: "missing", defaults: temporary.defaults))
    #expect(empty == [])
  }

  @Test
  func claudeProjectFoldersReplaceEveryNonASCIICharacter() {
    #expect(
      AIThreadNames.claudeProjectFolder("/Users/me/Développement/app")
        == "-Users-me-D-veloppement-app")
    #expect(AIThreadNames.claudeProjectFolder("/a b/c.d") == "-a-b-c-d")
  }

  @Test
  func claudeInstalledUnderApplicationSupportIsRecognised() throws {
    let record = RawProcessRecord(
      processID: 4_242, parentProcessID: 1, userID: 501, cpuPercent: 1, residentKilobytes: 1_024,
      elapsed: "01:00", terminal: "ttys001",
      arguments:
        "/Users/me/Library/Application Support/Claude/claude-code/2.1.295/claude --session-id abc")
    let process = try #require(
      DevProcessClassifier.classify(
        .init(
          record: record, listeningPorts: [], workingDirectory: "/Users/me/dev", memoryBytes: nil)
      ))
    #expect(process.kind == .claudeCode)
  }
}
