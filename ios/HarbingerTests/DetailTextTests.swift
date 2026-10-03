import Foundation
import Testing

@testable import Harbinger

struct DetailTextTests {
  @Test(
    "Runtime",
    arguments: [
      (98, "1h 38m"), (52, "52m"), (60, "1h"), (120, "2h"), (61, "1h 1m"), (1, "1m"),
    ])
  func runtime(minutes: Int, expected: String) {
    #expect(runtimeText(minutes) == expected)
  }

  @Test(arguments: [nil, 0, -5])
  func unknownRuntimeIsHidden(minutes: Int?) {
    #expect(runtimeText(minutes) == nil)
  }

  @Test(
    "Metadata line omits missing parts",
    arguments: [
      (2015, 92, "Robert Eggers", "2015 · 1h 32m · Directed by Robert Eggers"),
      (nil, 92, "Robert Eggers", "1h 32m · Directed by Robert Eggers"),
      (2015, nil, "Robert Eggers", "2015 · Directed by Robert Eggers"),
      (2015, 92, nil, "2015 · 1h 32m"),
      (2015, nil, nil, "2015"),
      (nil, nil, "Robert Eggers", "Directed by Robert Eggers"),
      (nil, nil, "  ", ""),
      (nil, nil, nil, ""),
    ])
  func metadata(year: Int?, runtime: Int?, director: String?, expected: String) {
    #expect(metadataLine(year: year, runtime: runtime, director: director) == expected)
  }

  @Test(
    "Provider type labels",
    arguments: [
      ("flatrate", "Stream"), ("free", "Free"), ("ads", "With ads"), ("rent", "Rent"),
      ("buy", "Buy"),
    ])
  func providerLabel(type: String, expected: String) {
    #expect(providerTypeLabel(type) == expected)
  }

  @Test func unknownProviderTypeHasNoLabel() {
    #expect(providerTypeLabel("cinema") == nil)
    #expect(providerTypeLabel("") == nil)
  }

  @Test func trailerLink() {
    #expect(
      trailerURL(key: "abc123")?.absoluteString == "https://www.youtube.com/watch?v=abc123")
    // Keys are query-encoded, never spliced into the URL.
    #expect(
      trailerURL(key: "a&b=c")?.absoluteString == "https://www.youtube.com/watch?v=a%26b%3Dc")
    #expect(trailerURL(key: nil) == nil)
    #expect(trailerURL(key: "") == nil)
  }

  @Test func letterboxdLink() {
    #expect(
      letterboxdURL(tmdbID: 12345)?.absoluteString == "https://letterboxd.com/tmdb/12345")
  }

  // MARK: - Detail info

  func cachedPick(_ json: String) throws -> CachedRecommendation {
    let dto = try decodeFixture(Recommendation.self, json)
    let pick = CachedRecommendation(id: dto.id)
    pick.apply(dto, conversationID: "conv-1", messageID: "msg-4")
    return pick
  }

  @Test func fullPick() throws {
    let info = PickDetailInfo(try cachedPick(Fixtures.fullRecommendation))

    #expect(info.title == "The Witch")
    #expect(info.metadata == "2015 · 1h 32m · Directed by Robert Eggers")
    #expect(info.overview == "A family in 1630s New England.")
    #expect(
      info.providers
        == [
          PickDetailInfo.ProviderItem(
            name: "Shudder", label: "Stream",
            logoURL: URL(string: "https://image.tmdb.org/t/p/w92/x.jpg"))
        ])
    #expect(
      info.providersURL?.absoluteString
        == "https://www.themoviedb.org/movie/12345/watch?locale=US")
    #expect(info.trailerURL?.absoluteString == "https://www.youtube.com/watch?v=abc123")
    #expect(info.letterboxdURL?.absoluteString == "https://letterboxd.com/tmdb/12345")
  }

  /// A W4a-era row: no director, providers, providers link, trailer, year, runtime, overview.
  @Test func barePick() throws {
    let info = PickDetailInfo(try cachedPick(Fixtures.bareRecommendation))

    #expect(info.metadata.isEmpty)
    #expect(info.overview == nil)
    #expect(info.providers.isEmpty)
    #expect(info.providersURL == nil)
    #expect(info.trailerURL == nil)
    #expect(info.letterboxdURL?.absoluteString == "https://letterboxd.com/tmdb/67890")
  }
}
