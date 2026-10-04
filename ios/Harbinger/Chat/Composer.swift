import SwiftData
import SwiftUI

/// Pinned under the transcript, in two rows: the draft field and Send, then the model and
/// Just pick.
struct Composer: View {
  @Bindable var model: ChatModel
  @FocusState private var isEditing: Bool

  var body: some View {
    VStack(alignment: .trailing, spacing: 8) {
      if model.isOverLimit {
        Text("\(model.draftLength) / \(MessageLimit.maxLength)")
          .font(.caption)
          .foregroundStyle(.red)
      }
      HStack(alignment: .bottom, spacing: 8) {
        TextField("What are you in the mood for?", text: $model.draft, axis: .vertical)
          .lineLimit(1...5)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 18))
          .focused($isEditing)
        Button(action: model.send) {
          Image(systemName: "arrow.up.circle.fill")
            .font(.title)
        }
        .disabled(!model.canSend)
        .accessibilityLabel("Send")
      }
      HStack(spacing: 8) {
        ModelControl(model: model)
        Spacer(minLength: 8)
        // The keyboard covers the transcript, and a multi-line field has no Return-to-dismiss.
        if isEditing {
          Button("Hide keyboard", systemImage: "keyboard.chevron.compact.down") {
            isEditing = false
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.bordered)
        }
        Button("Just pick", action: model.justPick)
          .buttonStyle(.bordered)
          .disabled(!model.canJustPick)
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.bar)
  }
}

/// The model in use. A new conversation can choose it (the model is fixed once the
/// conversation exists); an existing one shows its own, read-only.
private struct ModelControl: View {
  @Bindable var model: ChatModel

  var body: some View {
    if let id = model.conversationID {
      ConversationModelLabel(conversationID: id)
        // The query is fixed at init: restart it when a new conversation gets its id.
        .id(id)
    } else if let allowed = model.session.allowedModels {
      Menu {
        Picker("Model", selection: $model.selectedModel) {
          ForEach(allowed, id: \.self) { name in
            Text(name).tag(Optional(name))
          }
        }
      } label: {
        // The choice made here, else the saved default, else the server default.
        ModelLabel(name: model.model ?? "Server default")
      }
      .disabled(model.isSending)
      .accessibilityLabel("Model")
      .accessibilityValue(model.model ?? "Server default")
    } else {
      // Models didn't load: nothing to choose from, and the server picks.
      ModelLabel(name: "Server default")
        .foregroundStyle(.secondary)
    }
  }
}

/// An existing conversation's model, from the cache.
private struct ConversationModelLabel: View {
  @Query private var conversations: [CachedConversation]

  init(conversationID: String) {
    _conversations = Query(filter: #Predicate<CachedConversation> { $0.id == conversationID })
  }

  var body: some View {
    ModelLabel(name: conversations.first?.model ?? "")
      .foregroundStyle(.secondary)
      .opacity(conversations.isEmpty ? 0 : 1)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Model")
      .accessibilityValue(conversations.first?.model ?? "")
  }
}

private struct ModelLabel: View {
  let name: String

  var body: some View {
    Label(name, systemImage: "cpu")
      .labelStyle(.titleAndIcon)
      .font(.subheadline)
      .lineLimit(1)
      .truncationMode(.middle)
  }
}
