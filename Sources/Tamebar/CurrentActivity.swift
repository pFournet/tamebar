import Foundation

/// What is still affected now. Ended sessions and servers are recovery history, not current
/// activity, so they do not appear in the card or Activity tab.
struct CurrentActivity: Equatable, Sendable {
  struct Slowed: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable { case session, workload, app }

    let id: String
    let name: String
    let kind: Kind
  }

  let slowed: [Slowed]
  let paused: [StoppedEntry]
  let quitApps: [StoppedEntry]
  let pluginsOff: [StoppedEntry]

  init(stopped: [StoppedEntry] = [], slowed: [Slowed] = []) {
    self.slowed = slowed
    paused = stopped.filter { $0.state == .paused }
    quitApps = stopped.filter { $0.state == .quit }
    pluginsOff = stopped.filter { $0.state == .off }
  }

  var cardLines: [String] {
    var lines: [String] = []
    if slowed.count == 1, let item = slowed.first {
      lines.append("Slowed now: \(item.name)")
    } else if !slowed.isEmpty {
      let sessions = slowed.filter { $0.kind == .session }.count
      let others = slowed.count - sessions
      var parts: [String] = []
      if sessions > 0 { parts.append("\(sessions) \(sessions == 1 ? "session" : "sessions")") }
      if others > 0 {
        parts.append("\(others) \(others == 1 ? "app or workload" : "apps or workloads")")
      }
      lines.append("Slowed now: " + parts.joined(separator: ", "))
    }
    if !paused.isEmpty {
      lines.append("\(paused.count) paused · resume automatically")
    }
    if !quitApps.isEmpty {
      lines.append(
        "\(quitApps.count) \(quitApps.count == 1 ? "app" : "apps") quit · reopen if needed")
    }
    if !pluginsOff.isEmpty {
      lines.append(
        "\(pluginsOff.count) Codex \(pluginsOff.count == 1 ? "plugin" : "plugins") off · optional")
    }
    return lines
  }
}
