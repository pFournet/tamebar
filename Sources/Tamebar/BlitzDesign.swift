import AppKit
import SwiftUI

enum BlitzType {
  static let largeTitle = Font.system(size: 24, weight: .semibold)
  static let title = Font.system(size: 17, weight: .semibold)
  static let headline = Font.system(size: 15, weight: .semibold)
  static let section = Font.system(size: 13, weight: .semibold)
  static let callout = Font.system(size: 13)
  static let rowTitle = Font.system(size: 13, weight: .medium)
  static let body = Font.system(size: 12)
  static let label = Font.system(size: 12, weight: .medium)
  static let caption = Font.system(size: 11)
  static let captionEmphasis = Font.system(size: 11, weight: .medium)
  /// Values (sizes, percentages, counts) in SF Mono.
  static let numeric = Font.system(size: 11, design: .monospaced)
}

enum BlitzUI {
  /// The one accent: the system accent color (blue unless the user picked another).
  static let mint = Color.accentColor
  static let good = Color.green
  static let warning = Color.orange
  static let recordRed = Color.red
  static let canvasBackground = Color(nsColor: .windowBackgroundColor)
  static let panelBackground = Color(nsColor: .controlBackgroundColor)
  static let menuFill = panelBackground
  static let panelStroke = Color(nsColor: .separatorColor)
  static let separator = Color(nsColor: .separatorColor)
  static let cardFill = Color.primary.opacity(0.04)
  static let quietFill = Color.primary.opacity(0.04)
  static let controlFill = Color.primary.opacity(0.06)
  static let hoverFill = Color.primary.opacity(0.06)
  static let selectedFill = Color.primary.opacity(0.1)
  static let strongFill = Color.primary.opacity(0.1)
  static let strongStroke = Color(nsColor: .tertiaryLabelColor)
  static let primaryText = Color.primary
  static let supportingText = Color.secondary
  static let secondaryText = Color.secondary
  /// Captions use the secondary label too: tertiaryLabelColor is too faint for text in light mode.
  static let tertiaryText = Color.secondary
  /// Text and glyphs on an accent or tone fill.
  static let onAccent = Color.white
  /// The notch island's wings: black in light and dark alike, so they merge with the camera
  /// housing, which is black hardware.
  static let notchFill = Color.black
  /// Text and glyphs on the notch island.
  static let onNotch = Color.white
  static let controlRadius: CGFloat = 6
  static let cardRadius: CGFloat = 8
  static let titleFont = BlitzType.largeTitle
  static let valueFont = Font.system(size: 32, weight: .medium)

  static func sectionLabel(_ title: String) -> some View {
    Text(title).font(BlitzType.captionEmphasis).foregroundStyle(secondaryText).lineLimit(1)
  }
}

enum BlitzButtonEmphasis {
  case accent, emphasized, secondary, quiet
}

enum BlitzControlMetrics {
  static func height(_ size: ControlSize) -> CGFloat {
    switch size {
    case .mini: 24
    case .small: 28
    case .large, .extraLarge: 40
    default: 34
    }
  }

  static func fontSize(_ size: ControlSize) -> CGFloat {
    switch size {
    case .mini, .small: 11
    case .large, .extraLarge: 13
    default: 12
    }
  }

  static func horizontalPadding(_ size: ControlSize) -> CGFloat {
    switch size {
    case .mini, .small: 8
    case .large, .extraLarge: 16
    default: 10
    }
  }
}

struct BlitzButtonStyle: ButtonStyle {
  let emphasis: BlitzButtonEmphasis
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.controlSize) private var controlSize
  @State private var isHovered = false

  init(_ emphasis: BlitzButtonEmphasis) {
    self.emphasis = emphasis
  }

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: BlitzUI.controlRadius, style: .continuous)
    let pressed = configuration.isPressed && isEnabled
    let destructive = configuration.role == .destructive && emphasis != .accent
    return configuration.label
      .font(
        .system(
          size: BlitzControlMetrics.fontSize(controlSize),
          weight: emphasis == .quiet ? .medium : .semibold)
      )
      .lineLimit(1)
      .symbolRenderingMode(.monochrome)
      .padding(.horizontal, BlitzControlMetrics.horizontalPadding(controlSize) + 2)
      .padding(.vertical, 4)
      .frame(minHeight: BlitzControlMetrics.height(controlSize))
      .foregroundStyle(foreground(configuration.role))
      .background(fill(destructive: destructive), in: shape)
      .overlay {
        shape.strokeBorder(border(destructive: destructive), lineWidth: 1).allowsHitTesting(false)
      }
      .scaleEffect(pressed ? 0.97 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
      .animation(.easeOut(duration: 0.15), value: isHovered)
      .opacity(isEnabled ? (pressed ? 0.9 : 1) : 0.4)
      .contentShape(shape)
      .onHover { isHovered = $0 }
      .blitzPointingHand()
  }

  private func foreground(_ role: ButtonRole?) -> Color {
    if role == .destructive, emphasis != .accent { return BlitzUI.recordRed }
    switch emphasis {
    case .accent: return isEnabled ? BlitzUI.onAccent : BlitzUI.secondaryText
    case .emphasized: return BlitzUI.canvasBackground
    case .secondary: return BlitzUI.primaryText
    case .quiet: return isHovered && isEnabled ? BlitzUI.primaryText : BlitzUI.secondaryText
    }
  }

  private func border(destructive: Bool) -> Color {
    if emphasis == .accent, !isEnabled { return BlitzUI.separator }
    if emphasis == .quiet || emphasis == .accent || emphasis == .emphasized { return .clear }
    if destructive { return BlitzUI.recordRed.opacity(0.35) }
    return BlitzUI.separator
  }

  /// Flat fills only: no gradient, glow or highlight.
  private func fill(destructive: Bool) -> Color {
    let hovered = isHovered && isEnabled
    if destructive, emphasis != .quiet {
      return BlitzUI.recordRed.opacity(hovered ? 0.16 : 0.1)
    }
    switch emphasis {
    // Disabled, the system grays the accent; a neutral fill keeps the label readable.
    case .accent: return isEnabled ? BlitzUI.mint.opacity(hovered ? 0.88 : 1) : BlitzUI.controlFill
    case .emphasized: return BlitzUI.primaryText.opacity(hovered ? 0.88 : 1)
    case .secondary: return hovered ? BlitzUI.selectedFill : BlitzUI.controlFill
    case .quiet: return hovered ? BlitzUI.quietFill : .clear
    }
  }
}

extension View {
  func blitzButton(_ emphasis: BlitzButtonEmphasis) -> some View {
    buttonStyle(BlitzButtonStyle(emphasis))
  }

  @ViewBuilder func blitzPointingHand() -> some View {
    if #available(macOS 15.0, *) {
      pointerStyle(.link).allowsWindowActivationEvents(true)
    } else {
      self
    }
  }

  func blitzTheme() -> some View {
    self
      .background(BlitzUI.canvasBackground.ignoresSafeArea())
      .foregroundStyle(BlitzUI.primaryText)
      .tint(BlitzUI.mint)
      .buttonStyle(BlitzButtonStyle(.secondary))
      .toggleStyle(BlitzCheckboxStyle())
  }
}

extension View {
  func blitzChipGroup() -> some View {
    padding(2)
      .background(BlitzUI.controlFill, in: RoundedRectangle(cornerRadius: BlitzUI.controlRadius))
  }
}

enum BlitzStatusTone: Equatable {
  case good, working, warning, critical, muted

  var color: Color {
    switch self {
    case .good: BlitzUI.good
    case .working: BlitzUI.supportingText
    case .warning: BlitzUI.warning
    case .critical: BlitzUI.recordRed
    case .muted: BlitzUI.tertiaryText
    }
  }
}

struct BlitzStatusDot: View {
  let tone: BlitzStatusTone
  var diameter: CGFloat = 6

  var body: some View {
    Circle().fill(tone.color).frame(width: diameter, height: diameter)
      .accessibilityHidden(true)
  }
}

struct BlitzStatusBadge: View {
  let title: String
  let tone: BlitzStatusTone

  var body: some View {
    HStack(spacing: 6) {
      BlitzStatusDot(tone: tone, diameter: 5)
      Text(title).font(BlitzType.captionEmphasis).lineLimit(1)
    }
    .foregroundStyle(tone == .muted || tone == .working ? BlitzUI.secondaryText : tone.color)
    .padding(.horizontal, 9)
    .frame(height: 24)
    .background(
      (tone == .muted || tone == .working ? BlitzUI.primaryText : tone.color).opacity(0.08),
      in: .capsule)
  }
}

/// Hover and pressed fill shared by every full-row button: menus, browser rows, tray rows.
private struct BlitzRowHighlight: ViewModifier {
  let isPressed: Bool
  let radius: CGFloat
  @State private var hovered = false
  @Environment(\.isEnabled) private var isEnabled

  func body(content: Content) -> some View {
    content
      .background(
        isPressed ? BlitzUI.selectedFill : hovered && isEnabled ? BlitzUI.hoverFill : .clear,
        in: RoundedRectangle(cornerRadius: radius)
      )
      .contentShape(RoundedRectangle(cornerRadius: radius))
      .onHover { hovered = $0 }
      .blitzPointingHand()
  }
}

struct BlitzRowButtonStyle: ButtonStyle {
  var radius: CGFloat = 0

  func makeBody(configuration: Configuration) -> some View {
    configuration.label.modifier(
      BlitzRowHighlight(isPressed: configuration.isPressed, radius: radius))
  }
}

extension View {
  /// Severity-tinted surface for alerts.
  func blitzToneCard(_ tone: MetricTone, radius: CGFloat = BlitzUI.cardRadius) -> some View {
    background(tone.color.opacity(0.08), in: RoundedRectangle(cornerRadius: radius))
      .overlay {
        RoundedRectangle(cornerRadius: radius)
          .strokeBorder(tone.color.opacity(0.22), lineWidth: 1).allowsHitTesting(false)
      }
  }
}

private struct BlitzRowModifier: ViewModifier {
  @State private var hovered = false

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 16).padding(.vertical, 10)
      .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
      .background(hovered ? BlitzUI.quietFill : .clear)
      .contentShape(Rectangle())
      .onHover { hovered = $0 }
  }
}

struct BlitzRowDivider: View {
  var leading: CGFloat = 56

  var body: some View {
    Rectangle().fill(BlitzUI.separator).frame(height: 1).padding(.leading, leading)
  }
}

extension View {
  func blitzRow() -> some View { modifier(BlitzRowModifier()) }

  func blitzTable() -> some View {
    background(BlitzUI.cardFill)
      .clipShape(RoundedRectangle(cornerRadius: BlitzUI.cardRadius))
      .overlay {
        RoundedRectangle(cornerRadius: BlitzUI.cardRadius)
          .strokeBorder(BlitzUI.separator, lineWidth: 1).allowsHitTesting(false)
      }
  }
}

struct BlitzSwitchStyle: ToggleStyle {
  var showsLabel = true

  func makeBody(configuration: Configuration) -> some View {
    BlitzToggleBody(configuration: configuration, kind: .switch, showsLabel: showsLabel)
  }
}

struct BlitzCheckboxStyle: ToggleStyle {
  var showsLabel = true

  func makeBody(configuration: Configuration) -> some View {
    BlitzToggleBody(configuration: configuration, kind: .checkbox, showsLabel: showsLabel)
  }
}

private struct BlitzToggleBody: View {
  enum Kind { case `switch`, checkbox }

  let configuration: ToggleStyleConfiguration
  let kind: Kind
  let showsLabel: Bool
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovered = false

  var body: some View {
    Button {
      withAnimation(.easeOut(duration: 0.14)) { configuration.isOn.toggle() }
    } label: {
      HStack(spacing: 10) {
        if kind == .checkbox { indicator }
        if showsLabel {
          configuration.label.frame(
            maxWidth: kind == .switch ? .infinity : nil, alignment: .leading)
        }
        if kind == .switch { indicator }
      }.frame(minWidth: 34, minHeight: 34).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(isEnabled ? 1 : 0.4)
    .onHover { hovered = $0 }
    .blitzPointingHand()
    .accessibilityRepresentation {
      Toggle(isOn: configuration.$isOn) { configuration.label }
    }
  }

  @ViewBuilder private var indicator: some View {
    let on = configuration.isOn
    switch kind {
    case .switch:
      Capsule().fill(on ? BlitzUI.mint : hovered ? BlitzUI.strongFill : BlitzUI.selectedFill)
        .overlay(alignment: on ? .trailing : .leading) {
          Circle().fill(BlitzUI.onAccent).overlay {
            Circle().strokeBorder(on ? BlitzUI.separator : BlitzUI.strongStroke, lineWidth: 0.5)
          }
          .frame(width: 16, height: 16).padding(3)
        }
        .frame(width: 38, height: 22)
    case .checkbox:
      RoundedRectangle(cornerRadius: 5)
        .fill(on ? BlitzUI.mint : hovered ? BlitzUI.hoverFill : BlitzUI.controlFill)
        .overlay {
          RoundedRectangle(cornerRadius: 5)
            .strokeBorder(on ? .clear : BlitzUI.strongStroke, lineWidth: 1)
        }
        .overlay {
          Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
            .foregroundStyle(BlitzUI.onAccent).opacity(on ? 1 : 0)
        }
        .frame(width: 18, height: 18)
    }
  }
}
