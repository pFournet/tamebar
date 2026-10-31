import Darwin
import Foundation
import Testing

@testable import Tamebar

struct LeftoverProcessTests {
  @Test func malformedLaunchdOutputDoesNotClassifyServicesAsLeftovers() {
    for output in [
      "", "unreadable", "PID\tStatus\tLabel\nnot-a-pid\t0\tservice\n", "PID\tStatus\tLabel\n123\n",
    ] {
      #expect(LeftoverProcessFinder.launchdJobs(output) == nil)
    }
  }

  private struct Fixture {
    let processID: Int32
    var parentProcessID: Int32 = 1
    let executable: String
    var arguments: String? = nil
    var directory: String? = "/Users/me/dev/site"
    var hasIdentity = true
  }

  private struct CandidateInput {
    let fixtures: [Fixture]
    var apps: LeftoverProcessFinder.RunningApps = .init(processIDs: [], bundlePaths: [])
    var excluded: Set<Int32> = []
    var keptRunning: [String] = []
  }

  private func candidates(_ fixtures: [Fixture]) -> [LeftoverProcess] {
    candidates(.init(fixtures: fixtures))
  }

  private func candidates(_ input: CandidateInput) -> [LeftoverProcess] {
    let fixtures = input.fixtures
    let records = fixtures.map {
      RawProcessRecord(
        processID: $0.processID, parentProcessID: $0.parentProcessID, userID: Int(getuid()),
        cpuPercent: Double($0.processID), residentKilobytes: 0, elapsed: "01:00",
        terminal: nil, arguments: $0.arguments ?? $0.executable)
    }
    let executables = Dictionary(
      uniqueKeysWithValues: fixtures.map { ($0.processID, $0.executable) })
    let directories = Dictionary(
      uniqueKeysWithValues: fixtures.compactMap { f in f.directory.map { (f.processID, $0) } })
    let footprints: [Int32: UInt64] = Dictionary(
      uniqueKeysWithValues: fixtures.map { ($0.processID, 1_024) })
    let identities = Dictionary(
      uniqueKeysWithValues: fixtures.filter(\.hasIdentity).map {
        (
          $0.processID,
          DevProcessIdentity(
            process: .init(
              processID: $0.processID, owner: getuid(), startSeconds: 1_000, startMicroseconds: 0,
              state: 0),
            executable: $0.executable)
        )
      })
    return LeftoverProcessFinder.candidates(
      .init(
        records: records, executables: executables, directories: directories,
        footprints: footprints, identities: identities, apps: input.apps,
        excludedIDs: input.excluded, keptRunningRoots: input.keptRunning))
  }

  @Test
  func listsProcessesWhoseParentExited() {
    let found = candidates([
      .init(
        processID: 10, executable: "/opt/homebrew/bin/python3",
        arguments: "/opt/homebrew/bin/python3 -m http.server 8000"),
      .init(processID: 11, parentProcessID: 500, executable: "/opt/homebrew/bin/node"),
    ])

    #expect(found.map(\.processID) == [10])
    #expect(found.first?.title == "python http.server")
    #expect(found.first?.executableName == "python3")
    #expect(found.first?.workingDirectory == "/Users/me/dev/site")
  }

  @Test
  func skipsSystemServicesAndRunningApps() {
    let apps = LeftoverProcessFinder.RunningApps(
      processIDs: [30], bundlePaths: ["/Applications/Brave Browser.app"])
    let found = candidates(
      .init(
        fixtures: [
          .init(processID: 20, executable: "/usr/libexec/trustd"),
          .init(
            processID: 21,
            executable: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
          ),
          .init(
            processID: 22,
            executable:
              "/Applications/Brave Browser.app/Contents/Frameworks/Brave.framework/Helpers/Brave Helper"
          ),
          .init(
            processID: 23,
            executable: "/Applications/Tool.app/Contents/XPCServices/Sync.xpc/Contents/MacOS/Sync"),
          .init(processID: 24, executable: "/Applications/Gone.app/Contents/MacOS/gone-helper"),
          .init(
            processID: 30, executable: "/Applications/Notes Plus.app/Contents/MacOS/Notes Plus"),
        ], apps: apps))

    #expect(found.map(\.processID) == [24])
  }

  @Test
  func protectsAISessionsAgentsKeepRunningAndUnverifiedProcesses() {
    let found = candidates(
      .init(
        fixtures: [
          .init(processID: 40, executable: "/Users/me/.local/bin/claude"),
          .init(processID: 41, executable: "/usr/bin/ssh-agent"),
          .init(processID: 42, executable: "/opt/homebrew/bin/node", hasIdentity: false),
          .init(
            processID: 43, executable: "/opt/homebrew/bin/node",
            directory: "/Users/me/dev/kept/packages/api"),
          .init(processID: 44, executable: "/opt/homebrew/bin/node", directory: "/"),
        ], excluded: [40], keptRunning: ["/Users/me/dev/kept"]))

    #expect(found.map(\.processID) == [44])
    #expect(found.first?.workingDirectory == nil)
  }

  @Test
  func ranksByCPU() {
    let found = candidates([
      .init(processID: 50, executable: "/opt/homebrew/bin/ruby"),
      .init(processID: 52, executable: "/opt/homebrew/bin/ruby"),
      .init(processID: 51, executable: "/opt/homebrew/bin/ruby"),
    ])

    #expect(found.map(\.processID) == [52, 51, 50])
  }

  @Test
  func readsLaunchdJobPIDs() {
    let jobs = LeftoverProcessFinder.launchdJobs(
      "PID\tStatus\tLabel\n412\t0\tcom.apple.Finder\n-\t0\tcom.example.idle\n918\t-9\thomebrew.mxcl.postgresql\n"
    )

    #expect(jobs == [412, 918])
  }

  @Test
  func namesWhatAnInterpreterRuns() {
    let title = LeftoverProcessFinder.title
    #expect(
      title(.init(name: "python3.12", arguments: ["python3", "-u", "-m", "http.server"]))
        == "python http.server")
    #expect(
      title(
        .init(name: "node", arguments: ["node", "--require", "ts-node/register", "/srv/daemon.js"]))
        == "node daemon.js"
    )
    #expect(
      title(
        .init(
          name: "java",
          arguments: ["java", "-cp", "lib/*", "org.gradle.launcher.daemon.GradleDaemon"]))
        == "java GradleDaemon")
    #expect(
      title(.init(name: "java", arguments: ["java", "-jar", "/opt/tools/server.jar"]))
        == "java server.jar")
    #expect(title(.init(name: "node", arguments: ["node"])) == "node")
    #expect(title(.init(name: "esbuild", arguments: ["esbuild", "--service=0.19.2"])) == "esbuild")
  }
}
