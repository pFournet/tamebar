import Testing

@testable import Tamebar

struct SessionKeepsTests {
  @Test func keyPrefersSessionIDThenThreadID() {
    var thread = AIThread(
      id: "cursorAgent-9-100", tool: .cursorAgent, name: "x", directory: nil, terminal: nil,
      startedAt: nil, processIDs: [9], memoryBytes: 0, cpuPercent: 0, isPaused: false,
      isDetached: false)
    #expect(SessionKeeps.key(thread) == "cursorAgent-9-100")
    thread.sessionID = "abc"
    #expect(SessionKeeps.key(thread) == "session:abc")
  }

  @Test func toggleIsPersisted() {
    let store = TestDefaults("keeps")
    var keeps = SessionKeeps.load(store.defaults)
    keeps.toggle("session:abc")
    keeps.save(store.defaults)
    #expect(SessionKeeps.load(store.defaults).contains("session:abc"))
  }

  @Test func togglingTwiceRemovesTheKeepAndPersistsTheRemoval() {
    let store = TestDefaults("keeps")
    var keeps = SessionKeeps.load(store.defaults)
    keeps.toggle("session:abc")
    keeps.save(store.defaults)
    var reloaded = SessionKeeps.load(store.defaults)
    reloaded.toggle("session:abc")
    reloaded.save(store.defaults)
    #expect(!reloaded.contains("session:abc"))
    #expect(!SessionKeeps.load(store.defaults).contains("session:abc"))
    #expect(SessionKeeps.load(store.defaults) == SessionKeeps())
  }

  func cursor(_ id: String) -> AIThread {
    AIThread(
      id: id, tool: .cursorAgent, name: "x", directory: nil, terminal: nil, startedAt: nil,
      processIDs: [9], memoryBytes: 0, cpuPercent: 0, isPaused: false, isDetached: false)
  }

  @Test func aPinMadeBeforeTheSessionIDAppearsStillApplies() {
    var thread = cursor("cursorAgent-9-100")
    var keeps = SessionKeeps()
    keeps.toggle(thread)
    #expect(keeps.contains("cursorAgent-9-100"))
    thread.sessionID = "abc"
    #expect(keeps.contains(thread))
    keeps.toggle(thread)
    #expect(!keeps.contains(thread))
    #expect(keeps == SessionKeeps())
  }

  @Test func keepingAddsTheKeyTheThreadHasNowAndUnkeepingRemovesBoth() {
    var thread = cursor("cursorAgent-9-100")
    thread.sessionID = "abc"
    var keeps = SessionKeeps()
    keeps.toggle(thread)
    #expect(keeps.contains("session:abc"))
    #expect(!keeps.contains("cursorAgent-9-100"))
    keeps.toggle("cursorAgent-9-100")
    keeps.toggle(thread)
    #expect(keeps == SessionKeeps())
  }

  @Test func pruneDropsOnlyThreadIDPinsWithNoLiveThread() {
    var keeps = SessionKeeps()
    for key in ["session:abc", "cursorAgent-9-100", "cursorAgent-8-50"] { keeps.toggle(key) }
    keeps.prune(liveThreadIDs: ["cursorAgent-9-100"])
    #expect(keeps.contains("session:abc"))
    #expect(keeps.contains("cursorAgent-9-100"))
    #expect(!keeps.contains("cursorAgent-8-50"))
  }
}
