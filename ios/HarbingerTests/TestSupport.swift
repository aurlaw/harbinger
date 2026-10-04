import Foundation
import Synchronization

@testable import Harbinger

/// Built at runtime — never a key-shaped literal in the repo.
let testAPIKey = String(repeating: "k", count: 32)
let testBaseURL = URL(string: "https://api.example.test")!

// MARK: - Credential store fake

final class InMemoryCredentialStore: CredentialStore {
  private let key = Mutex<String?>(nil)
  private let saveError: KeychainError?

  init(key: String? = nil, saveError: KeychainError? = nil) {
    self.key.withLock { $0 = key }
    self.saveError = saveError
  }

  func apiKey() throws -> String? { key.withLock { $0 } }

  func saveAPIKey(_ newKey: String) throws {
    if let saveError { throw saveError }
    key.withLock { $0 = newKey }
  }

  func deleteAPIKey() throws { key.withLock { $0 = nil } }
}

// MARK: - URLProtocol stub

/// Serves canned responses. The handler and recorded requests are shared static state,
/// so suites using it must be `.serialized`.
final class StubURLProtocol: URLProtocol {
  nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
  nonisolated(unsafe) static var requests: [URLRequest] = []

  static func reset() {
    handler = nil
    requests = []
  }

  /// Responds to every request with `status`, `body`, and optional extra headers.
  static func respond(status: Int = 200, body: String, headers: [String: String] = [:]) {
    handler = { request in
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"].merging(headers) { _, new in new })!
      return (response, Data(body.utf8))
    }
  }

  static func fail(with code: URLError.Code) {
    handler = { _ in throw URLError(code) }
  }

  static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    // URLSession moves the body into a stream; restore it for assertions.
    var recorded = request
    if recorded.httpBody == nil, let stream = request.httpBodyStream {
      recorded.httpBody = Data(reading: stream)
    }
    Self.requests.append(recorded)

    do {
      guard let handler = Self.handler else { throw URLError(.resourceUnavailable) }
      let (response, data) = try handler(recorded)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

extension Data {
  fileprivate init(reading stream: InputStream) {
    self.init()
    stream.open()
    defer { stream.close() }
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      append(buffer, count: count)
    }
  }
}

// MARK: - API client fake

/// Records every `/health` check the setup flow makes, and answers it with `result`.
final class HealthRecorder: Sendable {
  private let checked = Mutex<[Connection]>([])
  let result: Result<HealthResponse, APIError>

  init(result: Result<HealthResponse, APIError>) {
    self.result = result
  }

  var connections: [Connection] { checked.withLock { $0 } }

  func makeClient(_ connection: Connection) -> any APIClient {
    FakeAPIClient(connection: connection, recorder: self)
  }

  fileprivate func record(_ connection: Connection) -> Result<HealthResponse, APIError> {
    checked.withLock { $0.append(connection) }
    return result
  }
}

/// Scripts `/sync`: answers each request with the next queued result and records its `since`.
final class SyncRecorder: Sendable {
  private struct State {
    var results: [Result<SyncResponse, APIError>]
    var sinces: [String?] = []
  }

  private let state: Mutex<State>
  /// Holds each request open, so concurrent callers overlap.
  private let delay: Duration?

  init(_ results: [Result<SyncResponse, APIError>] = [], delay: Duration? = nil) {
    self.state = Mutex(State(results: results))
    self.delay = delay
  }

  /// One entry per request; `nil` is a full pull.
  var sinces: [String?] { state.withLock { $0.sinces } }

  func enqueue(_ result: Result<SyncResponse, APIError>) {
    state.withLock { $0.results.append(result) }
  }

  fileprivate func next(since: String?) async -> Result<SyncResponse, APIError> {
    let result = state.withLock { state -> Result<SyncResponse, APIError> in
      state.sinces.append(since)
      return state.results.isEmpty ? .failure(.invalidResponse) : state.results.removeFirst()
    }
    if let delay {
      try? await Task.sleep(for: delay)
    }
    return result
  }
}

/// Scripts `/models` and chat turns (`createConversation` / `sendMessage`): records each call
/// and answers turns with the next queued result.
final class TurnScript: Sendable {
  enum Call: Equatable, Sendable {
    case models
    case create(model: String?, text: String, justPick: Bool)
    case send(conversationID: String, text: String?, justPick: Bool)
  }

  private struct State {
    var calls: [Call] = []
    var turns: [Result<ConversationResponse, APIError>]
    var models: Result<ModelsResponse, APIError>
  }

  private let state: Mutex<State>
  /// Holds each turn open, so tests can act while it is in flight.
  private let delay: Duration?

  init(
    _ turns: [Result<ConversationResponse, APIError>] = [],
    models: Result<ModelsResponse, APIError> = .failure(.invalidResponse),
    delay: Duration? = nil
  ) {
    self.state = Mutex(State(turns: turns, models: models))
    self.delay = delay
  }

  var calls: [Call] { state.withLock { $0.calls } }

  func enqueue(_ result: Result<ConversationResponse, APIError>) {
    state.withLock { $0.turns.append(result) }
  }

  fileprivate func models() -> Result<ModelsResponse, APIError> {
    state.withLock { state in
      state.calls.append(.models)
      return state.models
    }
  }

  fileprivate func turn(_ call: Call) async -> Result<ConversationResponse, APIError> {
    let result = state.withLock { state -> Result<ConversationResponse, APIError> in
      state.calls.append(call)
      return state.turns.isEmpty ? .failure(.invalidResponse) : state.turns.removeFirst()
    }
    if let delay {
      try? await Task.sleep(for: delay)
    }
    return result
  }
}

/// Scripts `setDecision`: records each call and answers with the next queued result.
final class DecisionScript: Sendable {
  struct Call: Equatable, Sendable {
    let tmdbID: Int
    let decision: Decision.Choice
    let conversationID: String
  }

  private struct State {
    var calls: [Call] = []
    var results: [Result<Decision, APIError>]
  }

  private let state: Mutex<State>
  /// Holds each request open, so tests can act while it is in flight.
  private let delay: Duration?

  init(_ results: [Result<Decision, APIError>] = [], delay: Duration? = nil) {
    self.state = Mutex(State(results: results))
    self.delay = delay
  }

  var calls: [Call] { state.withLock { $0.calls } }

  fileprivate func next(_ call: Call) async -> Result<Decision, APIError> {
    let result = state.withLock { state -> Result<Decision, APIError> in
      state.calls.append(call)
      return state.results.isEmpty ? .failure(.invalidResponse) : state.results.removeFirst()
    }
    if let delay {
      try? await Task.sleep(for: delay)
    }
    return result
  }
}

/// Scripts `renameConversation` / `deleteConversation`: records each call and answers with
/// the next queued result of its kind.
final class ManagementScript: Sendable {
  enum Call: Equatable, Sendable {
    case rename(id: String, title: String)
    case delete(id: String)
  }

  private struct State {
    var calls: [Call] = []
    var renames: [Result<Conversation, APIError>]
    var deletes: [APIError?]
  }

  private let state: Mutex<State>
  /// Holds each request open, so tests can act while it is in flight.
  private let delay: Duration?

  /// - Parameter deletes: one entry per expected delete; `nil` is a success.
  init(
    renames: [Result<Conversation, APIError>] = [], deletes: [APIError?] = [],
    delay: Duration? = nil
  ) {
    self.state = Mutex(State(renames: renames, deletes: deletes))
    self.delay = delay
  }

  var calls: [Call] { state.withLock { $0.calls } }

  fileprivate func rename(id: String, title: String) async -> Result<Conversation, APIError> {
    let result = state.withLock { state -> Result<Conversation, APIError> in
      state.calls.append(.rename(id: id, title: title))
      return state.renames.isEmpty ? .failure(.invalidResponse) : state.renames.removeFirst()
    }
    if let delay {
      try? await Task.sleep(for: delay)
    }
    return result
  }

  fileprivate func delete(id: String) async -> APIError? {
    let error = state.withLock { state -> APIError? in
      state.calls.append(.delete(id: id))
      return state.deletes.isEmpty ? .invalidResponse : state.deletes.removeFirst()
    }
    if let delay {
      try? await Task.sleep(for: delay)
    }
    return error
  }
}

/// `health()`, `sync(since:)`, `models()`, chat turns, decisions, and conversation rename /
/// delete are scripted; everything else fails.
final class FakeAPIClient: APIClient {
  let connection: Connection
  let recorder: HealthRecorder
  let syncs: SyncRecorder?
  let turns: TurnScript?
  let decisions: DecisionScript?
  let management: ManagementScript?

  init(
    connection: Connection, recorder: HealthRecorder, syncs: SyncRecorder? = nil,
    turns: TurnScript? = nil, decisions: DecisionScript? = nil,
    management: ManagementScript? = nil
  ) {
    self.connection = connection
    self.recorder = recorder
    self.syncs = syncs
    self.turns = turns
    self.decisions = decisions
    self.management = management
  }

  convenience init(
    syncs: SyncRecorder = SyncRecorder(), turns: TurnScript? = nil,
    decisions: DecisionScript? = nil, management: ManagementScript? = nil
  ) {
    self.init(
      connection: Connection(baseURL: testBaseURL, apiKey: testAPIKey),
      recorder: HealthRecorder(result: .success(HealthResponse(status: "ok"))), syncs: syncs,
      turns: turns, decisions: decisions, management: management)
  }

  func health() async throws(APIError) -> HealthResponse {
    try recorder.record(connection).get()
  }
  func models() async throws(APIError) -> ModelsResponse {
    guard let turns else { throw .invalidResponse }
    return try turns.models().get()
  }
  func createConversation(model: String?, text: String, justPick: Bool) async throws(APIError)
    -> ConversationResponse
  {
    guard let turns else { throw .invalidResponse }
    return try await turns.turn(.create(model: model, text: text, justPick: justPick)).get()
  }
  func sendMessage(conversationID: String, text: String?, justPick: Bool) async throws(APIError)
    -> ConversationResponse
  {
    guard let turns else { throw .invalidResponse }
    return try await turns.turn(
      .send(conversationID: conversationID, text: text, justPick: justPick)
    ).get()
  }
  func conversation(id: String) async throws(APIError) -> ConversationResponse {
    throw .invalidResponse
  }
  func renameConversation(id: String, title: String) async throws(APIError) -> Conversation {
    guard let management else { throw .invalidResponse }
    return try await management.rename(id: id, title: title).get()
  }
  func deleteConversation(id: String) async throws(APIError) {
    guard let management else { throw .invalidResponse }
    if let error = await management.delete(id: id) { throw error }
  }
  func setDecision(tmdbID: Int, decision: Decision.Choice, conversationID: String)
    async throws(APIError) -> Decision
  {
    guard let decisions else { throw .invalidResponse }
    let call = DecisionScript.Call(
      tmdbID: tmdbID, decision: decision, conversationID: conversationID)
    return try await decisions.next(call).get()
  }
  func tasteProfile() async throws(APIError) -> TasteProfile? { throw .invalidResponse }
  func saveTasteProfile(content: String) async throws(APIError) -> TasteProfile {
    throw .invalidResponse
  }
  func draftTasteProfile(model: String?) async throws(APIError) -> TasteProfileDraft {
    throw .invalidResponse
  }
  func sync(since: String?) async throws(APIError) -> SyncResponse {
    guard let syncs else { throw .invalidResponse }
    return try await syncs.next(since: since).get()
  }
}

/// Records URLs the app asked to open (instead of opening them).
final class OpenRecorder: Sendable {
  private let urls = Mutex<[URL]>([])

  var opened: [URL] { urls.withLock { $0 } }

  func open(_ url: URL) {
    urls.withLock { $0.append(url) }
  }
}
