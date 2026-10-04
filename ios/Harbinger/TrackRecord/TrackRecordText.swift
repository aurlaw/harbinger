import Foundation

// Pure helpers for the track record, kept out of the views so they can be tested.

/// Short names for the models the Worker allows; an unknown id is shown as it is.
nonisolated func modelDisplayName(_ id: String) -> String {
  switch id {
  case "claude-haiku-4-5-20251001": "Haiku 4.5"
  case "claude-sonnet-5": "Sonnet 5"
  case "claude-opus-5-5": "Opus 5.5"
  default: id
  }
}

/// A rating in half-stars as stars: `7` → `★3.5`, `8` → `★4`.
nonisolated func starText(halfStars: Int) -> String {
  halfStars.isMultiple(of: 2) ? "★\(halfStars / 2)" : "★\(halfStars / 2).5"
}

/// A `0...1` rate as a whole percent, rounded half up: `0.778` → `78%`; `nil` → `nil`.
nonisolated func percentText(_ rate: Double?) -> String? {
  guard let rate else { return nil }
  // The server rounds to three decimals; work in whole per-mille so `0.285` is 29%, not 28%.
  let perMille = Int((rate * 1000).rounded())
  return "\((perMille + 5) / 10)%"
}

/// An average in half-stars as stars to one decimal: `7.4` → `★3.7`; `nil` (hidden) → `nil`.
nonisolated func averageText(_ averageHalfStars: Double?) -> String? {
  guard let averageHalfStars else { return nil }
  // The server rounds to one decimal; halve in whole tenths, rounding half up.
  let tenths = (Int((averageHalfStars * 10).rounded()) + 1) / 2
  return "★\(tenths / 10).\(tenths % 10)"
}

/// `★3.5 or higher`, from the server's hit threshold.
nonisolated func thresholdText(halfStars: Int) -> String {
  "\(starText(halfStars: halfStars)) or higher"
}

/// `9 of 12 rated picks scored ★3.5 or higher`.
nonisolated func hitRateCaption(_ stats: OutcomeStats) -> String {
  let picks = stats.rated == 1 ? "rated pick" : "rated picks"
  let threshold = thresholdText(halfStars: stats.hitThresholdHalfStars)
  return "\(stats.hits) of \(stats.rated) \(picks) scored \(threshold)"
}

/// `7 of 9 hits (78%)`, or `Not rated yet` when none of the model's picks are rated.
nonisolated func modelOutcomeText(_ outcome: ModelOutcome) -> String {
  guard outcome.rated > 0 else { return "Not rated yet" }
  let hits = "\(outcome.hits) of \(outcome.rated) hits"
  return percentText(outcome.hitRate).map { "\(hits) (\($0))" } ?? hits
}

/// What follows the (bold) count when picks exist but none are rated.
nonisolated func picksSoFarSuffix(_ recommended: Int) -> String {
  "\(recommended == 1 ? "pick" : "picks") so far — none rated yet."
}

/// `12 picks so far — none rated yet.`
nonisolated func picksSoFarText(_ recommended: Int) -> String {
  "\(recommended) \(picksSoFarSuffix(recommended))"
}

nonisolated let rateToSeeOutcomesText =
  "Rate Harbinger picks on Letterboxd and import to see how they landed."

/// Error text for a failed track-record load.
nonisolated func trackRecordErrorMessage(_ error: APIError) -> String {
  baseErrorMessage(error) ?? "Couldn't load your track record — try again."
}

extension OutcomeStats {
  /// The Recent outcomes link is hidden when there is nothing to list.
  nonisolated var hasRecentOutcomes: Bool { !recent.isEmpty }
}

/// Everything a recent-outcome row shows, derived from the outcome.
nonisolated struct OutcomeRowInfo: Equatable, Sendable {
  /// `Title (2024)`, or the title alone without a year.
  let title: String
  /// `★4.5`
  let rating: String
  let markerSymbol: String
  /// `Hit` / `Miss`
  let markerLabel: String
  /// `Sonnet 5 · Sep 29, 2026`
  let subtitle: String
  let letterboxdURL: URL?

  init(_ outcome: Outcome) {
    title = outcome.year.map { "\(outcome.title) (\($0))" } ?? outcome.title
    rating = starText(halfStars: outcome.halfStars)
    markerSymbol = outcome.hit ? "checkmark.circle.fill" : "xmark.circle"
    markerLabel = outcome.hit ? "Hit" : "Miss"
    let date = outcome.firstRecommendedAt.formatted(date: .abbreviated, time: .omitted)
    subtitle = "\(modelDisplayName(outcome.model)) · \(date)"
    letterboxdURL = Harbinger.letterboxdURL(tmdbID: outcome.tmdbId)
  }
}

/// Opens the film's Letterboxd page through the given opener (the `openURL` action in views).
nonisolated func openLetterboxd(for outcome: Outcome, open: (URL) -> Void) {
  if let url = letterboxdURL(tmdbID: outcome.tmdbId) {
    open(url)
  }
}
