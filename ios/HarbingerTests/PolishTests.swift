import Foundation
import SwiftData
import SwiftUI
import Testing

@testable import Harbinger

// I6: error copy, slow / cut-off turns, starter suggestions, background time, accessibility.

/// A user message and a question reply for `conversationID`, as `/sync` sends them.
func syncedTurn(conversationID: String, firstSeq: Int, text: String) -> [Message] {
  [
    Message(
      id: "\(conversationID)-m\(firstSeq)", seq: firstSeq,
      content: .user(text: text, justPick: false),
      createdAt: timestamp("2026-10-04T12:00:00.000Z"), conversationId: conversationID),
    Message(
      id: "\(conversationID)-m\(firstSeq + 1)", seq: firstSeq + 1,
      content: .question(text: "How long?", chips: []),
      createdAt: timestamp("2026-10-04T12:00:30.000Z"), conversationId: conversationID),
  ]
}

// MARK: - Error text

struct ErrorTextTests {
  static let helpers: [(String, @Sendable (APIError) -> String)] = [
    ("turn", turnErrorMessage), ("delete", deleteErrorMessage), ("rename", renameErrorMessage),
    ("draft", draftErrorMessage), ("profile save", profileSaveErrorMessage),
    ("decision", decisionErrorMessage),
  ]

  @Test func theSharedBaseReadsTheSameInEveryContext() {
    for (context, message) in Self.helpers {
      #expect(
        message(.unauthorized) == "API key rejected — update it in Settings.",
        "\(context)")
      #expect(message(.network(.notConnectedToInternet)) == "You're offline.", "\(context)")
      #expect(message(.network(.cannotFindHost)) == "Can't reach the server.", "\(context)")
      #expect(message(.decoding("x")) == "Something went wrong.", "\(context)")
      #expect(message(.invalidResponse) == "Something went wrong.", "\(context)")
    }
  }

  @Test func contextsKeepTheirOwnServerText() {
    let server = serverError(500)
    #expect(deleteErrorMessage(server) == "Couldn't delete — try again.")
    #expect(renameErrorMessage(server) == "Couldn't rename — try again.")
    #expect(renameErrorMessage(notFound()) == "This conversation no longer exists.")
    #expect(draftErrorMessage(server) == "Couldn't draft — try again.")
    #expect(profileSaveErrorMessage(server) == "Couldn't save — try again.")
    #expect(decisionErrorMessage(server) == "Couldn't save that — try again.")
    // A cut-off request only means "may still arrive" for a chat turn.
    #expect(deleteErrorMessage(.network(.timedOut)) == "Can't reach the server.")
  }

  @Test func onlyCutOffRequestsMayStillArrive() {
    #expect(replyMayStillArrive(.network(.timedOut)))
    #expect(replyMayStillArrive(.network(.networkConnectionLost)))
    #expect(!replyMayStillArrive(.network(.notConnectedToInternet)))
    #expect(!replyMayStillArrive(.network(.cannotConnectToHost)))
    #expect(!replyMayStillArrive(.unauthorized))
    #expect(!replyMayStillArrive(serverError(502)))
  }

  @Test(arguments: [
    (SyncError.api(.unauthorized), "API key rejected — update it in Settings."),
    (.api(.network(.notConnectedToInternet)), "You're offline — pull to retry."),
    (.api(.network(.timedOut)), "Couldn't sync — pull to retry."),
    (.api(serverError(503)), "Couldn't sync — pull to retry."),
    (.store("x"), "Couldn't sync — pull to retry."),
  ])
  func syncNotice(error: SyncError, text: String) {
    #expect(syncNoticeMessage(error) == text)
  }

  @MainActor @Test func theListNoticeFollowsTheLastSync() async {
    let service = FakeSyncService(result: .failure(.api(.network(.notConnectedToInternet))))
    let controller = SyncController(service: service)
    #expect(syncNoticeMessage(controller.lastFailure) == nil)

    await controller.syncNow()
    #expect(syncNoticeMessage(controller.lastFailure) == "You're offline — pull to retry.")

    service.set(.success(SyncResult()))
    await controller.syncNow()
    #expect(controller.lastFailure == nil)
    #expect(syncNoticeMessage(controller.lastFailure) == nil)
  }

  // MARK: Accessibility text

  @Test func pickCardLabel() {
    #expect(
      pickAccessibilityLabel(
        title: "The Witch", year: 2015, whyShort: "Slow dread.", decision: .yes)
        == "The Witch, 2015. Slow dread. Decision: Yes")
    #expect(
      pickAccessibilityLabel(title: "The Witch", year: nil, whyShort: "Slow dread", decision: nil)
        == "The Witch. Slow dread")
    #expect(
      pickAccessibilityLabel(title: "Lake Mungo", year: 2008, whyShort: " ", decision: .no)
        == "Lake Mungo, 2008. Decision: No")
    #expect(
      pickAccessibilityLabel(title: "Kairo", year: nil, whyShort: "", decision: .maybe)
        == "Kairo. Decision: Maybe")
  }

  @Test func decisionButtonLabels() {
    #expect(decisionAccessibilityLabel(.yes) == "Yes — add to watchlist")
    #expect(decisionAccessibilityLabel(.maybe) == "Maybe")
    #expect(decisionAccessibilityLabel(.no) == "No — never recommend")
  }
}

// MARK: - Slow or cut-off turns

@MainActor
struct SlowTurnTests {
  let turn = TurnRequest(
    target: .conversation("conv-1"), text: "Less bleak", justPick: false, model: nil)
  let newTurn = TurnRequest(target: .new, text: "Folk horror", justPick: false, model: nil)
  let busy = APIError.server(
    status: 409, code: "conversation_busy", message: "busy", retryAfter: nil)

  /// conv-1 cached with two messages; `/sync` scripted by `syncs`.
  func harness(
    turns: [Result<ConversationResponse, APIError>], syncs: [Result<SyncResponse, APIError>] = []
  ) async throws -> SessionHarness {
    let harness = try SessionHarness(turns: TurnScript(turns), syncs: SyncRecorder(syncs))
    try await harness.session.syncService.ingest(try turnResponse(Fixtures.conversationResponse))
    return harness
  }

  /// A delta in which conv-1 has the cut-off turn and its reply.
  func arrivedDelta() -> SyncResponse {
    makeSync(
      conversations: [makeConversation(updatedAt: "2026-10-04T12:00:30.000Z")],
      messages: syncedTurn(conversationID: "conv-1", firstSeq: 3, text: "Less bleak"))
  }

  @Test func aCutOffTurnMayStillArriveAndSchedulesFollowUps() async throws {
    let harness = try await harness(
      turns: [.failure(.network(.timedOut))],
      syncs: [.success(makeSync()), .success(makeSync()), .success(makeSync())])
    let session = harness.session
    // A sync just succeeded: a throttled sync would now be skipped.
    await session.sync.syncNow()
    #expect(harness.syncs.sinces.count == 1)

    let outcome = await session.send(turn)

    let failure = TurnFailure(
      request: turn, message: "This is taking longer than usual — your reply may still arrive.",
      replyMayArrive: true)
    #expect(outcome == .failed(failure))
    // Retry stays available.
    #expect(session.failures[turn.target] == failure)

    // First follow-up 20 s after the failure…
    await eventually { harness.sleeper.requested == [.seconds(20)] }
    #expect(harness.sleeper.requested == [.seconds(20)])
    #expect(harness.syncs.sinces.count == 1)
    harness.sleeper.resumeNext()
    await eventually { harness.syncs.sinces.count == 2 }
    #expect(harness.syncs.sinces.count == 2)

    // …and, as nothing arrived, a second one 40 s after that (60 s in all).
    await eventually { harness.sleeper.requested.count == 2 }
    #expect(harness.sleeper.requested == [.seconds(20), .seconds(40)])
    harness.sleeper.resumeNext()
    await eventually { harness.syncs.sinces.count == 3 }
    #expect(harness.syncs.sinces.count == 3)

    // Still nothing: the notice stays, with Retry, and no more syncs are scheduled.
    try? await Task.sleep(for: .milliseconds(100))
    #expect(session.failures[turn.target] == failure)
    #expect(session.arrivals.isEmpty)
    #expect(harness.sleeper.requested.count == 2)
  }

  @Test func theReplyArrivingClearsTheNoticeAndTheComposer() async throws {
    let harness = try await harness(
      turns: [.failure(.network(.networkConnectionLost))], syncs: [.success(arrivedDelta())])
    let session = harness.session
    let chat = ChatModel(session: session, conversationID: "conv-1")
    chat.draft = "Less bleak"
    chat.send()
    await chat.sendTask?.value
    #expect(chat.failure?.replyMayArrive == true)
    #expect(chat.draft == "Less bleak")

    await eventually { harness.sleeper.requested.count == 1 }
    harness.sleeper.resumeNext()
    await eventually { session.arrivals[turn.target] != nil }

    #expect(session.failures.isEmpty)
    #expect(
      session.arrivals[turn.target]
        == TurnArrival(request: turn, conversationID: "conv-1", clearsDraft: true))
    #expect(try harness.counts() == [1, 4, 0])
    // No second follow-up once it has arrived.
    #expect(harness.sleeper.requested.count == 1)

    chat.arrivalChanged()
    #expect(chat.draft.isEmpty)
    #expect(chat.failure == nil)
  }

  @Test func editedTextIsNotClearedWhenTheReplyArrives() async throws {
    let harness = try await harness(
      turns: [.failure(.network(.timedOut))], syncs: [.success(arrivedDelta())])
    let chat = ChatModel(session: harness.session, conversationID: "conv-1")
    chat.draft = "Less bleak"
    chat.send()
    await chat.sendTask?.value
    chat.draft = "Less bleak, and shorter"

    await eventually { harness.sleeper.requested.count == 1 }
    harness.sleeper.resumeNext()
    await eventually { chat.arrival != nil }
    chat.arrivalChanged()

    #expect(chat.draft == "Less bleak, and shorter")
  }

  @Test func aNewConversationSwitchesToTheOneThatArrived() async throws {
    let delta = makeSync(
      conversations: [
        makeConversation(id: "conv-8", title: "Something else"),
        makeConversation(id: "conv-9", title: "Folk horror"),
      ],
      messages: syncedTurn(conversationID: "conv-8", firstSeq: 1, text: "Something else")
        + syncedTurn(conversationID: "conv-9", firstSeq: 1, text: "Folk horror"))
    let harness = try await harness(
      turns: [.failure(.network(.timedOut))], syncs: [.success(delta)])
    let session = harness.session
    let chat = ChatModel(session: session, conversationID: nil)
    chat.draft = "Folk horror"
    chat.send()
    await chat.sendTask?.value
    #expect(chat.isNew)
    #expect(chat.draft == "Folk horror")

    await eventually { harness.sleeper.requested.count == 1 }
    harness.sleeper.resumeNext()
    await eventually { session.arrivals[.new] != nil }
    // The conversation that starts with this turn's text, not just any new one.
    #expect(session.arrivals[.new]?.conversationID == "conv-9")
    #expect(session.failures.isEmpty)

    chat.arrivalChanged()
    #expect(chat.conversationID == "conv-9")
    #expect(chat.draft.isEmpty)

    // A new-conversation screen opened later didn't send that turn: it stays new.
    let later = ChatModel(session: session, conversationID: nil)
    later.arrivalChanged()
    #expect(later.isNew)
  }

  @Test func busySchedulesAFollowUpButKeepsTheUnsentText() async throws {
    let harness = try await harness(turns: [.failure(busy)], syncs: [.success(arrivedDelta())])
    let session = harness.session
    let chat = ChatModel(session: session, conversationID: "conv-1")
    chat.draft = "Less bleak"
    chat.send()
    await chat.sendTask?.value

    #expect(chat.failure?.message == "Still working on your last message.")
    #expect(chat.failure?.replyMayArrive == false)
    await eventually { harness.sleeper.requested.count == 1 }
    #expect(harness.sleeper.requested == [.seconds(20)])

    // The earlier turn lands: the busy notice goes, but this message was never sent.
    harness.sleeper.resumeNext()
    await eventually { chat.arrival != nil }
    #expect(chat.failure == nil)
    #expect(chat.arrival?.clearsDraft == false)
    chat.arrivalChanged()
    #expect(chat.draft == "Less bleak")
  }

  @Test func retryingACutOffTurnIntoBusyIsStillThatTurn() async throws {
    let harness = try await harness(
      turns: [.failure(.network(.timedOut)), .failure(busy)], syncs: [.success(arrivedDelta())])
    let session = harness.session
    await session.send(turn)

    let outcome = await session.retry(turn.target)

    // A new request was sent; the server is still running the original.
    #expect(harness.turns.calls.count == 2)
    let failure = TurnFailure(
      request: turn, message: "Still working on your last message.", replyMayArrive: true)
    #expect(outcome == .failed(failure))

    // The first failure's follow-up was cancelled; the retry scheduled its own.
    await eventually { harness.sleeper.requested.count == 2 }
    harness.sleeper.resumeNext()
    harness.sleeper.resumeNext()
    await eventually { session.arrivals[turn.target] != nil }
    #expect(session.arrivals[turn.target]?.clearsDraft == true)
    #expect(harness.syncs.sinces.count == 1)
  }

  @Test func aSuccessfulRetryCancelsTheFollowUps() async throws {
    let harness = try await harness(
      turns: [
        .failure(.network(.timedOut)), .success(try turnResponse(Fixtures.recommendationsResponse)),
      ],
      syncs: [.success(makeSync())])
    let session = harness.session
    await session.send(turn)
    await eventually { harness.sleeper.requested.count == 1 }

    #expect(await session.retry(turn.target) == .sent(conversationID: "conv-1"))
    harness.sleeper.resumeNext()
    try? await Task.sleep(for: .milliseconds(150))

    #expect(harness.syncs.sinces.isEmpty)
    #expect(session.failures.isEmpty)
    #expect(session.arrivals.isEmpty)
  }

  @Test(arguments: [
    APIError.network(.notConnectedToInternet), .network(.cannotConnectToHost), .unauthorized,
    serverError(502), serverError(503), notFound(), .invalidResponse,
  ])
  func otherErrorsScheduleNothing(error: APIError) async throws {
    let harness = try await harness(turns: [.failure(error)])

    await harness.session.send(turn)
    try? await Task.sleep(for: .milliseconds(100))

    #expect(harness.session.failures[turn.target]?.replyMayArrive == false)
    #expect(harness.sleeper.requested.isEmpty)
    #expect(harness.syncs.sinces.isEmpty)
  }
}

// MARK: - Starter suggestions

@MainActor
struct StarterSuggestionTests {
  @Test func theFixedSet() {
    #expect(
      StarterSuggestion.all.map(\.title) == [
        "Something slow and unsettling", "A hidden gem from the 70s or 80s",
        "Under 90 minutes, tonight", "Folk horror", "Surprise me",
      ])
    #expect(StarterSuggestion.all.filter(\.sendsImmediately) == [.surpriseMe])
  }

  @Test func aFillSuggestionFillsTheComposerWithoutSending() throws {
    let harness = try SessionHarness()
    let chat = ChatModel(session: harness.session, conversationID: nil)
    #expect(chat.showsSuggestions)

    chat.choose(StarterSuggestion.all[3])

    #expect(chat.draft == "Folk horror")
    #expect(chat.sendTask == nil)
    #expect(harness.turns.calls.isEmpty)
    // Still editable, and the suggestions stay until something is sent.
    #expect(chat.showsSuggestions)
    #expect(chat.canSend)
  }

  @Test func surpriseMeSendsAJustPickTurnAtOnce() async throws {
    let harness = try SessionHarness(
      turns: TurnScript(
        [.success(try turnResponse(Fixtures.recommendationsResponse))],
        delay: .milliseconds(200)))
    let chat = ChatModel(session: harness.session, conversationID: nil)
    chat.draft = "half-typed"

    chat.choose(.surpriseMe)
    await eventually { chat.pending != nil }
    // Hidden as soon as the first turn is on its way.
    #expect(!chat.showsSuggestions)
    await chat.sendTask?.value

    // The Worker needs text to create a conversation, so the suggestion's title is sent.
    #expect(harness.turns.calls == [.create(model: nil, text: "Surprise me", justPick: true)])
    #expect(chat.conversationID == "conv-1")
    #expect(!chat.showsSuggestions)
    #expect(chat.draft == "half-typed")
  }

  @Test func existingConversationsShowNoSuggestions() throws {
    let harness = try SessionHarness()
    let chat = ChatModel(session: harness.session, conversationID: "conv-1")

    #expect(!chat.showsSuggestions)
    chat.choose(.surpriseMe)
    chat.choose(StarterSuggestion.all[0])
    #expect(chat.draft.isEmpty)
    #expect(chat.sendTask == nil)
  }
}

// MARK: - Background time

@MainActor
struct BackgroundTimeTests {
  let turn = TurnRequest(
    target: .conversation("conv-1"), text: "Less bleak", justPick: false, model: nil)

  @Test func everyLongRequestRunsInsideABackgroundTaskThatIsEnded() async throws {
    let harness = try SessionHarness(
      turns: TurnScript([
        .success(try turnResponse(Fixtures.conversationResponse)),
        .failure(.network(.notConnectedToInternet)),
      ]),
      decisions: DecisionScript([.success(makeDecision(.maybe))]),
      management: ManagementScript(
        renames: [.success(makeConversation(title: "New"))], deletes: [serverError(500)]),
      profiles: ProfileScript(
        drafts: [.failure(.network(.timedOut))], saves: [.success(makeProfile("Saved."))]))
    let session = harness.session

    await session.send(turn)
    await session.send(turn)  // fails
    await session.setDecision(
      .maybe, for: DecisionTarget(tmdbID: 12345, conversationID: "conv-1"), current: nil)
    await session.renameConversation(id: "conv-1", title: "New")
    await session.deleteConversation(id: "conv-1")  // fails
    _ = await session.draftTasteProfile()  // fails
    await session.saveTasteProfile(content: "Saved.")

    #expect(
      harness.background.begun == [
        "Chat turn", "Chat turn", "Save decision", "Rename conversation",
        "Delete conversation", "Draft taste profile", "Save taste profile",
      ])
    // Each one ended, once, in order — the failures too.
    #expect(harness.background.ended == [0, 1, 2, 3, 4, 5, 6])
  }

  @Test func requestsThatMakeNoCallTakeNoBackgroundTime() async throws {
    let harness = try SessionHarness()

    #expect(await harness.session.renameConversation(id: "conv-1", title: " ") == .invalid)
    #expect(await harness.session.saveTasteProfile(content: "") == .invalid)

    #expect(harness.background.begun.isEmpty)
  }

  @Test func anExpiredTaskIsEndedOnceEvenThoughTheWorkFinishesLater() async {
    let recorder = BackgroundRecorder()
    let gate = ManualSleeper()

    let work = Task { await recorder.time.run("Slow") { await gate.sleep(.seconds(1)) } }
    await eventually { gate.requested.count == 1 }
    #expect(recorder.begun == ["Slow"])
    #expect(recorder.ended.isEmpty)

    recorder.expire(0)
    #expect(recorder.ended == [0])

    gate.resumeNext()
    await work.value
    #expect(recorder.ended == [0])
  }

  @Test func expiringBeforeBeginReturnsStillEndsTheTask() async {
    var ended: [Int] = []
    let time = BackgroundTime(
      begin: { _, onExpiration in
        onExpiration()
        return 7
      },
      end: { ended.append($0) })

    let value = await time.run("Instant") { 42 }

    #expect(value == 42)
    #expect(ended == [7])
  }
}

// MARK: - Screens

extension ScreenSmokeTests {
  @Test func emptyListWithASyncNoticeRenders() async throws {
    let harness = try SessionHarness(
      syncs: SyncRecorder([.failure(.network(.notConnectedToInternet))]))
    await harness.session.sync.syncNow()
    #expect(harness.session.sync.lastFailure != nil)
    try await render(
      NavigationStack { ConversationListView() }
        .environment(harness.session)
        .modelContainer(harness.container))
  }

  @Test func newChatRendersItsSuggestions() async throws {
    let harness = try SessionHarness()
    try await render(
      NavigationStack { ChatView(session: harness.session, conversationID: nil) }
        .environment(harness.session)
        .modelContainer(harness.container))
  }

  @Test func detailRendersAtTheLargestTextSize() async throws {
    let harness = try await cachedHarness()
    try await render(
      NavigationStack { PickDetailView(recommendationID: "rec-1") }
        .environment(harness.session)
        .modelContainer(harness.container)
        .dynamicTypeSize(.accessibility5))
  }
}
