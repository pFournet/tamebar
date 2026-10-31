import Foundation

/// The short text each `tamebar` command prints without `--json`, from the same report.
enum CLIText {
  // MARK: status

  /// "ends idle sessions · turns off unused Codex plugins · never ports 3000, 5173 · never
  /// Codex chat", or "watches and slows only" with both switches off.
  static func automatic(_ automatic: CLIStatus.Automatic) -> String {
    var parts: [String] = []
    if automatic.endIdleSessions { parts.append("ends idle sessions") }
    if automatic.trimCodexPlugins { parts.append("turns off unused Codex plugins") }
    if parts.isEmpty { parts.append("watches and slows only") }
    if !automatic.protectedPorts.isEmpty {
      parts.append(
        "never ports " + automatic.protectedPorts.map(String.init).joined(separator: ", "))
    }
    if !automatic.keptCodexServers.isEmpty {
      parts.append("never Codex " + automatic.keptCodexServers.joined(separator: ", "))
    }
    return parts.joined(separator: " · ")
  }

  static func status(_ report: CLIStatus, timeZone: TimeZone) -> String {
    var lines: [String] = []
    let verdict = report.assessment
    lines.append(
      verdict.advice.isEmpty ? "\(verdict.title)." : "\(verdict.title). \(verdict.advice)")
    let memory = report.memory
    var memoryLine =
      "\(ByteText.compact(memory.availableBytes)) available of \(ByteText.compact(memory.totalBytes))"
    if let swap = memory.swapUsedBytes { memoryLine += " · swap \(ByteText.compact(swap))" }
    memoryLine += " · pressure \(memory.pressure)"
    lines.append(row("Memory", memoryLine))
    lines.append(row("CPU", report.cpu.percent.map { "\(Int($0.rounded()))%" } ?? "measuring"))
    lines.append(
      row(
        "Heat",
        report.thermal.acting
          ? "\(report.thermal.state) · "
            + "Tamebar slows heavy work and pauses idle sessions until it cools"
          : report.thermal.state))
    lines.append(row("Strain", strain(report.strain)))
    if let codex = report.codexPlugins { lines.append(row("Codex", codexPlugins(codex, timeZone))) }
    lines.append(row("Auto", automatic(report.automatic)))
    for waiting in report.strain.waiting {
      lines.append(
        row(
          "Waiting",
          "\(waiting.project) · \(waiting.toolName), "
            + "\(StartWait.waited(TimeInterval(waiting.waitedSeconds))) · "
            + "tamebar start \(waiting.project)"))
    }
    lines.append(row("Disk", "\(ByteText.compact(report.disk.freeBytes)) free"))
    if let top = report.top.memory {
      lines.append(row("Top RAM", "\(top.name) \(ByteText.compact(top.bytes))"))
    }
    if let top = report.top.cpu {
      lines.append(row("Top CPU", "\(top.name) \(Int(top.percent.rounded()))%"))
    }
    lines.append(row("Call", call(report.call)))
    let tamebar = report.tamebar
    if let pid = tamebar.pid {
      lines.append("Tamebar is running (pid \(pid)).")
    } else {
      lines.append(
        "Tamebar isn't running. The numbers above are a fresh scan; what follows is its saved state."
      )
    }
    for note in tamebar.notes { lines.append(row("Note", note)) }
    let now = report.generatedAt
    for paused in tamebar.autoPaused {
      let name =
        paused.kind == "project"
        ? paused.project ?? paused.id
        : [paused.toolName, paused.project].compactMap { $0 }.joined(separator: " · ")
      let why =
        switch paused.reason {
        case "meeting": "call"
        case "heat": "heat"
        default: "memory pressure"
        }
      let held = DurationText.span(now.timeIntervalSince(paused.since))
      lines.append(row("Paused", "\(name) (\(why), \(held))"))
    }
    for app in tamebar.quitApps {
      let state = app.confirmed ? "reopens when memory recovers" : "quitting"
      lines.append(row("Quit", "\(app.name), \(ByteText.compact(app.memoryBytes)), \(state)"))
    }
    for slowed in tamebar.slowed {
      let text =
        switch slowed.kind {
        case "session": "\(slowed.label): \(slowed.executables.joined(separator: ", "))"
        case "app":
          "\(slowed.label), in the background"
            + (slowed.cpuPercent.map { " (\(AppSlow.percent($0)) CPU)" } ?? "")
        default: slowed.label
        }
      lines.append(row("Slowed", text))
    }
    if tamebar.autoPaused.isEmpty && tamebar.quitApps.isEmpty && tamebar.slowed.isEmpty {
      lines.append("Nothing paused, quit or slowed by Tamebar.")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// "struggling (fan 78%)", "none", or "unknown" without a running Tamebar to judge it (Q19).
  static func strain(_ strain: CLIStatus.Strain) -> String {
    guard let struggling = strain.struggling else { return "unknown, Tamebar isn't running" }
    guard struggling else { return "none" }
    let reasons = strain.signals.map(\.text)
    return reasons.isEmpty ? "struggling" : "struggling (\(reasons.joined(separator: ", ")))"
  }

  /// Q21: "off by Tamebar, no call in 30 days: cubic, context7 (checked Oct 30 22:41)".
  static func codexPlugins(_ codex: CLIStatus.CodexPlugins, _ timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "MMM d HH:mm"
    let when = "checked \(formatter.string(from: codex.checkedAt))"
    if let held = codex.held { return "nothing turned off: \(held) (\(when))" }
    guard !codex.off.isEmpty else { return "nothing unused in 30 days (\(when))" }
    return "off by Tamebar, no call in 30 days: \(codex.off.joined(separator: ", ")) (\(when))"
  }

  private static func row(_ label: String, _ value: String) -> String {
    label.padding(toLength: 9, withPad: " ", startingAt: 0) + value
  }

  private static func call(_ call: CLIStatus.Call?) -> String {
    guard let call else { return "unknown" }
    switch (call.mic, call.camera) {
    case (true, true): return "mic and camera in use"
    case (true, false): return "mic in use"
    case (false, true): return "camera on"
    case (false, false): return "none"
    }
  }

  // MARK: sessions

  static func sessions(_ report: CLISessions, timeZone: TimeZone) -> String {
    var lines: [String] = []
    let total = report.sessions.reduce(UInt64(0)) { $0 + $1.memoryBytes }
    var header =
      "\(report.sessions.count) AI \(report.sessions.count == 1 ? "session" : "sessions")"
      + " · \(ByteText.compact(total))"
    if report.hidden > 0 {
      header +=
        " · \(report.hidden) under \(ByteText.compact(report.minBytes)) hidden (--all shows them)"
    }
    lines.append(header)
    if !report.tamebarRunning { lines.append("Tamebar isn't running.") }
    if report.incomplete { lines.append("The scan was incomplete; some sessions may be missing.") }
    let projects = report.sessions.map { project($0.project) }
    let projectWidth = projects.map(\.count).max() ?? 0
    let memoryWidth = report.sessions.map { ByteText.compact($0.memoryBytes).count }.max() ?? 0
    for (session, project) in zip(report.sessions, projects) {
      let state = state(session)
      let protections = protections(session)
      var line =
        pad(session.toolName, 11) + "  " + pad(project, projectWidth) + "  "
        + pad(ByteText.compact(session.memoryBytes), memoryWidth) + "  "
      line += protections.isEmpty ? state : pad(state, 11) + "  " + protections
      lines.append(line)
      if let resume = session.resumeCommand { lines.append("    resume: \(resume)") }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func project(_ name: String?) -> String {
    guard let name else { return "-" }
    return name.count > 24 ? String(name.prefix(23)) + "…" : name
  }

  private static func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text.padding(toLength: width, withPad: " ", startingAt: 0)
  }

  private static func state(_ session: CLISessions.Session) -> String {
    switch session.state {
    case "paused":
      guard session.pausedBy == "tamebar" else { return "paused by you" }
      switch session.pauseReason {
      case "meeting": return "paused by Tamebar (call)"
      case "heat": return "paused by Tamebar (heat)"
      default: return "paused by Tamebar (memory pressure)"
      }
    case "idle":
      return session.idleSeconds.map { "idle \(age(TimeInterval($0)))" } ?? "idle"
    case "busy":
      return "busy"
    default:
      return "status unknown"
    }
  }

  /// `45m`, `5h`, `2d`.
  static func age(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    if minutes >= 1_440 { return "\(minutes / 1_440)d" }
    if minutes >= 60 { return "\(minutes / 60)h" }
    return minutes < 1 ? "<1m" : "\(minutes)m"
  }

  private static func protections(_ session: CLISessions.Session) -> String {
    session.protections.map { protection in
      switch protection {
      case "kept": "kept"
      case "kept_project": "project kept running"
      case "serving":
        session.ports.isEmpty
          ? "serving" : "serving " + session.ports.map { ":\($0)" }.joined(separator: " ")
      case "background_job": "background job"
      default: protection
      }
    }.joined(separator: ", ")
  }

  // MARK: stopped

  /// Q15's terminal mock: one line per entry (when, what, kind, memory, why and how it comes
  /// back), then the command that brings it back under it, in full so it can be pasted.
  static func stopped(_ report: CLIStopped, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "MMM d HH:mm"
    var lines: [String] = []
    let entries = report.stopped
    if entries.isEmpty {
      lines.append("Nothing stopped by Tamebar.")
    } else {
      let withCommand = entries.contains { $0.resumeCommand != nil }
      lines.append(
        "\(entries.count) stopped · "
          + (withCommand
            ? "bring back with the command under each"
            : (entries.count == 1 ? "it comes back on its own" : "each comes back on its own")))
    }
    if !report.tamebarRunning {
      lines.append("Tamebar isn't running; this is what it saved last.")
    }
    for note in report.notes { lines.append("Note: \(note)") }
    guard !entries.isEmpty else { return lines.joined(separator: "\n") + "\n" }
    lines.append("")
    let dates = entries.map { formatter.string(from: $0.stoppedAt) }
    let names = entries.map { project($0.name) }
    let memories = entries.map { $0.memoryBytes.map(ByteText.compact) ?? "—" }
    let dateWidth = dates.map(\.count).max() ?? 0
    let nameWidth = names.map(\.count).max() ?? 0
    let kindWidth = entries.map(\.kind.count).max() ?? 0
    let memoryWidth = memories.map(\.count).max() ?? 0
    let indent = String(repeating: " ", count: dateWidth + 2)
    for (index, entry) in entries.enumerated() {
      lines.append(
        pad(dates[index], dateWidth) + "  " + pad(names[index], nameWidth) + "  "
          + pad(entry.kind, kindWidth) + "  " + pad(memories[index], memoryWidth) + "  "
          + stoppedDetail(entry))
      if let command = entry.resumeCommand {
        lines.append(indent + command)
      } else if entry.kind == StoppedEntry.Kind.codexPlugin.rawValue {
        lines.append(indent + "Undo in Tamebar's Stopped list")
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// The report's state and reason in words, as `StoppedEntry.commandDetail` writes them.
  private static func stoppedDetail(_ entry: CLIStopped.Entry) -> String {
    let reason: StoppedEntry.Reason =
      switch entry.reason {
      case "call": .call
      case "heat": .heat
      case "idle": .idle(days: entry.idleDays ?? 0)
      case "unused": .unused(days: entry.idleDays ?? 0)
      case "by_you": .byYou
      default: .memory
      }
    let state = StoppedEntry.State(rawValue: entry.state) ?? .paused
    return StoppedEntry(
      id: entry.id, kind: .session, name: entry.name, stoppedAt: entry.stoppedAt, state: state,
      reason: reason, target: .ledger(entry.id)
    ).commandDetail
  }

  // MARK: history

  static func history(_ report: CLIHistory, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "MMM d HH:mm"
    let date = { (value: Date) in formatter.string(from: value) }
    var lines = [
      "Tamebar history · last \(window(TimeInterval(report.windowSeconds)))"
        + " (since \(date(report.since)))"
    ]
    if !report.tamebarRunning {
      lines.append("Tamebar isn't running; its files end when it stopped.")
    }
    for note in report.notes { lines.append("Note: \(note)") }
    let pressure = report.events.filter { $0.kind == "pressure" }
    lines.append("Pressure events: \(pressure.count)")
    let shown = pressure.suffix(5)
    if pressure.count > shown.count {
      lines.append("  (\(pressure.count - shown.count) earlier; --json lists them all)")
    }
    for event in shown {
      var parts = [event.detail]
      if let available = event.availableBytes {
        parts.append("\(ByteText.compact(available)) available")
      }
      if let swap = event.swapUsedBytes { parts.append("\(ByteText.compact(swap)) swap") }
      lines.append("  \(date(event.date))  " + parts.joined(separator: " · "))
      let users = [
        event.topApps.map { "\($0.name) \(ByteText.compact($0.bytes))" }.joined(separator: ", "),
        event.topProjects.map { "\($0.name) \(ByteText.compact($0.bytes))" }
          .joined(separator: ", "),
      ].filter { !$0.isEmpty }
      if !users.isEmpty { lines.append("                " + users.joined(separator: " · ")) }
    }
    if let peak = report.samples.max(by: { $0.memoryPercent < $1.memoryPercent }) {
      var line = "Peak RAM \(Int(peak.memoryPercent.rounded()))% at \(date(peak.date))"
      if let lead = peak.memoryLead { line += " (\(lead.name) \(ByteText.compact(lead.bytes)))" }
      lines.append(line)
    }
    if let peak = report.samples.filter({ $0.cpuPercent != nil })
      .max(by: { ($0.cpuPercent ?? 0) < ($1.cpuPercent ?? 0) }), let cpu = peak.cpuPercent
    {
      var line = "Peak CPU \(Int(cpu.rounded()))% at \(date(peak.date))"
      if let lead = peak.cpuLead { line += " (\(lead.name) \(Int(lead.percent.rounded()))%)" }
      lines.append(line)
    }
    if let latest = report.pressureLog.last {
      let minutes = report.pressureLog.count
      var line =
        "Pressure log: \(minutes) \(minutes == 1 ? "entry" : "entries"), latest \(date(latest.date))"
        + " \(latest.risk)"
      let projects = latest.topProjects.prefix(3).map { "\($0.name) \($0.memory)" }
      if !projects.isEmpty { line += " · " + projects.joined(separator: ", ") }
      lines.append(line)
    }
    var counts: [String: Int] = [:]
    for event in report.events where event.kind != "pressure" {
      counts[event.kind, default: 0] += 1
    }
    let others: [(kind: String, count: Int)] = counts.map { ($0.key, $0.value) }
      .sorted { $0.count == $1.count ? $0.kind < $1.kind : $0.count > $1.count }
    if !others.isEmpty {
      let parts = others.map { "\($0.count) \($0.kind)" }
      lines.append("Other events: " + parts.joined(separator: ", "))
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// `30m`, `24h`, `7d`.
  static func window(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes)m" }
    if minutes < 2 * 1_440 || minutes % 1_440 != 0 { return "\(minutes / 60)h" }
    return "\(minutes / 1_440)d"
  }
}
