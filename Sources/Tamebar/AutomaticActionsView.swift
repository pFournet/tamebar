import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Automatic actions (Q10, Q11, Q17; approved as mocked): when Tamebar may end
/// unused AI sessions on its own, whether it may end long-idle ones and trim Codex plugins (P2:
/// off until switched on, with the ports and servers never touched), and per app whether it may
/// slow it in the background and quit it under memory pressure.
struct AutomaticActionsSection: View {
  @ObservedObject var processes: DevProcessModel
  /// Apps added or changed while Settings shows: their rows stay put until it closes.
  @State private var added: Set<String> = []

  /// The two checkbox columns, wide enough for their headers.
  static let column: CGFloat = 124
  /// The trailing "suggested" column.
  static let tag: CGFloat = 64

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Automatic actions").font(BlitzType.section)
      unusedSessions
      IdleSessionsSwitch(processes: processes)
      Rectangle().fill(BlitzUI.separator).frame(height: 1)
      CodexPluginsSwitch(processes: processes)
      Rectangle().fill(BlitzUI.separator).frame(height: 1)
      apps
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .panelCard(padding: 16)
  }

  private var unusedSessions: some View {
    let settings = processes.autoEnd
    return VStack(alignment: .leading, spacing: 6) {
      Text("Unused AI sessions").font(BlitzType.label)
      VStack(alignment: .leading, spacing: 2) {
        BlitzRadioButton(title: "Ask me", isSelected: settings.mode == .ask) {
          processes.setAutoEnd(.init(mode: .ask, days: settings.days))
        }
        HStack(spacing: 8) {
          BlitzRadioButton(title: "End after", isSelected: settings.mode == .auto) {
            processes.setAutoEnd(.init(mode: .auto, days: settings.days))
          }
          // Only End after uses the count, so it is set once that is chosen.
          BlitzDayStepper(days: settings.days, range: AutoEndSettings.dayRange) { days in
            processes.setAutoEnd(.init(mode: settings.mode, days: days))
          }
          .disabled(settings.mode != .auto)
          Text(settings.days == 1 ? "day" : "days").font(BlitzType.callout)
            .foregroundStyle(settings.mode == .auto ? BlitzUI.primaryText : BlitzUI.tertiaryText)
        }
      }
      Text(
        "Ends idle sessions while you’re away. Find their restart commands with tamebar stopped."
      )
      .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
    }
  }

  /// Q17's mockup: one row per app, "Slow in background" (on unless unticked) and "Quit under
  /// pressure" (Q11's opt-in), memory and recent peak CPU, "suggested" on apps that keep topping
  /// memory under pressure, then "+ Add app".
  private var apps: some View {
    let rows = processes.appsUnderPressure(added: added)
    return VStack(alignment: .leading, spacing: 4) {
      Text("Apps under pressure").font(BlitzType.label)
      if !rows.isEmpty {
        HStack(spacing: 0) {
          Spacer(minLength: 0)
          Text("Slow in background").frame(width: Self.column)
          Text("Quit under pressure").frame(width: Self.column)
          Color.clear.frame(width: Self.tag)
        }
        .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
        .accessibilityHidden(true)
        ForEach(rows) { row in
          AppUnderPressureRow(
            row: row,
            slow: Binding(
              get: { row.slow },
              set: { on in
                added.insert(row.bundleID)
                processes.setSlowInBackground(row.bundleID, on: on)
              }),
            quit: Binding(
              get: { row.quit },
              set: { on in
                added.insert(row.bundleID)
                processes.setQuitUnderPressure(row.bundleID, on: on)
              }))
        }
      }
      Button(action: addApp) {
        Label("Add app", systemImage: "plus")
      }
      .blitzButton(.quiet).controlSize(.small)
      Text("Slow in background is on for every app unless you untick it.")
        .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
    }
  }

  /// The system's app chooser, in Applications. The app gets a row with its defaults; ticking
  /// or unticking is what keeps it in the list.
  private func addApp() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Add"
    guard panel.runModal() == .OK, let url = panel.url,
      let bundleID = Bundle(url: url)?.bundleIdentifier
    else { return }
    added.insert(bundleID)
  }
}

/// P2: Q18 and Q20 behind one check, off on a new install, with the ports never ended.
struct IdleSessionsSwitch: View {
  @ObservedObject var processes: DevProcessModel

  var body: some View {
    let safety = processes.safety
    return VStack(alignment: .leading, spacing: 6) {
      Toggle(
        "End long-idle sessions on their own",
        isOn: Binding(
          get: { safety.endIdleSessions },
          set: { on in
            var next = processes.safety
            next.endIdleSessions = on
            processes.setSafety(next)
          })
      )
      .toggleStyle(BlitzCheckboxStyle())
      Text(
        "Idle 12 h while memory stays tight, or idle 24 h with a dev server nobody opened. "
          + "Find their restart commands with tamebar stopped."
      )
      .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      .fixedSize(horizontal: false, vertical: true)
      SafetyListField(
        title: "Never end servers on ports", placeholder: "3000, 5173",
        value: AutomaticSafety.text(safety.protectedPorts),
        commit: { text in
          var next = processes.safety
          next.protectedPorts = AutomaticSafety.ports(text)
          processes.setSafety(next)
          return AutomaticSafety.text(next.protectedPorts)
        })
    }
  }
}

/// P2: Q21 behind one check, off on a new install, with the servers never turned off.
struct CodexPluginsSwitch: View {
  @ObservedObject var processes: DevProcessModel

  var body: some View {
    let safety = processes.safety
    return VStack(alignment: .leading, spacing: 6) {
      Toggle(
        "Turn off unused Codex plugins",
        isOn: Binding(
          get: { safety.trimCodexPlugins },
          set: { on in
            var next = processes.safety
            next.trimCodexPlugins = on
            processes.setSafety(next)
          })
      )
      .toggleStyle(BlitzCheckboxStyle())
      Text(
        "Sets enabled = false in ~/.codex/config.toml, after a backup, for a server no Codex "
          + "session called in 30 days. New sessions only; turn it back on from Activity."
      )
      .font(BlitzType.caption).foregroundStyle(BlitzUI.secondaryText)
      .fixedSize(horizontal: false, vertical: true)
      SafetyListField(
        title: "Never turn off", placeholder: "server names",
        value: AutomaticSafety.text(safety.keptCodexServers),
        commit: { text in
          var next = processes.safety
          next.keptCodexServers = AutomaticSafety.names(text)
          processes.setSafety(next)
          return AutomaticSafety.text(next.keptCodexServers)
        })
    }
  }
}

/// A comma-separated list in one field, saved on Return or when the field loses focus, then
/// shown as it was read (invalid entries dropped).
struct SafetyListField: View {
  let title: String
  let placeholder: String
  let value: String
  /// Saves the text and returns the list as saved.
  let commit: (String) -> String
  @State private var text = ""
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Text(title).font(BlitzType.callout).foregroundStyle(BlitzUI.primaryText)
      TextField(title, text: $text, prompt: Text(placeholder))
        .labelsHidden().textFieldStyle(.roundedBorder).font(BlitzType.body)
        .frame(maxWidth: 220)
        .focused($focused)
        .onSubmit { text = commit(text) }
        .onChange(of: focused) { _, isFocused in
          if !isFocused { text = commit(text) }
        }
    }
    .onAppear { text = value }
    .onChange(of: value) { _, saved in
      if !focused { text = saved }
    }
  }
}

/// One app of the list: icon, name, memory and peak CPU, its two checks, and "suggested".
struct AppUnderPressureRow: View {
  let row: AppsUnderPressure.Row
  @Binding var slow: Bool
  @Binding var quit: Bool

  var body: some View {
    HStack(spacing: 0) {
      HStack(spacing: 10) {
        ApplicationIcon(source: .name(row.bundleID), size: 20, fallback: "app")
        Text(row.name).font(BlitzType.body).lineLimit(1).truncationMode(.middle)
          .help(row.bundleID).layoutPriority(1)
        Text(row.detail).font(BlitzType.body).monospacedDigit()
          .foregroundStyle(BlitzUI.secondaryText)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      Toggle("Slow \(row.name) in background", isOn: $slow)
        .toggleStyle(BlitzCheckboxStyle(showsLabel: false))
        .frame(width: AutomaticActionsSection.column)
      Toggle("Quit \(row.name) under pressure", isOn: $quit)
        .toggleStyle(BlitzCheckboxStyle(showsLabel: false))
        .frame(width: AutomaticActionsSection.column)
      Text(row.suggested ? "suggested" : "").font(BlitzType.caption)
        .foregroundStyle(BlitzUI.secondaryText)
        .frame(width: AutomaticActionsSection.tag, alignment: .leading)
    }
    .frame(minHeight: 30)
  }
}

/// An app in the Q11 list, named as the Mac knows it: the running app's name, else the installed
/// bundle's, else its bundle id.
struct QuitListApp: Identifiable, Equatable {
  let bundleID: String
  let name: String
  var id: String { bundleID }

  @MainActor static func resolve(_ bundleID: String) -> QuitListApp {
    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
      .first, let name = running.localizedName
    {
      return .init(bundleID: bundleID, name: name)
    }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
      let name = FileManager.default.displayName(atPath: url.path)
      return .init(
        bundleID: bundleID, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
    }
    return .init(bundleID: bundleID, name: bundleID)
  }
}

/// One choice of a radio group: when selected, a circle in the system accent (`BlitzUI.mint`) with
/// a white `onAccent` dot. The group is its caller's buttons.
struct BlitzRadioButton: View {
  let title: String
  let isSelected: Bool
  let action: () -> Void
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Circle()
          .fill(isSelected ? BlitzUI.mint : hovered ? BlitzUI.hoverFill : BlitzUI.controlFill)
          .overlay {
            Circle().strokeBorder(isSelected ? .clear : BlitzUI.strongStroke, lineWidth: 1)
          }
          .overlay {
            Circle().fill(BlitzUI.onAccent).frame(width: 6, height: 6)
              .opacity(isSelected ? 1 : 0)
          }
          .frame(width: 16, height: 16)
        Text(title).font(BlitzType.callout).foregroundStyle(BlitzUI.primaryText)
      }
      .frame(minHeight: 28).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(isEnabled ? 1 : 0.4)
    .onHover { hovered = $0 }
    .blitzPointingHand()
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}

/// A whole-number stepper: minus, the value in monospaced digits, plus.
struct BlitzDayStepper: View {
  let days: Int
  let range: ClosedRange<Int>
  let onChange: (Int) -> Void
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    HStack(spacing: 0) {
      step("minus", to: days - 1)
      Text("\(days)").font(BlitzType.numeric).foregroundStyle(BlitzUI.primaryText)
        .frame(width: 26)
      step("plus", to: days + 1)
    }
    .blitzChipGroup()
    .opacity(isEnabled ? 1 : 0.4)
    .accessibilityRepresentation {
      Stepper(
        "Days", value: Binding(get: { days }, set: { onChange($0) }), in: range)
    }
  }

  private func step(_ symbol: String, to value: Int) -> some View {
    Button {
      onChange(value)
    } label: {
      Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
        .frame(width: 24, height: 22).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(BlitzUI.supportingText)
    .disabled(!range.contains(value))
    .blitzPointingHand()
  }
}
