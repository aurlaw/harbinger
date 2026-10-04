import Foundation
import Observation
import SwiftUI

/// What Settings needs to change the connection: the stores, and `RootView`'s hand-off
/// (which rebuilds the session for the new connection).
struct ConnectionEditor {
  let configuration: AppConfiguration
  let apply: (Connection) -> Void
}

extension EnvironmentValues {
  /// Set by `RootView`; `nil` where there is no connection to edit (tests, previews).
  @Entry var connectionEditor: ConnectionEditor?
}

/// State for the Settings screen. Cached values (profile, sync times) come from the view's
/// `@Query`; this holds the connection form and the rebuild confirmation.
@Observable
final class SettingsModel {
  let session: AppSession
  private let editor: ConnectionEditor?

  var endpoint: String
  /// A replacement key. The saved key is never shown.
  var apiKey = ""
  private(set) var isChecking = false
  private(set) var connectionError: String?
  var isConfirmingRebuild = false
  /// The request started by this screen, for tests and callers that want to wait.
  private(set) var task: Task<Void, Never>?

  init(session: AppSession, editor: ConnectionEditor?) {
    self.session = session
    self.editor = editor
    endpoint = session.connection.baseURL.absoluteString
  }

  // MARK: - Default model

  /// The picker's "Server default" row, naming the server's default when it is known.
  var serverDefaultLabel: String {
    session.defaultModel.map { "Server default (\($0))" } ?? "Server default"
  }

  /// The picker's selection: the saved model while the server still allows it, otherwise
  /// "Server default" (`nil`). Choosing "Server default" clears the stored value.
  var modelSelection: String? {
    get {
      guard let saved = session.savedModel, session.allowedModels?.contains(saved) == true
      else { return nil }
      return saved
    }
    set { session.setSavedModel(newValue) }
  }

  // MARK: - Sync

  func syncNow() {
    let sync = session.sync
    task = Task { await sync.syncNow() }
  }

  /// Runs only from the confirmation dialog.
  func confirmRebuild() {
    let sync = session.sync
    task = Task { await sync.rebuild() }
  }

  // MARK: - Connection

  var canEditConnection: Bool { editor != nil }

  private var newKey: String {
    apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Enabled when the URL differs from the saved one or a new key was entered.
  var canSaveConnection: Bool {
    guard editor != nil, !isChecking else { return false }
    let entered = try? normalizeEndpoint(endpoint).get()
    return entered != session.connection.baseURL || !newKey.isEmpty
  }

  /// Checks the candidate connection against `/health` (with the new key if one was
  /// entered, else the saved one), saves it, and hands it to `RootView`. Nothing is saved
  /// on failure.
  @discardableResult
  func saveConnection() async -> Connection? {
    guard let editor, canSaveConnection else { return nil }
    connectionError = nil
    isChecking = true
    defer { isChecking = false }

    let key = newKey.isEmpty ? session.connection.apiKey : newKey
    let result = await ConnectionCheck.verifyAndSave(
      endpoint: endpoint, apiKey: key, configuration: editor.configuration)
    switch result {
    case .success(let connection):
      apiKey = ""
      endpoint = connection.baseURL.absoluteString
      editor.apply(connection)
      return connection
    case .failure(let failure):
      connectionError = failure.message
      return nil
    }
  }
}

/// "Not set", or when the cached profile was last saved.
func profileStatusText(updatedAt: Date?, now: Date = Date()) -> String {
  guard let updatedAt else { return "Not set" }
  let relative = updatedAt.formatted(
    Date.RelativeFormatStyle(presentation: .named).locale(.current))
  // A save moments ago can land a hair after `now`; never say "in 0 seconds".
  return updatedAt >= now ? "Updated just now" : "Updated \(relative)"
}

/// "1.0 (2)" from the bundle's version and build.
nonisolated func appVersionText(_ info: [String: Any]?) -> String {
  let version = info?["CFBundleShortVersionString"] as? String
  let build = info?["CFBundleVersion"] as? String
  switch (version, build) {
  case (let version?, let build?): return "\(version) (\(build))"
  case (let version?, nil): return version
  case (nil, let build?): return "(\(build))"
  case (nil, nil): return "Unknown"
  }
}
