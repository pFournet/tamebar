import SwiftUI

/// The notch island's views (N1, N2, N5). `IslandController` owns the window; these only draw.

/// The collapsed island (N1, N2): a wing either side of the notch, in black so the three read as
/// one shape. Its width is fixed; the window clips it while it eases out of the notch.
struct IslandWings: View {
  let text: IslandWingText?
  let notchWidth: CGFloat
  let wingWidth: CGFloat
  let height: CGFloat

  var body: some View {
    HStack(spacing: 0) {
      HStack(spacing: 5) {
        if let text {
          Image(systemName: text.symbol)
            .foregroundStyle(text.tone == .neutral ? BlitzUI.onNotch : text.tone.color)
          if let label = text.label { Text(label) }
        }
      }
      .padding(.leading, NotchGeometry.wingPadding)
      .frame(width: wingWidth, alignment: .leading)
      Color.clear.frame(width: notchWidth)
      Text(text?.detail ?? "").monospacedDigit().lineLimit(1).truncationMode(.tail)
        .padding(.trailing, NotchGeometry.wingPadding)
        .frame(width: wingWidth, alignment: .trailing)
    }
    .font(.system(size: 12, weight: .semibold)).foregroundStyle(BlitzUI.onNotch)
    .frame(width: notchWidth + 2 * wingWidth, height: height)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      text.map { [$0.label, $0.detail].compactMap { $0 }.joined(separator: ", ") } ?? "")
  }
}

/// The island's outline: square at the screen's top edge, rounded below, like the notch.
struct IslandShape: Shape {
  var radius: CGFloat

  func path(in rect: CGRect) -> Path {
    UnevenRoundedRectangle(
      bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous
    ).path(in: rect)
  }
}

/// What the island's window holds: the black strip with the wings, a button that opens Tamebar's
/// window (N11).
struct IslandView: View {
  @ObservedObject var controller: IslandController

  var body: some View {
    IslandLayout(state: controller.state, metrics: controller.metrics) {
      controller.wingsClicked()
    }
  }
}

struct IslandLayout: View {
  let state: IslandState
  let metrics: IslandController.Metrics
  let onClick: () -> Void

  var body: some View {
    Button(action: onClick) {
      IslandWings(
        text: state.wingText, notchWidth: metrics.notchWidth, wingWidth: metrics.wingWidth,
        height: metrics.notchHeight
      )
      .frame(maxWidth: .infinity).frame(height: metrics.notchHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(BlitzUI.notchFill)
    .environment(\.colorScheme, .dark)
    .help("Show what \(AppBrand.name) did")
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .clipShape(IslandShape(radius: 10))
  }
}

extension MetricTone {
  /// Warning or critical: the only tones the menu bar colors.
  var isAlert: Bool { self == .warning || self == .critical }
}
