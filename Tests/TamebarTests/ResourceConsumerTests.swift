import Foundation
import Testing

@testable import Tamebar

struct ResourceConsumerTests {
  private func process(
    _ input: (
      pid: Int32, executable: String, owner: String, directory: String?, mb: UInt64, cpu: Double
    )
  ) -> ResourceProcess {
    ResourceProcess(
      processID: input.pid, parentProcessID: 1, name: ResourceOwnership.label(input.executable),
      owner: input.owner, directory: input.directory, memoryBytes: input.mb * 1_048_576,
      cpuPercent: input.cpu, isTool: false, executable: input.executable)
  }

  @Test func groupsHelpersIntoAppsAndTerminalToolsByProject() {
    let resources = [
      process(
        (
          10, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "Google Chrome", nil,
          400, 2
        )),
      process(
        (
          11,
          "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper",
          "Google Chrome", nil, 600, 1
        )),
      process((20, "/usr/local/bin/node", "cmux", "/Users/me/dev/fmx_ws", 800, 30)),
      process((21, "/usr/local/bin/node", "cmux", "/Users/me/dev/fmx_ws", 200, 0)),
      process((30, "/usr/libexec/cloudd", "Background service", nil, 100, 4)),
    ]
    let consumers = ResourceConsumers.build(
      .init(threads: [], resources: resources, stopped: [20, 21]))
    let chrome = consumers.first { $0.name == "Google Chrome" }
    #expect(chrome?.kind == .app)
    #expect(chrome?.memoryBytes == 1_000 * 1_048_576)
    let node = consumers.first { $0.name == "node · fmx_ws" }
    #expect(node?.kind == .workload)
    #expect(node?.processIDs == [20, 21])
    #expect(node?.isPaused == true)
  }

  @Test func versionedToolsUseTheirToolName() {
    #expect(ResourceOwnership.label("/Users/me/.local/share/claude/versions/2.1.302") == "claude")
    #expect(ResourceOwnership.label("/usr/local/bin/node") == "node")
  }
}

struct SystemProcessClassificationTests {
  @Test func commandsInUsrBinAreTheUsersWork() {
    let command = ResourceProcess(
      processID: 1, parentProcessID: 1, name: "yes", owner: "Background service", directory: nil,
      memoryBytes: 1, cpuPercent: 99, isTool: false, executable: "/usr/bin/yes")
    let daemon = ResourceProcess(
      processID: 2, parentProcessID: 1, name: "cloudd", owner: "Background service",
      directory: nil, memoryBytes: 1, cpuPercent: 1, isTool: false,
      executable: "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd")
    #expect(!command.isSystem)
    #expect(daemon.isSystem)
  }

  /// A booted iOS Simulator runs its own copies of callservicesd, chronod and the rest under
  /// `launchd_sim`, as the user, from its runtime root (seen on this Mac, 2026-10-29).
  @Test func aSimulatorRuntimesDaemonsAreSystem() {
    let root =
      "/private/var/run/com.apple.security.cryptexd/mnt/com.apple.iPhoneOS.SimulatorRuntime-v24.1"
      + ".434.0.QaDtlz/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.0.simruntime"
      + "/Contents/Resources/RuntimeRoot"
    for path in [
      "/System/Library/PrivateFrameworks/TelephonyUtilities.framework/callservicesd",
      "/System/Library/PrivateFrameworks/ChronoCore.framework/Support/chronod",
      "/usr/sbin/filecoordinationd",
      "/usr/libexec/runningboardd",
      "/System/Library/ExtensionKit/Extensions/ClockPosterExtension.appex/ClockPosterExtension",
      "/usr/bin/simctl-helper",
    ] {
      #expect(SystemExecutable.isSystem(root + path), "\(path)")
    }
    // The older location, a disk image mounted under CoreSimulator/Volumes.
    #expect(
      SystemExecutable.isSystem(
        "/Library/Developer/CoreSimulator/Volumes/iOS_21A328/Library/Developer/CoreSimulator"
          + "/Profiles/Runtimes/iOS 17.0.simruntime/Contents/Resources/RuntimeRoot/usr/libexec/"
          + "locationd"))
  }

  @Test func theHostsSystemFoldersAreSystem() {
    for path in [
      "/System/Library/PrivateFrameworks/PhotoAnalysis.framework/Versions/A/Support/photoanalysisd",
      "/usr/libexec/trustd", "/usr/sbin/cfprefsd", "/sbin/launchd",
      "/Library/Apple/System/Library/CoreServices/XProtect.app/Contents/MacOS/XProtect",
      "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari",
    ] {
      #expect(SystemExecutable.isSystem(path), "\(path)")
    }
  }

  /// An Apple platform binary is macOS's own wherever it lives, except the commands in `/bin`
  /// and `/usr/bin` (`sh`, `yes`, `ruby`), which are platform binaries too but the user's work.
  @Test func aPlatformBinaryIsSystemExceptTheUsersCommands() {
    #expect(
      SystemExecutable.isSystem(
        "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources"
          + "/Platforms/iphoneos/usr/libexec/CoreSimulatorBridge", platform: true))
    #expect(SystemExecutable.isSystem("/private/var/somewhere/daemon", platform: true))
    #expect(!SystemExecutable.isSystem("/private/var/somewhere/daemon", platform: false))
    for command in ["/bin/sh", "/bin/zsh", "/usr/bin/yes", "/usr/bin/ruby", "/usr/bin/make"] {
      #expect(!SystemExecutable.isSystem(command, platform: true), "\(command)")
    }
    // Xcode's and the Command Line Tools' compilers are platform binaries too (sourcekit-lsp
    // reads so on this Mac), and builds are what Q12 slows. An app's own code is its row's,
    // which Q17 rules by the app's place.
    for tool in [
      "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/"
        + "swift-frontend",
      "/Applications/Xcode.app/Contents/SharedFrameworks/XCBuild.framework/Versions/A/PlugIns/"
        + "XCBBuildService.bundle/Contents/MacOS/XCBBuildService",
      "/Library/Developer/CommandLineTools/usr/bin/clang",
    ] {
      #expect(!SystemExecutable.isSystem(tool, platform: true), "\(tool)")
    }
    for tool in ["/opt/homebrew/bin/node", "/Users/me/.cargo/bin/cargo"] {
      #expect(!SystemExecutable.isSystem(tool), "\(tool)")
    }
  }

  @Test func aPlatformProcessOutsideTheSystemFoldersIsSystem() {
    let daemon = ResourceProcess(
      processID: 3, parentProcessID: 1, name: "assetsd", owner: "Background service",
      directory: nil, memoryBytes: 1, cpuPercent: 90, isTool: false,
      executable: "/private/var/run/com.apple.security.cryptexd/mnt/x/assetsd", isPlatform: true)
    let yes = ResourceProcess(
      processID: 4, parentProcessID: 1, name: "yes", owner: "Background service",
      directory: "/code/app", memoryBytes: 1, cpuPercent: 99, isTool: false,
      executable: "/usr/bin/yes", isPlatform: true)
    #expect(daemon.isSystem)
    #expect(!yes.isSystem)
  }
}

struct DuplicateThreadTests {
  @Test func aSessionReportedTwiceBecomesOneRow() {
    let thread = AIThread(
      id: "same", tool: .claudeCode, name: "claude", directory: "/tmp/p", terminal: nil,
      startedAt: nil, processIDs: [10], memoryBytes: 100_000_000, cpuPercent: 0, isPaused: false,
      isDetached: false)
    let consumers = ResourceConsumers.build(
      .init(threads: [thread, thread], resources: [], stopped: []))
    #expect(consumers.filter { $0.id == "ai:same" }.count == 1)
  }
}
