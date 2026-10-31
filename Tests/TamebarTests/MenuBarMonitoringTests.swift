import AppKit
import Carbon
import SwiftUI
import Testing

@testable import Tamebar

struct AppQuitPolicyTests {
  @Test func ordinaryQuitKeepsMonitoringButExplicitStopExits() {
    #expect(AppQuitPolicy.keepsMonitoring(.init(explicitStop: false, event: nil)))
    #expect(!AppQuitPolicy.keepsMonitoring(.init(explicitStop: true, event: nil)))
    let event = quitEvent()
    #expect(AppQuitPolicy.keepsMonitoring(.init(explicitStop: false, event: event)))
  }

  @Test func logoutRestartAndShutdownNeverStayResident() {
    for reason in [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut, kAELogOut] {
      let event = quitEvent()
      event.setParam(
        NSAppleEventDescriptor(enumCode: OSType(reason)), forKeyword: AEKeyword(kAEQuitReason))
      #expect(!AppQuitPolicy.keepsMonitoring(.init(explicitStop: false, event: event)))
      let attributed = quitEvent()
      attributed.setAttribute(
        NSAppleEventDescriptor(enumCode: OSType(reason)), forKeyword: AEKeyword(kAEQuitReason))
      #expect(!AppQuitPolicy.keepsMonitoring(.init(explicitStop: false, event: attributed)))
    }
  }

  private func quitEvent() -> NSAppleEventDescriptor {
    NSAppleEventDescriptor(
      eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
      targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID))
  }
}

@MainActor
struct MenuBarMonitoringTests {
  private var snapshot: SystemSnapshot {
    .init(
      .init(
        diskAvailable: 120_000_000_000, diskTotal: 500_000_000_000,
        ramAvailable: 3_000_000_000, ramTotal: 16_000_000_000, memoryPressure: .normal,
        cpuUsage: 1, thermalStatus: .nominal, updatedAt: .now))
  }

  @Test func freeMemoryReadsInGigabytesOrADash() {
    #expect(MemoryFreeText.make(snapshot) == "3 GB free")
    #expect(MemoryFreeText.make(.empty) == "—")
  }
}
