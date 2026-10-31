import Darwin
import Foundation

extension DevProcess {
  var canStopWithProject: Bool {
    let serverNames: Set<String> = [
      "vite", "next", "next-server", "expo", "astro", "nuxt", "remix", "webpack",
      "wrangler", "http-server", "live-server", "serve",
    ]
    return kind == .devServer && !listeningPorts.isEmpty && serverNames.contains(name)
  }
}

struct DevProcessIdentity: Codable, Equatable, Sendable {
  let process: RecoveryProcess
  let executable: String

  static func read(_ processID: Int32) -> Self? {
    guard let process = RecoveryProcess.read(processID), !process.exited else {
      return nil
    }
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(processID, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return Self(
      process: process,
      executable: String(
        decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
  }

  func matches(_ other: Self) -> Bool {
    process.isSameInstance(other.process) && executable == other.executable
  }
}

struct DevProcessSnapshot: Sendable {
  let processes: [DevProcess]
  let identities: [Int32: DevProcessIdentity]
  let threads: [AIThread]
  let resources: [ResourceProcess]
  var workspaceRoots: [Int32: String] = [:]
  var leftovers: [LeftoverProcess] = []
  var incomplete = false
  /// Every scanned process holding a listening TCP port, before dev-process classification.
  var listeningIDs: Set<Int32> = []
  /// The ports each of them listens on.
  var listeningPorts: [Int32: [Int]] = [:]
  /// False when lsof timed out or overflowed, so `listeningIDs` may be missing some.
  var portsComplete = false
  /// Local ports with an established TCP connection (Q20); read only while a session serves.
  var establishedPorts: Set<Int> = []
  /// False when that lsof timed out or overflowed.
  var establishedComplete = true
  /// Each process's working directory.
  var directories: [Int32: String] = [:]
  /// This user's `ps` records by PID, with their real arguments.
  var records: [Int32: RawProcessRecord] = [:]
}

enum ProcessWorkingDirectory {
  static func read(_ processID: Int32) -> String? {
    var info = proc_vnodepathinfo()
    let size = MemoryLayout<proc_vnodepathinfo>.size
    guard proc_pidinfo(processID, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size)) == size else {
      return nil
    }
    return withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
      let path = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
      return path.isEmpty ? nil : path
    }
  }
}
