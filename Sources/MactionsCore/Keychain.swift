import Foundation
import Security

/// Minimal generic-password Keychain wrapper. We never store the GitHub token
/// in UserDefaults or a plist — it goes in the login keychain, encrypted at
/// rest, like any other credential.
public enum Keychain {
  /// Items are namespaced under one service so a user can wipe Mactions creds
  /// without touching anything else.
  public static let service = "com.kyter.mactions"

  public enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
  }

  public static func set(_ value: String, for account: String) throws {
    let data = Data(value.utf8)
    // Upsert: delete any existing item first, then add. Simpler than
    // SecItemUpdate's attribute dance and idempotent.
    try? remove(account)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
  }

  public static func get(_ account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public static func remove(_ account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.unexpectedStatus(status)
    }
  }
}
