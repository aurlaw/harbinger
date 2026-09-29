import Foundation

nonisolated let defaultEndpoint = "https://harbinger-api.aurlaw.dev"

nonisolated enum EndpointError: Error, Equatable, Sendable {
  case empty
  case malformed
  case missingHost
  case hasPath
  case hasQuery
  case hasFragment
  case insecureScheme
}

/// Normalizes a user-entered Worker endpoint to `scheme://host[:port]`.
///
/// Trailing slashes are dropped; any other path, a query, or a fragment is rejected.
/// Only `https` is allowed, except `http` for `localhost` / `127.0.0.1`.
nonisolated func normalizeEndpoint(_ input: String) -> Result<URL, EndpointError> {
  var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
  while text.hasSuffix("/") {
    text.removeLast()
  }
  guard !text.isEmpty else { return .failure(.empty) }
  guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased()
  else { return .failure(.malformed) }
  guard let host = components.host?.lowercased(), !host.isEmpty else {
    return .failure(.missingHost)
  }
  guard components.path.isEmpty else { return .failure(.hasPath) }
  guard components.query == nil else { return .failure(.hasQuery) }
  guard components.fragment == nil else { return .failure(.hasFragment) }

  let isLocal = host == "localhost" || host == "127.0.0.1"
  guard scheme == "https" || (scheme == "http" && isLocal) else {
    return .failure(.insecureScheme)
  }

  var normalized = URLComponents()
  normalized.scheme = scheme
  normalized.host = host
  normalized.port = components.port
  guard let url = normalized.url else { return .failure(.malformed) }
  return .success(url)
}
