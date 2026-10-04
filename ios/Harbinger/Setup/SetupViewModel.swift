import Foundation
import Observation

/// First-launch sheet: validates an endpoint + key against `/health`, and saves both
/// only when the check passes.
@Observable
final class SetupViewModel {
  static let invalidURLMessage = ConnectionCheck.invalidURLMessage
  static let keyRejectedMessage = ConnectionCheck.keyRejectedMessage
  static let unreachableMessage = ConnectionCheck.unreachableMessage

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

    isChecking = true
    defer { isChecking = false }
    let result = await ConnectionCheck.verifyAndSave(
      endpoint: endpoint, apiKey: trimmed(apiKey), configuration: configuration)
    switch result {
    case .success(let connection):
      return connection
    case .failure(let failure):
      errorMessage = failure.message
      return nil
    }
  }

  static func message(for error: APIError) -> String {
    ConnectionCheck.message(for: error)
  }

  private func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
