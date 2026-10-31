import Charts
import SwiftUI

/// What the Trend card draws (Q16): 7 days (N11) of the share of in-use time under memory pressure,
/// the markers between days, and one line comparing before and after the latest marker. Pure.
enum UsageTrendChart {
  static let days = 7
  /// A marker label longer than this is cut, so ticks keep their place on the axis.
  static let labelLength = 18

  struct Bar: Identifiable, Equatable {
    let day: String
    let start: Date
    /// Shares of the day's in-use time, 0–1.
    let warning: Double
    let critical: Double
    var id: String { day }
    var pressure: Double { warning + critical }
  }

  struct Tick: Identifiable, Equatable {
    /// The boundary after the marker's day.
    let date: Date
    let label: String
    var id: Date { date }
  }

  struct Model: Equatable {
    var bars: [Bar] = []
    var ticks: [Tick] = []
    var start = Date.distantPast
    var end = Date.distantPast
    /// Days in the window the Mac was in use: the chart needs 2.
    var useDays = 0
    var summary: String?
    /// The top of the scale: the highest bar, rounded up to 20 %, at least 20 %.
    var top = 0.2
    var firstLabel = ""
    var lastLabel = ""

    var isEmpty: Bool { useDays < 2 }
  }

  static func model(_ data: UsageTrendData, now: Date, calendar: Calendar, days: Int = days)
    -> Model
  {
    var model = Model()
    let today = UsageCalendar.key(now, calendar)
    guard let firstKey = UsageCalendar.adding(-(days - 1), to: today, calendar),
      let start = UsageCalendar.start(firstKey, calendar),
      let todayStart = UsageCalendar.start(today, calendar),
      let end = calendar.date(byAdding: .day, value: 1, to: todayStart)
    else { return model }
    model.start = start
    model.end = end
    model.firstLabel = UsageCalendar.short(firstKey, calendar)
    model.lastLabel = UsageCalendar.short(today, calendar)
    let window = data.days.filter { $0.day >= firstKey && $0.day <= today }
    model.useDays = window.filter(\.hasUse).count
    model.bars = window.compactMap { day in
      guard let pressure = day.pressureShare, let critical = day.criticalShare,
        let dayStart = UsageCalendar.start(day.day, calendar)
      else { return nil }
      return Bar(
        day: day.day, start: dayStart, warning: max(0, pressure - critical), critical: critical)
    }
    let highest = model.bars.map(\.pressure).max() ?? 0
    model.top = max(0.2, (highest * 5).rounded(.up) / 5)
    let markers = UsageMarkers.display(data.markers, calendar: calendar)
    model.ticks = markers.compactMap { marker in
      let key = UsageCalendar.key(marker.at, calendar)
      guard key >= firstKey, key <= today, let next = UsageCalendar.adding(1, to: key, calendar),
        let date = UsageCalendar.start(next, calendar)
      else { return nil }
      return Tick(date: min(date, end), label: short(marker.label))
    }
    // One tick per boundary: the latest marker of a day names it.
    var seen: [Date: Int] = [:]
    for (index, tick) in model.ticks.enumerated() { seen[tick.date] = index }
    model.ticks = model.ticks.enumerated().filter { seen[$0.element.date] == $0.offset }
      .map(\.element)
    if let latest = markers.last {
      model.summary = UsageComparison.around(latest, days: data.days, calendar: calendar).summary
    } else {
      let used = window.filter(\.hasUse)
      let inUse = used.reduce(0) { $0 + $1.inUseSeconds }
      if inUse > 0 {
        let share = used.reduce(0) { $0 + $1.pressureSeconds } / inUse
        model.summary =
          "\(UsageComparison.percent(share)) of awake time under pressure over these days"
      }
    }
    return model
  }

  static func short(_ label: String) -> String {
    label.count > labelLength ? String(label.prefix(labelLength - 1)) + "…" : label
  }
}

/// The Trend card on the window's Activity tab (Q16, N11): a bar a day for 7 days of the share of
/// in-use time under memory pressure, critical in red under warning in orange, a dashed tick after
/// each marker's day with its label on the axis, and the before and after of the latest marker.
/// Under two days of data it is one line.
struct UsageTrendCard: View {
  let data: UsageTrendData
  var now: Date = .now
  var calendar: Calendar = .autoupdatingCurrent

  var body: some View {
    let model = UsageTrendChart.model(data, now: now, calendar: calendar)
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text("Trend · \(UsageTrendChart.days) days").font(BlitzType.section)
        Spacer(minLength: 8)
        if !model.isEmpty { legend }
      }
      if model.isEmpty {
        Text("The trend starts once Tamebar has recorded two days.")
          .font(BlitzType.body).foregroundStyle(BlitzUI.secondaryText)
      } else {
        chart(model).frame(height: 132)
        if let summary = model.summary {
          Text(summary).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
            .lineLimit(1).truncationMode(.middle)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .panelCard(padding: 16)
  }

  private var legend: some View {
    HStack(spacing: 10) {
      swatch(BlitzUI.warning, "Under pressure")
      swatch(BlitzStatusTone.critical.color, "Critical")
    }
  }

  private func swatch(_ color: Color, _ title: String) -> some View {
    HStack(spacing: 4) {
      RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
      Text(title).font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
    }
  }

  private func chart(_ model: UsageTrendChart.Model) -> some View {
    // A marker is named under its tick; the first and last days at the chart's two ends.
    let labels = Dictionary(
      model.ticks.map { ($0.date, $0.label) }, uniquingKeysWith: { _, latest in latest })
    return Chart {
      ForEach(model.bars) { bar in
        BarMark(
          x: .value("Day", bar.start, unit: .day), y: .value("Share", bar.critical),
          width: .ratio(0.7)
        )
        .foregroundStyle(BlitzStatusTone.critical.color)
        BarMark(
          x: .value("Day", bar.start, unit: .day), y: .value("Share", bar.warning),
          width: .ratio(0.7)
        )
        .foregroundStyle(BlitzUI.warning)
      }
      ForEach(model.ticks) { tick in
        RuleMark(x: .value("Marker", tick.date))
          .foregroundStyle(BlitzUI.secondaryText)
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
      }
    }
    .chartXScale(domain: model.start...model.end)
    .chartYScale(domain: 0...model.top)
    .chartXAxis {
      AxisMarks(values: [model.start]) { _ in
        AxisValueLabel(anchor: .topLeading) {
          Text(model.firstLabel).font(BlitzType.caption)
        }
      }
      AxisMarks(values: labels.keys.sorted()) { value in
        AxisTick(length: 3)
        AxisValueLabel(collisionResolution: .greedy) {
          if let date = value.as(Date.self), let label = labels[date] {
            Text(label).font(BlitzType.caption)
          }
        }
      }
      AxisMarks(values: [model.end]) { _ in
        AxisValueLabel(anchor: .topTrailing) {
          Text(model.lastLabel).font(BlitzType.caption)
        }
      }
    }
    .chartYAxis {
      AxisMarks(
        position: .leading,
        values: stride(from: 0, through: model.top, by: model.top / 2).map { $0 }
      ) {
        value in
        AxisGridLine().foregroundStyle(BlitzUI.panelStroke)
        AxisValueLabel {
          if let share = value.as(Double.self) {
            Text("\(Int((share * 100).rounded()))%").font(BlitzType.numeric)
          }
        }
      }
    }
    .accessibilityLabel(
      "Share of awake time under memory pressure, last \(UsageTrendChart.days) days"
    )
    .accessibilityValue(model.summary ?? "")
  }
}
