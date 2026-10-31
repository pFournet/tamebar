import SwiftUI

extension View {
  /// The one card surface: panel fill, hairline border, card corners.
  func blitzCard(padding: CGFloat) -> some View {
    self.padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        BlitzUI.panelBackground,
        in: RoundedRectangle(cornerRadius: BlitzUI.cardRadius, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: BlitzUI.cardRadius, style: .continuous)
          .strokeBorder(BlitzUI.separator, lineWidth: 1))
  }
}
