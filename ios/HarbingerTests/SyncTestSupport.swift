import Foundation
import SwiftData
import Synchronization
import Testing

@testable import Harbinger

func timestamp(_ string: String) -> Date {
  parseTimestamp(string)!
}

func decodeFixture<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
  try makeDecoder().decode(type, from: Data(json.utf8))
}

/// A `/sync` response built in code; everything defaults to "no changes".
func makeSync(
  nextSince: String = "2026-09-29T19:00:00.000Z",
  conversations: [Conversation] = [], messages: [Message] = [],
  recommendations: [Recommendation] = [], decisions: [Decision] = [],
  profile: TasteProfile? = nil, lastImportAt: Date? = timestamp("2026-09-24T21:54:00.000Z")
) -> SyncResponse {
  SyncResponse(
    serverTime: "2026-09-29T19:02:00.000Z", nextSince: nextSince, conversations: conversations,
    messages: messages, recommendations: recommendations, decisions: decisions,
    tasteProfile: profile, lastImportAt: lastImportAt)
}

func makeConversation(
  id: String = "conv-1", title: String? = "Something slow and unsettling",
  questionRounds: Int = 1, updatedAt: String = "2026-09-29T18:01:30.456Z"
) -> Conversation {
  Conversation(
    id: id, title: title, model: "claude-sonnet-5", questionRounds: questionRounds,
    createdAt: timestamp("2026-09-29T18:00:00.000Z"), updatedAt: timestamp(updatedAt))
}

func makeDecision(_ choice: Decision.Choice, tmdbID: Int = 12345) -> Decision {
  Decision(
    tmdbId: tmdbID, decision: choice, conversationId: "conv-1",
    decidedAt: timestamp("2026-09-29T18:30:00.000Z"))
}

func makeProfile(_ content: String) -> TasteProfile {
  TasteProfile(
    content: content, basedOnImportId: 3, updatedAt: timestamp("2026-09-29T18:40:00.000Z"))
}

/// Reads the cache through its own context, as the UI would: only saved state is visible.
/// Make a new reader after each write — the context must outlive the rows it fetched.
struct CacheReader {
  let context: ModelContext

  init(_ container: ModelContainer) {
    context = ModelContext(container)
  }

  func all<Model: PersistentModel>(_ type: Model.Type) throws -> [Model] {
    try context.fetch(FetchDescriptor<Model>())
  }

  func conversation(_ id: String) throws -> CachedConversation? {
    try all(CachedConversation.self).first { $0.id == id }
  }

  func message(_ id: String) throws -> CachedMessage? {
    try all(CachedMessage.self).first { $0.id == id }
  }

  func state() throws -> SyncState? {
    try all(SyncState.self).first
  }

  func counts() throws -> [Int] {
    [
      try all(CachedConversation.self).count, try all(CachedMessage.self).count,
      try all(CachedRecommendation.self).count, try all(CachedDecision.self).count,
      try all(CachedTasteProfile.self).count, try all(SyncState.self).count,
    ]
  }

  /// Every cached value except `lastSyncedAt`, in a stable order.
  func snapshot() throws -> [String] {
    var lines: [String] = []
    for row in try all(CachedConversation.self).sorted(by: { $0.id < $1.id }) {
      lines.append(
        "conversation \(row.id) \(row.title ?? "-") \(row.model) \(row.questionRounds) "
          + "\(row.createdAt) \(row.updatedAt) \(row.orderedMessages.map(\.id))")
    }
    for row in try all(CachedMessage.self).sorted(by: { $0.id < $1.id }) {
      lines.append(
        "message \(row.id) \(row.conversationID) \(row.seq) \(row.role) \(row.kind) "
          + "\(row.text ?? "-") \(row.justPick) \(row.chips) \(row.dropped) \(row.createdAt) "
          + "\(row.conversation?.id ?? "-") \(row.orderedRecommendations.map(\.id))")
    }
    for row in try all(CachedRecommendation.self).sorted(by: { $0.id < $1.id }) {
      lines.append(
        "recommendation \(row.id) \(row.conversationID) \(row.messageID) \(row.position) "
          + "\(row.tmdbID) \(row.title) \(String(describing: row.year)) \(row.whyShort) "
          + "\(row.providers) \(String(describing: row.createdAt)) \(row.message?.id ?? "-")")
    }
    for row in try all(CachedDecision.self).sorted(by: { $0.tmdbID < $1.tmdbID }) {
      lines.append(
        "decision \(row.tmdbID) \(row.decision) \(row.conversationID) \(row.decidedAt)")
    }
    for row in try all(CachedTasteProfile.self) {
      lines.append(
        "profile \(row.content) \(String(describing: row.basedOnImportID)) \(row.updatedAt)")
    }
    for row in try all(SyncState.self) {
      lines.append("state \(row.nextSince ?? "-") \(String(describing: row.lastImportAt))")
    }
    return lines
  }
}

/// A `beforeSave` hook that fails while `isFailing` is set.
final class SaveFailure: Sendable {
  struct Forced: Error {}

  private let failing: Mutex<Bool>

  init(isFailing: Bool = true) {
    failing = Mutex(isFailing)
  }

  func set(_ isFailing: Bool) {
    failing.withLock { $0 = isFailing }
  }

  func check() throws {
    if failing.withLock({ $0 }) { throw Forced() }
  }
}

/// A sync service that only counts calls (`calls` for `sync()`, `resets` for
/// `resetAndSync()`, `watchedForces` for each `refreshWatched(force:)`).
final class FakeSyncService: SyncServicing {
  private struct State {
    var calls = 0
    var resets = 0
    var result: Result<SyncResult, SyncError>
    var watchedForces: [Bool] = []
    var watchedError: SyncError?
  }

  private let state: Mutex<State>

  init(result: Result<SyncResult, SyncError> = .success(SyncResult())) {
    state = Mutex(State(result: result))
  }

  var calls: Int { state.withLock { $0.calls } }
  var resets: Int { state.withLock { $0.resets } }

  /// One entry per `refreshWatched(force:)`, in order.
  var watchedForces: [Bool] { state.withLock { $0.watchedForces } }

  func set(_ result: Result<SyncResult, SyncError>) {
    state.withLock { $0.result = result }
  }

  /// `nil` makes watched refreshes succeed.
  func setWatchedError(_ error: SyncError?) {
    state.withLock { $0.watchedError = error }
  }

  func refreshWatched(force: Bool) async throws(SyncError) -> Bool {
    let error = state.withLock { state -> SyncError? in
      state.watchedForces.append(force)
      return state.watchedError
    }
    if let error { throw error }
    return force
  }

  func sync() async throws(SyncError) -> SyncResult {
    try state.withLock { state -> Result<SyncResult, SyncError> in
      state.calls += 1
      return state.result
    }.get()
  }

  func resetAndSync() async throws(SyncError) -> SyncResult {
    try state.withLock { state -> Result<SyncResult, SyncError> in
      state.resets += 1
      return state.result
    }.get()
  }
}
