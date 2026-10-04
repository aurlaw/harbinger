import Foundation
import Testing

@testable import Harbinger

@MainActor
struct ChatModelTests {
  func existingChat(
    _ results: [Result<ConversationResponse, APIError>] = [], delay: Duration? = nil
  ) throws -> (ChatModel, SessionHarness) {
    let harness = try SessionHarness(turns: TurnScript(results, delay: delay))
    return (ChatModel(session: harness.session, conversationID: "conv-1"), harness)
  }

  // MARK: - Chips

  @Test func tappingAChipSendsItsText() async throws {
    let (chat, harness) = try existingChat([
      .success(try turnResponse(Fixtures.conversationResponse))
    ])

    chat.sendChip("Under 90 min")
    await chat.sendTask?.value

    #expect(
      harness.turns.calls
        == [.send(conversationID: "conv-1", text: "Under 90 min", justPick: false)])
  }

  @Test func chipsAreLiveOnlyOnTheLatestMessageWhileIdle() async throws {
    let (chat, _) = try existingChat(
      [.success(try turnResponse(Fixtures.conversationResponse))], delay: .milliseconds(300))

    #expect(chat.chipsEnabled(messageID: "msg-2", latestMessageID: "msg-2"))
    #expect(!chat.chipsEnabled(messageID: "msg-1", latestMessageID: "msg-2"))

    chat.sendChip("Under 90 min")
    await eventually { chat.isSending }
    #expect(!chat.chipsEnabled(messageID: "msg-2", latestMessageID: "msg-2"))
    await chat.sendTask?.value
  }

  // MARK: - Just pick

  @Test func justPickWithEmptyTextSendsNoText() async throws {
    let (chat, harness) = try existingChat([
      .success(try turnResponse(Fixtures.recommendationsResponse))
    ])
    chat.draft = "   "

    #expect(chat.canJustPick)
    chat.justPick()
    await chat.sendTask?.value

    #expect(harness.turns.calls == [.send(conversationID: "conv-1", text: nil, justPick: true)])
  }

  @Test func justPickIncludesTheDraft() async throws {
    let (chat, harness) = try existingChat([
      .success(try turnResponse(Fixtures.recommendationsResponse))
    ])
    chat.draft = " Folk horror \n"

    chat.justPick()
    await chat.sendTask?.value

    #expect(
      harness.turns.calls
        == [.send(conversationID: "conv-1", text: "Folk horror", justPick: true)])
    #expect(chat.draft.isEmpty)
  }

  /// The Worker requires text to create a conversation, even with `just_pick`.
  @Test func justPickOnANewConversationNeedsText() async throws {
    let harness = try SessionHarness(
      turns: TurnScript([.success(try turnResponse(Fixtures.recommendationsResponse))]))
    let chat = ChatModel(session: harness.session, conversationID: nil)

    #expect(!chat.canJustPick)
    chat.justPick()
    #expect(harness.turns.calls.isEmpty)

    chat.draft = "Something for tonight"
    #expect(chat.canJustPick)
    chat.justPick()
    await chat.sendTask?.value
    #expect(
      harness.turns.calls
        == [.create(model: nil, text: "Something for tonight", justPick: true)])
  }

  // MARK: - Send

  @Test(
    "Send is enabled only for 1–2,000 characters after trimming",
    arguments: [
      ("", false),
      ("   \n\t ", false),
      ("hi", true),
      (String(repeating: "a", count: 2000), true),
      (String(repeating: "a", count: 2001), false),
      ("  " + String(repeating: "a", count: 2000) + "  ", true),
      // Counted as UTF-16, like the Worker: each emoji is 2.
      (String(repeating: "😀", count: 1000), true),
      (String(repeating: "😀", count: 1001), false),
    ])
  func sendEnabled(draft: String, enabled: Bool) throws {
    let (chat, _) = try existingChat()
    chat.draft = draft

    #expect(chat.canSend == enabled)
    #expect(chat.isOverLimit == (chat.draftLength > 2000))
  }

  @Test func overTheLimitAlsoDisablesJustPick() throws {
    let (chat, _) = try existingChat()
    chat.draft = String(repeating: "a", count: 2001)

    #expect(chat.isOverLimit)
    #expect(chat.draftLength == 2001)
    #expect(!chat.canJustPick)
  }

  @Test func newConversationSwitchesToTheReturnedID() async throws {
    let harness = try SessionHarness(
      turns: TurnScript(
        [.success(try turnResponse(Fixtures.conversationResponse))], models: .success(testModels)))
    await harness.session.loadModels()
    let chat = ChatModel(session: harness.session, conversationID: nil)
    #expect(chat.target == .new)
    #expect(chat.model == "claude-sonnet-5")
    chat.selectedModel = "claude-opus-5-5"

    chat.draft = "Something slow"
    chat.send()
    await chat.sendTask?.value

    #expect(chat.conversationID == "conv-1")
    #expect(chat.target == .conversation("conv-1"))
    #expect(!chat.isNew)
    #expect(
      harness.turns.calls.last
        == .create(model: "claude-opus-5-5", text: "Something slow", justPick: false))
  }

  @Test func existingConversationsNeverSendAModel() async throws {
    let (chat, harness) = try existingChat([
      .success(try turnResponse(Fixtures.conversationResponse))
    ])
    chat.selectedModel = "claude-opus-5-5"

    chat.draft = "hi"
    chat.send()
    await chat.sendTask?.value

    #expect(harness.turns.calls == [.send(conversationID: "conv-1", text: "hi", justPick: false)])
  }

  // MARK: - Pending bubble

  @Test func pendingBubbleWhileSendingThenGoneAfterSuccess() async throws {
    let (chat, _) = try existingChat(
      [.success(try turnResponse(Fixtures.conversationResponse))], delay: .milliseconds(300))
    chat.draft = "Less bleak"

    chat.send()
    await eventually { chat.pending != nil }

    #expect(chat.pending?.request.text == "Less bleak")
    #expect(chat.draft.isEmpty)
    #expect(!chat.canSend)

    await chat.sendTask?.value
    #expect(chat.pending == nil)
    #expect(chat.failure == nil)
    #expect(chat.draft.isEmpty)
  }

  @Test func failureRemovesThePendingBubbleAndRestoresTheText() async throws {
    let (chat, _) = try existingChat(
      [.failure(.network(.notConnectedToInternet))], delay: .milliseconds(200))
    chat.draft = "Less bleak"

    chat.send()
    await eventually { chat.pending != nil }
    #expect(chat.draft.isEmpty)
    await chat.sendTask?.value

    #expect(chat.pending == nil)
    #expect(chat.draft == "Less bleak")
    #expect(chat.failure?.message == "You're offline.")
  }

  @Test func retryFromTheChatResendsTheFailedTurn() async throws {
    let (chat, harness) = try existingChat([
      .failure(.network(.timedOut)),
      .success(try turnResponse(Fixtures.conversationResponse)),
    ])
    chat.draft = "Less bleak"
    chat.send()
    await chat.sendTask?.value
    // The restored text stays in the composer; Retry doesn't touch it.
    #expect(chat.draft == "Less bleak")

    chat.retry()
    await chat.sendTask?.value

    let call = TurnScript.Call.send(conversationID: "conv-1", text: "Less bleak", justPick: false)
    #expect(harness.turns.calls == [call, call])
    #expect(chat.failure == nil)
  }
}
