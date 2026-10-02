import Foundation
import SwiftData
import Testing

@testable import Harbinger

struct SyncServiceTests {
  let container: ModelContainer
  let recorder = SyncRecorder()
  let service: SyncService

  init() throws {
    container = try CacheStore.inMemory()
    service = SyncService(modelContainer: container, client: FakeAPIClient(syncs: recorder))
  }

  /// The real-shaped payload: 1 conversation, 3 messages, 1 recommendation, 1 decision,
  /// `taste_profile: null`.
  func fullPayload() throws -> SyncResponse {
    try decodeFixture(SyncResponse.self, Fixtures.sync)
  }

  @discardableResult
  func seed() async throws -> SyncResult {
    recorder.enqueue(.success(try fullPayload()))
    return try await service.sync()
  }

  // MARK: - Full pull

  @Test func fullPullInsertsEveryRowWithRelationships() async throws {
    let result = try await seed()

    #expect(
      result
        == SyncResult(
          conversations: 1, messages: 3, recommendations: 1, decisions: 1, profileUpdated: false))
    let reader = CacheReader(container)
    #expect(try reader.counts() == [1, 3, 1, 1, 0, 1])

    let conversation = try #require(try reader.conversation("conv-1"))
    #expect(conversation.title == "Something slow and unsettling")
    #expect(conversation.questionRounds == 1)
    #expect(conversation.updatedAt == timestamp("2026-09-29T18:01:30.456Z"))

    let messages = conversation.orderedMessages
    #expect(messages.map(\.id) == ["msg-1", "msg-2", "msg-4"])
    #expect(messages.map(\.seq) == [1, 2, 4])
    #expect(messages.map(\.conversationID) == ["conv-1", "conv-1", "conv-1"])
    #expect(messages[0].content == .user(text: "Something slow", justPick: false))
    #expect(messages[1].content == .question(text: "How long?", chips: ["Short", "Long"]))
    #expect(messages[2].content == .recommendations(dropped: 0))

    let recommendation = try #require(messages[2].orderedRecommendations.first)
    #expect(recommendation.id == "rec-2")
    #expect(recommendation.message?.id == "msg-4")
    #expect(recommendation.messageID == "msg-4")
    #expect(recommendation.conversationID == "conv-1")
    #expect(recommendation.tmdbID == 67890)
    #expect(recommendation.runtime == 87)
    #expect(recommendation.director == nil)
    #expect(recommendation.providers.isEmpty)
    #expect(recommendation.createdAt == timestamp("2026-09-29T18:01:30.456Z"))

    let decision = try #require(try reader.all(CachedDecision.self).first)
    #expect(decision.tmdbID == 12345)
    #expect(decision.choice == .maybe)
  }

  @Test func fullPullStoresProviders() async throws {
    let message = try decodeFixture(Message.self, Fixtures.recommendationsMessage)
    let flat = Message(
      id: message.id, seq: message.seq, content: message.content, createdAt: message.createdAt,
      conversationId: "conv-1", recommendations: message.recommendations)
    recorder.enqueue(
      .success(makeSync(conversations: [makeConversation()], messages: [flat])))

    try await service.sync()

    let cached = try #require(try CacheReader(container).message("msg-4"))
    #expect(cached.orderedRecommendations.map(\.position) == [1, 2])
    #expect(
      cached.orderedRecommendations[0].providers
        == [CachedProvider(name: "Shudder", type: "flatrate", logoPath: "/x.jpg")])
  }

  @Test func cursorIsStoredAndSentBackByteForByte() async throws {
    try await seed()

    let state = try #require(try CacheReader(container).state())
    #expect(state.nextSince == Fixtures.nextSince)
    #expect(state.lastSyncedAt != nil)
    #expect(state.lastImportAt == timestamp("2026-09-24T21:54:00.000Z"))

    recorder.enqueue(.success(makeSync(nextSince: "2026-09-29T19:00:00.000Z")))
    try await service.sync()
    recorder.enqueue(.success(makeSync()))
    try await service.sync()

    #expect(recorder.sinces == [nil, Fixtures.nextSince, "2026-09-29T19:00:00.000Z"])
  }

  // MARK: - Delta

  @Test func deltaOverwritesConversationAndAddsMessages() async throws {
    try await seed()
    let newMessage = Message(
      id: "msg-5", seq: 5, content: .user(text: "Less bleak", justPick: false),
      createdAt: timestamp("2026-09-29T18:20:00.000Z"), conversationId: "conv-1")
    recorder.enqueue(
      .success(
        makeSync(
          conversations: [
            makeConversation(
              title: "Renamed", questionRounds: 2, updatedAt: "2026-09-29T18:20:05.000Z")
          ],
          messages: [newMessage])))

    let result = try await service.sync()

    #expect(result.conversations == 1)
    #expect(result.messages == 1)
    let reader = CacheReader(container)
    #expect(try reader.counts() == [1, 4, 1, 1, 0, 1])
    let conversation = try #require(try reader.conversation("conv-1"))
    #expect(conversation.title == "Renamed")
    #expect(conversation.questionRounds == 2)
    #expect(conversation.updatedAt == timestamp("2026-09-29T18:20:05.000Z"))
    #expect(conversation.orderedMessages.map(\.id) == ["msg-1", "msg-2", "msg-4", "msg-5"])
    // Rows the delta didn't mention are untouched.
    #expect(conversation.orderedMessages[0].text == "Something slow")
    #expect(conversation.orderedMessages[2].orderedRecommendations.map(\.id) == ["rec-2"])
  }

  @Test func changedDecisionUpdatesTheSingleRow() async throws {
    try await seed()
    recorder.enqueue(.success(makeSync(decisions: [makeDecision(.yes)])))

    try await service.sync()

    let decisions = try CacheReader(container).all(CachedDecision.self)
    #expect(decisions.count == 1)
    #expect(decisions.first?.choice == .yes)
    #expect(decisions.first?.decidedAt == timestamp("2026-09-29T18:30:00.000Z"))
  }

  @Test func nullProfileLeavesCachedProfileIntact() async throws {
    recorder.enqueue(.success(makeSync(profile: makeProfile("## Enjoys\n- Folk horror"))))
    let first = try await service.sync()
    #expect(first.profileUpdated)

    recorder.enqueue(.success(makeSync(profile: nil)))
    let second = try await service.sync()

    #expect(!second.profileUpdated)
    let profiles = try CacheReader(container).all(CachedTasteProfile.self)
    #expect(profiles.map(\.content) == ["## Enjoys\n- Folk horror"])
    #expect(profiles.first?.basedOnImportID == 3)
  }

  @Test func newProfileOverwritesCachedProfile() async throws {
    recorder.enqueue(.success(makeSync(profile: makeProfile("Old"))))
    try await service.sync()
    recorder.enqueue(.success(makeSync(profile: makeProfile("New"))))
    try await service.sync()

    #expect(try CacheReader(container).all(CachedTasteProfile.self).map(\.content) == ["New"])
  }

  @Test func emptyDeltaChangesNothing() async throws {
    try await seed()
    recorder.enqueue(.success(makeSync(nextSince: Fixtures.nextSince)))
    let before = try CacheReader(container).snapshot()

    let result = try await service.sync()

    #expect(result == SyncResult())
    #expect(try CacheReader(container).snapshot() == before)
  }

  @Test func applyingTheSameResponseTwiceIsIdempotent() async throws {
    try await seed()
    let before = try CacheReader(container).snapshot()

    try await seed()

    let reader = CacheReader(container)
    #expect(try reader.counts() == [1, 3, 1, 1, 0, 1])
    #expect(try reader.snapshot() == before)
  }

  @Test func orphanedRowsAreSkipped() async throws {
    let orphanRecommendation = Recommendation(
      id: "rec-x", position: 1, tmdbId: 1, title: "Orphan", year: nil, whyShort: "",
      whyFull: "", conversationId: "conv-1", messageId: "missing")
    let orphanMessage = Message(
      id: "msg-x", seq: 1, content: .user(text: "hi", justPick: false),
      createdAt: timestamp("2026-09-29T18:00:00.000Z"), conversationId: "missing")
    recorder.enqueue(
      .success(makeSync(messages: [orphanMessage], recommendations: [orphanRecommendation])))

    let result = try await service.sync()

    #expect(result == SyncResult())
    #expect(try CacheReader(container).counts() == [0, 0, 0, 0, 0, 1])
  }

  // MARK: - Failure + concurrency

  @Test func apiErrorWritesNothing() async throws {
    try await seed()
    let before = try CacheReader(container).snapshot()
    recorder.enqueue(.failure(.unauthorized))

    await #expect(throws: SyncError.api(.unauthorized)) { try await service.sync() }

    #expect(try CacheReader(container).snapshot() == before)
    #expect(try CacheReader(container).state()?.nextSince == Fixtures.nextSince)
  }

  @Test func apiErrorOnEmptyCacheLeavesNoCursor() async throws {
    recorder.enqueue(.failure(.network(.timedOut)))

    await #expect(throws: SyncError.api(.network(.timedOut))) { try await service.sync() }

    #expect(try CacheReader(container).counts() == [0, 0, 0, 0, 0, 0])
  }

  @Test func saveFailureRollsBack() async throws {
    let failure = SaveFailure()
    let service = SyncService(
      modelContainer: container, client: FakeAPIClient(syncs: recorder),
      beforeSave: { try failure.check() })
    recorder.enqueue(.success(try fullPayload()))

    await #expect {
      try await service.sync()
    } throws: { error in
      if case .store = error as? SyncError { return true }
      return false
    }
    #expect(try CacheReader(container).counts() == [0, 0, 0, 0, 0, 0])

    // A later successful save must not carry the failed sync's rows or cursor with it.
    failure.set(false)
    try await service.ingest(makeProfile("Saved later"))
    #expect(try CacheReader(container).counts() == [0, 0, 0, 0, 1, 0])

    // And the next sync is still a full pull.
    recorder.enqueue(.success(try fullPayload()))
    try await service.sync()
    #expect(recorder.sinces == [nil, nil])
  }

  @Test func concurrentSyncsShareOneRequest() async throws {
    let recorder = SyncRecorder([.success(try fullPayload())], delay: .milliseconds(200))
    let service = SyncService(modelContainer: container, client: FakeAPIClient(syncs: recorder))

    async let first = service.sync()
    async let second = service.sync()
    let results = try await [first, second]

    #expect(recorder.sinces.count == 1)
    #expect(results[0] == results[1])
    #expect(try CacheReader(container).counts() == [1, 3, 1, 1, 0, 1])
  }

  // MARK: - Reset

  @Test func resetClearsEverythingThenPullsInFull() async throws {
    try await seed()
    try await service.ingest(makeProfile("Cached"))
    recorder.enqueue(
      .success(
        makeSync(
          nextSince: "2026-09-29T20:00:00.000Z",
          conversations: [makeConversation(id: "conv-2", title: "Fresh")])))

    let result = try await service.resetAndSync()

    #expect(result.conversations == 1)
    #expect(recorder.sinces == [nil, nil])
    let reader = CacheReader(container)
    #expect(try reader.counts() == [1, 0, 0, 0, 0, 1])
    #expect(try reader.all(CachedConversation.self).map(\.id) == ["conv-2"])
    #expect(try reader.state()?.nextSince == "2026-09-29T20:00:00.000Z")
  }

  @Test func resetWithFailedPullLeavesAnEmptyCache() async throws {
    try await seed()
    recorder.enqueue(.failure(.network(.notConnectedToInternet)))

    await #expect(throws: SyncError.api(.network(.notConnectedToInternet))) {
      try await service.resetAndSync()
    }

    #expect(try CacheReader(container).counts() == [0, 0, 0, 0, 0, 0])
  }

  // MARK: - Ingest

  @Test func ingestConversationResponseAddsTheTurn() async throws {
    try await seed()
    let turn = try decodeFixture(ConversationResponse.self, Fixtures.recommendationsResponse)

    try await service.ingest(turn)

    let reader = CacheReader(container)
    // msg-3 and rec-1 are new; msg-4 and rec-2 were already cached.
    #expect(try reader.counts() == [1, 4, 2, 1, 0, 1])
    let conversation = try #require(try reader.conversation("conv-1"))
    #expect(conversation.orderedMessages.map(\.id) == ["msg-1", "msg-2", "msg-3", "msg-4"])
    #expect(conversation.orderedMessages[2].content == .user(text: nil, justPick: true))

    let picks = conversation.orderedMessages[3]
    #expect(picks.content == .recommendations(dropped: 1))
    #expect(picks.orderedRecommendations.map(\.id) == ["rec-1", "rec-2"])
    #expect(picks.orderedRecommendations.map(\.conversationID) == ["conv-1", "conv-1"])
    #expect(picks.orderedRecommendations.map(\.messageID) == ["msg-4", "msg-4"])
    // Nested recommendations carry no timestamp: the synced one is kept.
    #expect(picks.orderedRecommendations[1].createdAt == timestamp("2026-09-29T18:01:30.456Z"))
    #expect(picks.orderedRecommendations[0].createdAt == nil)

    #expect(try reader.state()?.nextSince == Fixtures.nextSince)
    #expect(recorder.sinces == [nil])
  }

  @Test func ingestIntoEmptyCacheLeavesNoCursor() async throws {
    let turn = try decodeFixture(ConversationResponse.self, Fixtures.conversationResponse)

    try await service.ingest(turn)

    let reader = CacheReader(container)
    #expect(try reader.counts() == [1, 2, 0, 0, 0, 0])
    #expect(try reader.conversation("conv-1")?.orderedMessages.map(\.id) == ["msg-1", "msg-2"])
  }

  @Test func ingestDecisionUpserts() async throws {
    try await seed()

    try await service.ingest(makeDecision(.no))
    try await service.ingest(makeDecision(.yes, tmdbID: 67890))

    let decisions = try CacheReader(container).all(CachedDecision.self)
      .sorted { $0.tmdbID < $1.tmdbID }
    #expect(decisions.map(\.tmdbID) == [12345, 67890])
    #expect(decisions.map(\.choice) == [.no, .yes])
    #expect(try CacheReader(container).state()?.nextSince == Fixtures.nextSince)
  }

  @Test func ingestProfileUpserts() async throws {
    try await service.ingest(makeProfile("First"))
    try await service.ingest(makeProfile("Second"))

    let reader = CacheReader(container)
    #expect(try reader.all(CachedTasteProfile.self).map(\.content) == ["Second"])
    #expect(try reader.state() == nil)
  }
}
