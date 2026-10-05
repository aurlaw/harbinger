import SwiftData
import SwiftUI

/// The root screen: conversations, newest first.
struct ConversationListView: View {
  @Environment(AppSession.self) private var session

  var body: some View {
    ConversationList(session: session)
  }
}

private struct ConversationList: View {
  let session: AppSession
  @Query(sort: \CachedConversation.updatedAt, order: .reverse)
  private var conversations: [CachedConversation]

  @State private var actions: ConversationActions
  /// The conversation whose delete is waiting for confirmation.
  @State private var deleteCandidate: String?
  @State private var renameTarget: RenameTarget?

  init(session: AppSession) {
    self.session = session
    _actions = State(initialValue: ConversationActions(session: session))
  }

  var body: some View {
    List(conversations) { conversation in
      let id = conversation.id
      let isDeleting = actions.isDeleting(id)
      NavigationLink(value: Route.conversation(id)) {
        ConversationRow(
          title: conversation.title, updatedAt: conversation.updatedAt, isDeleting: isDeleting)
      }
      .disabled(isDeleting)
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        // Not offered while a turn is in flight, or while already deleting.
        if actions.canDelete(id) {
          // Tinted rather than `role: .destructive`: the row must stay until the user
          // confirms and the server has deleted it.
          Button("Delete", systemImage: "trash") { deleteCandidate = id }
            .tint(.red)
        }
      }
      .contextMenu {
        Button("Rename", systemImage: "pencil") {
          renameTarget = RenameTarget(id: id, title: conversation.title)
        }
        .disabled(isDeleting)
        Button("Delete", systemImage: "trash", role: .destructive) { deleteCandidate = id }
          .disabled(!actions.canDelete(id))
      }
    }
    .confirmationDialog(
      "Delete this conversation?",
      isPresented: Binding(
        get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }),
      titleVisibility: .visible, presenting: deleteCandidate
    ) { id in
      Button("Delete", role: .destructive) { actions.delete(id) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("Its messages and picks will be removed. Your Yes and No decisions are kept.")
    }
    .renameAlert($renameTarget) { id, title in actions.rename(id, to: title) }
    .actionErrorAlert(actions)
    .overlay {
      if conversations.isEmpty {
        ContentUnavailableView {
          Label("No conversations yet", systemImage: "film.stack")
        } description: {
          Text("Tell Harbinger what you're in the mood for.")
        } actions: {
          NavigationLink("Start a Conversation", value: Route.newConversation)
            .buttonStyle(.borderedProminent)
        }
      }
    }
    // Sync failures never block: a small notice until the next sync succeeds.
    .safeAreaInset(edge: .top, spacing: 0) {
      if let notice = syncNoticeMessage(session.sync.lastFailure) {
        Label(notice, systemImage: "exclamationmark.icloud")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal)
          .padding(.vertical, 6)
          .background(.bar)
      }
    }
    .refreshable {
      await session.sync.syncNow()
    }
    .navigationTitle("Harbinger")
    .toolbar {
      // Maybes and Settings are tabs; New is the only toolbar item.
      ToolbarItem(placement: .topBarTrailing) {
        NavigationLink(value: Route.newConversation) {
          Label("New conversation", systemImage: "square.and.pencil")
        }
        .tint(.accentColor)
      }
    }
  }
}

private struct ConversationRow: View {
  let title: String?
  let updatedAt: Date
  let isDeleting: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title ?? "Untitled")
        .lineLimit(1)
      Spacer()
      if isDeleting {
        ProgressView()
          .controlSize(.small)
      } else {
        Text(listDateText(updatedAt, now: Date()))
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .opacity(isDeleting ? 0.5 : 1)
  }
}
