import AppKit
import SwiftUI

/// Section title with an optional item count and up to two trailing actions.
struct BlitzSectionHeader<Trailing: View>: View {
  let title: String
  let count: Int?
  @ViewBuilder let trailing: () -> Trailing

  var body: some View {
    HStack(spacing: 6) {
      Text(title).font(BlitzType.section)
      if let count {
        Text("\(count)").font(BlitzType.caption).monospacedDigit()
          .foregroundStyle(BlitzUI.tertiaryText)
      }
      Spacer(minLength: 8)
      trailing()
    }.accessibilityElement(children: .contain).accessibilityAddTraits(.isHeader)
  }
}

enum Pasteboard {
  @MainActor static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
