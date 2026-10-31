import Darwin
import Foundation
import IOKit

/// The fans' speed in percent of their max, read from AppleSMC without root, the way spike S5
/// (and the Stats app) reads it: `IOServiceOpen("AppleSMC")`, then `IOConnectCallStructMethod`
/// selector 2 with an 80-byte `SMCKeyData_t`; `data8` 9 reads a key's size and type, 5 its bytes.
/// On Apple Silicon the fan keys are `flt ` (little-endian Float32), on Intel `fpe2`. One call per
/// fan per reading; the connection is opened once. With no fan, or a read that fails, it reads
/// nil, and Q19's fan signal is just absent.
final class FanReader: @unchecked Sendable {
  private var connection: io_connect_t = 0
  /// Each fan's max, read once.
  private var maxima: [Double] = []
  /// The SMC couldn't be opened or has no fan: never tried again.
  private var unavailable = false

  deinit {
    if connection != 0 { IOServiceClose(connection) }
  }

  /// The highest fan's speed, 0–100 % of its max; nil without a fan or a reading.
  func percent() -> Double? {
    guard !unavailable else { return nil }
    if connection == 0, !open() { return nil }
    var best: Double?
    for (index, maximum) in maxima.enumerated() where maximum > 0 {
      guard let actual = number("F\(index)Ac"), actual.isFinite, actual >= 0 else { continue }
      best = max(best ?? 0, min(100, actual / maximum * 100))
    }
    return best
  }

  private func open() -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
    guard service != 0 else {
      unavailable = true
      return false
    }
    defer { IOObjectRelease(service) }
    var opened: io_connect_t = 0
    guard IOServiceOpen(service, mach_task_self_, 0, &opened) == KERN_SUCCESS else {
      unavailable = true
      return false
    }
    connection = opened
    let count = Int(number("FNum") ?? 0)
    maxima = (0..<max(0, min(count, 8))).map { number("F\($0)Mx") ?? 0 }
    if !maxima.contains(where: { $0 > 0 }) {
      unavailable = true
      IOServiceClose(connection)
      connection = 0
      return false
    }
    return true
  }

  private static func fourCC(_ key: String) -> UInt32 {
    key.utf8.reduce(0) { $0 << 8 | UInt32($1) }
  }

  private func call(_ input: [UInt8]) -> (kern_return_t, [UInt8]) {
    var output = [UInt8](repeating: 0, count: 80)
    var size = 80
    let result = input.withUnsafeBytes { inBytes in
      output.withUnsafeMutableBytes { outBytes in
        IOConnectCallStructMethod(
          connection, 2, inBytes.baseAddress, 80, outBytes.baseAddress, &size)
      }
    }
    return (result, output)
  }

  /// A key's value as a number; nil when it can't be read or has another type.
  private func number(_ key: String) -> Double? {
    var input = [UInt8](repeating: 0, count: 80)
    withUnsafeBytes(of: Self.fourCC(key)) { for i in 0..<4 { input[i] = $0[i] } }
    input[42] = 9  // kSMCGetKeyInfo
    let (infoResult, info) = call(input)
    guard infoResult == KERN_SUCCESS, info[40] == 0 else { return nil }
    let size = info[28..<32].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    let type = info[32..<36].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    withUnsafeBytes(of: size) { for i in 0..<4 { input[28 + i] = $0[i] } }
    input[42] = 5  // kSMCReadKey
    let (readResult, data) = call(input)
    guard readResult == KERN_SUCCESS, data[40] == 0, size > 0 else { return nil }
    let bytes = Array(data[48..<(48 + Int(min(size, 32)))])
    return Self.decode(type: type, bytes: bytes)
  }

  /// `flt `, `fpe2`, `ui8 `, `ui16` and `ui32`; nil for anything else. Pure.
  static func decode(type: UInt32, bytes: [UInt8]) -> Double? {
    switch type {
    case fourCC("flt "):
      guard bytes.count >= 4 else { return nil }
      return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
    case fourCC("fpe2"):
      guard bytes.count >= 2 else { return nil }
      return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
    case fourCC("ui8 "):
      return bytes.first.map(Double.init)
    case fourCC("ui16"):
      guard bytes.count >= 2 else { return nil }
      return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
    case fourCC("ui32"):
      guard bytes.count >= 4 else { return nil }
      return Double(bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    default:
      return nil
    }
  }
}
