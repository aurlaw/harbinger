import Foundation
import Observation

/// The root tabs, in tab-bar order.
nonisolated enum AppTab: Hashable, Sendable, CaseIterable {
  case picks
  case maybes
  case watched
  case settings

  var title: String {
    switch self {
    case .picks: "Picks"
    case .maybes: "Maybes"
    case .watched: "Watched"
    case .settings: "Settings"
    }
  }

  var symbol: String {
    switch self {
    case .picks: "bubble.left.and.text.bubble.right"
    case .maybes: "questionmark.circle"
    case .watched: "film.stack"
    case .settings: "gearshape"
    }
  }
}

/// Where the app is: the selected tab and each tab's own stack. Created with the session
/// and injected with `.environment(_:)`. The selection is never persisted — every launch
/// (and every new session) starts on Picks.
@Observable
final class AppNavigation {
  var selectedTab: AppTab = .picks
  var picksPath: [Route] = []
  var maybesPath: [Route] = []
  var watchedPath: [Route] = []
  var settingsPath: [Route] = []

  func path(for tab: AppTab) -> [Route] {
    switch tab {
    case .picks: picksPath
    case .maybes: maybesPath
    case .watched: watchedPath
    case .settings: settingsPath
    }
  }

  /// Selects `tab` and replaces its stack with just `route` (deep links). Other tabs keep
  /// their place.
  func open(_ route: Route, in tab: AppTab) {
    setPath([route], for: tab)
    selectedTab = tab
  }

  /// Clears only that tab's stack; the selection is unchanged.
  func popToRoot(_ tab: AppTab) {
    setPath([], for: tab)
  }

  private func setPath(_ path: [Route], for tab: AppTab) {
    switch tab {
    case .picks: picksPath = path
    case .maybes: maybesPath = path
    case .watched: watchedPath = path
    case .settings: settingsPath = path
    }
  }
}

/// The Maybes tab's badge: how many films the Maybes screen lists. `nil` (no badge) for none.
nonisolated func maybesBadgeCount(
  decisions: [CachedDecision], recommendations: [CachedRecommendation]
) -> Int? {
  let count = maybes(decisions: decisions, recommendations: recommendations).count
  return count > 0 ? count : nil
}
