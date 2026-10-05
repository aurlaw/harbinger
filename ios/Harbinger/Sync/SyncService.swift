import Foundation
import OSLog
import SwiftData

nonisolated enum SyncError: Error, Sendable, Equatable {
  case api(APIError)
  case store(String)
}

/// Rows upserted (and conversations deleted by tombstones) by one sync.
nonisolated struct SyncResult: Sendable, Equatable {
  var conversations = 0
  var messages = 0
  var recommendations = 0
  var decisions = 0
  var profileUpdated = false
  /// Cached conversations removed by tombstones.
  var conversationsDeleted = 0
}

/// What the sync controller needs from the service (a seam for tests).
nonisolated protocol SyncServicing: Sendable {
  func sync() async throws(SyncError) -> SyncResult
  func resetAndSync() async throws(SyncError) -> SyncResult
  /// Returns whether the watched list was fetched (and replaced).
  @discardableResult
  func refreshWatched(force: Bool) async throws(SyncError) -> Bool
}

/// The only writer to the cache. Pulls `/sync`, upserts by id, and advances the cursor in
/// the same save as the data it covers.
///
/// Conforms to `ModelActor` by hand: the `@ModelActor` macro's generated initializer
/// can't take the API client.
actor SyncService: ModelActor, SyncServicing {
  nonisolated let modelExecutor: any ModelExecutor
  nonisolated let modelContainer: ModelContainer

  let log = Logger(subsystem: "com.aurlaw.harbinger", category: "sync")
  private let client: any APIClient
  private let beforeSave: (@Sendable () throws -> Void)?
  private var inFlight: Task<Result<SyncResult, SyncError>, Never>?
  private var isPulling = false

  /// - Parameter beforeSave: runs just before every save; tests use it to force a failure.
  init(
    modelContainer: ModelContainer, client: any APIClient,
    beforeSave: (@Sendable () throws -> Void)? = nil
  ) {
    self.modelContainer = modelContainer
    self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))
    self.client = client
    self.beforeSave = beforeSave
  }

  /// Builds the service off the main actor, so its context never runs on the main thread.
  @concurrent
  static func make(modelContainer: ModelContainer, client: any APIClient) async -> SyncService {
    SyncService(modelContainer: modelContainer, client: client)
  }

  // MARK: - Sync

  /// Pulls changes since the stored cursor (a full pull when there is none).
  ///
  /// The actor is reentrant across `await`, so a call made while a sync is running joins
  /// that sync instead of starting another request.
  @discardableResult
  func sync() async throws(SyncError) -> SyncResult {
    if let inFlight {
      return try await inFlight.value.get()
    }
    // The task clears itself, so a later call never joins a sync that has already finished.
    // A task created on a model actor starts running immediately, before the next line
    // here, so it may already be done: only keep it while the pull is still running.
    isPulling = true
    let task = Task {
      let result = await self.pull()
      self.isPulling = false
      self.inFlight = nil
      return result
    }
    if isPulling {
      inFlight = task
    }
    return try await task.value.get()
  }

  /// Deletes every cached row and the cursor, then does a full pull.
  @discardableResult
  func resetAndSync() async throws(SyncError) -> SyncResult {
    if let inFlight {
      _ = await inFlight.value
    }
    do {
      try deleteAll()
      try beforeSave?()
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw .store(String(describing: error))
    }
    return try await sync()
  }

  private func pull() async -> Result<SyncResult, SyncError> {
    let since: String?
    do {
      since = try syncState()?.nextSince
    } catch {
      return .failure(.store(String(describing: error)))
    }

    // An API failure leaves the cache and the cursor untouched.
    log.info("Sync started, since \(since ?? "the beginning", privacy: .public)")
    let response: SyncResponse
    do {
      response = try await client.sync(since: since)
    } catch {
      log.error("Sync request failed: \(String(describing: error), privacy: .public)")
      return .failure(.api(error))
    }

    do {
      let result = try apply(CacheBatch(response))
      let state = try syncState() ?? insertSyncState()
      state.nextSince = response.nextSince
      state.lastSyncedAt = Date()
      state.lastImportAt = response.lastImportAt
      try beforeSave?()
      try modelContext.save()
      log.info(
        """
        Sync saved: \(result.conversations) conversations, \(result.messages) messages, \
        \(result.recommendations) recommendations, \(result.decisions) decisions, \
        \(result.conversationsDeleted) conversations deleted; \
        next since \(response.nextSince, privacy: .public)
        """)
      return .success(result)
    } catch {
      modelContext.rollback()
      log.error("Sync rolled back: \(String(describing: error), privacy: .public)")
      return .failure(.store(String(describing: error)))
    }
  }

  // MARK: - Watched

  /// Replaces the cached watched list from `GET /library/watched`.
  ///
  /// Not forced: fetches only when an import exists and the cached list wasn't fetched for
  /// it (`SyncState.lastImportAt != watchedImportAt`) — the list changes only on import, so
  /// this is a no-op after most syncs. Forced: always fetches. On any failure the cached
  /// rows and the marker are unchanged.
  @discardableResult
  func refreshWatched(force: Bool) async throws(SyncError) -> Bool {
    if !force {
      let state: SyncState?
      do {
        state = try syncState()
      } catch {
        throw .store(String(describing: error))
      }
      guard let lastImportAt = state?.lastImportAt, lastImportAt != state?.watchedImportAt
      else { return false }
    }

    let response: WatchedResponse
    do {
      response = try await client.watched()
    } catch {
      log.error("Watched request failed: \(String(describing: error), privacy: .public)")
      throw .api(error)
    }

    do {
      try replaceWatched(with: response.films)
      let state = try syncState() ?? insertSyncState()
      state.watchedImportAt = response.lastImportAt
      try beforeSave?()
      try modelContext.save()
      log.info("Watched saved: \(response.films.count) films")
      return true
    } catch {
      modelContext.rollback()
      log.error("Watched rolled back: \(String(describing: error), privacy: .public)")
      throw .store(String(describing: error))
    }
  }

  /// Wholesale replace, by key: update or insert each film, then delete the rest. (Never a
  /// delete-all followed by inserts of the same unique keys in one save.)
  private func replaceWatched(with films: [WatchedFilm]) throws {
    var cached: [String: CachedWatchedFilm] = [:]
    for row in try modelContext.fetch(FetchDescriptor<CachedWatchedFilm>()) {
      cached[row.letterboxdURI] = row
    }
    for film in films {
      let row = cached.removeValue(forKey: film.letterboxdUri) ?? insertWatched(film)
      row.apply(film)
    }
    for row in cached.values {
      modelContext.delete(row)
    }
  }

  private func insertWatched(_ film: WatchedFilm) -> CachedWatchedFilm {
    let row = CachedWatchedFilm(letterboxdURI: film.letterboxdUri)
    modelContext.insert(row)
    return row
  }

  // MARK: - Ingest (write responses; the cursor is not advanced)

  /// A new chat turn: the conversation, its messages, and their nested recommendations.
  func ingest(_ response: ConversationResponse) throws(SyncError) {
    try write(CacheBatch(response))
  }

  /// A rename response: the conversation row only. One with `deletedAt` set is a tombstone.
  func ingest(_ conversation: Conversation) throws(SyncError) {
    try write(CacheBatch(conversations: [conversation]))
  }

  /// Drops a conversation (with its messages and recommendations) after the server deleted
  /// it, or said it is already gone. Decisions are kept. An unknown id is not an error.
  func removeConversation(id: String) throws(SyncError) {
    do {
      guard try deleteConversation(id: id) else { return }
      try beforeSave?()
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw .store(String(describing: error))
    }
  }

  func ingest(_ decision: Decision) throws(SyncError) {
    try write(CacheBatch(decisions: [decision]))
  }

  func ingest(_ profile: TasteProfile) throws(SyncError) {
    try write(CacheBatch(profile: profile))
  }

  private func write(_ batch: CacheBatch) throws(SyncError) {
    do {
      _ = try apply(batch)
      try beforeSave?()
      try modelContext.save()
    } catch {
      modelContext.rollback()
      throw .store(String(describing: error))
    }
  }

  // MARK: - Sync state

  private func syncState() throws -> SyncState? {
    try modelContext.fetch(FetchDescriptor<SyncState>()).first
  }

  private func insertSyncState() -> SyncState {
    let state = SyncState()
    modelContext.insert(state)
    return state
  }

  // Children first. The only other deletes are conversation tombstones / `removeConversation`.
  private func deleteAll() throws {
    try deleteEvery(CachedRecommendation.self)
    try deleteEvery(CachedMessage.self)
    try deleteEvery(CachedConversation.self)
    try deleteEvery(CachedDecision.self)
    try deleteEvery(CachedTasteProfile.self)
    // With `SyncState` (and its `watchedImportAt`) gone, the next sync refetches the list.
    try deleteEvery(CachedWatchedFilm.self)
    try deleteEvery(SyncState.self)
  }

  private func deleteEvery<Model: PersistentModel>(_ type: Model.Type) throws {
    for row in try modelContext.fetch(FetchDescriptor<Model>()) {
      modelContext.delete(row)
    }
  }
}
