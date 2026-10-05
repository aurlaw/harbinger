import Foundation
import SwiftData
import SwiftUI
import Testing

@testable import Harbinger

// I7: the track record (GET /stats/outcomes) in Settings and its recent-outcomes list.

func makeStats(
  recommended: Int = 41, rated: Int = 12, hits: Int = 9, hitRate: Double? = 0.75,
  averageHalfStars: Double? = 7.4, byModel: [ModelOutcome] = [], recent: [Outcome] = []
) -> OutcomeStats {
  OutcomeStats(
    hitThresholdHalfStars: 7, recommended: recommended, rated: rated, hits: hits,
    hitRate: hitRate, averageHalfStars: averageHalfStars, byModel: byModel, recent: recent)
}

func makeOutcome(
  tmdbId: Int = 12345, title: String = "Noroi: The Curse", year: Int? = 2005,
  halfStars: Int = 9, hit: Bool = true, model: String = "claude-sonnet-5"
) -> Outcome {
  Outcome(
    tmdbId: tmdbId, title: title, year: year, halfStars: halfStars, hit: hit, model: model,
    firstRecommendedAt: timestamp("2026-09-29T18:01:30.456Z"))
}

// MARK: - Client

extension APIClientTests {
  @Test func decodesOutcomeStats() async throws {
    StubURLProtocol.respond(body: Fixtures.outcomeStats)

    let stats = try await client.outcomeStats()

    let request = try onlyRequest()
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path() == "/stats/outcomes")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(testAPIKey)")
    #expect(
      stats
        == OutcomeStats(
          hitThresholdHalfStars: 7, recommended: 41, rated: 12, hits: 9, hitRate: 0.75,
          averageHalfStars: 7.4,
          byModel: [
            ModelOutcome(
              model: "claude-sonnet-5", recommended: 30, rated: 9, hits: 7, hitRate: 0.778),
            ModelOutcome(
              model: "claude-opus-5-5", recommended: 11, rated: 3, hits: 2, hitRate: 0.667),
          ],
          recent: [
            Outcome(
              tmdbId: 12345, title: "Noroi: The Curse", year: 2005, halfStars: 9, hit: true,
              model: "claude-sonnet-5",
              firstRecommendedAt: timestamp("2026-09-29T18:01:30.456Z")),
            Outcome(
              tmdbId: 67890, title: "Lake Mungo", year: nil, halfStars: 4, hit: false,
              model: "claude-opus-5-5",
              firstRecommendedAt: timestamp("2026-09-20T09:00:00.000Z")),
          ]))
  }

  @Test func decodesEmptyOutcomeStats() async throws {
    StubURLProtocol.respond(body: Fixtures.emptyOutcomeStats)

    let stats = try await client.outcomeStats()

    #expect(stats.hitRate == nil)
    #expect(stats.averageHalfStars == nil)
    #expect(stats.byModel == [])
    #expect(stats.recent == [])
    #expect(stats.recommended == 0)
  }

  @Test func decodesANullModelHitRate() async throws {
    StubURLProtocol.respond(
      body: """
        { "hit_threshold_half_stars": 7, "recommended": 3, "rated": 0, "hits": 0,
          "hit_rate": null, "average_half_stars": null,
          "by_model": [ { "model": "claude-sonnet-5", "recommended": 3, "rated": 0, "hits": 0,
                          "hit_rate": null } ],
          "recent": [] }
        """)

    let stats = try await client.outcomeStats()

    #expect(
      stats.byModel == [
        ModelOutcome(model: "claude-sonnet-5", recommended: 3, rated: 0, hits: 0, hitRate: nil)
      ])
  }

  @Test func outcomeStatsUnauthorized() async {
    StubURLProtocol.respond(status: 401, body: Fixtures.error("unauthorized"))

    await #expect(throws: APIError.unauthorized) { _ = try await client.outcomeStats() }
  }
}

// MARK: - Formatting

struct TrackRecordTextTests {
  @Test(arguments: [
    (0.75, "75%"), (0.778, "78%"), (0.005, "1%"), (0.0, "0%"), (1.0, "100%"),
    (0.667, "67%"), (0.285, "29%"), (0.004, "0%"), (0.5, "50%"),
  ])
  func percent(rate: Double, expected: String) {
    #expect(percentText(rate) == expected)
  }

  @Test func noRateHasNoPercent() {
    #expect(percentText(nil) == nil)
  }

  @Test(arguments: [(7.4, "★3.7"), (8.0, "★4.0"), (6.5, "★3.3"), (10.0, "★5.0"), (1.0, "★0.5")])
  func average(halfStars: Double, expected: String) {
    #expect(averageText(halfStars) == expected)
  }

  @Test func noAverageIsHidden() {
    #expect(averageText(nil) == nil)
  }

  @Test(arguments: [(7, "★3.5"), (8, "★4"), (1, "★0.5"), (10, "★5"), (9, "★4.5")])
  func stars(halfStars: Int, expected: String) {
    #expect(starText(halfStars: halfStars) == expected)
  }

  @Test func thresholdComesFromTheServer() {
    #expect(thresholdText(halfStars: 7) == "★3.5 or higher")
    #expect(thresholdText(halfStars: 8) == "★4 or higher")
    #expect(hitRateCaption(makeStats()) == "9 of 12 rated picks scored ★3.5 or higher")
    #expect(
      hitRateCaption(makeStats(rated: 1, hits: 1, hitRate: 1))
        == "1 of 1 rated pick scored ★3.5 or higher")
  }

  @Test(arguments: [
    ("claude-haiku-4-5-20251001", "Haiku 4.5"), ("claude-sonnet-5", "Sonnet 5"),
    ("claude-opus-5-5", "Opus 5.5"), ("claude-future-9", "claude-future-9"), ("", ""),
  ])
  func displayName(id: String, expected: String) {
    #expect(modelDisplayName(id) == expected)
  }

  @Test func perModelText() {
    let rated = ModelOutcome(
      model: "claude-sonnet-5", recommended: 30, rated: 9, hits: 7, hitRate: 0.778)
    #expect(modelOutcomeText(rated) == "7 of 9 hits (78%)")
    let unrated = ModelOutcome(
      model: "claude-opus-5-5", recommended: 4, rated: 0, hits: 0, hitRate: nil)
    #expect(modelOutcomeText(unrated) == "Not rated yet")
    let noHits = ModelOutcome(
      model: "claude-opus-5-5", recommended: 4, rated: 2, hits: 0, hitRate: 0)
    #expect(modelOutcomeText(noHits) == "0 of 2 hits (0%)")
  }

  @Test func picksSoFar() {
    #expect(picksSoFarText(12) == "12 picks so far — none rated yet.")
    #expect(picksSoFarText(1) == "1 pick so far — none rated yet.")
  }

  @Test func errorText() {
    #expect(trackRecordErrorMessage(.network(.notConnectedToInternet)) == "You're offline.")
    #expect(trackRecordErrorMessage(.network(.timedOut)) == "Can't reach the server.")
    #expect(
      trackRecordErrorMessage(.unauthorized) == "API key rejected — update it in Settings.")
    #expect(
      trackRecordErrorMessage(
        .server(status: 503, code: "db_unavailable", message: "", retryAfter: nil))
        == "Couldn't load your track record — try again.")
  }
}

// MARK: - States

@MainActor
struct TrackRecordModelTests {
  func model(_ script: OutcomeScript) -> TrackRecordModel {
    TrackRecordModel(client: FakeAPIClient(outcomes: script))
  }

  @Test func firstLoadShowsLoadingThenData() async {
    let stats = makeStats()
    let script = OutcomeScript([.success(stats)], delay: .milliseconds(100))
    let model = model(script)
    #expect(model.content == .loading)

    let load = Task { await model.load() }
    await eventually { model.isLoading }
    #expect(model.content == .loading)
    await load.value

    #expect(model.content == .stats(stats))
    #expect(!model.isLoading)
    #expect(model.refreshError == nil)
    #expect(script.calls == 1)
  }

  @Test func noPicksYet() async {
    let model = model(
      OutcomeScript([
        .success(makeStats(recommended: 0, rated: 0, hits: 0, hitRate: nil, averageHalfStars: nil))
      ]))
    await model.load()

    #expect(model.content == .noPicks)
  }

  @Test func picksButNoneRated() async {
    let model = model(
      OutcomeScript([
        .success(
          makeStats(recommended: 12, rated: 0, hits: 0, hitRate: nil, averageHalfStars: nil))
      ]))
    await model.load()

    #expect(model.content == .noneRated(recommended: 12))
  }

  @Test func refreshFailureKeepsThePreviousStatsAndShowsTheError() async {
    let stats = makeStats()
    let model = model(OutcomeScript([.success(stats), .failure(.network(.timedOut))]))
    await model.load()
    await model.load()

    #expect(model.content == .stats(stats))
    #expect(model.refreshError == "Can't reach the server.")
  }

  @Test func aLaterSuccessReplacesTheStatsAndClearsTheError() async {
    let newer = makeStats(recommended: 42, rated: 13, hits: 10, hitRate: 0.769)
    let model = model(
      OutcomeScript([.success(makeStats()), .failure(.invalidResponse), .success(newer)]))
    await model.load()
    await model.load()
    await model.load()

    #expect(model.content == .stats(newer))
    #expect(model.refreshError == nil)
  }

  @Test func firstLoadFailureShowsTheErrorAlone() async {
    let model = model(
      OutcomeScript([
        .failure(.server(status: 503, code: "db_unavailable", message: "", retryAfter: nil))
      ]))
    await model.load()

    #expect(model.content == .failed("Couldn't load your track record — try again."))
    #expect(model.stats == nil)
    #expect(model.refreshError == nil)
  }

  @Test func offline() async {
    let model = model(OutcomeScript([.failure(.network(.notConnectedToInternet))]))
    await model.load()

    #expect(model.content == .failed("You're offline."))
  }

  @Test func offlineRefreshKeepsTheStats() async {
    let stats = makeStats()
    let model = model(
      OutcomeScript([.success(stats), .failure(.network(.notConnectedToInternet))]))
    await model.load()
    await model.load()

    #expect(model.content == .stats(stats))
    #expect(model.refreshError == "You're offline.")
  }

  @Test func aLoadWhileOneIsInFlightMakesNoSecondRequest() async {
    let script = OutcomeScript([.success(makeStats())], delay: .milliseconds(100))
    let model = model(script)

    let first = Task { await model.load() }
    await eventually { model.isLoading }
    await model.load()
    await first.value

    #expect(script.calls == 1)
  }
}

// MARK: - Recent outcomes

@MainActor
struct RecentOutcomesTests {
  let hit = makeOutcome()
  let miss = makeOutcome(
    tmdbId: 67890, title: "Lake Mungo", year: nil, halfStars: 4, hit: false,
    model: "claude-opus-5-5")

  @Test func rowContent() {
    let date = timestamp("2026-09-29T18:01:30.456Z").formatted(
      date: .abbreviated, time: .omitted)

    let hitRow = OutcomeRowInfo(hit)
    #expect(hitRow.title == "Noroi: The Curse (2005)")
    #expect(hitRow.rating == "★4.5")
    #expect(hitRow.markerSymbol == "checkmark.circle.fill")
    #expect(hitRow.markerLabel == "Hit")
    #expect(hitRow.subtitle == "Sonnet 5 · \(date)")
    #expect(hitRow.letterboxdURL?.absoluteString == "https://letterboxd.com/tmdb/12345")

    let missRow = OutcomeRowInfo(miss)
    #expect(missRow.title == "Lake Mungo")
    #expect(missRow.rating == "★2")
    #expect(missRow.markerSymbol == "xmark.circle")
    #expect(missRow.markerLabel == "Miss")
    #expect(missRow.subtitle.hasPrefix("Opus 5.5 · "))
  }

  @Test func rowsKeepTheServerOrder() throws {
    let stats = try decodeFixture(OutcomeStats.self, Fixtures.outcomeStats)

    #expect(stats.recent.map(\.tmdbId) == [12345, 67890])
    #expect(stats.recent.map { OutcomeRowInfo($0).markerLabel } == ["Hit", "Miss"])
  }

  @Test func tappingARowOpensThatFilmOnLetterboxd() {
    let opener = OpenRecorder()

    openLetterboxd(for: miss) { opener.open($0) }
    openLetterboxd(for: hit) { opener.open($0) }

    #expect(
      opener.opened.map(\.absoluteString) == [
        "https://letterboxd.com/tmdb/67890", "https://letterboxd.com/tmdb/12345",
      ])
  }

  @Test func theLinkIsHiddenWhenThereAreNoRecentOutcomes() {
    #expect(!makeStats(recent: []).hasRecentOutcomes)
    #expect(makeStats(recent: [hit]).hasRecentOutcomes)
  }

  @Test func theRouteCarriesTheOutcomes() {
    #expect(Route.recentOutcomes([hit, miss]) == Route.recentOutcomes([hit, miss]))
    #expect(Route.recentOutcomes([hit]) != Route.recentOutcomes([miss]))
  }
}

// MARK: - Screens

extension ScreenSmokeTests {
  /// The track record moved to the Watched tab (I11): Settings neither shows nor loads it.
  @Test func settingsNoLongerLoadsTheTrackRecord() async throws {
    let container = try CacheStore.inMemory()
    let stats = try decodeFixture(OutcomeStats.self, Fixtures.outcomeStats)
    let script = OutcomeScript([.success(stats)])
    let client = FakeAPIClient(outcomes: script)
    let service = SyncService(modelContainer: container, client: client)
    let session = AppSession(
      connection: Connection(baseURL: testBaseURL, apiKey: testAPIKey), client: client,
      syncService: service, sync: SyncController(service: service), open: { _ in },
      background: BackgroundRecorder().time)

    try await render(
      NavigationStack { SettingsView(session: session, editor: nil) }
        .environment(session)
        .modelContainer(container))
    #expect(script.calls == 0)

    // Its new home: the screen behind `Route.trackRecord`, with the I7 content.
    try await render(
      NavigationStack { RouteDestination(route: .trackRecord, session: session) }
        .environment(session)
        .modelContainer(container))
    #expect(script.calls == 1)
    #expect(session.trackRecord.content == .stats(stats))
  }

  @Test func recentOutcomesRenders() async throws {
    let stats = try decodeFixture(OutcomeStats.self, Fixtures.outcomeStats)
    try await render(NavigationStack { RecentOutcomesView(outcomes: stats.recent) })
  }
}
