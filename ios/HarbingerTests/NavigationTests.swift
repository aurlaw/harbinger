import Foundation
import SwiftData
import SwiftUI
import Testing

@testable import Harbinger

// I10: the tab root — navigation state, the shared route destinations, the Maybes badge.

@MainActor
struct AppNavigationTests {
  @Test func startsOnPicksWithEmptyPaths() {
    let navigation = AppNavigation()

    #expect(navigation.selectedTab == .picks)
    for tab in AppTab.allCases {
      #expect(navigation.path(for: tab).isEmpty)
    }
  }

  @Test func openSelectsTheTabAndReplacesItsPath() {
    let navigation = AppNavigation()
    navigation.selectedTab = .settings
    navigation.picksPath = [.conversation("old"), .recommendation("rec-1")]

    navigation.open(.conversation("x"), in: .picks)

    #expect(navigation.selectedTab == .picks)
    #expect(navigation.picksPath == [.conversation("x")])
  }

  @Test func openLeavesOtherTabsWhereTheyWere() {
    let navigation = AppNavigation()
    navigation.maybesPath = [.recommendation("rec-1")]
    navigation.settingsPath = [.tasteProfile]

    navigation.open(.conversation("x"), in: .picks)

    #expect(navigation.maybesPath == [.recommendation("rec-1")])
    #expect(navigation.settingsPath == [.tasteProfile])
    #expect(navigation.watchedPath.isEmpty)
  }

  @Test func switchingTabsPreservesEachTabsPath() {
    let navigation = AppNavigation()
    navigation.picksPath = [.conversation("conv-1"), .recommendation("rec-1")]
    navigation.settingsPath = [.tasteProfile]

    for tab in [AppTab.settings, .maybes, .watched, .picks] {
      navigation.selectedTab = tab
    }

    #expect(navigation.selectedTab == .picks)
    #expect(navigation.picksPath == [.conversation("conv-1"), .recommendation("rec-1")])
    #expect(navigation.settingsPath == [.tasteProfile])
    #expect(navigation.maybesPath.isEmpty)
  }

  @Test(arguments: AppTab.allCases)
  func popToRootClearsOnlyThatTabsPath(_ tab: AppTab) {
    let navigation = AppNavigation()
    navigation.picksPath = [.conversation("conv-1")]
    navigation.maybesPath = [.recommendation("rec-1")]
    navigation.watchedPath = [.recommendation("rec-2")]
    navigation.settingsPath = [.tasteProfile]
    navigation.selectedTab = .maybes

    navigation.popToRoot(tab)

    for other in AppTab.allCases {
      #expect(navigation.path(for: other).isEmpty == (other == tab))
    }
    #expect(navigation.selectedTab == .maybes)
  }

  @Test func tabsInOrderWithTitlesAndSymbols() {
    #expect(AppTab.allCases == [.picks, .maybes, .watched, .settings])
    #expect(AppTab.allCases.map(\.title) == ["Picks", "Maybes", "Watched", "Settings"])
    #expect(
      AppTab.allCases.map(\.symbol) == [
        "bubble.left.and.text.bubble.right", "questionmark.circle", "film.stack", "gearshape",
      ])
  }
}

struct MaybesBadgeTests {
  @Test func theBadgeIsTheMaybesCount() {
    let decisions = [
      cachedDecision(.maybe, tmdbID: 1), cachedDecision(.maybe, tmdbID: 2),
      // No pick in its own conversation: not listed, so not counted.
      cachedDecision(.maybe, tmdbID: 3, conversationID: "conv-gone"),
      cachedDecision(.yes, tmdbID: 4),
    ]
    let picks = (1...4).map { cachedPick(id: "rec-\($0)", tmdbID: $0) }

    #expect(maybesBadgeCount(decisions: decisions, recommendations: picks) == 2)
    #expect(
      maybesBadgeCount(decisions: decisions, recommendations: picks)
        == maybes(decisions: decisions, recommendations: picks).count)
  }

  @Test func zeroIsNoBadge() {
    #expect(maybesBadgeCount(decisions: [], recommendations: []) == nil)
    #expect(
      maybesBadgeCount(
        decisions: [cachedDecision(.no, tmdbID: 1)],
        recommendations: [cachedPick(id: "rec-1", tmdbID: 1)]) == nil)
    #expect(
      maybesBadgeCount(decisions: [cachedDecision(.maybe, tmdbID: 1)], recommendations: [])
        == nil)
  }
}

extension ScreenSmokeTests {
  /// Every remaining route resolves through the one shared destination.
  @Test func everyRouteResolves() async throws {
    let harness = try await cachedHarness()
    let stats = try decodeFixture(OutcomeStats.self, Fixtures.outcomeStats)
    let routes: [Route] = [
      .conversation("conv-1"), .newConversation, .recommendation("rec-1"), .tasteProfile,
      .recentOutcomes(stats.recent),
    ]

    for route in routes {
      try await render(
        NavigationStack { RouteDestination(route: route, session: harness.session) }
          .environment(harness.session)
          .modelContainer(harness.container),
        for: 0.2)
    }
  }

  /// The tabs render with a pick pushed on both the Picks and the Maybes stacks.
  @Test func tabsRenderWithAPickPushedInPicksAndMaybes() async throws {
    let harness = try await cachedHarness()
    try await harness.session.syncService.ingest(makeDecision(.maybe))
    let navigation = AppNavigation()
    let view = AppTabView(session: harness.session)
      .environment(harness.session)
      .environment(navigation)
      .modelContainer(harness.container)

    try await render(view, for: 0.3)
    #expect(navigation.selectedTab == .picks)

    navigation.open(.recommendation("rec-1"), in: .picks)
    try await render(view, for: 0.3)
    navigation.open(.recommendation("rec-1"), in: .maybes)
    try await render(view, for: 0.3)
    #expect(navigation.picksPath == [.recommendation("rec-1")])
    #expect(navigation.maybesPath == [.recommendation("rec-1")])

    for tab in [AppTab.watched, .settings] {
      navigation.selectedTab = tab
      try await render(view, for: 0.3)
    }
  }
}
