import SwiftUI

/// Draft field, Send, and Just pick. Pinned under the transcript.
struct Composer: View {
  @Bindable var model: ChatModel

  var body: some View {
    VStack(alignment: .trailing, spacing: 4) {
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
        Button("Just pick", action: model.justPick)
          .buttonStyle(.bordered)
          .disabled(!model.canJustPick)
        Button(action: model.send) {
          Image(systemName: "arrow.up.circle.fill")
            .font(.title)
        }
        .disabled(!model.canSend)
        .accessibilityLabel("Send")
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.bar)
  }
}
