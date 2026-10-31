import Foundation
import Testing

@testable import Tamebar

/// Q19, settled after spike S5 (2026-10-30: "Yes, these four"): the Mac is struggling when
/// swap-ins average over 4,000 pages/s for 30 s at warning or critical, the fan averages over
/// 70 % of its max for 60 s, the thermal state is serious or critical, or pressure is critical;
/// it clears after 60 s with none.
struct StrainTests {
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  /// Drives the planner every 2 s with a swap-in rate (pages/s), a fan and a pressure.
  struct Sim {
    var planner = StrainPlanner()
    var swapIns: UInt64 = 1_000_000
    var second: TimeInterval = 0
    let t0: Date

    init(_ t0: Date) { self.t0 = t0 }

    mutating func run(
      for seconds: TimeInterval, rate: Double = 89, fan: Double? = 38,
      pressure: MemoryPressureLevel = .warning, thermal: ThermalStatus = .nominal,
      forced: Bool? = nil
    ) {
      let end = second + seconds
      while second < end {
        second += 2
        swapIns += UInt64(rate * 2)
        planner.observe(
          .init(
            date: t0.addingTimeInterval(second), swapIns: swapIns, pressure: pressure,
            fanPercent: fan, thermal: thermal), forced: forced)
      }
    }
  }

  @Test func aNormalDayAtWarningNeverStruggles() {
    var sim = Sim(t0)
    // S5's normal day: swap-ins with a worst 30 s of 2,327 pages/s, the fan under 46 %, warning.
    sim.run(for: 120, rate: 89, fan: 38)
    sim.run(for: 60, rate: 2_300, fan: 45)
    sim.run(for: 4, rate: 16_897, fan: 46)
    sim.run(for: 300, rate: 900, fan: 41)
    #expect(!sim.planner.struggling)
    #expect(sim.planner.signals.isEmpty)
  }

  @Test func swapInsOver4000For30SecondsAtWarningStruggle() {
    var sim = Sim(t0)
    sim.run(for: 40)
    sim.run(for: 14, rate: 6_000)
    #expect(!sim.planner.struggling, "14 s keep the 30 s mean under 4,000")
    sim.run(for: 30, rate: 6_000)
    #expect(sim.planner.struggling)
    let signal = try? #require(sim.planner.signals.first)
    #expect(signal?.kind == .swap)
    #expect(abs((signal?.value ?? 0) - 6_000) < 1)
    #expect(signal?.text == "swap-ins 6,000 pages/s")
  }

  @Test func swapInsAtNormalPressureDontCount() {
    var sim = Sim(t0)
    sim.run(for: 120, rate: 9_000, pressure: .normal)
    #expect(!sim.planner.struggling)
  }

  @Test func aShortSwapBurstStaysUnderTheAverage() {
    var sim = Sim(t0)
    sim.run(for: 40)
    sim.run(for: 4, rate: 16_000)
    sim.run(for: 40)
    #expect(!sim.planner.struggling)
  }

  @Test func theFanOver70PercentFor60SecondsStruggles() {
    var sim = Sim(t0)
    sim.run(for: 40, fan: 40)
    sim.run(for: 40, fan: 80)
    #expect(!sim.planner.struggling, "the 60 s mean is still under 70 %")
    sim.run(for: 20, fan: 80)
    #expect(sim.planner.struggling)
    #expect(sim.planner.signals.map(\.kind) == [.fan])
    #expect(sim.planner.signals.first?.text == "fan 80%")
  }

  @Test func noFanIsJustNoSignal() {
    var sim = Sim(t0)
    sim.run(for: 300, fan: nil)
    #expect(!sim.planner.struggling)
  }

  @Test func heatAndCriticalCountAtOnce() {
    var hot = Sim(t0)
    hot.run(for: 2, thermal: .serious)
    #expect(hot.planner.struggling)
    #expect(hot.planner.signals.map(\.text) == ["heat serious"])
    var critical = Sim(t0)
    critical.run(for: 2, pressure: .critical)
    #expect(critical.planner.struggling)
    #expect(critical.planner.signals.map(\.text) == ["memory critical"])
    var warm = Sim(t0)
    warm.run(for: 60, thermal: .fair)
    #expect(!warm.planner.struggling, "fair isn't hot")
  }

  @Test func itClearsAfter60SecondsWithNone() {
    var sim = Sim(t0)
    sim.run(for: 4, pressure: .critical)
    let since = sim.planner.since
    #expect(since == t0.addingTimeInterval(2))
    sim.run(for: 50)
    #expect(sim.planner.struggling, "50 s isn't 60")
    sim.run(for: 2, pressure: .critical)
    sim.run(for: 58)
    #expect(sim.planner.struggling, "a signal restarted the 60 s")
    #expect(sim.planner.since == since, "the same episode")
    sim.run(for: 2)
    #expect(!sim.planner.struggling)
    #expect(sim.planner.since == nil && sim.planner.signals.isEmpty)
  }

  @Test func aSleepStartsTheAveragesAgain() {
    var sim = Sim(t0)
    sim.run(for: 40, fan: 90)
    sim.second += 3_600
    sim.run(for: 30, fan: 90)
    #expect(!sim.planner.struggling, "the fan's 60 s start again after the gap")
    sim.run(for: 40, fan: 90)
    #expect(sim.planner.struggling)
  }

  @Test func aSwapCounterThatGoesBackIsIgnored() {
    var planner = StrainPlanner()
    for (second, count) in [(0.0, 5_000_000), (2, 10), (4, 20)] {
      planner.observe(
        .init(
          date: t0.addingTimeInterval(second), swapIns: UInt64(count), pressure: .warning,
          fanPercent: nil, thermal: .nominal))
    }
    #expect(!planner.struggling)
  }

  @Test func anE2EControlForcesItOnAndOffAtOnce() {
    var sim = Sim(t0)
    sim.run(for: 2, forced: true)
    #expect(sim.planner.struggling)
    #expect(sim.planner.signals.map(\.kind) == [.forced])
    sim.run(for: 2, forced: false)
    #expect(!sim.planner.struggling, "no 60 s clear when forced")
  }

  @Test func theFileSaysWhoWroteItAndWhy() throws {
    let file = StrainFile(
      pid: 42, pidStart: 100, struggling: true, since: t0,
      signals: [.init(kind: .fan, value: 78.4), .init(kind: .heat, state: "serious")],
      updated: t0)
    #expect(file.summary == "struggling (fan 78%, heat serious)")
    #expect(file.writerRuns { $0 == 42 ? 100.0002 : nil })
    #expect(!file.writerRuns { $0 == 42 ? 200 : nil }, "a reused pid")
    #expect(!file.writerRuns { _ in nil }, "not running")
    let none = StrainFile(pid: 42, struggling: false, signals: [], updated: t0)
    #expect(none.summary == "none")

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("TamebarTests-Strain-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    file.write(root)
    #expect(StrainFile.read(root) == file)
  }

  @Test func fanKeysDecodeAsS5ReadThem() {
    let float = withUnsafeBytes(of: Float32(2_500).bitPattern.littleEndian) { Array($0) }
    #expect(FanReader.decode(type: 0x666C_7420, bytes: float) == 2_500)  // "flt "
    #expect(FanReader.decode(type: 0x6670_6532, bytes: [0x27, 0x10]) == 2_500)  // "fpe2"
    #expect(FanReader.decode(type: 0x7569_3820, bytes: [1]) == 1)  // "ui8 "
    #expect(FanReader.decode(type: 0x6368_6172, bytes: [1]) == nil)  // "char"
  }
}
