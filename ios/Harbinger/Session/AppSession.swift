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

/// A decision on a pick: the film, the choice, and the conversation that recommended it
/// (the server only accepts decisions on films recommended in that conversation).
nonisolated struct DecisionRequest: Hashable, Sendable {
  let tmdbID: Int
  let choice: Decision.Choice
  let conversationID: String
}

nonisolated struct DecisionFailure: Equatable, Sendable {
  let request: DecisionRequest
  let message: String
}

nonisolated enum DecisionOutcome: Equatable, Sendable {
  case saved(Decision.Choice)
  /// Re-tapped the current choice: no request (Yes still re-opens Letterboxd).
  case unchanged
  case failed(DecisionFailure)
  /// A decision for that film is already in flight; no request was made.
  case rejected
}

/// The pick a decision is about, as plain values (no model object crosses into the session).
nonisolated struct DecisionTarget: Hashable, Sendable {
  let tmdbID: Int
  /// The recommendation's own conversation.
  let conversationID: String

  init(tmdbID: Int, conversationID: String) {
    self.tmdbID = tmdbID
    self.conversationID = conversationID
  }

  init(_ pick: CachedRecommendation) {
    self.init(tmdbID: pick.tmdbID, conversationID: pick.conversationID)
  }
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

  /// Decisions in flight, by TMDB id.
  private(set) var pendingDecisions: [Int: DecisionRequest] = [:]
  /// The last failed decision per TMDB id, kept for Retry until the next attempt.
  private(set) var decisionFailures: [Int: DecisionFailure] = [:]

  private let now: () -> Date
  /// Opens external links (Letterboxd after a Yes). `RootView` passes the `openURL` action.
  private let open: (URL) -> Void
  private var modelsRequested = false

  init(
    connection: Connection, client: any APIClient, syncService: SyncService,
    sync: SyncController, open: @escaping (URL) -> Void,
    now: @escaping () -> Date = Date.init
  ) {
    self.connection = connection
    self.client = client
    self.syncService = syncService
    self.sync = sync
    self.open = open
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

  // MARK: - Decisions

  /// Records a decision. `current` is the cached decision for the film: re-choosing it makes
  /// no request (re-choosing Yes just re-opens Letterboxd). After a Yes is saved, opens the
  /// film on Letterboxd. Like turns, the request runs in a task the session owns.
  @discardableResult
  func setDecision(
    _ choice: Decision.Choice, for pick: DecisionTarget, current: Decision.Choice?
  ) async -> DecisionOutcome {
    guard pendingDecisions[pick.tmdbID] == nil else { return .rejected }
    if choice == current {
      if choice == .yes {
        openLetterboxd(pick.tmdbID)
      }
      return .unchanged
    }
    return await submit(
      DecisionRequest(tmdbID: pick.tmdbID, choice: choice, conversationID: pick.conversationID))
  }

  /// Resends the failed decision for the film, unchanged.
  @discardableResult
  func retryDecision(tmdbID: Int) async -> DecisionOutcome {
    guard pendingDecisions[tmdbID] == nil, let failure = decisionFailures[tmdbID] else {
      return .rejected
    }
    return await submit(failure.request)
  }

  private func submit(_ request: DecisionRequest) async -> DecisionOutcome {
    let tmdbID = request.tmdbID
    decisionFailures[tmdbID] = nil
    pendingDecisions[tmdbID] = request

    let task = Task {
      let outcome = await self.perform(request)
      self.pendingDecisions[tmdbID] = nil
      switch outcome {
      case .failed(let failure):
        self.decisionFailures[tmdbID] = failure
      case .saved(.yes):
        self.openLetterboxd(tmdbID)
      case .saved, .unchanged, .rejected:
        break
      }
      return outcome
    }
    return await task.value
  }

  private func perform(_ request: DecisionRequest) async -> DecisionOutcome {
    let decision: Decision
    do {
      decision = try await client.setDecision(
        tmdbID: request.tmdbID, decision: request.choice, conversationID: request.conversationID)
    } catch {
      return .failed(DecisionFailure(request: request, message: decisionErrorMessage(error)))
    }
    // Saved on the server. If caching it fails, a sync will deliver it.
    do {
      try await syncService.ingest(decision)
    } catch {
      await sync.syncNow()
    }
    return .saved(decision.decision)
  }

  private func openLetterboxd(_ tmdbID: Int) {
    if let url = letterboxdURL(tmdbID: tmdbID) {
      open(url)
    }
  }

  // MARK: - Turns

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
