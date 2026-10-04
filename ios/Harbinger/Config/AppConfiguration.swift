import Foundation

/// The saved Worker endpoint (`UserDefaults`, key `endpointURL`, normalized string).
nonisolated struct EndpointStore {
  static let key = "endpointURL"

  var defaults: UserDefaults = .standard

  func url() -> URL? {
    guard let stored = defaults.string(forKey: Self.key) else { return nil }
    return try? normalizeEndpoint(stored).get()
  }

  func save(_ url: URL) {
    defaults.set(url.absoluteString, forKey: Self.key)
  }
}

/// The user's default model for new conversations and drafts (`UserDefaults`, key
/// `defaultModel`). No value means "use the server default".
nonisolated struct ModelPreferenceStore {
  static let key = "defaultModel"

  var defaults: UserDefaults = .standard

  func model() -> String? {
    defaults.string(forKey: Self.key)
  }

  func save(_ model: String?) {
    if let model {
      defaults.set(model, forKey: Self.key)
    } else {
      defaults.removeObject(forKey: Self.key)
    }
  }
}

/// The model to use: the saved default if the server still allows it, else the server
/// default. A saved model that is no longer allowed is ignored, not deleted. `nil` (models
/// not loaded) lets the server choose.
nonisolated func resolveModel(saved: String?, allowed: [String]?, serverDefault: String?)
  -> String?
{
  if let saved, let allowed, allowed.contains(saved) { return saved }
  return serverDefault
}

/// A saved endpoint + API key: enough to build an `APIClient`.
nonisolated struct Connection: Equatable, Sendable {
  let baseURL: URL
  let apiKey: String
}

/// A different endpoint is a different server: its data must never mix with the cache built
/// from the old one. A key-only change (or the first connection) keeps the cache.
nonisolated func isDifferentServer(from old: Connection?, to new: Connection) -> Bool {
  guard let old else { return false }
  return old.baseURL != new.baseURL
}

nonisolated struct AppConfiguration {
  var endpoints = EndpointStore()
  var modelPreference = ModelPreferenceStore()
  var credentials: any CredentialStore = KeychainCredentialStore()
  var makeClient: @Sendable (Connection) -> any APIClient = { URLSessionAPIClient(connection: $0) }

  /// The saved connection, or `nil` when either value is missing (→ first-launch sheet).
  func connection() -> Connection? {
    guard let url = endpoints.url(),
      let key = (try? credentials.apiKey()) ?? nil, !key.isEmpty
    else { return nil }
    return Connection(baseURL: url, apiKey: key)
  }

  /// Saves the key first: if the Keychain write fails, nothing is saved.
  func save(_ connection: Connection) throws {
    try credentials.saveAPIKey(connection.apiKey)
    endpoints.save(connection.baseURL)
  }
}
