import CryptoKit
import Foundation

struct ResourceProcess: Identifiable, Equatable, Sendable {
  let processID: Int32
  let parentProcessID: Int32
  let name: String
  let owner: String
  let directory: String?
  let memoryBytes: UInt64?
  let cpuPercent: Double
  let isTool: Bool
  /// Absolute path of the process's own executable.
  let executable: String
  /// An Apple platform binary (`CS_PLATFORM_BINARY`).
  var isPlatform = false
  var id: Int32 { processID }

  /// The app bundle this process ships inside, such as a browser helper; nil for tools started from a terminal.
  var bundleApp: String? { ResourceOwnership.appName(executable) }

  /// A macOS daemon, or anything a simulator runtime runs (its apps too); commands in /usr/bin
  /// such as `python3` or `yes` count as the user's own work.
  var isSystem: Bool {
    SystemExecutable.inSimulatorRuntime(executable)
      || (bundleApp == nil && SystemExecutable.isSystem(executable, platform: isPlatform))
  }
}

@_silgen_name("csops")
private func csops(
  _ pid: pid_t, _ ops: UInt32, _ useraddr: UnsafeMutableRawPointer?, _ usersize: Int
) -> Int32

/// macOS's own code: shown as macOS services, never slowed (Q12, Q13, Q17), whatever its CPU.
///
/// Found on 2026-10-29: Q12 slowed callservicesd, chronod and photoanalysisd. They were a booted
/// iOS Simulator's copies: run as the user under `launchd_sim`, from the runtime's root
/// (`…/iOS 27.0.simruntime/Contents/Resources/RuntimeRoot/System/Library/…`), which no system
/// folder prefix matched, so each became a terminal job of its own.
enum SystemExecutable {
  /// The Mac's own folders.
  static let prefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
  /// Platform binaries too, but what the user runs from a terminal (`sh`, `yes`, `ruby`) or
  /// builds with (the Command Line Tools' compilers): the user's work.
  static let userCommands = ["/bin/", "/usr/bin/", "/Library/Developer/CommandLineTools/"]
  /// A simulator runtime's own system tree, wherever the runtime is mounted.
  static let simulatorRuntime = ".simruntime/Contents/Resources/RuntimeRoot/"
  /// `CS_OPS_STATUS` and its `CS_PLATFORM_BINARY` flag (`<kern/cs_blobs.h>`).
  private static let statusOperation: UInt32 = 0
  private static let platformBinary: UInt32 = 0x0400_0000

  /// In the Mac's system folders or a simulator runtime, or an Apple platform binary (`platform`)
  /// anywhere but `userCommands` and an app's bundle. Xcode's compilers read as platform binaries
  /// too, and an app's own code is its row's, which Q17 rules by the app's place (`/System/…`
  /// for Finder, Music or Safari).
  static func isSystem(_ path: String, platform: Bool = false) -> Bool {
    if prefixes.contains(where: { path.hasPrefix($0) }) || inSimulatorRuntime(path) {
      return true
    }
    return platform && !path.contains(".app/") && !userCommands.contains { path.hasPrefix($0) }
  }

  static func inSimulatorRuntime(_ path: String) -> Bool { path.contains(simulatorRuntime) }

  /// The kernel's code-signing status says Apple platform binary. False when unreadable.
  static func isPlatform(_ pid: Int32) -> Bool {
    var flags: UInt32 = 0
    guard csops(pid, statusOperation, &flags, MemoryLayout<UInt32>.size) == 0 else {
      return false
    }
    return flags & platformBinary != 0
  }
}

struct ResourceGroup: Identifiable, Codable, Equatable, Sendable {
  let id: String
  let name: String
  let owner: String
  let project: String?
  let processCount: Int
  let memoryBytes: UInt64
  let unknownMemoryCount: Int
}

enum ResourceOwnership {
  struct Input {
    let records: [RawProcessRecord]
    let directories: [Int32: String]
    let footprints: [Int32: UInt64]
    let executables: [Int32: String]
    /// Apple platform binaries (`CS_PLATFORM_BINARY`).
    var platform: Set<Int32> = []
  }

  static func processes(_ input: Input) -> [ResourceProcess] {
    let records = Dictionary(
      input.records.map { ($0.processID, $0) }, uniquingKeysWith: { a, _ in a })
    return input.records.compactMap { record in
      guard let executable = input.executables[record.processID] else { return nil }
      var current = record
      var visited: Set<Int32> = []
      var owner: String?
      var directory: String?
      while visited.insert(current.processID).inserted {
        if directory == nil, let candidate = input.directories[current.processID],
          candidate != "/", candidate != FileManager.default.homeDirectoryForCurrentUser.path
        {
          directory = candidate
        }
        if let path = input.executables[current.processID], let app = appName(path) {
          owner = app
        }
        if owner == nil, let path = input.executables[current.processID] {
          let name = URL(fileURLWithPath: path).lastPathComponent
          if name == "claude" { owner = "Claude Code" }
          if name == "codex" { owner = "Codex" }
        }
        guard let parent = records[current.parentProcessID], parent.userID == record.userID else {
          break
        }
        current = parent
      }
      let name = ResourceOwnership.label(executable)
      let arguments = record.arguments.lowercased()
      let runtime =
        ["node", "bun", "deno", "java", "uv", "npx"].contains(name)
        || name.lowercased().hasPrefix("python") || name.lowercased().contains("mcp")
      let isTool =
        (runtime && (arguments.contains("mcp") || arguments.contains("modelcontextprotocol")))
        || name == "node_repl" || name == "codex-code-mode-host"
      let label: String
      if isTool && arguments.contains("maestro") {
        label = "Maestro tools"
      } else if isTool && arguments.contains("studio") && arguments.contains("algomax") {
        label = "Algomax Studios tools"
      } else if isTool && arguments.contains("playwright") {
        label = "Playwright tools"
      } else if isTool && arguments.contains("chrome-devtools") {
        label = "Chrome DevTools"
      } else if isTool && name == "node" {
        label = "Node tool services"
      } else if isTool && (name.lowercased().contains("python") || name == "uv") {
        label = "Python tool services"
      } else {
        label = name
      }
      return ResourceProcess(
        processID: record.processID, parentProcessID: record.parentProcessID,
        name: label, owner: owner ?? "Background service", directory: directory,
        memoryBytes: input.footprints[record.processID], cpuPercent: record.cpuPercent,
        isTool: isTool, executable: executable,
        isPlatform: input.platform.contains(record.processID))
    }
  }

  static func groups(_ processes: [ResourceProcess]) -> [ResourceGroup] {
    let grouped = Dictionary(grouping: processes, by: groupID)
    return grouped.compactMap { key, items in
      guard let first = items.first else { return nil }
      return ResourceGroup(
        id: key,
        name: first.name, owner: first.owner,
        project: first.directory.map { URL(fileURLWithPath: $0).lastPathComponent },
        processCount: items.count, memoryBytes: items.compactMap(\.memoryBytes).reduce(0, +),
        unknownMemoryCount: items.filter { $0.memoryBytes == nil }.count)
    }.sorted { $0.memoryBytes > $1.memoryBytes }
  }

  static func groupID(_ process: ResourceProcess) -> String {
    let key = [process.owner, process.directory ?? "", process.name].joined(separator: "\u{1F}")
    return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// The executable's name, except tools installed under a version folder, such as Claude Code's `versions/2.1.302`.
  static func label(_ executable: String) -> String {
    let url = URL(fileURLWithPath: executable)
    let name = url.lastPathComponent
    let parent = url.deletingLastPathComponent()
    guard parent.lastPathComponent == "versions", name.first?.isNumber == true else { return name }
    return parent.deletingLastPathComponent().lastPathComponent
  }

  static func appName(_ path: String) -> String? {
    guard let range = path.range(of: ".app/") else { return nil }
    return URL(fileURLWithPath: String(path[..<range.lowerBound])).lastPathComponent
  }
}

@MainActor
enum ResourceSnapshotCache {
  static var groups: [ResourceGroup] = []
  static var pressure = PressureAssessment.checking
  static var scannedAt: Date?

  static var recentGroups: [ResourceGroup]? {
    guard let scannedAt, Date.now.timeIntervalSince(scannedAt) < 30 else { return nil }
    return Array(groups.prefix(32))
  }
}
