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
  /// The request was cut off after it was sent (or retried into a `409` while it was still
  /// running), so this turn's reply may still arrive by sync.
  var replyMayArrive = false
}

/// A failed turn's reply turned up in the cache after a follow-up sync. View state only.
nonisolated struct TurnArrival: Equatable, Sendable {
  let request: TurnRequest
  let conversationID: String
  /// The arrived reply answers `request` itself, so the text restored to the composer has
  /// been sent. `false` when it was an earlier turn that landed (`409`).
  let clearsDraft: Bool
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

nonisolated enum DeleteOutcome: Equatable, Sendable {
  /// Gone from the server (deleted now, or already gone) and removed from the cache.
  case deleted
  case failed(String)
  /// A turn is in flight for that conversation; no request was made.
  case blocked
  /// A delete for that conversation is already in flight; no request was made.
  case rejected
}

nonisolated enum RenameOutcome: Equatable, Sendable {
  case renamed
  /// Includes a `404`: the conversation is gone, and has been removed from the cache.
  case failed(String)
  /// Empty or over `TitleLimit.maxLength` after trimming; no request was made.
  case invalid
  /// A rename for that conversation is already in flight; no request was made.
  case rejected
}

nonisolated enum ProfileDraftOutcome: Equatable, Sendable {
  /// Not saved: the editor shows it, and nothing is cached until the user saves.
  case drafted(TasteProfileDraft)
  case failed(String)
  /// A draft is already in flight; no request was made.
  case rejected
}

nonisolated enum ProfileSaveOutcome: Equatable, Sendable {
  /// Saved on the server and cached.
  case saved(TasteProfile)
  case failed(String)
  /// Empty or over `ProfileLimit.maxLength` after trimming; no request was made.
  case invalid
  /// A save is already in flight; no request was made.
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
  /// The track record (fetched, never cached), shared by the Watched tab's summary row and
  /// the full track-record screen.
  let trackRecord: TrackRecordModel

  /// From `GET /models`, once per session; `nil` until loaded or if loading failed.
  private(set) var defaultModel: String?
  private(set) var allowedModels: [String]?
  /// The user's default model (Settings); `nil` means the server default.
  private(set) var savedModel: String?

  /// Turns in flight, by target.
  private(set) var pending: [TurnTarget: PendingTurn] = [:]
  /// The last failed turn per target, kept for Retry until the next send.
  private(set) var failures: [TurnTarget: TurnFailure] = [:]
  /// Failed turns whose reply has since arrived by sync, until the next send.
  private(set) var arrivals: [TurnTarget: TurnArrival] = [:]
  /// Follow-up syncs for turns that may still land, by target.
  private var followUps: [TurnTarget: Task<Void, Never>] = [:]

  /// When to sync again after a turn that may still land: 20 s and 60 s after it failed.
  static let followUpDelays: [Duration] = [.seconds(20), .seconds(40)]

  /// Decisions in flight, by TMDB id.
  private(set) var pendingDecisions: [Int: DecisionRequest] = [:]
  /// The last failed decision per TMDB id, kept for Retry until the next attempt.
  private(set) var decisionFailures: [Int: DecisionFailure] = [:]

  /// Conversations with a delete / rename in flight, by id.
  private(set) var deleting: Set<String> = []
  private(set) var renaming: Set<String> = []

  /// A taste-profile draft / save in flight.
  private(set) var isDraftingProfile = false
  private(set) var isSavingProfile = false

  private let modelPreference: ModelPreferenceStore
  private let background: BackgroundTime
  private let sleep: @Sendable (Duration) async -> Void
  private let now: () -> Date
  /// Opens external links (Letterboxd after a Yes). `RootView` passes the `openURL` action.
  private let open: (URL) -> Void
  private var modelsRequested = false

  init(
    connection: Connection, client: any APIClient, syncService: SyncService,
    sync: SyncController, open: @escaping (URL) -> Void,
    modelPreference: ModelPreferenceStore = ModelPreferenceStore(),
    background: BackgroundTime = .live,
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
    now: @escaping () -> Date = Date.init
  ) {
    self.connection = connection
    self.client = client
    self.syncService = syncService
    self.sync = sync
    self.trackRecord = TrackRecordModel(client: client)
    self.open = open
    self.modelPreference = modelPreference
    self.savedModel = modelPreference.model()
    self.background = background
    self.sleep = sleep
    self.now = now
  }

  /// The model for new conversations and drafts: the saved default if the server still
  /// allows it, else the server default; `nil` (models not loaded) lets the server choose.
  var preferredModel: String? {
    resolveModel(saved: savedModel, allowed: allowedModels, serverDefault: defaultModel)
  }

  /// Saves the default model; `nil` clears it ("Server default").
  func setSavedModel(_ model: String?) {
    modelPreference.save(model)
    savedModel = model
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
    // Retrying a turn that may still land: if the server answers "busy", the turn still
    // running there is this one.
    let isRetryOfCutOffTurn = failures[target].map { $0.replyMayArrive && $0.request == request }
    failures[target] = nil
    arrivals[target] = nil
    followUps.removeValue(forKey: target)?.cancel()
    pending[target] = PendingTurn(request: request, startedAt: now())

    // Unstructured, so cancelling or releasing the caller doesn't cancel the request.
    let task = Task {
      let result = await self.background.run("Chat turn") {
        await self.perform(request, isRetryOfCutOffTurn: isRetryOfCutOffTurn ?? false)
      }
      self.pending[target] = nil
      if case .failed(let failure) = result.outcome {
        self.failures[target] = failure
        if let baseline = result.followUpBaseline {
          self.scheduleFollowUps(for: failure, since: baseline)
        }
      }
      return result.outcome
    }
    return await task.value
  }

  /// A cut-off turn usually still commits on the server, and `/sync` delivers it: sync again
  /// 20 s and 60 s later (manual syncs, so the 30 s throttle doesn't apply). When the reply
  /// shows up in the cache the failure is replaced by an arrival.
  private func scheduleFollowUps(for failure: TurnFailure, since baseline: TurnBaseline) {
    let target = failure.request.target
    followUps[target] = Task {
      for delay in Self.followUpDelays {
        await self.sleep(delay)
        if Task.isCancelled { return }
        await self.sync.syncNow()
        // A newer send for the target owns its state now.
        guard !Task.isCancelled, self.failures[target] == failure else { return }
        let arrived = try? await self.syncService.arrivedConversation(
          for: failure.request, since: baseline)
        guard let arrived, self.failures[target] == failure else { continue }
        self.failures[target] = nil
        self.arrivals[target] = TurnArrival(
          request: failure.request, conversationID: arrived,
          clearsDraft: failure.replyMayArrive)
        return
      }
    }
  }

  /// Resends the failed turn for `target`, unchanged.
  @discardableResult
  func retry(_ target: TurnTarget) async -> TurnOutcome {
    guard let failure = failures[target] else { return .rejected }
    return await send(failure.request)
  }

  // MARK: - Conversation management

  func isDeleting(_ id: String) -> Bool {
    deleting.contains(id)
  }

  /// Deletes a conversation on the server, then drops it from the cache (decisions are
  /// kept). Refused while a turn is in flight for it. Like turns, the request runs in a
  /// task the session owns.
  @discardableResult
  func deleteConversation(id: String) async -> DeleteOutcome {
    guard !isSending(.conversation(id)) else { return .blocked }
    guard !deleting.contains(id) else { return .rejected }
    deleting.insert(id)

    let task = Task {
      let outcome = await self.background.run("Delete conversation") {
        await self.performDelete(id)
      }
      self.deleting.remove(id)
      return outcome
    }
    return await task.value
  }

  /// Renames a conversation; the cache only changes from the server's response. Allowed
  /// while a turn is in flight (the server's turn save doesn't touch the title).
  @discardableResult
  func renameConversation(id: String, title: String) async -> RenameOutcome {
    let title = TitleLimit.trimmed(title)
    guard TitleLimit.isValid(title) else { return .invalid }
    guard !renaming.contains(id) else { return .rejected }
    renaming.insert(id)

    let task = Task {
      let outcome = await self.background.run("Rename conversation") {
        await self.performRename(id, title: title)
      }
      self.renaming.remove(id)
      return outcome
    }
    return await task.value
  }

  private func performDelete(_ id: String) async -> DeleteOutcome {
    do {
      try await client.deleteConversation(id: id)
    } catch .server(404, _, _, _) {
      // Already gone on the server: the same result.
    } catch {
      return .failed(deleteErrorMessage(error))
    }
    await removeFromCache(id)
    return .deleted
  }

  private func performRename(_ id: String, title: String) async -> RenameOutcome {
    let conversation: Conversation
    do {
      conversation = try await client.renameConversation(id: id, title: title)
    } catch {
      // A 404 means the conversation is gone (deleted elsewhere).
      if case .server(404, _, _, _) = error {
        await removeFromCache(id)
      }
      return .failed(renameErrorMessage(error))
    }
    // Saved on the server. If caching it fails, a sync will deliver it.
    do {
      try await syncService.ingest(conversation)
    } catch {
      await sync.syncNow()
    }
    return .renamed
  }

  /// The server no longer has the conversation. If dropping it fails, a sync delivers the
  /// tombstone.
  private func removeFromCache(_ id: String) async {
    do {
      try await syncService.removeConversation(id: id)
    } catch {
      await sync.syncNow()
    }
    failures[.conversation(id)] = nil
  }

  // MARK: - Taste profile

  /// Asks the server for a draft. Nothing is saved or cached; a draft that completes after
  /// the editor has gone is simply dropped. Like turns, the request runs in a task the
  /// session owns.
  func draftTasteProfile() async -> ProfileDraftOutcome {
    guard !isDraftingProfile else { return .rejected }
    isDraftingProfile = true
    let model = preferredModel

    let task = Task {
      let outcome = await self.background.run("Draft taste profile") {
        await self.performDraft(model: model)
      }
      self.isDraftingProfile = false
      return outcome
    }
    return await task.value
  }

  private func performDraft(model: String?) async -> ProfileDraftOutcome {
    do {
      return .drafted(try await client.draftTasteProfile(model: model))
    } catch {
      return .failed(draftErrorMessage(error))
    }
  }

  /// Saves the profile and caches the server's copy.
  @discardableResult
  func saveTasteProfile(content: String) async -> ProfileSaveOutcome {
    let content = ProfileLimit.trimmed(content)
    guard ProfileLimit.isValid(content) else { return .invalid }
    guard !isSavingProfile else { return .rejected }
    isSavingProfile = true

    let task = Task {
      let outcome = await self.background.run("Save taste profile") {
        await self.performProfileSave(content)
      }
      self.isSavingProfile = false
      return outcome
    }
    return await task.value
  }

  private func performProfileSave(_ content: String) async -> ProfileSaveOutcome {
    let profile: TasteProfile
    do {
      profile = try await client.saveTasteProfile(content: content)
    } catch {
      return .failed(profileSaveErrorMessage(error))
    }
    // Saved on the server. If caching it fails, a sync will deliver it.
    do {
      try await syncService.ingest(profile)
    } catch {
      await sync.syncNow()
    }
    return .saved(profile)
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
      let outcome = await self.background.run("Save decision") {
        await self.perform(request)
      }
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

  /// A turn's outcome, plus — when its reply may still land — what the cache held before
  /// it was sent.
  private struct TurnResult {
    let outcome: TurnOutcome
    var followUpBaseline: TurnBaseline?
  }

  private func perform(_ request: TurnRequest, isRetryOfCutOffTurn: Bool) async -> TurnResult {
    // Taken before the request, so a reply that lands at any point afterwards is noticed.
    let baseline = try? await syncService.turnBaseline(for: request.target)

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
      let cutOff = replyMayStillArrive(error)
      let busy = isConversationBusy(error)
      let failure = TurnFailure(
        request: request, message: turnErrorMessage(error),
        replyMayArrive: cutOff || (busy && isRetryOfCutOffTurn))
      // Busy means an earlier turn is still landing: follow up for that too.
      return TurnResult(
        outcome: .failed(failure), followUpBaseline: cutOff || busy ? baseline : nil)
    }

    // The server has committed the turn. If caching it fails, a sync will deliver it.
    do {
      try await syncService.ingest(response)
    } catch {
      await sync.syncNow()
    }
    return TurnResult(outcome: .sent(conversationID: response.conversation.id))
  }
}
