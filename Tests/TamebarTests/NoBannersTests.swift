import Foundation
import Testing

@testable import Tamebar

/// No banners (2026-10-27): "the notification system is very bad, it's too spammy and I
/// want the app proactive not informative". Tamebar acts, then says what it did in a 4 s note in
/// the notch; it never posts a macOS notification.
struct NoBannersTests {
  /// Every Swift file under Sources, read from this file's place in the checkout.
  private static func sources() throws -> [(name: String, text: String)] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
    let files = try #require(
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    )
    .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
  }

  @Test func noSourcePostsOrAsksForANotification() throws {
    let sources = try Self.sources()
    #expect(sources.count > 50, "Sources not found")
    let banned = [
      "UNNotificationRequest", "UNUserNotificationCenter", "import UserNotifications",
      "NSUserNotification", "display notification",
    ]
    for (name, text) in sources {
      for word in banned {
        #expect(!text.contains(word), "\(name) uses \(word)")
      }
    }
  }

  struct DiskNote {
    let gb: UInt64 = 1_000_000_000

    /// One note when free space crosses into low; nothing while it stays low, gets worse, or dips
    /// back above the reserve by less than the margin; again once it has recovered and goes low.
    @Test func oneNotePerLowEpisode() {
      var note = DiskLowNote()
      #expect(note.next(available: 50 * gb) == nil)
      #expect(note.next(available: 29 * gb) == "Disk reserve low · 29 GB free")
      #expect(note.next(available: 28 * gb) == nil)
      #expect(note.next(available: 10 * gb) == nil, "worse, same episode")
      #expect(note.next(available: 30 * gb) == nil, "back at the reserve, not recovered")
      #expect(note.next(available: 29 * gb) == nil)
      #expect(note.next(available: 31 * gb) == nil, "recovered: the episode ends")
      #expect(note.next(available: 31 * gb) == nil)
      #expect(note.next(available: 4 * gb) == "Disk almost full · 4 GB free")
    }

    /// Low at the first reading (Tamebar launched on a full disk) is an episode too.
    @Test func lowAtTheFirstReadingShowsOnce() {
      var note = DiskLowNote()
      #expect(note.next(available: 12 * gb) == "Disk filling up · 12 GB free")
      #expect(note.next(available: 12 * gb) == nil)
    }

    /// The model turns a low disk into its island note once, then leaves it alone.
    @Test @MainActor func theModelShowsTheDiskNoteOnce() {
      let model = DevProcessModel()
      let now = Date(timeIntervalSince1970: 1_800_000_000)
      model.noteDisk(free: 50 * gb, now: now)
      #expect(model.note == nil)
      model.noteDisk(free: 20 * gb, now: now.addingTimeInterval(2))
      #expect(model.note?.text == "Disk reserve low · 20 GB free")
      #expect(model.note?.at == now.addingTimeInterval(2))
      model.noteDisk(free: 19 * gb, now: now.addingTimeInterval(4))
      #expect(model.note?.at == now.addingTimeInterval(2), "no second note this episode")
      let state = IslandState.resolve(
        model.islandFacts(now: now.addingTimeInterval(3), freeBytes: 0), on: .notch
      ) { false }
      #expect(state == .note("Disk reserve low · 20 GB free"))
    }
  }
}
