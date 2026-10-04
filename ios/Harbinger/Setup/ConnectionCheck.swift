import Foundation

/// Why a connection wasn't saved, as text for the form.
nonisolated struct ConnectionFailure: Error, Equatable, Sendable {
  let message: String
}

/// Validating and saving an endpoint + key, shared by the first-launch sheet and Settings.
enum ConnectionCheck {
  static let invalidURLMessage = "Enter a valid https URL (http is allowed for localhost)"
  static let keyRejectedMessage = "Key rejected"
  static let unreachableMessage = "Can't reach endpoint"

  /// Normalizes the URL, checks `/health` with the key, and saves both only when the check
  /// passes. Nothing is saved on failure.
  static func verifyAndSave(
    endpoint: String, apiKey: String, configuration: AppConfiguration
  ) async -> Result<Connection, ConnectionFailure> {
    guard case .success(let url) = normalizeEndpoint(endpoint) else {
      return .failure(ConnectionFailure(message: invalidURLMessage))
    }
    let connection = Connection(baseURL: url, apiKey: apiKey)

    do {
      _ = try await configuration.makeClient(connection).health()
    } catch {
      return .failure(ConnectionFailure(message: message(for: error)))
    }

    do {
      try configuration.save(connection)
    } catch {
      return .failure(ConnectionFailure(message: "Couldn't save the key (\(error))"))
    }
    return .success(connection)
  }

  static func message(for error: APIError) -> String {
    switch error {
    case .unauthorized: keyRejectedMessage
    case .network: unreachableMessage
    case .server(_, let code, _, _): "Unexpected response (\(code))"
    case .decoding: "Unexpected response (decoding)"
    case .invalidResponse: "Unexpected response (invalid_response)"
    }
  }
}
