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

/// Only `health()` is scripted; everything else fails — the setup flow uses nothing else.
final class FakeAPIClient: APIClient {
  let connection: Connection
  let recorder: HealthRecorder

  init(connection: Connection, recorder: HealthRecorder) {
    self.connection = connection
    self.recorder = recorder
  }

  func health() async throws(APIError) -> HealthResponse {
    try recorder.record(connection).get()
  }
  func models() async throws(APIError) -> ModelsResponse { throw .invalidResponse }
  func createConversation(model: String?, text: String, justPick: Bool) async throws(APIError)
    -> ConversationResponse
  { throw .invalidResponse }
  func sendMessage(conversationID: String, text: String?, justPick: Bool) async throws(APIError)
    -> ConversationResponse
  { throw .invalidResponse }
  func conversation(id: String) async throws(APIError) -> ConversationResponse {
    throw .invalidResponse
  }
  func setDecision(tmdbID: Int, decision: Decision.Choice, conversationID: String)
    async throws(APIError) -> Decision
  { throw .invalidResponse }
  func tasteProfile() async throws(APIError) -> TasteProfile? { throw .invalidResponse }
  func saveTasteProfile(content: String) async throws(APIError) -> TasteProfile {
    throw .invalidResponse
  }
  func draftTasteProfile(model: String?) async throws(APIError) -> TasteProfileDraft {
    throw .invalidResponse
  }
  func sync(since: String?) async throws(APIError) -> SyncResponse { throw .invalidResponse }
}
