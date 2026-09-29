import Foundation
import Security

/// Storage for the Worker API key. The key is never logged or printed.
nonisolated protocol CredentialStore: Sendable {
  func apiKey() throws -> String?
  func saveAPIKey(_ key: String) throws
  func deleteAPIKey() throws
}

nonisolated enum KeychainError: Error, Equatable, Sendable {
  case status(OSStatus)
  case unexpectedData
}

/// Generic-password Keychain item, device-only and available after first unlock
/// (so background sync can read it). Never iCloud-synced.
nonisolated struct KeychainCredentialStore: CredentialStore {
  var service = "com.aurlaw.harbinger"
  var account = "api-key"

  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  func apiKey() throws -> String? {
    var query = query
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError.status(status) }
    guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
      throw KeychainError.unexpectedData
    }
    return key
  }

  func saveAPIKey(_ key: String) throws {
    let attributes: [String: Any] = [
      kSecValueData as String: Data(key.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw KeychainError.status(status) }

    let add = query.merging(attributes) { _, new in new }
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
  }

  func deleteAPIKey() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.status(status)
    }
  }
}
