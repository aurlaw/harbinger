import SwiftUI

/// The conversation a rename alert is for.
nonisolated struct RenameTarget: Equatable, Sendable {
  let id: String
  /// The current title; `nil` for "Untitled" (the field starts empty).
  let title: String?
}

extension View {
  /// The rename alert shared by the conversation list and the chat title: a text field
  /// prefilled with the current title, Save (disabled unless the title is valid) and Cancel.
  func renameAlert(
    _ target: Binding<RenameTarget?>, onSave: @escaping (_ id: String, _ title: String) -> Void
  ) -> some View {
    modifier(RenameAlert(target: target, onSave: onSave))
  }

  /// An alert for a failed delete or rename.
  func actionErrorAlert(_ actions: ConversationActions) -> some View {
    alert(
      actions.errorMessage ?? "",
      isPresented: Binding(
        get: { actions.errorMessage != nil },
        set: { if !$0 { actions.errorMessage = nil } })
    ) {
      Button("OK", role: .cancel) {}
    }
  }
}

private struct RenameAlert: ViewModifier {
  @Binding var target: RenameTarget?
  let onSave: (String, String) -> Void
  @State private var text = ""

  func body(content: Content) -> some View {
    content
      .alert(
        "Rename conversation",
        isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
        presenting: target
      ) { target in
        TextField("Title", text: $text)
        Button("Save") { onSave(target.id, text) }
          .disabled(!TitleLimit.isValid(text))
        Button("Cancel", role: .cancel) {}
      }
      .onChange(of: target) {
        if let target {
          text = target.title ?? ""
        }
      }
  }
}
