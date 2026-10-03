import Foundation
import SwiftData
import Testing

@testable import Harbinger

/// A session over a fake Worker, an in-memory cache, and a real `SyncService`.
@MainActor
struct SessionHarness {
  let turns: TurnScript
  let decisions: DecisionScript
  let opener = OpenRecorder()
  let container: ModelContainer
  let session: AppSession

  init(turns: TurnScript = TurnScript(), decisions: DecisionScript = DecisionScript()) throws {
    self.turns = turns
    self.decisions = decisions
    container = try CacheStore.inMemory()
    let client = FakeAPIClient(turns: turns, decisions: decisions)
    let service = SyncService(modelContainer: container, client: client)
    let sync = SyncController(service: service)
    session = AppSession(
      connection: Connection(baseURL: testBaseURL, apiKey: testAPIKey), client: client,
      syncService: service, sync: sync, open: { [opener] in opener.open($0) })
  }

  /// Conversations, messages, recommendations (as in `CacheReader.counts()`, first three).
  func counts() throws -> [Int] {
    Array(try CacheReader(container).counts().prefix(3))
  }
}

/// Polls until `condition` holds (or a few seconds pass).
@MainActor
func eventually(_ seconds: Double = 3, _ condition: () throws -> Bool) async rethrows {
  let deadline = Date().addingTimeInterval(seconds)
  while try !condition(), Date() < deadline {
    try? await Task.sleep(for: .milliseconds(20))
  }
}

func turnResponse(_ json: String) throws -> ConversationResponse {
  try decodeFixture(ConversationResponse.self, json)
}

let testModels = ModelsResponse(
  defaultModel: "claude-sonnet-5",
  allowed: ["claude-haiku-4-5-20251001", "claude-sonnet-5", "claude-opus-5-5"])

@MainActor
struct AppSessionTests {
  let newTurn = TurnRequest(
    target: .new, text: "Something slow", justPick: false, model: "claude-opus-5-5")
  let nextTurn = TurnRequest(
    target: .conversation("conv-1"), text: "Less bleak", justPick: false, model: nil)

  // MARK: - Models

  @Test func loadModelsCachesDefaultAndAllowed() async throws {
    let harness = try SessionHarness(turns: TurnScript(models: .success(testModels)))

    await harness.session.loadModels()
    await harness.session.loadModels()

    #expect(harness.session.defaultModel == "claude-sonnet-5")
    #expect(harness.session.allowedModels == testModels.allowed)
    #expect(harness.turns.calls == [.models])
  }

  @Test func failedModelsMeanNewConversationsOmitTheModel() async throws {
    let turns = TurnScript(
      [.success(try turnResponse(Fixtures.conversationResponse))],
      models: .failure(.network(.notConnectedToInternet)))
    let harness = try SessionHarness(turns: turns)
    await harness.session.loadModels()
    #expect(harness.session.defaultModel == nil)
    #expect(harness.session.allowedModels == nil)

    let chat = ChatModel(session: harness.session, conversationID: nil)
    chat.draft = "Something slow"
    chat.send()
    await chat.sendTask?.value

    #expect(turns.calls.last == .create(model: nil, text: "Something slow", justPick: false))
  }

  // MARK: - Sending

  @Test func createConversationIsSentAndIngested() async throws {
    let harness = try SessionHarness(
      turns: TurnScript([.success(try turnResponse(Fixtures.recommendationsResponse))]))

    let outcome = await harness.session.send(newTurn)

    #expect(outcome == .sent(conversationID: "conv-1"))
    #expect(
      harness.turns.calls
        == [.create(model: "claude-opus-5-5", text: "Something slow", justPick: false)])
    #expect(try harness.counts() == [1, 2, 2])
    let conversation = try #require(try CacheReader(harness.container).conversation("conv-1"))
    let picks = conversation.orderedMessages.last?.orderedRecommendations
    #expect(picks?.map(\.id) == ["rec-1", "rec-2"])
    #expect(harness.session.pending.isEmpty)
  }

  @Test func sendMessageIsSentAndIngested() async throws {
    let harness = try SessionHarness(
      turns: TurnScript([.success(try turnResponse(Fixtures.conversationResponse))]))

    let outcome = await harness.session.send(nextTurn)

    #expect(outcome == .sent(conversationID: "conv-1"))
    #expect(
      harness.turns.calls == [.send(conversationID: "conv-1", text: "Less bleak", justPick: false)])
    #expect(try harness.counts() == [1, 2, 0])
  }

  @Test func secondSendWhileInFlightIsRejected() async throws {
    let harness = try SessionHarness(
      turns: TurnScript(
        [.success(try turnResponse(Fixtures.conversationResponse))], delay: .milliseconds(300)))
    let session = harness.session

    let first = Task { await session.send(nextTurn) }
    await eventually { session.isSending(nextTurn.target) }
    let second = await session.send(nextTurn)

    #expect(second == .rejected)
    #expect(await first.value == .sent(conversationID: "conv-1"))
    #expect(harness.turns.calls.count == 1)
  }

  @Test func otherTargetsAreNotBlocked() async throws {
    let harness = try SessionHarness(
      turns: TurnScript(
        [
          .success(try turnResponse(Fixtures.conversationResponse)),
          .success(try turnResponse(Fixtures.conversationResponse)),
        ], delay: .milliseconds(200)))
    let session = harness.session

    async let first = session.send(nextTurn)
    async let second = session.send(newTurn)
    let outcomes = await [first, second]

    #expect(!outcomes.contains(.rejected))
    #expect(harness.turns.calls.count == 2)
  }

  @Test func turnCompletesAfterTheChatScreenIsReleased() async throws {
    let harness = try SessionHarness(
      turns: TurnScript(
        [.success(try turnResponse(Fixtures.recommendationsResponse))], delay: .milliseconds(300)))
    var chat: ChatModel? = ChatModel(session: harness.session, conversationID: nil)
    weak let released = chat
    chat?.draft = "Something slow"
    chat?.send()
    await eventually { harness.session.isSending(.new) }

    chat = nil
    #expect(released == nil)

    // Ingest finishes just before the pending entry is cleared: wait for both.
    try await eventually { try harness.counts() == [1, 2, 2] && harness.session.pending.isEmpty }
    #expect(try harness.counts() == [1, 2, 2])
    #expect(harness.session.pending.isEmpty)
  }

  @Test func failureLeavesTheCacheUnchanged() async throws {
    let harness = try SessionHarness(
      turns: TurnScript([
        .failure(
          .server(status: 409, code: "conversation_busy", message: "busy", retryAfter: nil))
      ]))

    let outcome = await harness.session.send(nextTurn)

    let failure = TurnFailure(request: nextTurn, message: "Still working on the last message.")
    #expect(outcome == .failed(failure))
    #expect(harness.session.failures[nextTurn.target] == failure)
    #expect(harness.session.pending.isEmpty)
    #expect(try harness.counts() == [0, 0, 0])
  }

  @Test func retryResendsTheIdenticalRequest() async throws {
    let turn = TurnRequest(
      target: .conversation("conv-1"), text: nil, justPick: true, model: nil)
    let harness = try SessionHarness(
      turns: TurnScript([
        .failure(.network(.notConnectedToInternet)),
        .success(try turnResponse(Fixtures.recommendationsResponse)),
      ]))

    #expect(await harness.session.send(turn) != .sent(conversationID: "conv-1"))
    let outcome = await harness.session.retry(turn.target)

    let call = TurnScript.Call.send(conversationID: "conv-1", text: nil, justPick: true)
    #expect(harness.turns.calls == [call, call])
    #expect(outcome == .sent(conversationID: "conv-1"))
    #expect(harness.session.failures.isEmpty)
    #expect(try harness.counts() == [1, 2, 2])
  }

  @Test func retryWithoutAFailureDoesNothing() async throws {
    let harness = try SessionHarness()

    #expect(await harness.session.retry(.new) == .rejected)
    #expect(harness.turns.calls.isEmpty)
  }
}
