import Foundation
import SwiftData
import SwiftUI
import Testing

@testable import Harbinger

// I11: the Watched tab — the client, the cached list and its refresh rule, the list logic.

func makeWatchedFilm(
  _ code: String, title: String? = nil, tmdbId: Int? = 1, halfStars: Int? = 8,
  loggedOn: String? = "2024-06-01", isHorror: Bool = false, harbingerPick: Bool = false
) -> WatchedFilm {
  WatchedFilm(
    letterboxdUri: "https://boxd.it/\(code)", tmdbId: tmdbId, title: title ?? "Film \(code)",
    year: 2000, halfStars: halfStars, loggedOn: loggedOn, posterPath: "/\(code).jpg",
    isHorror: isHorror, harbingerPick: harbingerPick, firstRecommendedAt: nil)
}

func makeWatched(_ films: [WatchedFilm], lastImportAt: String? = "2026-09-24T21:54:00.000Z")
  -> WatchedResponse
{
  WatchedResponse(lastImportAt: lastImportAt.map(timestamp), films: films)
}

func watchedRow(
  _ code: String, title: String? = nil, year: Int? = 2000, halfStars: Int? = nil,
  loggedOn: String = "2024-06-01", isHorror: Bool = false, harbingerPick: Bool = false
) -> WatchedRowInput {
  WatchedRowInput(
    letterboxdURI: "https://boxd.it/\(code)", title: title ?? "Film \(code)", year: year,
    halfStars: halfStars, loggedOn: loggedOn, isHorror: isHorror, harbingerPick: harbingerPick)
}

// MARK: - Client

extension APIClientTests {
  @Test func decodesWatched() async throws {
    StubURLProtocol.respond(body: Fixtures.watched)

    let watched = try await client.watched()

    #expect(watched.lastImportAt == timestamp("2026-09-24T22:10:00.000Z"))
    #expect(
      watched.films == [
        WatchedFilm(
          letterboxdUri: "https://boxd.it/aaaa", tmdbId: 12345, title: "Noroi: The Curse",
          year: 2005, halfStars: 9, loggedOn: "2026-10-01", posterPath: "/noroi.jpg",
          isHorror: true, harbingerPick: true,
          firstRecommendedAt: timestamp("2026-09-29T18:01:30.456Z")),
        WatchedFilm(
          letterboxdUri: "https://boxd.it/2BUo", tmdbId: 123, title: "Jack Reacher",
          year: 2012, halfStars: 6, loggedOn: "2021-03-11", posterPath: "/abc.jpg",
          isHorror: false, harbingerPick: false, firstRecommendedAt: nil),
        // Unmatched and unrated: every nullable field is null.
        WatchedFilm(
          letterboxdUri: "https://boxd.it/zzzz", tmdbId: nil, title: "Obscure", year: 1972,
          halfStars: nil, loggedOn: nil, posterPath: nil, isHorror: false,
          harbingerPick: false, firstRecommendedAt: nil),
      ])
    // A calendar date stays the exact string.
    #expect(watched.films[1].loggedOn == "2021-03-11")
  }

  @Test func decodesAnEmptyWatchedList() async throws {
    StubURLProtocol.respond(body: #"{ "last_import_at": null, "films": [] }"#)

    #expect(try await client.watched() == WatchedResponse(lastImportAt: nil, films: []))
  }
}

// MARK: - Cache

struct WatchedCacheTests {
  let container: ModelContainer
  let syncs = SyncRecorder()
  let script = WatchedScript()
  let service: SyncService

  init() throws {
    container = try CacheStore.inMemory()
    service = SyncService(
      modelContainer: container, client: FakeAPIClient(syncs: syncs, watched: script))
  }

  func films() throws -> [CachedWatchedFilm] {
    try CacheReader(container).all(CachedWatchedFilm.self).sorted {
      $0.letterboxdURI < $1.letterboxdURI
    }
  }

  func marker() throws -> Date? {
    try CacheReader(container).state()?.watchedImportAt
  }

  /// A sync that reports an import at `lastImportAt`.
  func sync(lastImportAt: String?) async throws {
    syncs.enqueue(.success(makeSync(lastImportAt: lastImportAt.map(timestamp))))
    try await service.sync()
  }

  @Test func theFirstRefreshAfterAnImportStoresEveryFilm() async throws {
    try await sync(lastImportAt: "2026-09-24T22:10:00.000Z")
    script.enqueue(.success(try decodeFixture(WatchedResponse.self, Fixtures.watched)))

    #expect(try await service.refreshWatched(force: false))

    let rows = try films()
    #expect(
      rows.map(\.letterboxdURI) == [
        "https://boxd.it/2BUo", "https://boxd.it/aaaa", "https://boxd.it/zzzz",
      ])
    let noroi = try #require(rows.first { $0.tmdbID == 12345 })
    #expect(noroi.title == "Noroi: The Curse")
    #expect(noroi.year == 2005)
    #expect(noroi.halfStars == 9)
    #expect(noroi.loggedOn == "2026-10-01")
    #expect(noroi.posterPath == "/noroi.jpg")
    #expect(noroi.isHorror)
    #expect(noroi.harbingerPick)
    #expect(noroi.firstRecommendedAt == timestamp("2026-09-29T18:01:30.456Z"))
    let obscure = try #require(rows.last)
    #expect(obscure.tmdbID == nil)
    #expect(obscure.halfStars == nil)
    #expect(obscure.loggedOn == "")
    #expect(obscure.posterPath == nil)
    #expect(try marker() == timestamp("2026-09-24T22:10:00.000Z"))
  }

  @Test func anUnchangedImportMakesNoRequest() async throws {
    try await sync(lastImportAt: "2026-09-24T22:10:00.000Z")
    script.enqueue(
      .success(makeWatched([makeWatchedFilm("a")], lastImportAt: "2026-09-24T22:10:00.000Z")))
    try await service.refreshWatched(force: false)

    // Another sync, same import.
    try await sync(lastImportAt: "2026-09-24T22:10:00.000Z")
    #expect(try await service.refreshWatched(force: false) == false)

    #expect(script.calls == 1)
    #expect(try films().count == 1)
  }

  @Test func noImportEverMakesNoRequest() async throws {
    // Before any sync, and after a sync that reports no import.
    #expect(try await service.refreshWatched(force: false) == false)
    try await sync(lastImportAt: nil)
    #expect(try await service.refreshWatched(force: false) == false)

    #expect(script.calls == 0)
    #expect(try films().isEmpty)
  }

  @Test func aNewerImportReplacesTheListWholesale() async throws {
    try await sync(lastImportAt: "2026-09-24T22:10:00.000Z")
    script.enqueue(
      .success(
        makeWatched(
          [makeWatchedFilm("a", halfStars: 4), makeWatchedFilm("b"), makeWatchedFilm("c")],
          lastImportAt: "2026-09-24T22:10:00.000Z")))
    try await service.refreshWatched(force: false)

    try await sync(lastImportAt: "2026-10-03T09:00:00.000Z")
    script.enqueue(
      .success(
        makeWatched(
          [makeWatchedFilm("a", halfStars: 9, harbingerPick: true), makeWatchedFilm("d")],
          lastImportAt: "2026-10-03T09:00:00.000Z")))
    #expect(try await service.refreshWatched(force: false))

    let rows = try films()
    // b and c are gone; a is updated in place; d is new.
    #expect(rows.map(\.letterboxdURI) == ["https://boxd.it/a", "https://boxd.it/d"])
    #expect(rows.first?.halfStars == 9)
    #expect(rows.first?.harbingerPick == true)
    #expect(try marker() == timestamp("2026-10-03T09:00:00.000Z"))
    #expect(script.calls == 2)
  }

  @Test func forcedAlwaysFetches() async throws {
    // No sync state at all.
    script.enqueue(.success(makeWatched([makeWatchedFilm("a")])))
    #expect(try await service.refreshWatched(force: true))
    #expect(try films().count == 1)

    // And again with nothing new.
    try await sync(lastImportAt: "2026-09-24T21:54:00.000Z")
    script.enqueue(.success(makeWatched([makeWatchedFilm("a"), makeWatchedFilm("b")])))
    #expect(try await service.refreshWatched(force: true))

    #expect(script.calls == 2)
    #expect(try films().count == 2)
    // The marker matches the import, so the next routine refresh has nothing to do.
    #expect(try await service.refreshWatched(force: false) == false)
    #expect(script.calls == 2)
  }

  @Test func aFailedRequestLeavesTheCacheAndTheMarkerUnchanged() async throws {
    try await sync(lastImportAt: "2026-09-24T22:10:00.000Z")
    script.enqueue(
      .success(makeWatched([makeWatchedFilm("a")], lastImportAt: "2026-09-24T22:10:00.000Z")))
    try await service.refreshWatched(force: false)
    script.enqueue(.failure(.network(.notConnectedToInternet)))

    await #expect(throws: SyncError.api(.network(.notConnectedToInternet))) {
      try await service.refreshWatched(force: true)
    }

    #expect(try films().map(\.letterboxdURI) == ["https://boxd.it/a"])
    #expect(try marker() == timestamp("2026-09-24T22:10:00.000Z"))
  }

  @Test func aFailedSaveRollsBack() async throws {
    let failure = SaveFailure(isFailing: false)
    let service = SyncService(
      modelContainer: container, client: FakeAPIClient(syncs: syncs, watched: script),
      beforeSave: { try failure.check() })
    script.enqueue(.success(makeWatched([makeWatchedFilm("a")])))
    try await service.refreshWatched(force: true)
    let before = try marker()

    failure.set(true)
    script.enqueue(
      .success(makeWatched([makeWatchedFilm("b")], lastImportAt: "2026-10-03T09:00:00.000Z")))
    await #expect(throws: SyncError.self) { try await service.refreshWatched(force: true) }

    #expect(try films().map(\.letterboxdURI) == ["https://boxd.it/a"])
    #expect(try marker() == before)

    // The next one succeeds.
    failure.set(false)
    script.enqueue(.success(makeWatched([makeWatchedFilm("b")])))
    try await service.refreshWatched(force: true)
    #expect(try films().map(\.letterboxdURI) == ["https://boxd.it/b"])
  }

  @Test func resetAndSyncClearsTheWatchedRowsAndTheMarker() async throws {
    try await sync(lastImportAt: "2026-09-24T22:10:00.000Z")
    script.enqueue(
      .success(makeWatched([makeWatchedFilm("a")], lastImportAt: "2026-09-24T22:10:00.000Z")))
    try await service.refreshWatched(force: false)
    #expect(try films().count == 1)

    syncs.enqueue(.success(makeSync(lastImportAt: timestamp("2026-09-24T22:10:00.000Z"))))
    try await service.resetAndSync()

    #expect(try films().isEmpty)
    #expect(try marker() == nil)
    // So the list refetches even though the import is the same one.
    script.enqueue(
      .success(makeWatched([makeWatchedFilm("a")], lastImportAt: "2026-09-24T22:10:00.000Z")))
    #expect(try await service.refreshWatched(force: false))
    #expect(try films().count == 1)
  }

  @Test func refreshingTwiceIsIdempotent() async throws {
    let response = try decodeFixture(WatchedResponse.self, Fixtures.watched)
    script.enqueue(.success(response))
    script.enqueue(.success(response))

    try await service.refreshWatched(force: true)
    let first = try films().map { "\($0.letterboxdURI) \($0.title) \($0.loggedOn)" }
    try await service.refreshWatched(force: true)

    #expect(try films().map { "\($0.letterboxdURI) \($0.title) \($0.loggedOn)" } == first)
    #expect(try films().count == 3)
  }
}

// MARK: - When the refresh runs

@MainActor
struct WatchedRefreshTriggerTests {
  let service = FakeSyncService()
  let offline = SyncError.api(.network(.notConnectedToInternet))

  @Test func aSuccessfulSyncRunsTheRoutineRefresh() async {
    let controller = SyncController(service: service)

    await controller.syncNow()
    await controller.syncIfStale()

    // The second is throttled: no sync, so no refresh either.
    #expect(service.calls == 1)
    #expect(service.watchedForces == [false])
    #expect(controller.watchedFailure == nil)
  }

  @Test func aFailedSyncDoesNot() async {
    service.set(.failure(offline))
    let controller = SyncController(service: service)

    await controller.syncNow()

    #expect(service.calls == 1)
    #expect(service.watchedForces.isEmpty)
    #expect(controller.lastFailure == offline)
  }

  @Test func aRebuildRunsTheRoutineRefresh() async {
    let controller = SyncController(service: service)

    await controller.rebuild()

    #expect(service.resets == 1)
    #expect(service.watchedForces == [false])
  }

  @Test func pullingOnWatchedSyncsThenForcesTheRefresh() async {
    let controller = SyncController(service: service)

    await controller.refreshWatched()

    #expect(service.calls == 1)
    #expect(service.watchedForces == [true])
    #expect(!controller.isSyncing)
  }

  @Test func pullingOnWatchedStillTriesWhenTheSyncFails() async {
    service.set(.failure(offline))
    service.setWatchedError(offline)
    let controller = SyncController(service: service)

    await controller.refreshWatched()

    #expect(service.watchedForces == [true])
    #expect(controller.watchedFailure == offline)
    #expect(syncNoticeMessage(controller.watchedFailure) == "You're offline — pull to retry.")
  }

  @Test func aRefreshFailureIsKeptUntilTheNextSuccess() async {
    service.setWatchedError(offline)
    let controller = SyncController(service: service)
    await controller.syncNow()
    // The sync itself succeeded.
    #expect(controller.lastFailure == nil)
    #expect(controller.watchedFailure == offline)

    service.setWatchedError(nil)
    await controller.syncNow()

    #expect(controller.watchedFailure == nil)
    #expect(service.watchedForces == [false, false])
  }

  /// The real service behind the real controller: one sync caches the list.
  @Test func aSyncAfterAnImportCachesTheWatchedList() async throws {
    let container = try CacheStore.inMemory()
    let script = WatchedScript([
      .success(try decodeFixture(WatchedResponse.self, Fixtures.watched))
    ])
    let syncs = SyncRecorder([
      .success(makeSync(lastImportAt: timestamp("2026-09-24T22:10:00.000Z"))),
      .success(makeSync(lastImportAt: timestamp("2026-09-24T22:10:00.000Z"))),
    ])
    let controller = SyncController(
      service: SyncService(
        modelContainer: container, client: FakeAPIClient(syncs: syncs, watched: script)))

    await controller.syncNow()
    await controller.syncNow()

    #expect(try CacheReader(container).all(CachedWatchedFilm.self).count == 3)
    #expect(script.calls == 1)
    #expect(controller.watchedFailure == nil)
  }
}

// MARK: - List logic

struct WatchedListTests {
  let films = [
    watchedRow("a", title: "Alien", halfStars: 10, loggedOn: "2021-01-01", isHorror: true),
    watchedRow(
      "b", title: "Barbarian", halfStars: 7, loggedOn: "2024-06-01", isHorror: true,
      harbingerPick: true),
    watchedRow("c", title: "Casablanca", halfStars: 9, loggedOn: "2023-02-02"),
    watchedRow("d", title: "Drive", loggedOn: "2025-12-31", harbingerPick: true),
  ]

  func codes(_ options: WatchedOptions) -> [String] {
    watchedRows(films, options: options).map { String($0.letterboxdURI.suffix(1)) }
  }

  @Test func defaultsAreAllFilmsNewestLoggedFirst() {
    let options = WatchedOptions()

    #expect(options.genre == .all)
    #expect(!options.picksOnly)
    #expect(options.sort == .logged)
    #expect(options.search.isEmpty)
    #expect(!options.isFiltering)
    #expect(codes(options) == ["d", "b", "c", "a"])
  }

  @Test func genreAndPicksOnlyCombine() {
    #expect(codes(WatchedOptions(genre: .horror)) == ["b", "a"])
    #expect(codes(WatchedOptions(picksOnly: true)) == ["d", "b"])
    #expect(codes(WatchedOptions(genre: .horror, picksOnly: true)) == ["b"])
    #expect(codes(WatchedOptions(genre: .horror, picksOnly: true, search: "alien")).isEmpty)
    #expect(WatchedOptions(genre: .horror).isFiltering)
    #expect(WatchedOptions(picksOnly: true).isFiltering)
    #expect(WatchedOptions(search: " x ").isFiltering)
    #expect(!WatchedOptions(sort: .rating, search: "  ").isFiltering)
  }

  @Test func loggedSortBreaksTiesByTitleThenURI() {
    let tied = [
      watchedRow("3", title: "Zulu", loggedOn: "2024-06-01"),
      watchedRow("2", title: "Beta", loggedOn: "2024-06-01"),
      watchedRow("1", title: "Beta", loggedOn: "2024-06-01"),
      watchedRow("5", title: "Alpha", loggedOn: "2020-01-01"),
      // No date: last.
      watchedRow("6", title: "Aardvark", loggedOn: ""),
      watchedRow("4", title: "Omega", loggedOn: "2025-01-01"),
    ]

    let sorted = watchedRows(tied, options: WatchedOptions())
    #expect(sorted.map { String($0.letterboxdURI.suffix(1)) } == ["4", "1", "2", "3", "5", "6"])
    #expect(watchedRows(tied.reversed(), options: WatchedOptions()) == sorted)
  }

  @Test func ratingSortPutsUnratedLast() {
    #expect(codes(WatchedOptions(sort: .rating)) == ["a", "c", "b", "d"])

    let tied = [
      watchedRow("1", title: "Older", halfStars: 8, loggedOn: "2020-01-01"),
      watchedRow("2", title: "Newer", halfStars: 8, loggedOn: "2024-01-01"),
      watchedRow("3", title: "Unrated new", loggedOn: "2026-01-01"),
      watchedRow("4", title: "Unrated old", loggedOn: "2019-01-01"),
      watchedRow("5", title: "Low", halfStars: 1, loggedOn: "2026-06-01"),
      watchedRow("6", title: "B same day", halfStars: 8, loggedOn: "2024-01-01"),
    ]
    let sorted = watchedRows(tied, options: WatchedOptions(sort: .rating))
    // Same rating: newest logged first, then title.
    #expect(sorted.map { String($0.letterboxdURI.suffix(1)) } == ["6", "2", "1", "5", "3", "4"])
  }

  @Test func searchIgnoresCaseAndDiacritics() {
    let films = [
      watchedRow("1", title: "Amélie"), watchedRow("2", title: "The Witch"),
      watchedRow("3", title: "WITCHFINDER"),
    ]
    func found(_ search: String) -> [String] {
      watchedRows(films, options: WatchedOptions(search: search)).map(\.title)
    }

    #expect(found("Amelie") == ["Amélie"])
    #expect(found("AMÉL") == ["Amélie"])
    #expect(found("witch") == ["The Witch", "WITCHFINDER"])
    #expect(found("  witch  ") == ["The Witch", "WITCHFINDER"])
    #expect(found("itc") == ["The Witch", "WITCHFINDER"])
    #expect(found("nope").isEmpty)
    #expect(found("").count == 3)
  }

  @Test func rowsAreBuiltFromTheCache() {
    let cached = CachedWatchedFilm(letterboxdURI: "https://boxd.it/aaaa")
    cached.apply(
      WatchedFilm(
        letterboxdUri: "https://boxd.it/aaaa", tmdbId: 12345, title: "Noroi", year: 2005,
        halfStars: 9, loggedOn: "2026-10-01", posterPath: "/noroi.jpg", isHorror: true,
        harbingerPick: true, firstRecommendedAt: nil))

    #expect(
      WatchedRowInput(cached)
        == WatchedRowInput(
          letterboxdURI: "https://boxd.it/aaaa", tmdbID: 12345, title: "Noroi", year: 2005,
          halfStars: 9, loggedOn: "2026-10-01", posterPath: "/noroi.jpg", isHorror: true,
          harbingerPick: true))
  }

  @Test func optionRawValuesAreStable() {
    // `@AppStorage` keeps these.
    #expect(WatchedGenre.allCases.map(\.rawValue) == ["all", "horror"])
    #expect(WatchedSort.allCases.map(\.rawValue) == ["logged", "rating"])
    #expect(WatchedGenre.allCases.map(\.title) == ["All", "Horror"])
    #expect(WatchedSort.allCases.map(\.title) == ["Logged", "Rating"])
  }
}

// MARK: - Display helpers

struct WatchedTextTests {
  static func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
  }

  let us = Locale(identifier: "en_US")

  @Test(arguments: ["Pacific/Kiritimati", "Pacific/Pago_Pago", "UTC", "America/New_York"])
  func loggedTextIsTheSameDayInEveryTimeZone(_ zone: String) {
    let calendar = Self.calendar(zone)

    #expect(loggedText("2021-03-11", calendar: calendar, locale: us) == "Logged Mar 11, 2021")
    #expect(loggedText("2024-12-31", calendar: calendar, locale: us) == "Logged Dec 31, 2024")
    #expect(loggedText("2025-01-01", calendar: calendar, locale: us) == "Logged Jan 1, 2025")
  }

  @Test(arguments: ["", "2021-03", "2021-13-01", "2021-02-30", "March 11", "2021-03-11T00:00"])
  func anythingElseHasNoLoggedText(_ value: String) {
    #expect(loggedText(value, calendar: Self.calendar("UTC"), locale: us) == nil)
  }

  @Test func ratingText() {
    #expect(watchedRatingText(halfStars: 9) == "★4.5")
    #expect(watchedRatingText(halfStars: 8) == "★4")
    #expect(watchedRatingText(halfStars: nil) == "Not rated")
  }

  @Test func accessibilityLabel() {
    let calendar = Self.calendar("UTC")
    func label(_ film: WatchedRowInput) -> String {
      watchedAccessibilityLabel(film, calendar: calendar, locale: us)
    }

    #expect(
      label(
        watchedRow(
          "a", title: "Noroi", year: 2005, halfStars: 9, loggedOn: "2021-03-11",
          harbingerPick: true))
        == "Noroi, 2005. ★4.5. Logged Mar 11, 2021. Recommended by Harbinger.")
    #expect(
      label(watchedRow("a", title: "Noroi", year: 2005, halfStars: 9, loggedOn: "2021-03-11"))
        == "Noroi, 2005. ★4.5. Logged Mar 11, 2021.")
    #expect(
      label(watchedRow("a", title: "Noroi", year: nil, loggedOn: "2021-03-11"))
        == "Noroi. Not rated. Logged Mar 11, 2021.")
    #expect(
      label(watchedRow("a", title: "Noroi", year: nil, loggedOn: "", harbingerPick: true))
        == "Noroi. Not rated. Recommended by Harbinger.")
  }

  @Test func countAndLinks() {
    #expect(watchedCountText(124) == "124 films")
    #expect(watchedCountText(1) == "1 film")
    #expect(watchedCountText(0) == "0 films")
    #expect(watchedURL("https://boxd.it/2BUo")?.absoluteString == "https://boxd.it/2BUo")
    #expect(watchedURL("") == nil)
    #expect(watchedURL("javascript:alert(1)") == nil)
    #expect(watchedURL("http://boxd.it/2BUo") == nil)
  }

  @Test func trackRecordSummary() {
    #expect(
      trackRecordSummaryText(.stats(makeStats())) == "Hit rate 75% · 9 of 12 rated picks")
    #expect(
      trackRecordSummaryText(.stats(makeStats(rated: 1, hits: 1, hitRate: 1)))
        == "Hit rate 100% · 1 of 1 rated pick")
    #expect(trackRecordSummaryText(.noPicks) == "No picks yet.")
    #expect(
      trackRecordSummaryText(.noneRated(recommended: 12)) == "12 picks so far — none rated yet.")
    #expect(trackRecordSummaryText(.failed("You're offline.")) == "You're offline.")
    #expect(trackRecordSummaryText(.loading) == nil)
  }
}

// MARK: - Screens

extension ScreenSmokeTests {
  @Test func watchedRendersWithFilmsAndLoadsTheTrackRecord() async throws {
    let container = try CacheStore.inMemory()
    let outcomes = OutcomeScript([
      .success(try decodeFixture(OutcomeStats.self, Fixtures.outcomeStats))
    ])
    let watched = WatchedScript([
      .success(try decodeFixture(WatchedResponse.self, Fixtures.watched))
    ])
    let client = FakeAPIClient(outcomes: outcomes, watched: watched)
    let service = SyncService(modelContainer: container, client: client)
    try await service.refreshWatched(force: true)
    let session = AppSession(
      connection: Connection(baseURL: testBaseURL, apiKey: testAPIKey), client: client,
      syncService: service, sync: SyncController(service: service), open: { _ in },
      background: BackgroundRecorder().time)

    try await render(
      NavigationStack { WatchedView() }
        .environment(session)
        .modelContainer(container))

    #expect(outcomes.calls == 1)
    #expect(try container.mainContext.fetchCount(FetchDescriptor<CachedWatchedFilm>()) == 3)
  }

  @Test func emptyWatchedRenders() async throws {
    let harness = try SessionHarness()

    try await render(
      NavigationStack { WatchedView() }
        .environment(harness.session)
        .modelContainer(harness.container))
  }
}
