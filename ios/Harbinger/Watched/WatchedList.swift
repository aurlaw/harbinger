import Foundation

// Pure list logic and text for the Watched tab, kept out of the views so it can be tested.

/// A watched film as plain values (no model object).
nonisolated struct WatchedRowInput: Equatable, Sendable, Identifiable {
  let letterboxdURI: String
  var tmdbID: Int?
  let title: String
  var year: Int?
  var halfStars: Int?
  /// `YYYY-MM-DD` (a calendar date), or empty when Letterboxd exported none.
  var loggedOn = ""
  var posterPath: String?
  var isHorror = false
  var harbingerPick = false

  var id: String { letterboxdURI }
}

extension WatchedRowInput {
  nonisolated init(_ film: CachedWatchedFilm) {
    self.init(
      letterboxdURI: film.letterboxdURI, tmdbID: film.tmdbID, title: film.title,
      year: film.year, halfStars: film.halfStars, loggedOn: film.loggedOn,
      posterPath: film.posterPath, isHorror: film.isHorror, harbingerPick: film.harbingerPick)
  }
}

/// Raw values are what `@AppStorage` keeps.
nonisolated enum WatchedGenre: String, Sendable, CaseIterable {
  case all
  case horror

  var title: String {
    switch self {
    case .all: "All"
    case .horror: "Horror"
    }
  }
}

nonisolated enum WatchedSort: String, Sendable, CaseIterable {
  /// Newest logged first.
  case logged
  /// Highest rated first, unrated last.
  case rating

  var title: String {
    switch self {
    case .logged: "Logged"
    case .rating: "Rating"
    }
  }
}

nonisolated struct WatchedOptions: Equatable, Sendable {
  var genre = WatchedGenre.all
  var picksOnly = false
  var sort = WatchedSort.logged
  var search = ""

  /// Something other than the defaults is narrowing the list.
  var isFiltering: Bool {
    genre != .all || picksOnly || !trimmedSearch.isEmpty
  }

  var trimmedSearch: String {
    search.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// The Watched list: filters combine (AND), then one total order.
nonisolated func watchedRows(_ films: [WatchedRowInput], options: WatchedOptions)
  -> [WatchedRowInput]
{
  let search = options.trimmedSearch
  let filtered = films.filter { film in
    if options.genre == .horror, !film.isHorror { return false }
    if options.picksOnly, !film.harbingerPick { return false }
    // Case- and diacritic-insensitive: "Amelie" finds "Amélie".
    return search.isEmpty || film.title.localizedStandardContains(search)
  }
  return filtered.sorted { a, b in
    if options.sort == .rating, a.halfStars != b.halfStars {
      // Highest first; unrated last.
      return (a.halfStars ?? Int.min) > (b.halfStars ?? Int.min)
    }
    // `YYYY-MM-DD` sorts as a string; a missing date (empty) sorts last.
    if a.loggedOn != b.loggedOn { return a.loggedOn > b.loggedOn }
    let titles = a.title.localizedStandardCompare(b.title)
    if titles != .orderedSame { return titles == .orderedAscending }
    return a.letterboxdURI < b.letterboxdURI
  }
}

// MARK: - Text

/// `2021-03-11` as that calendar day in `calendar` (noon, so no time zone can shift it);
/// `nil` when it isn't a date.
nonisolated func loggedDate(_ loggedOn: String, calendar: Calendar = .current) -> Date? {
  let parts = loggedOn.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
  guard parts.count == 3, let year = parts[0], let month = parts[1], let day = parts[2] else {
    return nil
  }
  let components = DateComponents(year: year, month: month, day: day, hour: 12)
  guard components.isValidDate(in: calendar) else { return nil }
  return calendar.date(from: components)
}

/// `Logged Mar 11, 2021` — the day the film was marked watched on Letterboxd, which is not a
/// viewing date. `nil` when there is no date.
nonisolated func loggedText(
  _ loggedOn: String, calendar: Calendar = .current, locale: Locale = .current
) -> String? {
  guard let date = loggedDate(loggedOn, calendar: calendar) else { return nil }
  let style = Date.FormatStyle(
    date: .abbreviated, time: .omitted, locale: locale, calendar: calendar,
    timeZone: calendar.timeZone)
  return "Logged \(date.formatted(style))"
}

/// `★4.5`, or `Not rated`.
nonisolated func watchedRatingText(halfStars: Int?) -> String {
  halfStars.map { starText(halfStars: $0) } ?? "Not rated"
}

nonisolated let harbingerPickLabel = "Recommended by Harbinger"

/// A row read as one element: "<Title>, <year>. <stars or Not rated>. Logged <date>.
/// Recommended by Harbinger." — missing parts omitted.
nonisolated func watchedAccessibilityLabel(
  _ film: WatchedRowInput, calendar: Calendar = .current, locale: Locale = .current
) -> String {
  let parts = [
    film.year.map { "\(film.title), \($0)" } ?? film.title,
    watchedRatingText(halfStars: film.halfStars),
    loggedText(film.loggedOn, calendar: calendar, locale: locale),
    film.harbingerPick ? harbingerPickLabel : nil,
  ]
  return parts.compactMap { $0 }.joined(separator: ". ") + "."
}

/// `124 films` / `1 film`.
nonisolated func watchedCountText(_ count: Int) -> String {
  count == 1 ? "1 film" : "\(count) films"
}

/// The film's Letterboxd page (works for films that never matched on TMDB); `nil` unless it
/// is an `https` URL.
nonisolated func watchedURL(_ letterboxdURI: String) -> URL? {
  guard let url = URL(string: letterboxdURI), url.scheme == "https", url.host() != nil else {
    return nil
  }
  return url
}

/// The Watched tab's track-record row as plain text: "Hit rate 75% · 9 of 12 rated picks",
/// the no-picks / none-rated text, or the error. `nil` while the first load is in flight.
nonisolated func trackRecordSummaryText(_ content: TrackRecordContent) -> String? {
  switch content {
  case .loading: nil
  case .failed(let message): message
  case .noPicks: "No picks yet."
  case .noneRated(let recommended): picksSoFarText(recommended)
  case .stats(let stats):
    [percentText(stats.hitRate).map { "Hit rate \($0)" }, ratedPicksText(stats)]
      .compactMap { $0 }.joined(separator: " · ")
  }
}

/// `9 of 12 rated picks`.
nonisolated func ratedPicksText(_ stats: OutcomeStats) -> String {
  "\(stats.hits) of \(stats.rated) rated \(stats.rated == 1 ? "pick" : "picks")"
}
