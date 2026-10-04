import Foundation

// Pure helpers for the pick detail screen, kept out of the views so they can be tested.

/// `https://letterboxd.com/tmdb/{id}`: Letterboxd resolves TMDB ids to its film page.
nonisolated func letterboxdURL(tmdbID: Int) -> URL? {
  var components = URLComponents()
  components.scheme = "https"
  components.host = "letterboxd.com"
  components.path = "/tmdb/\(tmdbID)"
  return components.url
}

/// `https://www.youtube.com/watch?v={key}`; `nil` without a key.
nonisolated func trailerURL(key: String?) -> URL? {
  guard let key, !key.isEmpty else { return nil }
  var components = URLComponents()
  components.scheme = "https"
  components.host = "www.youtube.com"
  components.path = "/watch"
  components.queryItems = [URLQueryItem(name: "v", value: key)]
  return components.url
}

/// `98` → `1h 38m`, `52` → `52m`, `60` → `1h`; `nil` (hidden) when unknown.
nonisolated func runtimeText(_ minutes: Int?) -> String? {
  guard let minutes, minutes > 0 else { return nil }
  let hours = minutes / 60
  let rest = minutes % 60
  switch (hours, rest) {
  case (0, _): return "\(rest)m"
  case (_, 0): return "\(hours)h"
  default: return "\(hours)h \(rest)m"
  }
}

/// `year · runtime · Directed by …`, skipping missing parts; empty when all are missing.
nonisolated func metadataLine(year: Int?, runtime: Int?, director: String?) -> String {
  let director = director?.trimmingCharacters(in: .whitespaces)
  let parts = [
    year.map { String($0) },
    runtimeText(runtime),
    director.flatMap { $0.isEmpty ? nil : "Directed by \($0)" },
  ]
  return parts.compactMap { $0 }.joined(separator: " · ")
}

/// Short label for a provider's offer type; `nil` for an unknown type.
nonisolated func providerTypeLabel(_ type: String) -> String? {
  switch type {
  case "flatrate": "Stream"
  case "free": "Free"
  case "ads": "With ads"
  case "rent": "Rent"
  case "buy": "Buy"
  default: nil
  }
}

/// Error text for a failed decision. Basic copy; I6 refines it.
nonisolated func decisionErrorMessage(_ error: APIError) -> String {
  baseErrorMessage(error) ?? "Couldn't save that — try again."
}

/// Everything the detail screen shows, derived from a cached pick.
nonisolated struct PickDetailInfo: Equatable, Sendable {
  nonisolated struct ProviderItem: Equatable, Sendable, Identifiable {
    let name: String
    let label: String?
    let logoURL: URL?

    var id: String { name }
  }

  let title: String
  let metadata: String
  let posterPath: String?
  let whyFull: String
  /// `nil` when TMDB has no overview.
  let overview: String?
  /// In the Worker's order (stream → free → ads → rent → buy).
  let providers: [ProviderItem]
  /// The TMDB watch page (JustWatch-backed); providers open it.
  let providersURL: URL?
  let trailerURL: URL?
  let letterboxdURL: URL?

  init(_ pick: CachedRecommendation) {
    title = pick.title
    metadata = metadataLine(year: pick.year, runtime: pick.runtime, director: pick.director)
    posterPath = pick.posterPath
    whyFull = pick.whyFull
    let overview = pick.overview.trimmingCharacters(in: .whitespacesAndNewlines)
    self.overview = overview.isEmpty ? nil : overview
    providers = pick.providers.map {
      ProviderItem(
        name: $0.name, label: providerTypeLabel($0.type),
        logoURL: tmdbImageURL(path: $0.logoPath, size: .w92))
    }
    providersURL = pick.providersLink.flatMap { URL(string: $0) }
    trailerURL = Harbinger.trailerURL(key: pick.trailerKey)
    letterboxdURL = Harbinger.letterboxdURL(tmdbID: pick.tmdbID)
  }
}
