import Darwin
import Foundation

/// What a consumer of memory or CPU is, which decides what the automatic actions may do to it.
enum ConsumerKind: String, Equatable, Sendable {
  /// A Claude, Codex or Cursor session with its tool servers.
  case aiSession
  /// An app with all its helpers.
  case app
  /// Tools started from a terminal, grouped by program and project, such as `node · fmx_ws`.
  case workload
  /// macOS services; shown for context, never stopped from here.
  case system
}

/// One thing the user recognizes as using memory or CPU, built from live processes.
struct ResourceConsumer: Identifiable, Equatable, Sendable {
  let id: String
  let kind: ConsumerKind
  let name: String
  /// App or tool name used to look up the row's icon.
  let iconName: String
  let processIDs: [Int32]
  let memoryBytes: UInt64
  /// Sum across processes; 100% equals one core.
  let cpuPercent: Double
  let directory: String?
  let isPaused: Bool
  /// The AI thread behind an AI session; absent for other kinds.
  let threadID: String?

  var project: String? { directory.map { URL(fileURLWithPath: $0).lastPathComponent } }
}

enum ResourceConsumers {
  struct Input {
    let threads: [AIThread]
    let resources: [ResourceProcess]
    /// Processes stopped with SIGSTOP.
    let stopped: Set<Int32>
  }

  private static let minimumBytes: UInt64 = 20 * 1_024 * 1_024

  /// Groups processes so each block of memory and CPU belongs to exactly one consumer.
  static func build(_ input: Input) -> [ResourceConsumer] {
    var seen: Set<String> = []
    let threads = input.threads.filter { seen.insert($0.id).inserted }
    var consumers = threads.map { thread in
      ResourceConsumer(
        id: "ai:" + thread.id, kind: .aiSession, name: thread.displayName,
        iconName: thread.tool.appName ?? thread.name, processIDs: thread.processIDs,
        memoryBytes: thread.memoryBytes, cpuPercent: thread.cpuPercent,
        directory: thread.directory, isPaused: thread.isPaused, threadID: thread.id)
    }
    let claimed = Set(threads.flatMap(\.processIDs))
    let own = getpid()
    let rest = input.resources.filter { !claimed.contains($0.processID) && $0.processID != own }
    let grouped = Dictionary(grouping: rest, by: key)
    for (key, items) in grouped {
      guard let first = items.first else { continue }
      let kind: ConsumerKind =
        key == systemKey ? .system : key.hasPrefix("app:") ? .app : .workload
      let ids = items.map(\.processID).sorted()
      let name: String =
        switch kind {
        case .system: "macOS services"
        case .app: first.bundleApp ?? first.name
        default:
          first.directory.map { "\(first.name) · \(URL(fileURLWithPath: $0).lastPathComponent)" }
            ?? first.name
        }
      consumers.append(
        ResourceConsumer(
          id: key, kind: kind, name: name,
          iconName: kind == .app ? name : kind == .system ? "Activity Monitor" : first.owner,
          processIDs: ids, memoryBytes: items.compactMap(\.memoryBytes).reduce(0, +),
          cpuPercent: items.reduce(0) { $0 + $1.cpuPercent },
          directory: kind == .workload ? first.directory : nil,
          isPaused: !ids.isEmpty && ids.allSatisfy(input.stopped.contains), threadID: nil))
    }
    return
      consumers
      .filter { $0.memoryBytes >= minimumBytes || $0.cpuPercent >= 1 }
      .filter { $0.name != AppBrand.name }
      .sorted { $0.memoryBytes == $1.memoryBytes ? $0.id < $1.id : $0.memoryBytes > $1.memoryBytes }
  }

  static let systemKey = "system"

  private static func key(_ process: ResourceProcess) -> String {
    // First: a simulator runtime's apps (its SpringBoard) are macOS's too.
    if process.isSystem { return systemKey }
    if let app = process.bundleApp { return "app:" + app }
    return "work:" + process.name + "|" + (process.directory ?? "")
  }
}
