import SwiftData
import SwiftUI

/// A conversation: messages, pick cards, and the composer. Also used for a new conversation,
/// which switches to its returned id in place after the first turn.
struct ChatView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: ChatModel
  @State private var actions: ConversationActions

  init(session: AppSession, conversationID: String?) {
    _model = State(initialValue: ChatModel(session: session, conversationID: conversationID))
    _actions = State(initialValue: ConversationActions(session: session))
  }

  /// The conversation was deleted. An error alert (rename's "no longer exists") is read first.
  private var shouldPop: Bool {
    model.shouldDismiss && actions.errorMessage == nil
  }

  var body: some View {
    ChatTranscript(model: model, actions: actions, conversationID: model.conversationID)
      // A new conversation's query restarts once it has an id.
      .id(model.conversationID)
      .safeAreaInset(edge: .bottom) {
        VStack(spacing: 0) {
          if model.showsSuggestions {
            StarterSuggestions(onChoose: model.choose)
          }
          Composer(model: model)
        }
      }
      .navigationBarTitleDisplayMode(.inline)
      .actionErrorAlert(actions)
      .onChange(of: model.arrival, initial: true) {
        model.arrivalChanged()
      }
      .onChange(of: shouldPop) {
        if shouldPop {
          dismiss()
        }
      }
  }
}

/// Fixed suggestions for a new conversation, in the question chips' capsule style.
private struct StarterSuggestions: View {
  let onChoose: (StarterSuggestion) -> Void

  var body: some View {
    FlowLayout(spacing: 8) {
      ForEach(StarterSuggestion.all, id: \.self) { suggestion in
        Button(suggestion.title) { onChoose(suggestion) }
          .buttonStyle(.bordered)
          .buttonBorderShape(.capsule)
          .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal)
    .padding(.vertical, 8)
  }
}

/// The scrolling transcript. Queries by conversation id, so it is rebuilt when the id changes.
private struct ChatTranscript: View {
  let model: ChatModel
  let actions: ConversationActions

  @State private var renameTarget: RenameTarget?
  @Query private var conversations: [CachedConversation]
  @Query private var messages: [CachedMessage]
  @Query private var recommendations: [CachedRecommendation]
  @Query private var decisions: [CachedDecision]

  init(model: ChatModel, actions: ConversationActions, conversationID: String?) {
    self.model = model
    self.actions = actions
    let id = conversationID ?? ""
    _conversations = Query(filter: #Predicate<CachedConversation> { $0.id == id })
    _messages = Query(
      filter: #Predicate<CachedMessage> { $0.conversationID == id }, sort: \.seq)
    _recommendations = Query(
      filter: #Predicate<CachedRecommendation> { $0.conversationID == id }, sort: \.position)
  }

  private var latestMessageID: String? { messages.last?.id }

  private var title: String {
    if model.isNew { return "New conversation" }
    return conversations.first?.title ?? "Untitled"
  }

  var body: some View {
    let picks = Dictionary(grouping: recommendations, by: \.messageID)
    let choices = Dictionary(
      decisions.map { ($0.tmdbID, $0.choice) }, uniquingKeysWith: { first, _ in first })

    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(messages) { message in
            MessageView(
              message: message, picks: picks[message.id] ?? [], choices: choices,
              chipsEnabled: model.chipsEnabled(
                messageID: message.id, latestMessageID: latestMessageID),
              onChip: model.sendChip)
          }
          if let pending = model.pending {
            let request = pending.request
            UserBubble(text: userBubbleText(text: request.text, justPick: request.justPick))
              .opacity(0.6)
            TypingIndicator(startedAt: pending.startedAt)
          }
          if let failure = model.failure {
            ErrorRow(message: failure.message, onRetry: model.retry)
          }
          Color.clear
            .frame(height: 1)
            .id(Self.bottom)
        }
        .padding()
      }
      .defaultScrollAnchor(.bottom)
      // Dragging the transcript down also puts the keyboard away.
      .scrollDismissesKeyboard(.interactively)
      .onChange(of: messages.count) {
        withAnimation { proxy.scrollTo(Self.bottom) }
      }
      .onChange(of: model.pending) {
        withAnimation { proxy.scrollTo(Self.bottom) }
      }
    }
    .navigationTitle(title)
    .toolbar {
      // Existing conversations only: tapping the title renames, as in the list's menu.
      if let conversation = conversations.first {
        ToolbarItem(placement: .principal) {
          Button {
            renameTarget = RenameTarget(id: conversation.id, title: conversation.title)
          } label: {
            HStack(spacing: 4) {
              Text(title)
                .font(.headline)
                .lineLimit(1)
              Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }
          }
          .buttonStyle(.plain)
          .accessibilityHint("Renames the conversation")
        }
      }
    }
    .renameAlert($renameTarget) { id, title in actions.rename(id, to: title) }
    .onChange(of: conversations.isEmpty, initial: true) {
      model.conversationIsCached(!conversations.isEmpty)
    }
  }

  private static let bottom = "bottom"
}

private struct MessageView: View {
  let message: CachedMessage
  let picks: [CachedRecommendation]
  let choices: [Int: Decision.Choice?]
  let chipsEnabled: Bool
  let onChip: (String) -> Void

  var body: some View {
    switch message.content {
    case .user(let text, let justPick):
      UserBubble(text: userBubbleText(text: text, justPick: justPick))
    case .question(let text, let chips):
      VStack(alignment: .leading, spacing: 8) {
        AssistantBubble(text: text)
        if !chips.isEmpty {
          ChipList(chips: chips, isEnabled: chipsEnabled, onChip: onChip)
        }
      }
    case .recommendations:
      VStack(spacing: 10) {
        ForEach(picks) { pick in
          NavigationLink(value: Route.recommendation(pick.id)) {
            PickCard(pick: pick, badge: DecisionBadge(choices[pick.tmdbID] ?? nil))
          }
          .buttonStyle(.plain)
        }
      }
    }
  }
}

struct UserBubble: View {
  let text: String

  var body: some View {
    HStack {
      Spacer(minLength: 48)
      Text(text)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .background(Color.accentColor, in: .rect(cornerRadius: 16))
    }
  }
}

private struct AssistantBubble: View {
  let text: String

  var body: some View {
    HStack {
      Text(text)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
      Spacer(minLength: 48)
    }
  }
}

private struct ChipList: View {
  let chips: [String]
  let isEnabled: Bool
  let onChip: (String) -> Void

  var body: some View {
    FlowLayout(spacing: 8) {
      ForEach(chips, id: \.self) { chip in
        Button(chip) { onChip(chip) }
          .buttonStyle(.bordered)
          .buttonBorderShape(.capsule)
          .controlSize(.small)
      }
    }
    .disabled(!isEnabled)
  }
}

/// Animated dots; after ~20 s a quiet line explains the wait (replacement rounds are slow).
private struct TypingIndicator: View {
  let startedAt: Date

  var body: some View {
    TimelineView(.periodic(from: startedAt, by: 0.4)) { context in
      let elapsed = context.date.timeIntervalSince(startedAt)
      let lit = Int(elapsed / 0.4) % 3
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 4) {
          ForEach(0..<3) { index in
            Circle()
              .frame(width: 7, height: 7)
              .opacity(index == lit ? 0.9 : 0.3)
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
        if elapsed >= 20 {
          Text("Still working on it…")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Harbinger is thinking")
    }
  }
}

private struct ErrorRow: View {
  let message: String
  let onRetry: () -> Void

  var body: some View {
    HStack {
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Spacer()
      Button("Retry", action: onRetry)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
  }
}
