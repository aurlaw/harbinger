import Foundation
import Observation

/// Delete and rename for a screen (the list, or a chat's title). The requests run on
/// `AppSession`, so they outlive this object; this only holds the screen's error alert.
@Observable
final class ConversationActions {
  let session: AppSession
  /// The last failure, shown in an alert until dismissed.
  var errorMessage: String?
  /// The request started by this screen, for tests and callers that want to wait.
  private(set) var task: Task<Void, Never>?

  init(session: AppSession) {
    self.session = session
  }

  func isDeleting(_ id: String) -> Bool {
    session.isDeleting(id)
  }

  /// Delete isn't offered while a turn is in flight for the conversation (the server would
  /// drop the turn), or while a delete is already running.
  func canDelete(_ id: String) -> Bool {
    !session.isSending(.conversation(id)) && !session.isDeleting(id)
  }

  /// Call after the user confirms.
  func delete(_ id: String) {
    guard canDelete(id) else { return }
    let session = session
    task = Task { [weak self] in
      let outcome = await session.deleteConversation(id: id)
      if case .failed(let message) = outcome {
        self?.errorMessage = message
      }
    }
  }

  func rename(_ id: String, to title: String) {
    guard TitleLimit.isValid(title) else { return }
    let session = session
    task = Task { [weak self] in
      let outcome = await session.renameConversation(id: id, title: title)
      if case .failed(let message) = outcome {
        self?.errorMessage = message
      }
    }
  }
}
