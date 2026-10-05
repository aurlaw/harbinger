import SwiftUI

/// Navigation values pushed onto a tab's stack. Small and `Hashable`; screens look rows up
/// by id. Maybes and Settings are tabs (`AppTab`), not routes.
nonisolated enum Route: Hashable, Sendable {
  case conversation(String)
  case newConversation
  /// A pick card's detail screen.
  case recommendation(String)
  /// The taste profile editor, pushed from Settings.
  case tasteProfile
  /// The full track record, pushed from the Watched tab's summary row.
  case trackRecord
  /// The track record's recent outcomes, pushed from the track record. Carries the list itself:
  /// outcomes are fetched, not cached, so there is nothing to look up by id.
  case recentOutcomes([Outcome])
}

/// The screen a route pushes. One switch for every tab's stack.
struct RouteDestination: View {
  let route: Route
  let session: AppSession

  var body: some View {
    switch route {
    case .conversation(let id):
      ChatView(session: session, conversationID: id)
    case .newConversation:
      ChatView(session: session, conversationID: nil)
    case .recommendation(let id):
      PickDetailView(recommendationID: id)
    case .tasteProfile:
      TasteProfileEditorView(session: session)
    case .trackRecord:
      TrackRecordView(model: session.trackRecord)
    case .recentOutcomes(let outcomes):
      RecentOutcomesView(outcomes: outcomes)
    }
  }
}

extension View {
  /// Resolves `Route` values for a tab's `NavigationStack`. Every tab applies it: Maybes and
  /// Settings push routes too.
  func routeDestinations(session: AppSession) -> some View {
    navigationDestination(for: Route.self) { route in
      RouteDestination(route: route, session: session)
    }
  }
}
