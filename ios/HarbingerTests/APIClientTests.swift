import Foundation
import Testing

@testable import Harbinger

/// One app endpoint call, with the request it must produce.
struct EndpointCase: Sendable, CustomTestStringConvertible {
  let name: String
  let method: String
  let path: String
  let timeout: TimeInterval
  /// Expected JSON body (compared as parsed JSON), or `nil` for no body.
  let body: String?
  let response: String
  let call: @Sendable (URLSessionAPIClient) async throws -> Void

  var testDescription: String { name }
}

@Suite(.serialized)
struct APIClientTests {
  static let cases: [EndpointCase] = [
    EndpointCase(
      name: "health", method: "GET", path: "/health", timeout: 15, body: nil,
      response: Fixtures.health, call: { _ = try await $0.health() }),
    EndpointCase(
      name: "models", method: "GET", path: "/models", timeout: 30, body: nil,
      response: Fixtures.models, call: { _ = try await $0.models() }),
    EndpointCase(
      name: "createConversation", method: "POST", path: "/conversations", timeout: 180,
      body: #"{ "model": "claude-sonnet-5", "text": "Something slow", "just_pick": false }"#,
      response: Fixtures.conversationResponse,
      call: {
        _ = try await $0.createConversation(
          model: "claude-sonnet-5", text: "Something slow", justPick: false)
      }),
    EndpointCase(
      name: "createConversation default model", method: "POST", path: "/conversations",
      timeout: 180, body: #"{ "text": "Something slow", "just_pick": true }"#,
      response: Fixtures.conversationResponse,
      call: {
        _ = try await $0.createConversation(model: nil, text: "Something slow", justPick: true)
      }),
    EndpointCase(
      name: "sendMessage", method: "POST", path: "/conversations/conv-1/messages", timeout: 180,
      body: #"{ "text": "Less bleak", "just_pick": false }"#,
      response: Fixtures.conversationResponse,
      call: {
        _ = try await $0.sendMessage(conversationID: "conv-1", text: "Less bleak", justPick: false)
      }),
    EndpointCase(
      name: "sendMessage just pick", method: "POST", path: "/conversations/conv-1/messages",
      timeout: 180, body: #"{ "just_pick": true }"#,
      response: Fixtures.recommendationsResponse,
      call: { _ = try await $0.sendMessage(conversationID: "conv-1", text: nil, justPick: true) }),
    EndpointCase(
      name: "conversation", method: "GET", path: "/conversations/conv-1", timeout: 30, body: nil,
      response: Fixtures.conversationResponse,
      call: { _ = try await $0.conversation(id: "conv-1") }),
    EndpointCase(
      name: "setDecision", method: "PUT", path: "/decisions/12345", timeout: 30,
      body: #"{ "decision": "maybe", "conversation_id": "conv-1" }"#,
      response: Fixtures.decision,
      call: {
        _ = try await $0.setDecision(tmdbID: 12345, decision: .maybe, conversationID: "conv-1")
      }),
    EndpointCase(
      name: "tasteProfile", method: "GET", path: "/taste-profile", timeout: 30, body: nil,
      response: Fixtures.tasteProfile, call: { _ = try await $0.tasteProfile() }),
    EndpointCase(
      name: "saveTasteProfile", method: "PUT", path: "/taste-profile", timeout: 30,
      body: #"{ "content": "Enjoys folk horror" }"#, response: Fixtures.tasteProfile,
      call: { _ = try await $0.saveTasteProfile(content: "Enjoys folk horror") }),
    EndpointCase(
      name: "draftTasteProfile", method: "POST", path: "/taste-profile/draft", timeout: 180,
      body: #"{ "model": "claude-opus-5-5" }"#, response: Fixtures.draft,
      call: { _ = try await $0.draftTasteProfile(model: "claude-opus-5-5") }),
    EndpointCase(
      name: "sync", method: "GET", path: "/sync", timeout: 60, body: nil,
      response: Fixtures.sync, call: { _ = try await $0.sync(since: nil) }),
  ]

  let client = URLSessionAPIClient(
    connection: Connection(baseURL: testBaseURL, apiKey: testAPIKey),
    session: StubURLProtocol.makeSession())

  init() {
    StubURLProtocol.reset()
  }

  func onlyRequest() throws -> URLRequest {
    #expect(StubURLProtocol.requests.count == 1)
    return try #require(StubURLProtocol.requests.first)
  }

  func json(_ data: Data?) throws -> NSDictionary {
    let data = try #require(data)
    return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
  }

  // MARK: - Requests

  @Test(arguments: cases)
  func buildsRequest(_ endpoint: EndpointCase) async throws {
    StubURLProtocol.respond(body: endpoint.response)

    try await endpoint.call(client)

    let request = try onlyRequest()
    #expect(request.httpMethod == endpoint.method)
    #expect(request.url?.host() == testBaseURL.host())
    #expect(request.url?.path() == endpoint.path)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(testAPIKey)")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.timeoutInterval == endpoint.timeout)
    if let body = endpoint.body {
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
      #expect(try json(request.httpBody) == json(Data(body.utf8)))
    } else {
      #expect(request.httpBody == nil)
    }
  }

  @Test func pathSegmentsAreEncoded() async throws {
    StubURLProtocol.respond(body: Fixtures.conversationResponse)

    _ = try await client.conversation(id: "a/b?c")

    let url = try #require(try onlyRequest().url)
    #expect(url.absoluteString == "https://api.example.test/conversations/a%2Fb%3Fc")
  }

  // MARK: - Sync

  @Test func decodesSyncPayload() async throws {
    StubURLProtocol.respond(body: Fixtures.sync)

    let sync = try await client.sync(since: nil)

    #expect(sync.serverTime == "2026-09-29T18:10:00.123Z")
    #expect(sync.conversations.map(\.id) == ["conv-1"])
    #expect(sync.conversations[0].updatedAt == parseTimestamp("2026-09-29T18:01:30.456Z"))
    #expect(sync.messages.map(\.conversationId) == ["conv-1", "conv-1", "conv-1"])
    #expect(sync.messages.map(\.recommendations) == [nil, nil, nil])
    #expect(sync.messages[1].content == .question(text: "How long?", chips: ["Short", "Long"]))

    let recommendation = try #require(sync.recommendations.first)
    #expect(recommendation.conversationId == "conv-1")
    #expect(recommendation.messageId == "msg-4")
    #expect(recommendation.createdAt == parseTimestamp("2026-09-29T18:01:30.456Z"))

    #expect(sync.decisions.first?.decision == .maybe)
    #expect(sync.decisions.first?.tmdbId == 12345)
    #expect(sync.tasteProfile == nil)
    #expect(sync.lastImportAt == parseTimestamp("2026-09-24T21:54:00.000Z"))
  }

  @Test func fractionalSecondsArePreserved() throws {
    let date = try #require(parseTimestamp("2026-09-29T18:00:12.345Z"))
    let whole = try #require(parseTimestamp("2026-09-29T18:00:12Z"))
    #expect(abs(date.timeIntervalSince(whole) - 0.345) < 0.0001)
  }

  @Test(
    "Timestamps re-format to the server string",
    arguments: [
      "2026-09-29T18:01:30.456Z", "2026-09-29T18:00:00.000Z", "2026-09-29T18:00:12.345Z",
      "2026-09-29T23:59:59.999Z",
    ])
  func timestampRoundTrip(_ string: String) throws {
    #expect(formatTimestamp(try #require(parseTimestamp(string))) == string)
  }

  @Test func syncCursorRoundTripsByteForByte() async throws {
    StubURLProtocol.respond(body: Fixtures.sync)

    let first = try await client.sync(since: nil)
    #expect(first.nextSince == Fixtures.nextSince)
    _ = try await client.sync(since: first.nextSince)

    #expect(StubURLProtocol.requests.count == 2)
    let initial = try #require(StubURLProtocol.requests[0].url)
    #expect(URLComponents(url: initial, resolvingAgainstBaseURL: false)?.queryItems == nil)

    let next = try #require(StubURLProtocol.requests[1].url)
    let items = URLComponents(url: next, resolvingAgainstBaseURL: false)?.queryItems
    #expect(items == [URLQueryItem(name: "since", value: Fixtures.nextSince)])
  }

  // MARK: - Messages and recommendations

  @Test func decodesMessageContentByRoleAndKind() async throws {
    StubURLProtocol.respond(body: Fixtures.conversationResponse)
    let response = try await client.conversation(id: "conv-1")

    #expect(response.conversation.questionRounds == 1)
    #expect(response.messages.map(\.role) == [.user, .assistant])
    #expect(
      response.messages[0].content == .user(text: "Something slow and unsettling", justPick: false))
    #expect(
      response.messages[1].content
        == .question(
          text: "How much time do you have?",
          chips: ["Under 90 min", "Around 2 hours", "Doesn't matter"]))

    StubURLProtocol.respond(body: Fixtures.recommendationsResponse)
    let picks = try await client.sendMessage(conversationID: "conv-1", text: nil, justPick: true)

    #expect(picks.messages[0].content == .user(text: nil, justPick: true))
    #expect(picks.messages[1].content == .recommendations(dropped: 1))
    #expect(picks.messages[1].recommendations?.map(\.position) == [1, 2])
  }

  @Test func decodesRecommendationFields() async throws {
    StubURLProtocol.respond(body: Fixtures.recommendationsResponse)
    let response = try await client.conversation(id: "conv-1")
    let recommendations = try #require(response.messages[1].recommendations)

    let full = recommendations[0]
    #expect(full.tmdbId == 12345)
    #expect(full.director == "Robert Eggers")
    #expect(full.providers == [Provider(name: "Shudder", type: "flatrate", logoPath: "/x.jpg")])
    #expect(full.providersLink == "https://www.themoviedb.org/movie/12345/watch?locale=US")
    #expect(full.trailerKey == "abc123")
    #expect(full.whyFull == "A slow, bleak folk horror.")
    #expect(full.conversationId == nil)
    #expect(full.createdAt == nil)

    let bare = recommendations[1]
    #expect(bare.director == nil)
    #expect(bare.providers.isEmpty)
    #expect(bare.trailerKey == nil)
    #expect(bare.year == nil)
    #expect(bare.runtime == nil)
    #expect(bare.posterPath == nil)
  }

  @Test func decodesOtherResponses() async throws {
    StubURLProtocol.respond(body: Fixtures.models)
    let models = try await client.models()
    #expect(models.defaultModel == "claude-sonnet-5")
    #expect(models.allowed.count == 3)

    StubURLProtocol.respond(body: Fixtures.tasteProfile)
    let profile = try await client.tasteProfile()
    #expect(profile?.basedOnImportId == 3)
    #expect(profile?.content == "## Enjoys\n- Folk horror")

    StubURLProtocol.respond(body: Fixtures.draft)
    let draft = try await client.draftTasteProfile(model: nil)
    #expect(draft.changes.count == 1)
  }

  @Test func messageRoundTripsThroughCodable() throws {
    let data = Data(Fixtures.recommendationsMessage.utf8)
    let message = try makeDecoder().decode(Message.self, from: data)
    let again = try makeDecoder().decode(Message.self, from: makeEncoder().encode(message))
    #expect(again == message)
  }

  @Test func unknownAssistantKindIsADecodingError() async throws {
    StubURLProtocol.respond(
      body: """
        { "conversation": \(Fixtures.conversation), "messages": [
          { "id": "m", "seq": 1, "role": "assistant", "kind": "poem", "content": {},
            "created_at": "2026-09-29T18:00:00.000Z" } ] }
        """)

    await #expect {
      try await client.conversation(id: "conv-1")
    } throws: { error in
      if case .decoding = error as? APIError { return true }
      return false
    }
  }

  // MARK: - Errors

  @Test func unauthorized() async {
    StubURLProtocol.respond(status: 401, body: Fixtures.error("unauthorized"))
    await #expect(throws: APIError.unauthorized) { try await client.health() }
  }

  @Test func conversationBusy() async {
    StubURLProtocol.respond(
      status: 409, body: Fixtures.error("conversation_busy", "Another message is being processed"))
    await #expect(
      throws: APIError.server(
        status: 409, code: "conversation_busy", message: "Another message is being processed",
        retryAfter: nil)
    ) {
      try await client.sendMessage(conversationID: "conv-1", text: "hi", justPick: false)
    }
  }

  @Test func retryAfter() async {
    StubURLProtocol.respond(
      status: 503, body: Fixtures.error("claude_unavailable", "Busy"),
      headers: ["Retry-After": "5"])
    await #expect(
      throws: APIError.server(
        status: 503, code: "claude_unavailable", message: "Busy", retryAfter: 5)
    ) {
      try await client.createConversation(model: nil, text: "hi", justPick: false)
    }
  }

  @Test func timeout() async {
    StubURLProtocol.fail(with: .timedOut)
    await #expect(throws: APIError.network(.timedOut)) { try await client.health() }
  }

  @Test func malformedBody() async {
    StubURLProtocol.respond(body: #"{ "conversation": 42 }"#)
    await #expect {
      try await client.conversation(id: "conv-1")
    } throws: { error in
      if case .decoding = error as? APIError { return true }
      return false
    }
  }

  @Test func errorWithoutEnvelope() async {
    StubURLProtocol.respond(status: 502, body: "<html>Bad gateway</html>")
    await #expect(throws: APIError.invalidResponse) { try await client.health() }
  }

  @Test func noTasteProfileIsNil() async throws {
    StubURLProtocol.respond(status: 404, body: Fixtures.error("no_taste_profile"))
    #expect(try await client.tasteProfile() == nil)
  }

  @Test func otherTasteProfile404IsAnError() async {
    StubURLProtocol.respond(status: 404, body: Fixtures.error("not_found"))
    await #expect(
      throws: APIError.server(
        status: 404, code: "not_found", message: "Something went wrong", retryAfter: nil)
    ) {
      try await client.tasteProfile()
    }
  }

  @Test func apiKeyNeverAppearsInErrors() async {
    let failures: [@Sendable () -> Void] = [
      { StubURLProtocol.respond(status: 401, body: Fixtures.error("unauthorized")) },
      { StubURLProtocol.respond(status: 409, body: Fixtures.error("conversation_busy")) },
      { StubURLProtocol.respond(status: 502, body: "not json") },
      { StubURLProtocol.respond(body: #"{ "nope": true }"#) },
      { StubURLProtocol.fail(with: .timedOut) },
      { StubURLProtocol.fail(with: .cannotConnectToHost) },
    ]
    for setUp in failures {
      setUp()
      do {
        _ = try await client.models()
        Issue.record("Expected an error")
      } catch {
        for text in [
          String(describing: error), String(reflecting: error), error.localizedDescription,
        ] {
          #expect(!text.contains(testAPIKey))
        }
      }
    }
  }
}
