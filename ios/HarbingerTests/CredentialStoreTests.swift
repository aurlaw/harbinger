import Foundation
import Testing

@testable import Harbinger

struct CredentialStoreTests {
  static let other = String(repeating: "j", count: 32)

  /// Save, read, overwrite, delete — the same contract for both implementations.
  func roundTrip(_ store: some CredentialStore) throws {
    try store.deleteAPIKey()
    #expect(try store.apiKey() == nil)

    try store.saveAPIKey(testAPIKey)
    #expect(try store.apiKey() == testAPIKey)

    try store.saveAPIKey(Self.other)
    #expect(try store.apiKey() == Self.other)

    try store.deleteAPIKey()
    #expect(try store.apiKey() == nil)
    try store.deleteAPIKey()  // deleting a missing item is not an error
  }

  @Test func inMemoryRoundTrip() throws {
    try roundTrip(InMemoryCredentialStore())
  }

  @Test func keychainRoundTrip() throws {
    // A separate account, so the test never touches a real saved key.
    try roundTrip(KeychainCredentialStore(account: "api-key-test-\(UUID().uuidString)"))
  }

  @Test func keychainUsesAppService() {
    let store = KeychainCredentialStore()
    #expect(store.service == "com.aurlaw.harbinger")
    #expect(store.account == "api-key")
  }
}
