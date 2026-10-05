import SwiftData
import SwiftUI

/// The root of a connected session: four tabs, each with its own `NavigationStack`.
struct AppTabView: View {
  let session: AppSession
  @Environment(AppNavigation.self) private var navigation
  @Environment(\.connectionEditor) private var connectionEditor
  // The Maybes screen's own two queries, for the tab badge.
  @Query private var maybeDecisions: [CachedDecision]
  @Query private var recommendations: [CachedRecommendation]

  init(session: AppSession) {
    self.session = session
    let maybe = Decision.Choice.maybe.rawValue
    _maybeDecisions = Query(filter: #Predicate<CachedDecision> { $0.decision == maybe })
  }

  var body: some View {
    @Bindable var navigation = navigation
    let badge = maybesBadgeCount(decisions: maybeDecisions, recommendations: recommendations)

    TabView(selection: $navigation.selectedTab) {
      Tab(AppTab.picks.title, systemImage: AppTab.picks.symbol, value: AppTab.picks) {
        NavigationStack(path: $navigation.picksPath) {
          ConversationListView()
            .routeDestinations(session: session)
        }
      }
      Tab(AppTab.maybes.title, systemImage: AppTab.maybes.symbol, value: AppTab.maybes) {
        NavigationStack(path: $navigation.maybesPath) {
          MaybesView()
            .routeDestinations(session: session)
        }
      }
      // No badge at all for zero.
      .badge(badge.map { Text(String($0)) })
      Tab(AppTab.watched.title, systemImage: AppTab.watched.symbol, value: AppTab.watched) {
        NavigationStack(path: $navigation.watchedPath) {
          WatchedPlaceholder()
            .routeDestinations(session: session)
        }
      }
      Tab(AppTab.settings.title, systemImage: AppTab.settings.symbol, value: AppTab.settings) {
        NavigationStack(path: $navigation.settingsPath) {
          SettingsView(session: session, editor: connectionEditor)
            .routeDestinations(session: session)
        }
      }
    }
    .tabBarMinimizeBehavior(.onScrollDown)
  }
}

/// Until the Watched screen exists (I11).
private struct WatchedPlaceholder: View {
  var body: some View {
    ContentUnavailableView(
      "Watched", systemImage: "film.stack",
      description: Text("Your watched films will appear here."))
  }
}
