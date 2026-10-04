import Foundation
import SwiftData
import Testing

@testable import Harbinger

// I4b: deleting and renaming conversations — client, cache, session, and view-model logic.

/// A deleted conversation as `/sync` deltas carry it: `deleted_at` set, no title.
func makeTombstone(id: String = "conv-1") -> Conversation {
  var conversation = makeConversation(id: id, title: nil, updatedAt: "2026-10-04T12:00:00.000Z")
  conversation.deletedAt = timestamp("2026-10-04T12:00:00.000Z")
  return conversation
}

func notFound() -> APIError {
  .server(status: 404, code: "not_found", message: "Conversation not found", retryAfter: nil)
}

func serverError(_ status: Int) -> APIError {
  .server(status: status, code: "some_error", message: "x", retryAfter: nil)
}

// MARK: - Client

extension APIClientTests {
  @Test func renameSendsThePatchAndDecodesABareConversation() async throws {
    StubURLProtocol.respond(
      body: """
        { "id": "conv-1", "title": "Folk horror night", "model": "claude-sonnet-5",
          "question_rounds": 1, "created_at": "2026-09-29T18:00:00.000Z",
          "updated_at": "2026-10-04T12:00:00.000Z", "deleted_at": null }
        """)

    let conversation = try await client.renameConversation(id: "conv-1", title: "Folk horror night")

    let request = try onlyRequest()
    #expect(request.httpMethod == "PATCH")
    #expect(request.url?.path() == "/conversations/conv-1")
    #expect(request.timeoutInterval == 30)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(
      try json(request.httpBody) == json(Data(#"{ "title": "Folk horror night" }"#.utf8)))
    #expect(conversation.title == "Folk horror night")
    #expect(conversation.updatedAt == timestamp("2026-10-04T12:00:00.000Z"))
    #expect(conversation.deletedAt == nil)
  }

  @Test func deleteSucceedsOnAnEmpty204() async throws {
    StubURLProtocol.respond(status: 204, body: "")

    try await client.deleteConversation(id: "a/b")

    let request = try onlyRequest()
    #expect(request.httpMethod == "DELETE")
    #expect(request.url?.absoluteString == "https://api.example.test/conversations/a%2Fb")
    #expect(request.timeoutInterval == 30)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(testAPIKey)")
    #expect(request.httpBody == nil)
  }

  @Test func deleteMapsErrorsLikeEveryOtherRequest() async {
    StubURLProtocol.respond(
      status: 404, body: Fixtures.error("not_found", "Conversation not found"))
    await #expect(throws: notFound()) { try await client.deleteConversation(id: "conv-1") }

    StubURLProtocol.respond(status: 401, body: Fixtures.error("unauthorized"))
    await #expect(throws: APIError.unauthorized) {
      try await client.deleteConversation(id: "conv-1")
    }

    StubURLProtocol.respond(status: 502, body: "not json")
    await #expect(throws: APIError.invalidResponse) {
      try await client.deleteConversation(id: "conv-1")
    }

    StubURLProtocol.fail(with: .timedOut)
    await #expect(throws: APIError.network(.timedOut)) {
      try await client.deleteConversation(id: "conv-1")
    }
  }

  @Test func conversationDecodesWithDeletedAtPresentNullAndAbsent() throws {
    func conversation(_ deletedAt: String) throws -> Conversation {
      try decodeFixture(
        Conversation.self,
        """
        { "id": "conv-1", "title": null, "model": "claude-sonnet-5", "question_rounds": 0,
          "created_at": "2026-09-29T18:00:00.000Z", "updated_at": "2026-10-04T12:00:00.123Z"
          \(deletedAt) }
        """)
    }

    let deleted = try conversation(#", "deleted_at": "2026-10-04T12:00:00.123Z""#)
    #expect(deleted.deletedAt == timestamp("2026-10-04T12:00:00.123Z"))
    #expect(deleted.title == nil)
    #expect(try conversation(#", "deleted_at": null"#).deletedAt == nil)
    #expect(try conversation("").deletedAt == nil)
    #expect(try decodeFixture(Conversation.self, Fixtures.conversation).deletedAt == nil)
  }
}

// MARK: - Cache

struct TombstoneTests {
  let container: ModelContainer
  let recorder = SyncRecorder()
  let service: SyncService

  init() throws {
    container = try CacheStore.inMemory()
    service = SyncService(modelContainer: container, client: FakeAPIClient(syncs: recorder))
  }

  /// conv-1 (3 messages, 1 recommendation, 1 decision) from the fixture, plus conv-2 with one
  /// message and a decision made in conv-1 on another film.
  func seed() async throws {
    var payload = try decodeFixture(SyncResponse.self, Fixtures.sync)
    payload = makeSync(
      nextSince: payload.nextSince,
      conversations: payload.conversations + [makeConversation(id: "conv-2", title: "Other")],
      messages: payload.messages + [
        Message(
          id: "other-1", seq: 1, content: .user(text: "Hello", justPick: false),
          createdAt: timestamp("2026-09-29T18:00:00.000Z"), conversationId: "conv-2")
      ],
      recommendations: payload.recommendations,
      decisions: payload.decisions + [makeDecision(.no, tmdbID: 67890)])
    recorder.enqueue(.success(payload))
    try await service.sync()
    #expect(try CacheReader(container).counts() == [2, 4, 1, 2, 0, 1])
  }

  func decisions() throws -> [String] {
    try CacheReader(container).snapshot().filter { $0.hasPrefix("decision") }
  }

  @Test func tombstoneRemovesTheConversationSubtreeAndKeepsDecisions() async throws {
    try await seed()
    let decisionsBefore = try decisions()
    let otherBefore = try CacheReader(container).snapshot().filter { $0.contains("conv-2") }
    recorder.enqueue(.success(makeSync(conversations: [makeTombstone()])))

    let result = try await service.sync()

    #expect(result == SyncResult(conversationsDeleted: 1))
    let reader = CacheReader(container)
    #expect(try reader.counts() == [1, 1, 0, 2, 0, 1])
    #expect(try reader.conversation("conv-1") == nil)
    #expect(try decisions() == decisionsBefore)
    #expect(decisionsBefore.count == 2)
    #expect(try reader.snapshot().filter { $0.contains("conv-2") } == otherBefore)
    #expect(try reader.state()?.nextSince == "2026-09-29T19:00:00.000Z")
  }

  @Test func tombstoneForAnUncachedConversationInsertsNothing() async throws {
    try await seed()
    let before = try CacheReader(container).snapshot()
    recorder.enqueue(
      .success(makeSync(nextSince: Fixtures.nextSince, conversations: [makeTombstone(id: "nope")])))

    let result = try await service.sync()

    #expect(result == SyncResult())
    #expect(try CacheReader(container).snapshot() == before)
  }

  @Test func applyingTheSameTombstoneTwiceIsHarmless() async throws {
    try await seed()
    let delta = makeSync(conversations: [makeTombstone()])
    recorder.enqueue(.success(delta))
    recorder.enqueue(.success(delta))

    #expect(try await service.sync().conversationsDeleted == 1)
    let once = try CacheReader(container).snapshot()
    #expect(try await service.sync().conversationsDeleted == 0)

    #expect(try CacheReader(container).snapshot() == once)
    #expect(try CacheReader(container).counts() == [1, 1, 0, 2, 0, 1])
  }

  /// The server never sends content with a tombstone; if it did, it must not come back.
  @Test func contentSentWithATombstoneIsSkipped() async throws {
    try await seed()
    let payload = try decodeFixture(SyncResponse.self, Fixtures.sync)
    recorder.enqueue(
      .success(
        makeSync(
          conversations: [makeTombstone()], messages: payload.messages,
          recommendations: payload.recommendations)))

    let result = try await service.sync()

    #expect(result == SyncResult(conversationsDeleted: 1))
    #expect(try CacheReader(container).counts() == [1, 1, 0, 2, 0, 1])
  }

  // MARK: Ingest helpers

  @Test func ingestConversationUpdatesTheRowOnly() async throws {
    try await seed()
    let before = try CacheReader(container).snapshot()

    try await service.ingest(
      makeConversation(title: "Folk horror night", updatedAt: "2026-10-04T12:00:00.000Z"))

    let reader = CacheReader(container)
    let conversation = try #require(try reader.conversation("conv-1"))
    #expect(conversation.title == "Folk horror night")
    #expect(conversation.updatedAt == timestamp("2026-10-04T12:00:00.000Z"))
    #expect(conversation.orderedMessages.map(\.id) == ["msg-1", "msg-2", "msg-4"])
    #expect(try reader.counts() == [2, 4, 1, 2, 0, 1])
    // Everything but the conversation's own line is unchanged, and the cursor didn't move.
    let unchanged: (String) -> Bool = { !$0.hasPrefix("conversation conv-1") }
    #expect(try reader.snapshot().filter(unchanged) == before.filter(unchanged))
    #expect(recorder.sinces == [nil])
  }

  @Test func ingestingATombstoneDeletes() async throws {
    try await seed()

    try await service.ingest(makeTombstone())

    #expect(try CacheReader(container).counts() == [1, 1, 0, 2, 0, 1])
  }

  @Test func removeConversationDeletesTheSubtreeAndKeepsDecisions() async throws {
    try await seed()
    let decisionsBefore = try decisions()

    try await service.removeConversation(id: "conv-1")

    let reader = CacheReader(container)
    #expect(try reader.counts() == [1, 1, 0, 2, 0, 1])
    #expect(try decisions() == decisionsBefore)
    #expect(try reader.state()?.nextSince == Fixtures.nextSince)

    // Unknown (or already removed): not an error.
    try await service.removeConversation(id: "conv-1")
    try await service.removeConversation(id: "nope")
    #expect(try CacheReader(container).counts() == [1, 1, 0, 2, 0, 1])
  }

  /// A failed save after a delete must roll back cleanly (and the cursor must not move).
  @Test func failedDeletesRollBack() async throws {
    let failure = SaveFailure(isFailing: false)
    let service = SyncService(
      modelContainer: container, client: FakeAPIClient(syncs: recorder),
      beforeSave: { try failure.check() })
    recorder.enqueue(.success(try decodeFixture(SyncResponse.self, Fixtures.sync)))
    try await service.sync()
    let before = try CacheReader(container).snapshot()
    failure.set(true)

    await #expect(throws: SyncError.self) { try await service.removeConversation(id: "conv-1") }
    #expect(try CacheReader(container).snapshot() == before)

    recorder.enqueue(.success(makeSync(conversations: [makeTombstone()])))
    await #expect(throws: SyncError.self) { try await service.sync() }
    #expect(try CacheReader(container).snapshot() == before)

    // Once saving works again, both paths still delete.
    failure.set(false)
    try await service.removeConversation(id: "conv-1")
    #expect(try CacheReader(container).counts() == [0, 0, 0, 1, 0, 1])
  }
}

// MARK: - Session

@MainActor
struct ConversationManagementTests {
  let turn = TurnRequest(
    target: .conversation("conv-1"), text: "Less bleak", justPick: false, model: nil)

  /// conv-1 cached with 2 messages, 2 recommendations, and a No on one of its films.
  func harness(
    renames: [Result<Conversation, APIError>] = [], deletes: [APIError?] = [],
    delay: Duration? = nil, turns: TurnScript = TurnScript()
  ) async throws -> SessionHarness {
    let harness = try SessionHarness(
      turns: turns,
      management: ManagementScript(renames: renames, deletes: deletes, delay: delay))
    try await harness.session.syncService.ingest(
      try turnResponse(Fixtures.recommendationsResponse))
    try await harness.session.syncService.ingest(makeDecision(.no))
    #expect(try harness.counts() == [1, 2, 2])
    return harness
  }

  func slowTurns() throws -> TurnScript {
    TurnScript(
      [.success(try turnResponse(Fixtures.conversationResponse))], delay: .milliseconds(300))
  }

  func decisionCount(_ harness: SessionHarness) throws -> Int {
    try CacheReader(harness.container).all(CachedDecision.self).count
  }

  func title(_ harness: SessionHarness) throws -> String? {
    try CacheReader(harness.container).conversation("conv-1")?.title
  }

  let renamed = makeConversation(title: "Folk horror night", updatedAt: "2026-10-04T12:00:00.000Z")

  // MARK: Delete

  @Test func deleteRemovesTheConversationAndKeepsItsDecision() async throws {
    let harness = try await harness(deletes: [nil])

    let outcome = await harness.session.deleteConversation(id: "conv-1")

    #expect(outcome == .deleted)
    #expect(harness.management.calls == [.delete(id: "conv-1")])
    #expect(try harness.counts() == [0, 0, 0])
    #expect(try decisionCount(harness) == 1)
    #expect(harness.session.deleting.isEmpty)
  }

  @Test func deleteTreatsA404AsAlreadyGone() async throws {
    let harness = try await harness(deletes: [notFound()])

    #expect(await harness.session.deleteConversation(id: "conv-1") == .deleted)
    #expect(try harness.counts() == [0, 0, 0])
    #expect(try decisionCount(harness) == 1)
  }

  @Test func deleteIsBlockedWhileATurnIsInFlight() async throws {
    let harness = try await harness(deletes: [nil], turns: try slowTurns())
    let session = harness.session
    let sending = Task { await session.send(turn) }
    await eventually { session.isSending(turn.target) }

    #expect(await session.deleteConversation(id: "conv-1") == .blocked)
    #expect(harness.management.calls.isEmpty)

    _ = await sending.value
    #expect(await session.deleteConversation(id: "conv-1") == .deleted)
  }

  @Test func secondDeleteWhileInFlightIsRejected() async throws {
    let harness = try await harness(deletes: [nil], delay: .milliseconds(300))
    let session = harness.session

    let first = Task { await session.deleteConversation(id: "conv-1") }
    await eventually { session.isDeleting("conv-1") }
    let second = await session.deleteConversation(id: "conv-1")

    #expect(second == .rejected)
    #expect(await first.value == .deleted)
    #expect(harness.management.calls == [.delete(id: "conv-1")])
  }

  @Test(arguments: [
    (APIError.network(.notConnectedToInternet), "You're offline."),
    (serverError(500), "Couldn't delete — try again."),
    (.unauthorized, "API key rejected — update it in Settings."),
    (.invalidResponse, "Something went wrong."),
  ])
  func deleteFailureLeavesTheCacheUnchanged(error: APIError, text: String) async throws {
    let harness = try await harness(deletes: [error])

    #expect(await harness.session.deleteConversation(id: "conv-1") == .failed(text))
    #expect(try harness.counts() == [1, 2, 2])
    #expect(harness.session.deleting.isEmpty)
  }

  // MARK: Rename

  @Test func renameTrimsAndUpdatesTheCachedTitleOnly() async throws {
    let harness = try await harness(renames: [.success(renamed)])

    let outcome = await harness.session.renameConversation(
      id: "conv-1", title: "  Folk horror night \n")

    #expect(outcome == .renamed)
    #expect(harness.management.calls == [.rename(id: "conv-1", title: "Folk horror night")])
    #expect(try title(harness) == "Folk horror night")
    #expect(try harness.counts() == [1, 2, 2])
    #expect(harness.session.renaming.isEmpty)
  }

  @Test func renameValidatesBeforeAnyRequest() async throws {
    let ghost = "\u{1F47B}"
    // One grapheme cluster, five scalars: man + ZWJ + woman + ZWJ + girl.
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
    #expect(family.count == 1)
    let harness = try await harness(renames: [.success(renamed), .success(renamed)])
    let session = harness.session

    for title in [
      "", " \n\t ", String(repeating: "x", count: 101), String(repeating: ghost, count: 101),
      String(repeating: family, count: 21),
    ] {
      #expect(await session.renameConversation(id: "conv-1", title: title) == .invalid)
    }
    #expect(harness.management.calls.isEmpty)

    // 98 emoji plus an "e" with a combining accent: 100 scalars, 99 characters.
    let hundred = String(repeating: ghost, count: 98) + "e\u{301}"
    #expect(hundred.unicodeScalars.count == 100)
    #expect(hundred.count == 99)
    #expect(await session.renameConversation(id: "conv-1", title: hundred) == .renamed)
    let families = String(repeating: family, count: 20)
    #expect(await session.renameConversation(id: "conv-1", title: " \(families) ") == .renamed)
    #expect(
      harness.management.calls
        == [.rename(id: "conv-1", title: hundred), .rename(id: "conv-1", title: families)])
  }

  @Test func rename404RemovesTheConversation() async throws {
    let harness = try await harness(renames: [.failure(notFound())])

    let outcome = await harness.session.renameConversation(id: "conv-1", title: "New")

    #expect(outcome == .failed("This conversation no longer exists."))
    #expect(try harness.counts() == [0, 0, 0])
    #expect(try decisionCount(harness) == 1)
  }

  @Test(arguments: [
    (APIError.network(.timedOut), "Can't reach the server."),
    (serverError(400), "Couldn't rename — try again."),
    (.unauthorized, "API key rejected — update it in Settings."),
    (.decoding("x"), "Something went wrong."),
  ])
  func renameFailureLeavesTheCacheUnchanged(error: APIError, text: String) async throws {
    let harness = try await harness(renames: [.failure(error)])

    #expect(await harness.session.renameConversation(id: "conv-1", title: "New") == .failed(text))
    #expect(try title(harness) == "Something slow and unsettling")
    #expect(try harness.counts() == [1, 2, 2])
  }

  @Test func renameIsAllowedWhileATurnIsInFlight() async throws {
    let harness = try await harness(renames: [.success(renamed)], turns: try slowTurns())
    let session = harness.session
    let sending = Task { await session.send(turn) }
    await eventually { session.isSending(turn.target) }

    #expect(await session.renameConversation(id: "conv-1", title: "Folk horror night") == .renamed)
    #expect(session.isSending(turn.target))
    _ = await sending.value
  }

  @Test func secondRenameWhileInFlightIsRejected() async throws {
    let harness = try await harness(renames: [.success(renamed)], delay: .milliseconds(300))
    let session = harness.session

    let first = Task { await session.renameConversation(id: "conv-1", title: "Folk horror night") }
    await eventually { session.renaming.contains("conv-1") }

    #expect(await session.renameConversation(id: "conv-1", title: "Other") == .rejected)
    #expect(await first.value == .renamed)
    #expect(harness.management.calls.count == 1)
  }

  // MARK: View models

  @Test func deleteAndRenameCompleteAfterTheScreenIsReleased() async throws {
    let harness = try await harness(
      renames: [.success(renamed)], deletes: [nil], delay: .milliseconds(300))
    let session = harness.session

    var actions: ConversationActions? = ConversationActions(session: session)
    weak let released = actions
    actions?.rename("conv-1", to: "Folk horror night")
    await eventually { session.renaming.contains("conv-1") }
    actions = nil
    #expect(released == nil)
    try await eventually { try title(harness) == "Folk horror night" && session.renaming.isEmpty }
    #expect(try title(harness) == "Folk horror night")

    actions = ConversationActions(session: session)
    weak let releasedAgain = actions
    actions?.delete("conv-1")
    await eventually { session.isDeleting("conv-1") }
    actions = nil
    #expect(releasedAgain == nil)
    try await eventually { try harness.counts() == [0, 0, 0] && session.deleting.isEmpty }
    #expect(try harness.counts() == [0, 0, 0])
  }

  @Test func deleteIsUnavailableWhileATurnIsInFlight() async throws {
    let harness = try await harness(deletes: [nil], turns: try slowTurns())
    let session = harness.session
    let actions = ConversationActions(session: session)
    #expect(actions.canDelete("conv-1"))

    let sending = Task { await session.send(turn) }
    await eventually { session.isSending(turn.target) }
    #expect(!actions.canDelete("conv-1"))
    // Other conversations are unaffected.
    #expect(actions.canDelete("conv-2"))
    actions.delete("conv-1")
    #expect(actions.task == nil)

    _ = await sending.value
    #expect(actions.canDelete("conv-1"))
    #expect(harness.management.calls.isEmpty)
  }

  @Test func deleteIsUnavailableWhileDeletingAndFailuresSetTheAlertText() async throws {
    let harness = try await harness(
      renames: [.failure(.network(.timedOut))],
      deletes: [serverError(500)],
      delay: .milliseconds(200))
    let actions = ConversationActions(session: harness.session)

    actions.delete("conv-1")
    await eventually { actions.isDeleting("conv-1") }
    #expect(!actions.canDelete("conv-1"))
    await actions.task?.value
    #expect(actions.errorMessage == "Couldn't delete — try again.")
    #expect(actions.canDelete("conv-1"))

    actions.errorMessage = nil
    actions.rename("conv-1", to: "New")
    await actions.task?.value
    #expect(actions.errorMessage == "Can't reach the server.")
    #expect(try harness.counts() == [1, 2, 2])
  }

  @Test func chatAsksToPopBackWhenItsConversationDisappearsAfterLoading() async throws {
    let harness = try await harness()

    let chat = ChatModel(session: harness.session, conversationID: "conv-1")
    // Still loading: an empty query is not a deletion.
    chat.conversationIsCached(false)
    #expect(!chat.shouldDismiss)
    chat.conversationIsCached(true)
    #expect(!chat.shouldDismiss)
    chat.conversationIsCached(false)
    #expect(chat.shouldDismiss)

    // A new, unsaved conversation is never "deleted".
    let new = ChatModel(session: harness.session, conversationID: nil)
    new.conversationIsCached(false)
    new.conversationIsCached(false)
    #expect(!new.shouldDismiss)
  }
}
