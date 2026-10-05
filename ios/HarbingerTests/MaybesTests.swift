import Foundation
import SwiftData
import SwiftUI
import Testing

@testable import Harbinger

// I8: the Maybes list — which films appear, and promoting them to Yes or No.

func cachedDecision(
  _ choice: Decision.Choice, tmdbID: Int, conversationID: String = "conv-1",
  decidedAt: String = "2026-10-01T12:00:00.000Z"
) -> CachedDecision {
  let decision = CachedDecision(tmdbID: tmdbID)
  decision.apply(
    Decision(
      tmdbId: tmdbID, decision: choice, conversationId: conversationID,
      decidedAt: timestamp(decidedAt)))
  return decision
}

func cachedPick(
  id: String, tmdbID: Int, conversationID: String = "conv-1", title: String = "The Witch",
  year: Int? = 2015, posterPath: String? = "/witch.jpg", createdAt: String? = nil
) -> CachedRecommendation {
  let pick = CachedRecommendation(id: id)
  pick.conversationID = conversationID
  pick.tmdbID = tmdbID
  pick.title = title
  pick.year = year
  pick.posterPath = posterPath
  pick.whyShort = "Why \(id)."
  pick.createdAt = createdAt.map(timestamp)
  return pick
}

struct MaybeSelectionTests {
  @Test func aMaybeWithItsPickIsIncludedWithThePicksDetails() {
    let items = maybes(
      decisions: [cachedDecision(.maybe, tmdbID: 1, decidedAt: "2026-10-02T09:00:00.000Z")],
      recommendations: [cachedPick(id: "rec-1", tmdbID: 1)])

    #expect(
      items == [
        MaybeItem(
          recommendationID: "rec-1", tmdbID: 1, conversationID: "conv-1", title: "The Witch",
          year: 2015, posterPath: "/witch.jpg", whyShort: "Why rec-1.",
          decidedAt: timestamp("2026-10-02T09:00:00.000Z"))
      ])
    #expect(items.first?.target == DecisionTarget(tmdbID: 1, conversationID: "conv-1"))
    #expect(items.first?.id == 1)
  }

  /// Its conversation was deleted (W7), which removed the picks.
  @Test func aMaybeWithoutAPickIsExcluded() {
    let items = maybes(
      decisions: [cachedDecision(.maybe, tmdbID: 1, conversationID: "conv-gone")],
      recommendations: [cachedPick(id: "rec-2", tmdbID: 2, conversationID: "conv-gone")])

    #expect(items.isEmpty)
    #expect(maybes(decisions: [cachedDecision(.maybe, tmdbID: 1)], recommendations: []).isEmpty)
  }

  @Test func theSameFilmInAnotherConversationDoesNotCount() {
    let decision = cachedDecision(.maybe, tmdbID: 1, conversationID: "conv-gone")
    let elsewhere = cachedPick(id: "rec-other", tmdbID: 1, conversationID: "conv-2")

    #expect(maybes(decisions: [decision], recommendations: [elsewhere]).isEmpty)

    // With its own conversation's pick present too, that one is used — never the other.
    let own = cachedPick(id: "rec-own", tmdbID: 1, conversationID: "conv-gone", title: "Own")
    let items = maybes(decisions: [decision], recommendations: [elsewhere, own])
    #expect(items.map(\.recommendationID) == ["rec-own"])
    #expect(items.first?.conversationID == "conv-gone")
  }

  @Test func theMostRecentOfSeveralPicksIsUsed() {
    let decision = cachedDecision(.maybe, tmdbID: 1)
    let older = cachedPick(id: "rec-old", tmdbID: 1, createdAt: "2026-09-29T18:00:00.000Z")
    let newer = cachedPick(
      id: "rec-new", tmdbID: 1, title: "Newer", createdAt: "2026-09-30T18:00:00.000Z")
    let undated = cachedPick(id: "rec-undated", tmdbID: 1)

    for picks in [[older, newer, undated], [undated, newer, older], [newer, undated, older]] {
      let items = maybes(decisions: [decision], recommendations: picks)
      #expect(items.map(\.recommendationID) == ["rec-new"])
      #expect(items.first?.title == "Newer")
    }
    // Equal (or missing) timestamps: the choice is still stable.
    let a = cachedPick(id: "rec-a", tmdbID: 1)
    let b = cachedPick(id: "rec-b", tmdbID: 1)
    #expect(
      maybes(decisions: [decision], recommendations: [a, b])
        == maybes(decisions: [decision], recommendations: [b, a]))
  }

  @Test func yesAndNoNeverAppear() {
    let items = maybes(
      decisions: [
        cachedDecision(.yes, tmdbID: 1), cachedDecision(.no, tmdbID: 2),
        cachedDecision(.maybe, tmdbID: 3),
      ],
      recommendations: [
        cachedPick(id: "rec-1", tmdbID: 1), cachedPick(id: "rec-2", tmdbID: 2),
        cachedPick(id: "rec-3", tmdbID: 3),
      ])

    #expect(items.map(\.tmdbID) == [3])
  }

  @Test func newestDecisionFirst() {
    let items = maybes(
      decisions: [
        cachedDecision(.maybe, tmdbID: 1, decidedAt: "2026-10-01T12:00:00.000Z"),
        cachedDecision(.maybe, tmdbID: 2, decidedAt: "2026-10-03T12:00:00.000Z"),
        cachedDecision(.maybe, tmdbID: 3, decidedAt: "2026-10-02T12:00:00.000Z"),
        cachedDecision(.maybe, tmdbID: 4, decidedAt: "2026-10-02T12:00:00.000Z"),
      ],
      recommendations: (1...4).map { cachedPick(id: "rec-\($0)", tmdbID: $0) })

    #expect(items.map(\.tmdbID) == [2, 3, 4, 1])
  }

  @Test func savedText() {
    let day = timestamp("2026-10-01T12:00:00.000Z")
    #expect(maybeSavedText(decidedAt: day, now: day) == "Saved just now")
    let text = maybeSavedText(decidedAt: day, now: day.addingTimeInterval(3 * 86_400))
    #expect(text.hasPrefix("Saved "))
    #expect(text != "Saved just now")

    let item = MaybeItem(
      recommendationID: "rec-1", tmdbID: 1, conversationID: "conv-1", title: "The Witch",
      year: 2015, posterPath: nil, whyShort: "Slow dread", decidedAt: day)
    #expect(
      maybeAccessibilityLabel(item, now: day) == "The Witch, 2015. Slow dread. Saved just now")
  }
}

@MainActor
struct MaybePromotionTests {
  let letterboxd = URL(string: "https://letterboxd.com/tmdb/12345")!

  /// A session whose cache holds conv-1's picks (The Witch 12345, Lake Mungo 67890) and a
  /// Maybe on The Witch.
  func harness(
    _ results: [Result<Decision, APIError>], delay: Duration? = nil
  ) async throws -> SessionHarness {
    let harness = try SessionHarness(decisions: DecisionScript(results, delay: delay))
    try await harness.session.syncService.ingest(
      try turnResponse(Fixtures.recommendationsResponse))
    try await harness.session.syncService.ingest(makeDecision(.maybe))
    return harness
  }

  /// The list as the screen computes it: from the cache.
  func items(_ harness: SessionHarness) throws -> [MaybeItem] {
    let reader = CacheReader(harness.container)
    return maybes(
      decisions: try reader.all(CachedDecision.self),
      recommendations: try reader.all(CachedRecommendation.self))
  }

  @Test func theCachedMaybeIsListed() async throws {
    let harness = try await harness([])
    let item = try #require(try items(harness).first)

    #expect(try items(harness).count == 1)
    #expect(item.recommendationID == "rec-1")
    #expect(item.title == "The Witch")
    #expect(item.target == DecisionTarget(tmdbID: 12345, conversationID: "conv-1"))
  }

  @Test func yesIsSavedThenOpensLetterboxdAndTheItemIsGone() async throws {
    let harness = try await harness([.success(makeDecision(.yes))])
    let model = MaybesModel(session: harness.session)
    let item = try #require(try items(harness).first)

    model.promoteToYes(item)
    await model.task?.value

    #expect(
      harness.decisions.calls
        == [DecisionScript.Call(tmdbID: 12345, decision: .yes, conversationID: "conv-1")])
    #expect(harness.opener.opened == [letterboxd])
    #expect(try items(harness).isEmpty)
    #expect(model.errorMessage == nil)
  }

  @Test func noAsksFirstAndCancelSendsNothing() async throws {
    let harness = try await harness([.success(makeDecision(.no))])
    let model = MaybesModel(session: harness.session)
    let item = try #require(try items(harness).first)

    model.askNo(item)
    #expect(model.noCandidate == item)
    #expect(model.task == nil)
    // Cancel (the dialog's binding clears the candidate).
    model.noCandidate = nil
    model.confirmNo()

    #expect(model.task == nil)
    #expect(harness.decisions.calls.isEmpty)
    #expect(try items(harness) == [item])
  }

  @Test func confirmedNoIsSentAndTheItemIsGone() async throws {
    let harness = try await harness([.success(makeDecision(.no))])
    let model = MaybesModel(session: harness.session)
    let item = try #require(try items(harness).first)

    model.askNo(item)
    model.confirmNo()
    await model.task?.value

    #expect(model.noCandidate == nil)
    #expect(
      harness.decisions.calls
        == [DecisionScript.Call(tmdbID: 12345, decision: .no, conversationID: "conv-1")])
    #expect(harness.opener.opened.isEmpty)
    #expect(try items(harness).isEmpty)
    #expect(try CacheReader(harness.container).all(CachedDecision.self).first?.choice == .no)
  }

  @Test(arguments: [
    (APIError.network(.notConnectedToInternet), "You're offline."),
    (APIError.unauthorized, "API key rejected — update it in Settings."),
    (
      APIError.server(status: 422, code: "not_recommended", message: "", retryAfter: nil),
      "Couldn't save that — try again."
    ),
  ])
  func failureKeepsTheItemAndShowsTheDecisionErrorText(error: APIError, text: String)
    async throws
  {
    let harness = try await harness([.failure(error)])
    let model = MaybesModel(session: harness.session)
    let item = try #require(try items(harness).first)

    model.promoteToYes(item)
    await model.task?.value

    #expect(model.errorMessage == text)
    #expect(try items(harness) == [item])
    #expect(harness.opener.opened.isEmpty)
    #expect(!model.isSaving(item))
  }

  @Test func aSecondActionWhileOneIsInFlightMakesNoRequest() async throws {
    let harness = try await harness([.success(makeDecision(.yes))], delay: .milliseconds(150))
    let model = MaybesModel(session: harness.session)
    let item = try #require(try items(harness).first)

    model.promoteToYes(item)
    let first = model.task
    await eventually { model.isSaving(item) }
    #expect(model.isSaving(item))

    // From the list: neither a second Yes nor a No gets anywhere.
    model.promoteToYes(item)
    model.askNo(item)
    #expect(model.noCandidate == nil)
    // And the session itself rejects one from any other screen.
    #expect(await harness.session.setDecision(.no, for: item.target, current: .maybe) == .rejected)
    await first?.value

    #expect(harness.decisions.calls.map(\.decision) == [.yes])
    #expect(try items(harness).isEmpty)
  }

  @Test func promotingFromTheDetailScreenAlsoRemovesTheItem() async throws {
    let harness = try await harness([.success(makeDecision(.no))])
    let item = try #require(try items(harness).first)
    let detail = PickDetailModel(session: harness.session, target: item.target)

    detail.choose(.no, current: .maybe)
    await detail.decisionTask?.value

    #expect(try items(harness).isEmpty)
  }

  @Test func deletingTheConversationDropsItsMaybe() async throws {
    let harness = try await harness([])
    #expect(try items(harness).count == 1)

    try await harness.session.syncService.removeConversation(id: "conv-1")

    // The decision row is kept (a conversation delete never touches decisions) but inert.
    #expect(try CacheReader(harness.container).all(CachedDecision.self).count == 1)
    #expect(try items(harness).isEmpty)
  }
}

extension ScreenSmokeTests {
  @Test func maybesRendersWithAMaybe() async throws {
    let harness = try await cachedHarness()
    try await harness.session.syncService.ingest(makeDecision(.maybe))

    try await render(
      NavigationStack { MaybesView() }
        .environment(harness.session)
        .modelContainer(harness.container))
  }

  @Test func emptyMaybesRenders() async throws {
    let harness = try SessionHarness()

    try await render(
      NavigationStack { MaybesView() }
        .environment(harness.session)
        .modelContainer(harness.container))
  }
}
