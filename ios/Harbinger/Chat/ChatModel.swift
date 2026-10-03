import Foundation
import Observation

/// One chat screen: a new conversation (no id yet) or an existing one. Holds the draft and
/// the model choice; the turn itself runs on `AppSession`, so it outlives this object.
@Observable
final class ChatModel {
  let session: AppSession
  /// `nil` until a new conversation's first turn succeeds, then its id.
  private(set) var conversationID: String?
  var draft = ""
  /// New conversations only; `nil` means the server default.
  var selectedModel: String?
  /// The send started by this screen, for tests and callers that want to wait.
  private(set) var sendTask: Task<Void, Never>?

  init(session: AppSession, conversationID: String?) {
    self.session = session
    self.conversationID = conversationID
  }

  var target: TurnTarget {
    conversationID.map(TurnTarget.conversation) ?? .new
  }

  var isNew: Bool { conversationID == nil }
  var isSending: Bool { session.isSending(target) }
  var pending: PendingTurn? { session.pending[target] }
  var failure: TurnFailure? { session.failures[target] }

  /// The model a new conversation will use: the user's choice, else the server default.
  var model: String? { selectedModel ?? session.defaultModel }

  var draftLength: Int { MessageLimit.length(draft) }
  var isOverLimit: Bool { draftLength > MessageLimit.maxLength }

  var canSend: Bool {
    !isSending && draftLength > 0 && !isOverLimit
  }

  /// Allowed with or without text, except that the Worker requires text to create a
  /// conversation.
  var canJustPick: Bool {
    !isSending && !isOverLimit && (!isNew || draftLength > 0)
  }

  /// Chips are live only on the latest message, and only while nothing is sending.
  func chipsEnabled(messageID: String, latestMessageID: String?) -> Bool {
    messageID == latestMessageID && !isSending
  }

  func send() {
    guard canSend else { return }
    start(text: MessageLimit.trimmed(draft), justPick: false, clearsDraft: true)
  }

  func justPick() {
    guard canJustPick else { return }
    let text = MessageLimit.trimmed(draft)
    start(text: text.isEmpty ? nil : text, justPick: true, clearsDraft: true)
  }

  func sendChip(_ chip: String) {
    guard !isSending else { return }
    start(text: chip, justPick: false, clearsDraft: false)
  }

  func retry() {
    guard let failure, !isSending else { return }
    begin(failure.request, restoresDraft: false)
  }

  private func start(text: String?, justPick: Bool, clearsDraft: Bool) {
    let request = TurnRequest(
      target: target, text: text, justPick: justPick, model: isNew ? model : nil)
    if clearsDraft {
      draft = ""
    }
    begin(request, restoresDraft: clearsDraft)
  }

  /// Only `weak self` is captured: if the screen goes away the turn still completes on the
  /// session; there is just no screen left to update.
  private func begin(_ request: TurnRequest, restoresDraft: Bool) {
    let session = session
    sendTask = Task { [weak self] in
      let outcome = await session.send(request)
      self?.finish(outcome, request: request, restoresDraft: restoresDraft)
    }
  }

  private func finish(_ outcome: TurnOutcome, request: TurnRequest, restoresDraft: Bool) {
    switch outcome {
    case .sent(let id):
      if conversationID == nil {
        conversationID = id
      }
    case .failed:
      if restoresDraft, draft.isEmpty, let text = request.text {
        draft = text
      }
    case .rejected:
      break
    }
  }
}
