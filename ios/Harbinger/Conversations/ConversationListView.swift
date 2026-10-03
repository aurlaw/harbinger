import SwiftData
import SwiftUI

/// Navigation values for the root stack. Small and `Hashable`; screens look rows up by id.
nonisolated enum Route: Hashable, Sendable {
  case conversation(String)
  case newConversation
  /// A pick card's detail screen.
  case recommendation(String)
  /// Interim settings: the sync status screen (I5 replaces it).
  case settings
}

/// The root screen: conversations, newest first.
struct ConversationListView: View {
  @Environment(AppSession.self) private var session
  @Query(sort: \CachedConversation.updatedAt, order: .reverse)
  private var conversations: [CachedConversation]

  var body: some View {
    List(conversations) { conversation in
      NavigationLink(value: Route.conversation(conversation.id)) {
        ConversationRow(title: conversation.title, updatedAt: conversation.updatedAt)
      }
    }
    .overlay {
      if conversations.isEmpty {
        Text("No conversations yet")
          .foregroundStyle(.secondary)
      }
    }
    .refreshable {
      await session.sync.syncNow()
    }
    .navigationTitle("Harbinger")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        NavigationLink(value: Route.settings) {
          Label("Settings", systemImage: "gearshape")
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        NavigationLink(value: Route.newConversation) {
          Label("New conversation", systemImage: "square.and.pencil")
        }
      }
    }
    .navigationDestination(for: Route.self) { route in
      switch route {
      case .conversation(let id):
        ChatView(session: session, conversationID: id)
      case .newConversation:
        ChatView(session: session, conversationID: nil)
      case .recommendation(let id):
        PickDetailView(recommendationID: id)
      case .settings:
        SyncStatusView(host: session.connection.baseURL.host(), sync: session.sync)
          .navigationTitle("Settings")
      }
    }
  }
}

private struct ConversationRow: View {
  let title: String?
  let updatedAt: Date

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title ?? "Untitled")
        .lineLimit(1)
      Spacer()
      Text(listDateText(updatedAt, now: Date()))
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }
}
