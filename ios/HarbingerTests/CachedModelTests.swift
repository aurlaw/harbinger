import Foundation
import Testing

@testable import Harbinger

struct CachedModelTests {
  @Test(
    "CachedMessage.content round-trips",
    arguments: [
      MessageContent.user(text: "Something slow", justPick: false),
      .user(text: nil, justPick: true),
      .question(text: "How long?", chips: ["Short", "Long"]),
      .question(text: "Anything else?", chips: []),
      .recommendations(dropped: 0),
      .recommendations(dropped: 2),
    ])
  func contentRoundTrips(_ content: MessageContent) {
    let message = CachedMessage(id: "msg-1")
    message.content = content
    #expect(message.content == content)
  }

  @Test func contentIsFlattenedIntoColumns() {
    let message = CachedMessage(id: "msg-1")

    message.content = .question(text: "How long?", chips: ["Short", "Long"])
    #expect(message.role == "assistant")
    #expect(message.messageRole == .assistant)
    #expect(message.kind == "question")
    #expect(message.text == "How long?")
    #expect(message.chips == ["Short", "Long"])

    // Overwriting clears the columns the new case doesn't use.
    message.content = .user(text: nil, justPick: true)
    #expect(message.role == "user")
    #expect(message.kind == "text")
    #expect(message.text == nil)
    #expect(message.justPick)
    #expect(message.chips.isEmpty)

    message.content = .recommendations(dropped: 3)
    #expect(message.kind == "recommendations")
    #expect(message.dropped == 3)
    #expect(!message.justPick)
  }

  @Test func cachedMessageMatchesTheWireRoleAndKind() throws {
    for json in [Fixtures.userMessage, Fixtures.questionMessage, Fixtures.recommendationsMessage] {
      let dto = try decodeFixture(Message.self, json)
      let cached = CachedMessage(id: dto.id)
      cached.apply(dto, conversationID: "conv-1")
      #expect(cached.role == dto.role.rawValue)
      #expect(cached.kind == dto.kind)
      #expect(cached.content == dto.content)
      #expect(cached.seq == dto.seq)
    }
  }

  @Test func decisionChoice() {
    let decision = CachedDecision(tmdbID: 12345)
    #expect(decision.choice == nil)
    decision.apply(makeDecision(.maybe))
    #expect(decision.decision == "maybe")
    #expect(decision.choice == .maybe)
  }
}
