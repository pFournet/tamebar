import Foundation
import Testing

@testable import Tamebar

/// The daily usage record (Q16): accumulation, days, retention, baseline, markers, comparison and
/// the `tamebar trend` and `mark` commands.
enum UsageTrendTests {}

// MARK: Fixtures

private let gb: UInt64 = 1_000_000_000

private func calendar(_ zone: String = "Europe/Paris") -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: zone)!
  return calendar
}

private func date(_ text: String, _ zone: String = "Europe/Paris") -> Date {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(identifier: zone)!
  formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
  return formatter.date(from: text)!
}

private func reading(
  _ at: Date, present: Bool = true, risk: MemoryRisk = .normal, cpu: Bool = false,
  hot: Bool = false, swap: UInt64? = 10 * gb, available: UInt64? = 4 * gb,
  memory: Double? = 80, cpuPercent: Double? = 30, sessions: Int? = 10,
  sessionBytes: UInt64? = 8 * gb
) -> UsageReading {
  UsageReading(
    date: at, present: present, risk: risk, cpuStrained: cpu, hot: hot, swapBytes: swap,
    availableBytes: available, memoryPercent: memory, cpuPercent: cpuPercent, sessions: sessions,
    sessionBytes: sessionBytes)
}

/// Readings every `step` seconds from `start` for `count` steps, each made by `make`.
private func feed(
  _ record: inout UsageRecord, from start: Date, step: TimeInterval = 2, count: Int,
  calendar: Calendar, last: UsageReading? = nil, make: (Date) -> UsageReading = { reading($0) }
) -> UsageReading? {
  var previous = last
  for index in 0..<count {
    let next = make(start.addingTimeInterval(Double(index) * step))
    record.observe(next, after: previous, calendar: calendar)
    previous = next
  }
  return previous
}

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("TamebarTests-Usage-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// A live day with the mockup's figures.
private func liveDay(
  _ day: String, inUseHours: Double = 9, pressureMinutes: Double, criticalMinutes: Double,
  swapGB: UInt64, sessions: Double, sessionGB: UInt64, actions: UsageActions = .init()
) -> UsageDay {
  var value = UsageDay(day: day)
  value.awakeSeconds = inUseHours * 3_600
  value.inUseSeconds = inUseHours * 3_600
  value.criticalSeconds = criticalMinutes * 60
  value.warningSeconds = (pressureMinutes - criticalMinutes) * 60
  value.swapPeakBytes = swapGB * gb
  value.swapSeconds = value.awakeSeconds
  value.swapByteSeconds = Double(swapGB * gb) / 2 * value.awakeSeconds
  value.sessionSeconds = value.awakeSeconds
  value.sessionCountSeconds = sessions * value.awakeSeconds
  value.sessionMemoryByteSeconds = Double(sessionGB * gb) * value.awakeSeconds
  value.actions = actions
  return value
}

// MARK: Accumulation

extension UsageTrendTests {
  struct Accumulation {
    @Test func inUseTimeCountsPressureCPUAndHeatAtThePreviousReadingsState() throws {
      let calendar = calendar()
      var record = UsageRecord()
      let start = date("2026-10-20 10:00:00")
      // 60 s normal, 60 s warning, 30 s critical with CPU saturated and hot.
      var last = feed(&record, from: start, count: 30, calendar: calendar)
      last = feed(
        &record, from: start.addingTimeInterval(60), count: 30, calendar: calendar, last: last
      ) { reading($0, risk: .warning) }
      last = feed(
        &record, from: start.addingTimeInterval(120), count: 15, calendar: calendar, last: last
      ) { reading($0, risk: .critical, cpu: true, hot: true) }
      _ = feed(
        &record, from: start.addingTimeInterval(150), count: 1, calendar: calendar, last: last)
      let day = try #require(record.days.first)
      #expect(record.days.count == 1)
      #expect(day.day == "2026-10-20")
      #expect(day.awakeSeconds == 150)
      #expect(day.inUseSeconds == 150)
      #expect(day.warningSeconds == 60)
      #expect(day.criticalSeconds == 30)
      #expect(day.cpuSaturatedSeconds == 30)
      #expect(day.hotSeconds == 30)
      #expect(day.pressureShare == 0.6)
      #expect(day.criticalShare == 0.2)
    }

    @Test func awayTimeIsAwakeButNotInUseAndNotUnderPressure() throws {
      let calendar = calendar()
      var record = UsageRecord()
      _ = feed(&record, from: date("2026-10-20 10:00:00"), count: 31, calendar: calendar) {
        reading($0, present: false, risk: .critical)
      }
      let day = try #require(record.days.first)
      #expect(day.awakeSeconds == 60)
      #expect(day.inUseSeconds == 0)
      #expect(day.criticalSeconds == 0)
      #expect(day.pressureShare == nil)
      #expect(!day.hasUse)
      #expect(day.hasData)
    }

    @Test func aSleepGapOrAClockGoingBackAddsNoTime() throws {
      let calendar = calendar()
      var record = UsageRecord()
      let start = date("2026-10-20 10:00:00")
      let last = feed(&record, from: start, step: 10, count: 7, calendar: calendar)
      // 2 h asleep, then 60 s more.
      let wake = start.addingTimeInterval(7_200)
      let afterWake = feed(&record, from: wake, step: 10, count: 7, calendar: calendar, last: last)
      // The clock goes back a minute.
      _ = feed(
        &record, from: wake.addingTimeInterval(0), count: 1, calendar: calendar, last: afterWake)
      let day = try #require(record.days.first)
      #expect(day.awakeSeconds == 120)
    }

    @Test func aGapUpToAMinuteIsAwakeTime() throws {
      let calendar = calendar()
      var record = UsageRecord()
      let start = date("2026-10-20 10:00:00")
      _ = feed(&record, from: start, step: 60, count: 3, calendar: calendar)
      #expect(record.days.first?.awakeSeconds == 120)
      var other = UsageRecord()
      _ = feed(&other, from: start, step: 61, count: 3, calendar: calendar)
      #expect(other.days.first?.awakeSeconds == 0)
    }

    @Test func peaksLowestAndTimeWeightedAverages() throws {
      let calendar = calendar()
      var record = UsageRecord()
      let start = date("2026-10-20 10:00:00")
      var last = feed(&record, from: start, step: 10, count: 1, calendar: calendar) {
        reading(
          $0, swap: 10 * gb, available: 6 * gb, memory: 70, cpuPercent: 20, sessions: 10,
          sessionBytes: 8 * gb)
      }
      // 10 s at the first state, then 30 s at the second, then the last reading.
      last = feed(
        &record, from: start.addingTimeInterval(10), step: 30, count: 1, calendar: calendar,
        last: last
      ) {
        reading(
          $0, swap: 20 * gb, available: 2 * gb, memory: 90, cpuPercent: 60, sessions: 14,
          sessionBytes: 12 * gb)
      }
      _ = feed(
        &record, from: start.addingTimeInterval(40), count: 1, calendar: calendar, last: last
      ) {
        reading(
          $0, swap: 12 * gb, available: 5 * gb, memory: 75, cpuPercent: 25, sessions: 11,
          sessionBytes: 9 * gb)
      }
      let day = try #require(record.days.first)
      #expect(day.swapPeakBytes == 20 * gb)
      #expect(day.availableLowestBytes == 2 * gb)
      #expect(day.memoryPeakPercent == 90)
      #expect(day.cpuPeakPercent == 60)
      #expect(day.sessionsPeak == 14)
      #expect(day.sessionMemoryPeakBytes == 12 * gb)
      #expect(day.swapAverageBytes == UInt64((10.0 * 10 + 20.0 * 30) / 40 * Double(gb)))
      let memoryAverage: Double = (70.0 * 10 + 90.0 * 30) / 40
      let sessionsAverage: Double = (10.0 * 10 + 14.0 * 30) / 40
      #expect(day.memoryAveragePercent == memoryAverage)
      #expect(day.sessionsAverage == sessionsAverage)
      #expect(day.sessionMemoryAverageBytes == UInt64((8.0 * 10 + 12 * 30) / 40 * Double(gb)))
    }

    @Test func sessionsUnknownBeforeTheFirstScanLeaveTheAverageAlone() throws {
      let calendar = calendar()
      var record = UsageRecord()
      _ = feed(&record, from: date("2026-10-20 10:00:00"), count: 11, calendar: calendar) {
        reading($0, sessions: nil, sessionBytes: nil)
      }
      let day = try #require(record.days.first)
      #expect(day.sessionsAverage == nil)
      #expect(day.sessionsPeak == nil)
      #expect(day.awakeSeconds == 20)
    }

    @Test func anIntervalAcrossMidnightIsSplitBetweenTheTwoDays() throws {
      let calendar = calendar()
      var record = UsageRecord()
      _ = feed(
        &record, from: date("2026-10-20 23:59:40"), step: 20, count: 3, calendar: calendar
      ) { reading($0, risk: .warning) }
      #expect(record.days.map(\.day) == ["2026-10-20", "2026-10-21"])
      #expect(record.days[0].awakeSeconds == 20)
      #expect(record.days[0].warningSeconds == 20)
      #expect(record.days[1].awakeSeconds == 20)
      #expect(record.days[1].warningSeconds == 20)
    }

    @Test func aDaylightSavingDayLasts25HoursInTheAutumnAnd23InTheSpring() throws {
      let calendar = calendar()
      for (from, day, hours) in [
        ("2026-10-24 23:59:30", "2026-10-25", 25.0), ("2026-03-28 23:59:30", "2026-03-29", 23.0),
      ] {
        var record = UsageRecord()
        _ = feed(
          &record, from: date(from), step: 30, count: Int(hours * 120) + 3, calendar: calendar)
        let recorded = try #require(record.days.first { $0.day == day })
        #expect(recorded.awakeSeconds == hours * 3_600, "\(day)")
      }
    }

    @Test func actionsAddToTheirDay() throws {
      let calendar = calendar()
      var record = UsageRecord()
      let at = date("2026-10-20 12:00:00")
      record.record(.paused(count: 3, freedBytes: 2 * gb), at: at, calendar: calendar)
      record.record(.ended(freedBytes: gb), at: at, calendar: calendar)
      record.record(.quit(freedBytes: gb), at: at, calendar: calendar)
      record.record(.slowed(count: 2), at: at, calendar: calendar)
      let actions = try #require(record.days.first?.actions)
      #expect(actions.paused == 3)
      #expect(actions.ended == 1)
      #expect(actions.quit == 1)
      #expect(actions.slowed == 2)
      #expect(actions.queued == 0)
      #expect(actions.freedBytes == 4 * gb)
    }

    @Test func aYearIsKeptAndOlderDaysAreDropped() {
      let calendar = calendar()
      var record = UsageRecord()
      record.days = ["2025-10-28", "2025-10-29", "2026-01-01", "2026-10-29"].map {
        UsageDay(day: $0)
      }
      record.prune(now: date("2026-10-29 12:00:00"), calendar: calendar)
      #expect(record.days.map(\.day) == ["2025-10-29", "2026-01-01", "2026-10-29"])
    }
  }
}

// MARK: Files

extension UsageTrendTests {
  struct Files {
    @Test func theRecordRoundTripsAndSkipsAnUnreadableDayOrField() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = UsageStore(directory: directory)
      var record = UsageRecord()
      record.days = [
        liveDay(
          "2026-10-20", pressureMinutes: 60, criticalMinutes: 10, swapGB: 20,
          sessions: 12, sessionGB: 9)
      ]
      record.build = "0.1.0 · abc1234"
      store.save(record)
      #expect(store.load() == record)

      let json = """
        {"days": [{"day": "2026-10-21", "in_use_seconds": "not a number", "awakeSeconds": 60,
                   "inUseSeconds": 30, "actions": {"paused": 2, "future": true}},
                  {"no_day": 1},
                  {"day": "2026-10-20", "swapPeakBytes": -5}],
         "baselineImported": true, "unknown": [1, 2]}
        """
      try Data(json.utf8).write(to: store.url)
      let loaded = try #require(store.load())
      #expect(loaded.days.map(\.day) == ["2026-10-20", "2026-10-21"])
      #expect(loaded.days[1].awakeSeconds == 60)
      #expect(loaded.days[1].inUseSeconds == 30)
      #expect(loaded.days[1].actions.paused == 2)
      #expect(loaded.days[0].swapPeakBytes == nil)
      #expect(loaded.baselineImported)
    }

    @Test func anUnreadableFileIsKeptAsideAndTheRecordStartsEmpty() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = UsageStore(directory: directory)
      try Data("{not json".utf8).write(to: store.url)
      #expect(store.load(now: Date(timeIntervalSince1970: 1_800_000_000)) == UsageRecord())
      let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      #expect(names == ["usage-daily.json.unreadable-1800000000"])
      #expect(UsageStore(directory: directory).load() == nil)
    }

    @Test func aYearOfDaysStaysSmall() throws {
      var record = UsageRecord()
      let calendar = calendar()
      for offset in 0..<366 {
        let key = try #require(UsageCalendar.adding(-offset, to: "2026-10-29", calendar))
        var day = liveDay(
          key, pressureMinutes: 123.4, criticalMinutes: 12.3, swapGB: 23,
          sessions: 17.3, sessionGB: 14,
          actions: {
            var a = UsageActions()
            a.paused = 12
            a.freedBytes = 3 * gb
            return a
          }())
        day.availableLowestBytes = 1_234_567_890
        day.memoryPeakPercent = 97.123456
        day.cpuPeakPercent = 88.5
        day.memorySeconds = 32_400.5
        day.memoryPercentSeconds = 2_800_000.123
        day.sessionsPeak = 22
        day.sessionMemoryPeakBytes = 17 * gb
        record.days.append(day)
      }
      let data = try JSONEncoder().encode(record)
      #expect(data.count < 400_000, "\(data.count) bytes")
    }
  }
}

// MARK: Baseline

extension UsageTrendTests {
  struct Baseline {
    @Test func theWeekOfPeaksBecomesBaselineDaysBeforeToday() throws {
      let calendar = calendar()
      let start = date("2026-10-27 10:00:00")
      var samples: [ResourceSample] = []
      for index in 0..<4 {
        samples.append(
          .init(
            date: start.addingTimeInterval(Double(index) * 300), cpu: 0.1 * Double(index + 1),
            memory: 0.7 + 0.05 * Double(index)))
      }
      samples.append(.init(date: date("2026-10-28 09:00:00"), cpu: nil, memory: 0.6))
      // Today's samples stay out: today is recorded live.
      samples.append(.init(date: date("2026-10-29 08:00:00"), cpu: 0.9, memory: 0.99))
      let days = UsageBaseline.days(samples, before: "2026-10-29", calendar: calendar)
      #expect(days.map(\.day) == ["2026-10-27", "2026-10-28"])
      #expect(days.allSatisfy { $0.baseline })
      let first = days[0]
      #expect(abs((first.memoryPeakPercent ?? 0) - 85) < 0.001)
      #expect(abs((first.cpuPeakPercent ?? 0) - 40) < 0.001)
      #expect(abs((first.memoryAveragePercent ?? 0) - 77.5) < 0.001)
      #expect(first.pressureShare == nil)
      #expect(first.swapPeakBytes == nil)
      #expect(first.sessionsAverage == nil)
      #expect(days[1].cpuPeakPercent == nil)
      #expect(days[1].hasData)
      #expect(!days[1].hasUse)
    }

    @Test func itIsImportedOnceAndNeverOverALiveDay() {
      var record = UsageRecord()
      record.days = [
        liveDay(
          "2026-10-28", pressureMinutes: 10, criticalMinutes: 0, swapGB: 1,
          sessions: 1, sessionGB: 1)
      ]
      record.importBaseline([
        UsageDay(day: "2026-10-27", baseline: true),
        UsageDay(day: "2026-10-28", baseline: true),
      ])
      #expect(record.days.map(\.day) == ["2026-10-27", "2026-10-28"])
      #expect(record.days.map(\.baseline) == [true, false])
      #expect(record.baselineImported)
      record.importBaseline([UsageDay(day: "2026-10-26", baseline: true)])
      #expect(record.days.count == 2)
    }
  }
}

// MARK: Markers

extension UsageTrendTests {
  struct Markers {
    @Test func appendedMarkersReadBackOldestFirstAndATornLineIsSkipped() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let early = Date(timeIntervalSince1970: 1_800_000_000)
      #expect(
        UsageMarkers.append(
          .init(at: early.addingTimeInterval(60), kind: .note, text: "  later\nline  "),
          directory: directory)
          == .success(.init(at: early.addingTimeInterval(60), kind: .note, text: "later line")))
      _ = UsageMarkers.append(
        .init(
          at: early, kind: .version, text: "0.1.0 · abc1234", version: "0.1.0", commit: "abc1234"),
        directory: directory)
      let handle = try FileHandle(forWritingTo: UsageMarkers.url(directory))
      try handle.seekToEnd()
      try handle.write(contentsOf: Data("{\"at\": \"2026-".utf8))
      try handle.close()
      let markers = UsageMarkers.read(directory)
      #expect(markers.map(\.text) == ["0.1.0 · abc1234", "later line"])
      #expect(markers[0].label == "v0.1.0 · abc1234")
      #expect(
        UsageMarkers.append(.init(at: early, kind: .note, text: " \n "), directory: directory)
          == .failure(.emptyText))
      let long = String(repeating: "x", count: 500)
      if case .success(let marker) = UsageMarkers.append(
        .init(at: early, kind: .note, text: long), directory: directory)
      {
        #expect(marker.text.count == 200)
      } else {
        Issue.record("a long text is cut, not refused")
      }
    }

    @Test func concurrentAppendsKeepEveryLineWhole() async throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      await withTaskGroup(of: Void.self) { group in
        for index in 0..<40 {
          group.addTask {
            _ = UsageMarkers.append(
              .init(
                at: Date(timeIntervalSince1970: Double(1_800_000_000 + index)), kind: .note,
                text: "marker \(index) " + String(repeating: "y", count: 150)),
              directory: directory)
          }
        }
      }
      let markers = UsageMarkers.read(directory)
      #expect(markers.count == 40)
      #expect(Set(markers.map(\.text)).count == 40)
    }

    @Test func pruneDropsMarkersOlderThanAYear() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let now = Date(timeIntervalSince1970: 1_800_000_000)
      _ = UsageMarkers.append(
        .init(at: now.addingTimeInterval(-400 * 86_400), kind: .note, text: "old"),
        directory: directory)
      _ = UsageMarkers.append(
        .init(at: now.addingTimeInterval(-10 * 86_400), kind: .note, text: "recent"),
        directory: directory)
      UsageMarkers.prune(directory: directory, now: now)
      #expect(UsageMarkers.read(directory).map(\.text) == ["recent"])
    }

    @Test func aMarkerMatchesItsTextVersionOrCommit() {
      let build = UsageMarker(
        at: .now, kind: .version, text: "0.2 · abc1234", version: "0.2", commit: "abc1234")
      #expect(build.matches("v0.2"))
      #expect(build.matches("0.2"))
      #expect(build.matches("ABC1234"))
      #expect(build.matches("v0.2 · abc1234"))
      #expect(!build.matches("0.3"))
      let note = UsageMarker(at: .now, kind: .note, text: "Q16 installed")
      #expect(note.matches("q16 installed"))
      #expect(!note.matches("Q16"))
      #expect(CLITrendReport.marker("Q16", in: [note]) == note)
      #expect(CLITrendReport.marker("nothing", in: [note]) == nil)
    }

    @Test func severalInstallsInADayShowAsTheLastOne() {
      let calendar = calendar()
      let markers = [
        UsageMarker(at: date("2026-10-29 09:00:00"), kind: .version, text: "0.1.0 · aaa"),
        UsageMarker(at: date("2026-10-29 10:00:00"), kind: .note, text: "Q16 installed"),
        UsageMarker(at: date("2026-10-29 15:00:00"), kind: .version, text: "0.1.0 · bbb"),
        UsageMarker(at: date("2026-10-30 09:00:00"), kind: .version, text: "0.1.0 · ccc"),
      ]
      #expect(
        UsageMarkers.display(markers, calendar: calendar).map(\.text) == [
          "Q16 installed", "0.1.0 · bbb", "0.1.0 · ccc",
        ])
    }

    @Test func aSwitchedSettingIsOneMarkerTextPerChange() {
      let old = UsageSettings(
        autoEnd: "ask", autoEndDays: 7,
        quitApps: ["com.loom.desktop", "com.tinyspeck.slackmacgap"],
        autoPauseProjects: ["/code/web"])
      let new = UsageSettings(
        autoEnd: "auto", autoEndDays: 3, quitApps: ["com.loom.desktop", "us.zoom.xos"],
        autoPauseProjects: ["/code/api", "/code/web"])
      let names = ["us.zoom.xos": "Zoom", "com.tinyspeck.slackmacgap": "Slack"]
      #expect(
        UsageSettings.changes(from: old, to: new) { names[$0] ?? $0 } == [
          "Auto-end after 3 days", "Quit under pressure: + Zoom, − Slack", "Auto-pause: + api",
        ])
      #expect(UsageSettings.changes(from: new, to: new) { $0 }.isEmpty)
      var off = new
      off.autoEnd = "ask"
      off.autoEndDays = 9
      #expect(UsageSettings.changes(from: new, to: off) { $0 } == ["Auto-end off (Ask me)"])
      var ask = off
      ask.autoEndDays = 2
      #expect(UsageSettings.changes(from: off, to: ask) { $0 }.isEmpty)
    }
  }
}

// MARK: Recorder

extension UsageTrendTests {
  @MainActor struct Recorder {
    private func launch(
      _ directory: URL, now: Date, build: String = "0.1.0 · aaa",
      settings: @escaping @MainActor () -> UsageSettings = {
        .init(autoEnd: "ask", autoEndDays: 7, quitApps: [], autoPauseProjects: [])
      }, baseline: [ResourceSample] = []
    ) -> UsageRecorder {
      UsageRecorder(
        .init(
          directory: directory, now: now, calendar: calendar(), build: build, version: "0.1.0",
          commit: String(build.suffix(3)), baseline: { baseline }, settings: settings,
          appName: { $0 }))
    }

    @Test func theFirstRunImportsTheBaselineAndMarksNothing() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let now = date("2026-10-29 12:00:00")
      let recorder = launch(
        directory, now: now,
        baseline: [.init(date: date("2026-10-28 12:00:00"), cpu: 0.5, memory: 0.9)])
      #expect(recorder.record.days.map(\.day) == ["2026-10-28"])
      #expect(recorder.record.baselineImported)
      #expect(UsageMarkers.read(directory).isEmpty)
      #expect(UsageStore(directory: directory).load()?.build == "0.1.0 · aaa")
    }

    @Test func aNewBuildIsMarkedAtLaunchAndTheSameOneIsNot() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let now = date("2026-10-29 12:00:00")
      _ = launch(directory, now: now)
      _ = launch(directory, now: now.addingTimeInterval(60))
      #expect(UsageMarkers.read(directory).isEmpty)
      _ = launch(directory, now: now.addingTimeInterval(120), build: "0.1.0 · bbb")
      let markers = UsageMarkers.read(directory)
      #expect(markers.map(\.label) == ["v0.1.0 · bbb"])
      #expect(markers.first?.commit == "bbb")
      #expect(markers.first?.kind == .version)
    }

    @Test func itWritesAtMostOnceAMinuteAndOnPause() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let now = date("2026-10-29 12:00:00")
      let recorder = launch(directory, now: now)
      var flushes = 0
      recorder.flushed = { _ in flushes += 1 }
      for index in 1...29 { recorder.observe(reading(now.addingTimeInterval(Double(index) * 2))) }
      #expect(flushes == 0)
      #expect(UsageStore(directory: directory).load()?.days.isEmpty == true)
      recorder.observe(reading(now.addingTimeInterval(60)))
      #expect(flushes == 1)
      #expect(UsageStore(directory: directory).load()?.days.first?.awakeSeconds == 58)
      recorder.observe(reading(now.addingTimeInterval(62)))
      recorder.pause(now: now.addingTimeInterval(63))
      #expect(flushes == 2)
      // After the pause, the next reading starts afresh: the gap isn't awake time.
      recorder.observe(reading(now.addingTimeInterval(70)))
      recorder.pause(now: now.addingTimeInterval(71))
      #expect(UsageStore(directory: directory).load()?.days.first?.awakeSeconds == 60)
    }

    @Test func aSwitchedSettingIsMarkedAtTheNextFlush() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let now = date("2026-10-29 12:00:00")
      var current = UsageSettings(
        autoEnd: "ask", autoEndDays: 7, quitApps: [], autoPauseProjects: [])
      let recorder = launch(directory, now: now, settings: { current })
      current.autoEnd = "auto"
      recorder.flush(now: now.addingTimeInterval(5))
      recorder.flush(now: now.addingTimeInterval(65))
      #expect(UsageMarkers.read(directory).map(\.text) == ["Auto-end after 7 days"])
      #expect(UsageMarkers.read(directory).first?.kind == .setting)
    }
  }
}

// MARK: Comparison and text

extension UsageTrendTests {
  /// Seven days before `v0.2`, the marker's day, and four after, with the mockup's figures.
  static func mockupDays() -> (days: [UsageDay], marker: UsageMarker) {
    var days: [UsageDay] = []
    for day in 16...22 {
      days.append(
        liveDay(
          "2026-10-\(day)", pressureMinutes: 190, criticalMinutes: 32, swapGB: 24,
          sessions: 19, sessionGB: 16,
          actions: {
            var a = UsageActions()
            a.paused = 12
            return a
          }()))
    }
    // The marker's own day mixes both and counts on neither side.
    days.append(
      liveDay(
        "2026-10-23", pressureMinutes: 500, criticalMinutes: 300, swapGB: 40,
        sessions: 1, sessionGB: 1))
    for day in 24...27 {
      days.append(
        liveDay(
          "2026-10-\(day)", pressureMinutes: 90, criticalMinutes: 5, swapGB: 15,
          sessions: 21, sessionGB: 15,
          actions: {
            var a = UsageActions()
            a.ended = 3
            a.queued = 4
            return a
          }()))
    }
    let marker = UsageMarker(
      at: date("2026-10-23 15:00:00"), kind: .note, text: "v0.2 · Stopped log, courier fix")
    return (days, marker)
  }

  struct Comparison {
    @Test func sevenDaysBeforeAgainstTheDaysAfterWithoutTheMarkersDay() {
      let (days, marker) = UsageTrendTests.mockupDays()
      let older = [
        liveDay(
          "2026-10-10", pressureMinutes: 600, criticalMinutes: 600, swapGB: 99,
          sessions: 1, sessionGB: 1)
      ]
      let comparison = UsageComparison.around(marker, days: older + days, calendar: calendar())
      #expect(comparison.before.days.count == 7)
      #expect(comparison.before.days.first == "2026-10-16")
      #expect(comparison.after.days == ["2026-10-24", "2026-10-25", "2026-10-26", "2026-10-27"])
      #expect(comparison.pivotDay == "2026-10-23")
      #expect(comparison.workload == .same || comparison.workload == .heavier)
      #expect(
        comparison.text == """
          7 days before → after v0.2 · Stopped log, courier fix (4 days)
          Under pressure   35% → 17% of awake time
          Critical         32 min → 5 min a day
          Swap peak        24 → 15 GB
          AI sessions      19 → 21 on average, so the workload didn't drop

          """)
      #expect(
        comparison.summary
          == "Before v0.2 · Stopped log, courier fix: 35% · after: 17% · swap peak 24 → 15 GB")
    }

    @Test func aDayGivenAsADateIsTheFirstDayAfter() {
      let (days, _) = UsageTrendTests.mockupDays()
      let comparison = UsageComparison.from(day: "2026-10-24", days: days)
      #expect(comparison.before.days.last == "2026-10-23")
      #expect(comparison.after.days.first == "2026-10-24")
    }

    @Test func fewerSessionsAfterSaysTheWorkloadWasLighter() {
      let before = (1...3).map {
        liveDay(
          "2026-10-0\($0)", pressureMinutes: 100, criticalMinutes: 0, swapGB: 10,
          sessions: 20, sessionGB: 10)
      }
      let after = (5...6).map {
        liveDay(
          "2026-10-0\($0)", pressureMinutes: 10, criticalMinutes: 0, swapGB: 10,
          sessions: 12, sessionGB: 10)
      }
      let comparison = UsageComparison.around(
        .init(at: date("2026-10-04 12:00:00"), kind: .note, text: "x"), days: before + after,
        calendar: calendar())
      #expect(comparison.workload == .lighter)
      #expect(
        comparison.text.contains(
          "20 → 12 on average, so part of the change may be a lighter workload"))
      #expect(comparison.text.hasPrefix("3 days before → after x (2 days)"))
    }

    @Test func aBaselineOnlySideHasNoPressureButItsRAMPeak() {
      var baseline = UsageDay(day: "2026-10-20", baseline: true)
      baseline.memoryPeakPercent = 92
      baseline.memorySeconds = 300
      baseline.memoryPercentSeconds = 92 * 300
      var after = liveDay(
        "2026-10-22", pressureMinutes: 60, criticalMinutes: 6, swapGB: 12,
        sessions: 10, sessionGB: 9)
      after.memoryPeakPercent = 85
      let comparison = UsageComparison.around(
        .init(at: date("2026-10-21 12:00:00"), kind: .note, text: "Q16 installed"),
        days: [baseline, after], calendar: calendar())
      #expect(comparison.before.baselineOnly)
      let text = comparison.text
      #expect(text.contains("Under pressure   — → 11% of awake time"))
      #expect(text.contains("Critical         — → 6 min a day"))
      #expect(text.contains("Swap peak        — → 12 GB"))
      #expect(text.contains("RAM peak         92% → 85%"))
      #expect(text.contains("AI sessions      — → 10 on average\n"))
      #expect(
        text.contains("The days before are the baseline: RAM and CPU only, no pressure levels."))
    }

    @Test func noDayAfterYetIsSaid() {
      let (days, _) = UsageTrendTests.mockupDays()
      let comparison = UsageComparison.around(
        .init(at: date("2026-10-27 18:00:00"), kind: .note, text: "today"), days: days,
        calendar: calendar())
      #expect(comparison.after.days.isEmpty)
      #expect(comparison.text.contains("No full day after today yet."))
      #expect(comparison.summary == "Before today: 35% · after: no full day yet")
    }
  }
}

// MARK: The command line

extension UsageTrendTests {
  struct CommandLine {
    private func environment(
      _ directory: URL, now: Date, out: @escaping (String) -> Void = { _ in },
      err: @escaping (String) -> Void = { _ in }
    ) -> CLIEnvironment {
      CLIEnvironment(
        directory: directory, defaults: TestDefaults("Usage").defaults, now: { now },
        timeZone: TimeZone(identifier: "Europe/Paris")!,
        system: { fatalError("trend and mark read no live system") },
        sessions: { fatalError("trend and mark scan no sessions") },
        tamebarPID: { 42 }, label: { _ in nil }, out: out, err: err)
    }

    private func write(_ days: [UsageDay], markers: [UsageMarker], to directory: URL) {
      var record = UsageRecord()
      record.days = days
      record.baselineImported = true
      UsageStore(directory: directory).save(record)
      for marker in markers { UsageMarkers.append(marker, directory: directory) }
    }

    @Test func parsesTrendAndMark() throws {
      #expect(try CLI.parse(["trend"]).get() == .trend(json: false, days: 14, compare: nil))
      #expect(
        try CLI.parse(["trend", "--days", "30", "--compare", "v0.2", "--json"]).get()
          == .trend(json: true, days: 30, compare: "v0.2"))
      #expect(
        try CLI.parse(["trend", "--days=7", "--compare=2026-10-20"]).get()
          == .trend(json: false, days: 7, compare: "2026-10-20"))
      #expect(try CLI.parse(["mark", "Raised", "the", "limit"]).get() == .mark("Raised the limit"))
      #expect(try CLI.parse(["mark", "--help"]).get() == .help("mark"))
      #expect(try CLI.parse(["help", "trend"]).get() == .help("trend"))
      for bad in [
        ["trend", "--days", "0"], ["trend", "--days", "367"], ["trend", "--days"],
        ["trend", "--compare"], ["trend", "--all"], ["mark"], ["mark", "  "],
        ["status", "--days", "3"],
      ] {
        #expect(throws: CLI.UsageError.self, "\(bad)") { try CLI.parse(bad).get() }
      }
    }

    @Test func textIsTheMockupsTableWithTheMarkerAfterItsDay() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let (days, marker) = UsageTrendTests.mockupDays()
      let shown = [days[6], days[8]]
      write(shown, markers: [marker], to: directory)
      var out = ""
      let code = CLI.run(
        ["trend", "--days", "14"],
        environment(directory, now: date("2026-10-28 12:00:00"), out: { out += $0 }))
      #expect(code == 0)
      #expect(
        out == """
          Day     Awake  Pressure        Critical  Struggling  Swap peak  AI sessions  Tamebar did
          Oct 22  9h     3h 10m · 35%    32m       —           24 GB      19 · 16 GB   paused 12
           ── v0.2 · Stopped log, courier fix ──
          Oct 24  9h     1h 30m · 17%    5m        —           15 GB      21 · 15 GB   ended 3, queued 4

          """)
    }

    @Test func baselineDaysShowDashesAndTheirPeaks() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      // No record yet: the baseline is read from resource-history.json, and nothing is written.
      let samples = [ResourceSample(date: date("2026-10-27 10:00:00"), cpu: 0.81, memory: 0.92)]
      try JSONEncoder().encode(samples).write(
        to: directory.appendingPathComponent("resource-history.json"))
      var out = ""
      #expect(
        CLI.run(
          ["trend"], environment(directory, now: date("2026-10-28 12:00:00"), out: { out += $0 }))
          == 0)
      #expect(
        out.contains(
          "Oct 27  —      —               —         —           —          —            baseline · RAM peak 92% · CPU peak 81%"
        ))
      #expect(out.contains("Note: Tamebar hasn't recorded a day yet"))
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
          == ["resource-history.json"])
    }

    @Test func compareTextAndJSON() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let (days, marker) = UsageTrendTests.mockupDays()
      write(days, markers: [marker], to: directory)
      var out = ""
      #expect(
        CLI.run(
          ["trend", "--compare", "courier"],
          environment(directory, now: date("2026-10-28 12:00:00"), out: { out += $0 })) == 0)
      #expect(out.hasPrefix("7 days before → after v0.2 · Stopped log, courier fix (4 days)\n"))
      out = ""
      #expect(
        CLI.run(
          ["trend", "--days", "30", "--compare", "v0.2 · Stopped log, courier fix", "--json"],
          environment(directory, now: date("2026-10-28 12:00:00"), out: { out += $0 })) == 0)
      let object = try #require(
        JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
      #expect(object["schema"] as? Int == 1)
      #expect(object["command"] as? String == "trend")
      #expect(object["window_days"] as? Int == 30)
      let rows = try #require(object["days"] as? [[String: Any]])
      #expect(rows.count == 12)
      let first = rows[0]
      #expect(first["day"] as? String == "2026-10-16")
      #expect(first["in_use_minutes"] as? Int == 540)
      #expect(first["pressure_minutes"] as? Int == 190)
      #expect(first["pressure_percent"] as? Double == 35.2)
      #expect(first["swap_peak_bytes"] as? Int == 24_000_000_000)
      #expect(first["available_lowest_bytes"] is NSNull)
      #expect((first["tamebar_did"] as? [String: Any])?["paused"] as? Int == 12)
      let compare = try #require(object["compare"] as? [String: Any])
      #expect(compare["day"] as? String == "2026-10-23")
      #expect((compare["before"] as? [String: Any])?["pressure_percent"] as? Double == 35.2)
      #expect((compare["after"] as? [String: Any])?["critical_minutes_per_day"] as? Double == 5)
      #expect((compare["after"] as? [String: Any])?["ai_sessions_average"] as? Double == 21)
      let markers = try #require(object["markers"] as? [[String: Any]])
      #expect(markers.first?["kind"] as? String == "note")
      #expect(markers.first?["version"] is NSNull)
    }

    @Test func anUnknownMarkerIsBadUsage() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      var err = ""
      #expect(
        CLI.run(
          ["trend", "--compare", "v9"],
          environment(directory, now: .now, err: { err += $0 })) == 2)
      #expect(err.contains("No marker or day matches v9."))
    }

    @Test func markAppendsOneLineAndNeedsNoApp() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      var out = ""
      let now = date("2026-10-29 14:05:00")
      #expect(
        CLI.run(["mark", "Q16 installed"], environment(directory, now: now, out: { out += $0 }))
          == 0)
      #expect(out == "Marked “Q16 installed” at Oct 29 14:05.\n")
      #expect(UsageMarkers.read(directory) == [.init(at: now, kind: .note, text: "Q16 installed")])
      #expect(
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == [
          "usage-markers.jsonl", "usage-markers.lock",
        ])
    }

    @Test func emptyTrendSaysSoInOneLine() throws {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      write([], markers: [], to: directory)
      var out = ""
      #expect(CLI.run(["trend"], environment(directory, now: .now, out: { out += $0 })) == 0)
      #expect(out.hasPrefix("No usage recorded yet."))
    }
  }
}

// MARK: The Trend card

extension UsageTrendTests {
  struct Card {
    @Test func sevenDaysOfBarsTicksAfterTheMarkersDayAndTheSummary() throws {
      let calendar = calendar()
      let (days, marker) = UsageTrendTests.mockupDays()
      var baseline = UsageDay(day: "2026-10-12", baseline: true)
      baseline.memoryPeakPercent = 90
      baseline.memorySeconds = 300
      let old = liveDay(
        "2026-09-01", pressureMinutes: 100, criticalMinutes: 0, swapGB: 1, sessions: 1,
        sessionGB: 1)
      let model = UsageTrendChart.model(
        .init(days: [old, baseline] + days, markers: [marker]), now: date("2026-10-28 12:00:00"),
        calendar: calendar)
      #expect(model.start == date("2026-10-22 00:00:00"))
      #expect(model.end == date("2026-10-29 00:00:00"))
      #expect(model.firstLabel == "Oct 22")
      #expect(model.lastLabel == "Oct 28")
      // N11: seven days. The baseline and the days outside the window have no bar.
      #expect(model.bars.count == 6)
      #expect(model.useDays == 6)
      let first = try #require(model.bars.first)
      #expect(abs(first.critical - 32.0 / 540) < 1e-9)
      #expect(abs(first.pressure - 190.0 / 540) < 1e-9)
      #expect(model.top == 1)
      #expect(
        model.ticks == [.init(date: date("2026-10-24 00:00:00"), label: "v0.2 · Stopped lo…")])
      #expect(
        model.summary
          == "Before v0.2 · Stopped log, courier fix: 35% · after: 17% · swap peak 24 → 15 GB")
      #expect(!model.isEmpty)
    }

    @Test func underTwoDaysIsEmptyAndNoMarkerGivesTheAverage() {
      let calendar = calendar()
      let one = liveDay(
        "2026-10-28", pressureMinutes: 54, criticalMinutes: 0, swapGB: 1, sessions: 1,
        sessionGB: 1)
      let alone = UsageTrendChart.model(
        .init(days: [one]), now: date("2026-10-28 12:00:00"), calendar: calendar)
      #expect(alone.isEmpty)
      let two = liveDay(
        "2026-10-27", pressureMinutes: 0, criticalMinutes: 0, swapGB: 1, sessions: 1,
        sessionGB: 1)
      let model = UsageTrendChart.model(
        .init(days: [two, one]), now: date("2026-10-28 12:00:00"), calendar: calendar)
      #expect(!model.isEmpty)
      #expect(model.top == 0.2)
      #expect(model.summary == "5% of awake time under pressure over these days")
    }
  }
}
