import SwiftUI

enum MetricTone: Equatable {
  case neutral
  case good
  case warning
  case critical

  var color: Color {
    switch self {
    case .neutral:
      .secondary
    case .good:
      BlitzUI.good
    case .warning:
      BlitzUI.warning
    case .critical:
      BlitzUI.recordRed
    }
  }

  static func forUsedRatio(_ ratio: Double) -> MetricTone {
    if ratio >= 0.95 {
      return .critical
    }

    if ratio >= 0.85 {
      return .warning
    }

    return .good
  }

  static func forAvailableRatio(_ ratio: Double) -> MetricTone {
    if ratio <= 0.1 {
      return .critical
    }

    if ratio <= 0.2 {
      return .warning
    }

    return .good
  }

}

enum PanelMetrics {
  static let cardRadius: CGFloat = BlitzUI.cardRadius
  static let cardPadding: CGFloat = 16
  static let innerRadius: CGFloat = 6
}

private struct PanelCardModifier: ViewModifier {
  let padding: CGFloat

  func body(content: Content) -> some View {
    content
      .padding(padding)
      .background(
        BlitzUI.cardFill,
        in: RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous)
          .strokeBorder(BlitzUI.separator, lineWidth: 1)
          .allowsHitTesting(false)
      }
  }
}

extension View {
  func panelCard(padding: CGFloat = PanelMetrics.cardPadding) -> some View {
    modifier(PanelCardModifier(padding: padding))
  }
}

enum PercentText {
  static func make(_ ratio: Double) -> String {
    (ratio * 100).formatted(.number.precision(.fractionLength(0))) + "%"
  }
}
