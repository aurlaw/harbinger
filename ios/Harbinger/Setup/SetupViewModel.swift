import Foundation
import Observation

/// First-launch sheet: validates an endpoint + key against `/health`, and saves both
/// only when the check passes.
@Observable
final class SetupViewModel {
  static let invalidURLMessage = "Enter a valid https URL (http is allowed for localhost)"
  static let keyRejectedMessage = "Key rejected"
  static let unreachableMessage = "Can't reach endpoint"

  var endpoint = defaultEndpoint
  var apiKey = ""
  private(set) var isChecking = false
  private(set) var errorMessage: String?

  private let configuration: AppConfiguration

  init(configuration: AppConfiguration) {
    self.configuration = configuration
  }

  var canSave: Bool {
    !isChecking && !trimmed(endpoint).isEmpty && !trimmed(apiKey).isEmpty
  }

  /// Returns the saved connection, or `nil` (with `errorMessage` set) when nothing was saved.
  func save() async -> Connection? {
    guard canSave else { return nil }
    errorMessage = nil

    guard case .success(let url) = normalizeEndpoint(endpoint) else {
      errorMessage = Self.invalidURLMessage
      return nil
    }
    let connection = Connection(baseURL: url, apiKey: trimmed(apiKey))

    isChecking = true
    defer { isChecking = false }
    do {
      _ = try await configuration.makeClient(connection).health()
    } catch {
      errorMessage = Self.message(for: error)
      return nil
    }

    do {
      try configuration.save(connection)
    } catch {
      errorMessage = "Couldn't save the key (\(error))"
      return nil
    }
    return connection
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

  private func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
