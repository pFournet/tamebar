import Foundation
import Security

/// One secret string: the Keychain in the app, memory in tests.
protocol SecretStore: Sendable {
  /// Whether a secret is stored, without reading it: never prompts, cheap enough for launch.
  func exists() -> Bool
  func read() -> String?
  /// False when it couldn't be saved.
  func write(_ value: String) -> Bool
  func delete()
}

/// A generic-password item in the login Keychain. Only the shipped app creates one
/// (`GoogleCalendarMeetings.launch`); tests never reach it.
///
/// On macOS this is the file-based login keychain, which ignores `kSecAttrAccessible`
/// (TN3137), so none is set. The item is protected by the keychain's lock and by the item's
/// access list, which names the app that created it. It's never synced: it's marked
/// non-synchronizable, and the file-based keychain doesn't sync anyway.
///
/// Once a Developer ID exists, move it to the data protection keychain
/// (`kSecUseDataProtectionKeychain`), with a keychain-access-groups entitlement.
struct KeychainItem: SecretStore {
  let service: String
  let account: String

  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
    ]
  }

  /// Asks for the item's attributes only, never its data.
  func exists() -> Bool {
    var search = query
    search[kSecReturnAttributes as String] = true
    search[kSecMatchLimit as String] = kSecMatchLimitOne
    return SecItemCopyMatching(search as CFDictionary, nil) == errSecSuccess
  }

  func read() -> String? {
    var result: CFTypeRef?
    var search = query
    search[kSecReturnData as String] = true
    search[kSecMatchLimit as String] = kSecMatchLimitOne
    guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  func write(_ value: String) -> Bool {
    let data = Data(value.utf8)
    let update = [kSecValueData as String: data]
    switch SecItemUpdate(query as CFDictionary, update as CFDictionary) {
    case errSecSuccess: return true
    case errSecItemNotFound:
      var add = query
      add[kSecValueData as String] = data
      add[kSecAttrLabel as String] = "Tamebar Google Calendar"
      return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    default: return false
    }
  }

  func delete() { SecItemDelete(query as CFDictionary) }
}
