import Foundation

/// Every failure the API client reports. Never carries the API key.
nonisolated enum APIError: Error, Equatable, Sendable {
  /// 401 — the key was rejected.
  case unauthorized
  /// A non-2xx response with the Worker's `{ error: { code, message } }` envelope.
  case server(status: Int, code: String, message: String, retryAfter: Int?)
  /// Connection failure or timeout.
  case network(URLError.Code)
  /// A 2xx body that didn't match the expected shape.
  case decoding(String)
  /// Not an HTTP response, or an error response without the JSON envelope.
  case invalidResponse
}

/// The Worker's error envelope.
nonisolated struct ErrorEnvelope: Codable, Sendable, Equatable {
  nonisolated struct Detail: Codable, Sendable, Equatable {
    let code: String
    let message: String
  }

  let error: Detail
}
