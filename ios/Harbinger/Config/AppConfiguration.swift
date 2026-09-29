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

/// A saved endpoint + API key: enough to build an `APIClient`.
nonisolated struct Connection: Equatable, Sendable {
  let baseURL: URL
  let apiKey: String
}

nonisolated struct AppConfiguration {
  var endpoints = EndpointStore()
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
