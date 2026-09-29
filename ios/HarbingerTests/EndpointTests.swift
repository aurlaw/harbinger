import Foundation
import Testing

@testable import Harbinger

struct EndpointTests {
  @Test(
    "Accepted endpoints normalize",
    arguments: [
      ("https://harbinger-api.aurlaw.dev/", "https://harbinger-api.aurlaw.dev"),
      ("https://harbinger-api.aurlaw.dev///", "https://harbinger-api.aurlaw.dev"),
      ("  https://harbinger-api.aurlaw.dev  ", "https://harbinger-api.aurlaw.dev"),
      ("https://harbinger-api.aurlaw.dev\n", "https://harbinger-api.aurlaw.dev"),
      ("http://localhost:8787/", "http://localhost:8787"),
      ("http://127.0.0.1:8787", "http://127.0.0.1:8787"),
      ("https://example.dev:8443", "https://example.dev:8443"),
    ])
  func accepts(input: String, expected: String) throws {
    let url = try normalizeEndpoint(input).get()
    #expect(url.absoluteString == expected)
  }

  @Test(
    "Rejected endpoints",
    arguments: [
      ("http://harbinger-api.aurlaw.dev", EndpointError.insecureScheme),
      ("ftp://harbinger-api.aurlaw.dev", .insecureScheme),
      ("harbinger-api.aurlaw.dev", .malformed),
      ("https://x.dev/api", .hasPath),
      ("https://x.dev/api/", .hasPath),
      ("https://x.dev?q=1", .hasQuery),
      ("https://x.dev#frag", .hasFragment),
      ("", .empty),
      ("   ", .empty),
      ("https://", .missingHost),
    ])
  func rejects(input: String, expected: EndpointError) {
    #expect(throws: expected) { try normalizeEndpoint(input).get() }
  }

  @Test func endpointStoreRoundTrip() throws {
    let suite = "EndpointTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = EndpointStore(defaults: defaults)

    #expect(store.url() == nil)
    store.save(URL(string: "http://localhost:8787")!)
    #expect(defaults.string(forKey: "endpointURL") == "http://localhost:8787")
    #expect(store.url()?.absoluteString == "http://localhost:8787")
  }
}
