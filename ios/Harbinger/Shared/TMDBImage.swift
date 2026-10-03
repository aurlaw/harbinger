import Foundation

/// TMDB image widths the app uses: provider logos, pick cards, detail.
nonisolated enum TMDBImageSize: String, Sendable {
  case w92
  case w185
  case w500
}

/// TMDB returns only an image **path** (e.g. `/4zqCKJVHUolGs6C5AZwAZqLWixW.jpg`).
/// Builds `https://image.tmdb.org/t/p/{size}{path}`; `nil` for a missing or empty path.
nonisolated func tmdbImageURL(path: String?, size: TMDBImageSize) -> URL? {
  guard let path = path?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
  let normalized = path.hasPrefix("/") ? path : "/" + path
  return URL(string: "https://image.tmdb.org/t/p/\(size.rawValue)\(normalized)")
}
