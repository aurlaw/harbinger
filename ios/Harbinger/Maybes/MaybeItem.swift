import Foundation

/// A film marked Maybe, with the pick it was marked on. Plain values, no model objects.
nonisolated struct MaybeItem: Equatable, Sendable, Identifiable {
  /// The recommendation that was marked Maybe, for `Route.recommendation`.
  let recommendationID: String
  let tmdbID: Int
  /// The decision's own conversation — the only one the server accepts a new decision in.
  let conversationID: String
  let title: String
  let year: Int?
  let posterPath: String?
  let whyShort: String
  let decidedAt: Date

  /// One decision per film.
  var id: Int { tmdbID }

  var target: DecisionTarget {
    DecisionTarget(tmdbID: tmdbID, conversationID: conversationID)
  }
}

/// The Maybes list: each Maybe decision joined to the pick it was made on — the cached
/// recommendation with the same film **in the decision's own conversation** (the most recent
/// if there are several). A Maybe with no such pick is left out: its conversation was
/// deleted, which removes the picks and leaves the Maybe inert on the server. Newest first.
nonisolated func maybes(
  decisions: [CachedDecision], recommendations: [CachedRecommendation]
) -> [MaybeItem] {
  let items = decisions.compactMap { decision -> MaybeItem? in
    guard decision.choice == .maybe else { return nil }
    let picks = recommendations.filter {
      $0.tmdbID == decision.tmdbID && $0.conversationID == decision.conversationID
    }
    // Most recent first; the id keeps the choice stable when timestamps tie or are missing.
    let pick = picks.max { a, b in
      let (left, right) = (a.createdAt ?? .distantPast, b.createdAt ?? .distantPast)
      return left == right ? a.id < b.id : left < right
    }
    guard let pick else { return nil }
    return MaybeItem(
      recommendationID: pick.id, tmdbID: decision.tmdbID,
      conversationID: decision.conversationID, title: pick.title, year: pick.year,
      posterPath: pick.posterPath, whyShort: pick.whyShort, decidedAt: decision.decidedAt)
  }
  return items.sorted { a, b in
    a.decidedAt == b.decidedAt ? a.tmdbID < b.tmdbID : a.decidedAt > b.decidedAt
  }
}

/// "Saved 3 days ago" — when the film was marked Maybe.
nonisolated func maybeSavedText(decidedAt: Date, now: Date = Date()) -> String {
  // A decision saved moments ago can land a hair after `now`; never say "in 0 seconds".
  guard decidedAt < now else { return "Saved just now" }
  let relative = decidedAt.formatted(
    Date.RelativeFormatStyle(presentation: .named).locale(.current))
  return "Saved \(relative)"
}

/// A Maybes row read as one element: "<Title>, <year>. <whyShort>. Saved 3 days ago".
nonisolated func maybeAccessibilityLabel(_ item: MaybeItem, now: Date = Date()) -> String {
  let name = item.year.map { "\(item.title), \($0)" } ?? item.title
  let parts = [name, item.whyShort, maybeSavedText(decidedAt: item.decidedAt, now: now)]
  return parts.filter { !$0.isEmpty }.joined(separator: ". ")
}
