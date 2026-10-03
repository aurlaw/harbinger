import Foundation
import Observation

/// Where a turn goes: a new conversation (one slot) or an existing one.
nonisolated enum TurnTarget: Hashable, Sendable {
  case new
  case conversation(String)
}

/// One chat turn, exactly as sent. Retry resends the same value.
nonisolated struct TurnRequest: Hashable, Sendable {
  let target: TurnTarget
  /// Trimmed; `nil` for a just-pick turn with no text.
  let text: String?
  let justPick: Bool
  /// New conversations only; `nil` lets the server default apply.
  let model: String?
}

/// A turn in flight. View state only — never cached.
nonisolated struct PendingTurn: Equatable, Sendable {
  let request: TurnRequest
  let startedAt: Date
}

nonisolated struct TurnFailure: Equatable, Sendable {
  let request: TurnRequest
  let message: String
}

nonisolated enum TurnOutcome: Equatable, Sendable {
  case sent(conversationID: String)
  case failed(TurnFailure)
  /// A turn is already in flight for that target; no request was made.
  case rejected
}

/// Everything a connected screen needs: the API client, the cache writer, and the sync
/// controller. Created by `RootView` once a connection exists and injected with
/// `.environment(_:)`.
///
/// Sending lives here, not in views: the request and the ingest run in a task the session
/// owns, so a turn in flight survives navigating away from (and releasing) the chat screen.
@Observable
final class AppSession {
  let connection: Connection
  let client: any APIClient
  let syncService: SyncService
  let sync: SyncController

  /// From `GET /models`, once per session; `nil` until loaded or if loading failed.
  private(set) var defaultModel: String?
  private(set) var allowedModels: [String]?

  /// Turns in flight, by target.
  private(set) var pending: [TurnTarget: PendingTurn] = [:]
  /// The last failed turn per target, kept for Retry until the next send.
  private(set) var failures: [TurnTarget: TurnFailure] = [:]

  private let now: () -> Date
  private var modelsRequested = false

  init(
    connection: Connection, client: any APIClient, syncService: SyncService,
    sync: SyncController, now: @escaping () -> Date = Date.init
  ) {
    self.connection = connection
    self.client = client
    self.syncService = syncService
    self.sync = sync
    self.now = now
  }

  func loadModels() async {
    guard !modelsRequested else { return }
    modelsRequested = true
    do {
      let models = try await client.models()
      defaultModel = models.defaultModel
      allowedModels = models.allowed
    } catch {
      defaultModel = nil
      allowedModels = nil
    }
  }

  func isSending(_ target: TurnTarget) -> Bool {
    pending[target] != nil
  }

  /// Sends a turn and ingests the response. A second send for a target that already has a
  /// turn in flight is rejected without a request.
  @discardableResult
  func send(_ request: TurnRequest) async -> TurnOutcome {
    let target = request.target
    guard pending[target] == nil else { return .rejected }
    failures[target] = nil
    pending[target] = PendingTurn(request: request, startedAt: now())

    // Unstructured, so cancelling or releasing the caller doesn't cancel the request.
    let task = Task {
      let outcome = await self.perform(request)
      self.pending[target] = nil
      if case .failed(let failure) = outcome {
        self.failures[target] = failure
      }
      return outcome
    }
    return await task.value
  }

  /// Resends the failed turn for `target`, unchanged.
  @discardableResult
  func retry(_ target: TurnTarget) async -> TurnOutcome {
    guard let failure = failures[target] else { return .rejected }
    return await send(failure.request)
  }

  private func perform(_ request: TurnRequest) async -> TurnOutcome {
    let response: ConversationResponse
    do {
      switch request.target {
      case .new:
        response = try await client.createConversation(
          model: request.model, text: request.text ?? "", justPick: request.justPick)
      case .conversation(let id):
        response = try await client.sendMessage(
          conversationID: id, text: request.text, justPick: request.justPick)
      }
    } catch {
      return .failed(TurnFailure(request: request, message: turnErrorMessage(error)))
    }

    // The server has committed the turn. If caching it fails, a sync will deliver it.
    do {
      try await syncService.ingest(response)
    } catch {
      await sync.syncNow()
    }
    return .sent(conversationID: response.conversation.id)
  }
}
