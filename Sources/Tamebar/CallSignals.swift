import CoreAudio
import CoreMediaIO
import Foundation

/// What the call probe read: which processes record from a microphone, and whether a camera is
/// on. Pure, so the rules that read it are tested without hardware.
struct CallReading: Equatable, Sendable {
  struct Input: Equatable, Sendable {
    let processID: Int32
    let bundleID: String?
  }

  /// Processes recording from a microphone, Apple speech excluded (`CallSignals.speech`).
  var inputs: [Input] = []
  /// An input device runs and no process list says who: the fallback on a macOS without
  /// CoreAudio's process objects. It can't be tied to an app.
  var unattributedInput = false
  /// Mac-wide: there is no public API for which process holds the camera.
  var camera = false

  var mic: Bool { !inputs.isEmpty || unattributedInput }

  /// A running app, as attribution reads it.
  struct App: Equatable, Sendable {
    let processID: Int32
    let bundleID: String
  }

  /// The apps holding the mic or camera, by bundle id. Nil when every app counts as holding
  /// them: a camera is on, or an input can't be tied to a running app (a browser's shared
  /// WebKit GPU process, a command-line recorder, the device fallback).
  ///
  /// An input belongs to an app when it is the app's process or a descendant of it, or when its
  /// bundle id is the app's or extends it (`com.google.Chrome.helper` is Chrome's).
  ///
  /// Limitation: a Chrome web app (an app shim, `com.google.Chrome.app.<id>`) records through
  /// Chrome's own helpers, so its call is Chrome's and the shim itself counts as free. Quitting
  /// the shim would close that call; what prevents it is that no app is quit while a meeting is
  /// on (`AppPressurePlanner`), and the recording makes it one after 30 s.
  func holders(_ apps: [App], parents: [Int32: Int32]) -> Set<String>? {
    guard !camera, !unattributedInput else { return nil }
    var held: Set<String> = []
    for input in inputs {
      var ancestors: Set<Int32> = []
      var current: Int32? = input.processID
      while let pid = current, pid > 1, ancestors.insert(pid).inserted { current = parents[pid] }
      let owners = apps.filter { app in
        ancestors.contains(app.processID)
          || input.bundleID.map { $0 == app.bundleID || $0.hasPrefix(app.bundleID + ".") }
            == true
      }
      guard !owners.isEmpty else { return nil }
      held.formUnion(owners.map(\.bundleID))
    }
    return held
  }
}

/// The mic and camera probe (M1, spike S2). It reads CoreAudio's per-process input state and
/// CoreMediaIO's "running somewhere": no permission, no prompt, nothing captured. Input only, so
/// playback (AirPods playing music) never counts.
///
/// Every read fails closed: an error anywhere returns nil, which holds every app (Q11) and
/// keeps the meeting answer as it was.
enum CallSignals {
  /// Apple's own speech listeners, which open the mic for dictation, Siri and Sound Recognition,
  /// not for a call. Each was seen registered as a CoreAudio client on the development Mac (macOS 27,
  /// 2026-10-20): corespeechd (user and system), assistantd, SiriNCService, heard. Which one
  /// records during dictation is for the S2 spike to confirm (the probe prints each process).
  static let speech: Set<String> = [
    "com.apple.CoreSpeech", "com.apple.corespeechd_system", "com.apple.assistantd",
    "com.apple.SiriNCService", "com.apple.accessibility.heard",
  ]

  /// The inputs that may be a call: Apple speech dropped.
  static func callInputs(_ inputs: [CallReading.Input]) -> [CallReading.Input] {
    inputs.filter { $0.bundleID.map { !speech.contains($0) } ?? true }
  }

  /// The probe the shipped app uses. Nil anywhere else (tests, the e2e build, a debug run), so
  /// no test reads the real devices and the e2e build answers from its control file.
  static func liveProbe(shipped: Bool = AppBrand.isShippedApp)
    -> (@Sendable () -> CallReading?)?
  {
    guard shipped else { return nil }
    return { @Sendable in read() }
  }

  /// Nil when any read fails.
  static func read() -> CallReading? {
    guard let camera = cameraInUse() else { return nil }
    if hasProcessObjects() {
      guard let inputs = processInputs() else { return nil }
      return CallReading(inputs: callInputs(inputs), camera: camera)
    }
    // macOS without CoreAudio's process objects: any running input device, unattributed.
    guard let devices = audioDevices() else { return nil }
    var running = false
    for device in devices {
      guard let input = hasInput(device) else { return nil }
      guard input else { continue }
      guard let on = isRunning(device) else { return nil }
      running = running || on
    }
    return CallReading(unattributedInput: running, camera: camera)
  }

  // MARK: CoreAudio

  private static func address(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  private static let system = AudioObjectID(kAudioObjectSystemObject)

  /// `kAudioHardwarePropertyProcessObjectList` carries no availability in the SDK; it is
  /// checked at run time, so an older macOS takes the device fallback.
  private static func hasProcessObjects() -> Bool {
    var address = address(kAudioHardwarePropertyProcessObjectList)
    return AudioObjectHasProperty(system, &address)
  }

  private static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID]? {
    var address = address(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
      return nil
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    guard count > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
      return nil
    }
    return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
  }

  private static func audioDevices() -> [AudioObjectID]? { objects(kAudioHardwarePropertyDevices) }

  private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector)
    -> UInt32?
  {
    var address = address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return value
  }

  /// Every process recording from an input, with its PID and bundle id.
  private static func processInputs() -> [CallReading.Input]? {
    guard let processes = objects(kAudioHardwarePropertyProcessObjectList) else { return nil }
    var inputs: [CallReading.Input] = []
    for process in processes {
      guard let running = uint32(process, kAudioProcessPropertyIsRunningInput) else {
        return nil
      }
      guard running != 0 else { continue }
      var pidAddress = address(kAudioProcessPropertyPID)
      var pid: pid_t = 0
      var pidSize = UInt32(MemoryLayout<pid_t>.size)
      guard
        AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr
      else { return nil }
      inputs.append(.init(processID: pid, bundleID: bundleID(process)))
    }
    return inputs
  }

  /// The process's bundle id; nil when it has none (a command-line tool).
  private static func bundleID(_ process: AudioObjectID) -> String? {
    var address = address(kAudioProcessPropertyBundleID)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) {
      AudioObjectGetPropertyData(process, &address, 0, nil, &size, $0)
    }
    guard status == noErr, let id = value?.takeRetainedValue() as String?, !id.isEmpty else {
      return nil
    }
    return id
  }

  private static func hasInput(_ device: AudioObjectID) -> Bool? {
    var address = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else {
      return nil
    }
    return size > 0
  }

  private static func isRunning(_ device: AudioObjectID) -> Bool? {
    uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere).map { $0 != 0 }
  }

  // MARK: CoreMediaIO

  private static func cameraInUse() -> Bool? {
    var address = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    let system = CMIOObjectID(kCMIOObjectSystemObject)
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
      return nil
    }
    let count = Int(size) / MemoryLayout<CMIODeviceID>.size
    guard count > 0 else { return false }
    var devices = [CMIODeviceID](repeating: 0, count: count)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr
    else { return nil }
    for device in devices.prefix(Int(used) / MemoryLayout<CMIODeviceID>.size) {
      var running = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
      var value: UInt32 = 0
      var valueUsed: UInt32 = 0
      guard
        CMIOObjectGetPropertyData(
          device, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &valueUsed, &value)
          == noErr
      else { return nil }
      if value != 0 { return true }
    }
    return false
  }
}
