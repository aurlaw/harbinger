import Foundation

/// One method per app endpoint. Every failure is an `APIError`. No retries.
nonisolated protocol APIClient: Sendable {
  func health() async throws(APIError) -> HealthResponse
  func models() async throws(APIError) -> ModelsResponse
  func createConversation(model: String?, text: String, justPick: Bool) async throws(APIError)
    -> ConversationResponse
  func sendMessage(conversationID: String, text: String?, justPick: Bool) async throws(APIError)
    -> ConversationResponse
  func conversation(id: String) async throws(APIError) -> ConversationResponse
  /// Returns the bare conversation object, not a `ConversationResponse`.
  func renameConversation(id: String, title: String) async throws(APIError) -> Conversation
  /// Soft delete on the server; an already-deleted conversation also succeeds.
  func deleteConversation(id: String) async throws(APIError)
  func setDecision(tmdbID: Int, decision: Decision.Choice, conversationID: String)
    async throws(APIError) -> Decision
  /// `nil` when no profile has been saved (`404 no_taste_profile`).
  func tasteProfile() async throws(APIError) -> TasteProfile?
  func saveTasteProfile(content: String) async throws(APIError) -> TasteProfile
  func draftTasteProfile(model: String?) async throws(APIError) -> TasteProfileDraft
  /// `since` is a previous response's `nextSince`, passed back unchanged; `nil` for a full pull.
  func sync(since: String?) async throws(APIError) -> SyncResponse
  /// The track record: how past picks that have since been rated landed.
  func outcomeStats() async throws(APIError) -> OutcomeStats
  /// Every watched film, for the Watched tab's cache.
  func watched() async throws(APIError) -> WatchedResponse
}

/// Per-request timeouts. A chat turn or draft can take a minute+ (Claude + TMDB + replacements).
nonisolated enum RequestTimeout {
  static let health: TimeInterval = 15
  static let standard: TimeInterval = 30
  static let sync: TimeInterval = 60
  static let claude: TimeInterval = 180
}

nonisolated final class URLSessionAPIClient: APIClient {
  private let session: URLSession
  private let baseURL: URL
  private let apiKey: String

  init(connection: Connection, session: URLSession = .shared) {
    self.baseURL = connection.baseURL
    self.apiKey = connection.apiKey
    self.session = session
  }

  func health() async throws(APIError) -> HealthResponse {
    try await send(request("GET", ["health"], timeout: RequestTimeout.health))
  }

  func models() async throws(APIError) -> ModelsResponse {
    try await send(request("GET", ["models"], timeout: RequestTimeout.standard))
  }

  func createConversation(model: String?, text: String, justPick: Bool) async throws(APIError)
    -> ConversationResponse
  {
    let body = CreateConversationBody(model: model, text: text, justPick: justPick)
    return try await send(
      request("POST", ["conversations"], body: body, timeout: RequestTimeout.claude))
  }

  func sendMessage(conversationID: String, text: String?, justPick: Bool) async throws(APIError)
    -> ConversationResponse
  {
    let body = SendMessageBody(text: text, justPick: justPick)
    return try await send(
      request(
        "POST", ["conversations", conversationID, "messages"], body: body,
        timeout: RequestTimeout.claude))
  }

  func conversation(id: String) async throws(APIError) -> ConversationResponse {
    try await send(request("GET", ["conversations", id], timeout: RequestTimeout.standard))
  }

  func renameConversation(id: String, title: String) async throws(APIError) -> Conversation {
    try await send(
      request(
        "PATCH", ["conversations", id], body: RenameConversationBody(title: title),
        timeout: RequestTimeout.standard))
  }

  func deleteConversation(id: String) async throws(APIError) {
    try await sendNoContent(
      request("DELETE", ["conversations", id], timeout: RequestTimeout.standard))
  }

  func setDecision(tmdbID: Int, decision: Decision.Choice, conversationID: String)
    async throws(APIError) -> Decision
  {
    let body = DecisionBody(decision: decision, conversationId: conversationID)
    return try await send(
      request(
        "PUT", ["decisions", String(tmdbID)], body: body, timeout: RequestTimeout.standard))
  }

  func tasteProfile() async throws(APIError) -> TasteProfile? {
    do {
      return try await send(
        request("GET", ["taste-profile"], timeout: RequestTimeout.standard)) as TasteProfile
    } catch .server(404, "no_taste_profile", _, _) {
      return nil
    }
  }

  func saveTasteProfile(content: String) async throws(APIError) -> TasteProfile {
    try await send(
      request(
        "PUT", ["taste-profile"], body: TasteProfileBody(content: content),
        timeout: RequestTimeout.standard))
  }

  func draftTasteProfile(model: String?) async throws(APIError) -> TasteProfileDraft {
    try await send(
      request(
        "POST", ["taste-profile", "draft"], body: DraftTasteProfileBody(model: model),
        timeout: RequestTimeout.claude))
  }

  func sync(since: String?) async throws(APIError) -> SyncResponse {
    let query = since.map { [URLQueryItem(name: "since", value: $0)] } ?? []
    return try await send(request("GET", ["sync"], query: query, timeout: RequestTimeout.sync))
  }

  func outcomeStats() async throws(APIError) -> OutcomeStats {
    try await send(request("GET", ["stats", "outcomes"], timeout: RequestTimeout.standard))
  }

  func watched() async throws(APIError) -> WatchedResponse {
    try await send(request("GET", ["library", "watched"], timeout: RequestTimeout.standard))
  }

  // MARK: - Plumbing

  /// Builds a request. Each path segment is appended as one encoded component.
  private func request(
    _ method: String, _ segments: [String], query: [URLQueryItem] = [],
    body: (some Encodable)? = String?.none, timeout: TimeInterval
  ) throws(APIError) -> URLRequest {
    var url = baseURL
    for segment in segments {
      url.append(component: segment)
    }
    if !query.isEmpty {
      url.append(queryItems: query)
    }

    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = method
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      do {
        request.httpBody = try makeEncoder().encode(body)
      } catch {
        throw .decoding("Couldn't encode request body: \(error)")
      }
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return request
  }

  private func send<T: Decodable>(_ request: URLRequest) async throws(APIError) -> T {
    let data = try await perform(request)
    do {
      return try makeDecoder().decode(T.self, from: data)
    } catch {
      throw .decoding(String(describing: error))
    }
  }

  /// For endpoints that answer `204`: statuses and errors map as in `send`, but a `2xx`
  /// body is not decoded.
  private func sendNoContent(_ request: URLRequest) async throws(APIError) {
    _ = try await perform(request)
  }

  /// Runs the request and returns a `2xx` body; everything else is thrown as an `APIError`.
  private func perform(_ request: URLRequest) async throws(APIError) -> Data {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError {
      throw .network(error.code)
    } catch {
      throw .network(.unknown)
    }

    guard let http = response as? HTTPURLResponse else { throw .invalidResponse }
    switch http.statusCode {
    case 200..<300:
      return data
    case 401:
      throw .unauthorized
    default:
      guard let envelope = try? makeDecoder().decode(ErrorEnvelope.self, from: data) else {
        throw .invalidResponse
      }
      let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap {
        Int($0.trimmingCharacters(in: .whitespaces))
      }
      throw .server(
        status: http.statusCode, code: envelope.error.code, message: envelope.error.message,
        retryAfter: retryAfter)
    }
  }
}
