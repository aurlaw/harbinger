import SwiftData
import SwiftUI

/// The taste profile as plain text: draft (or redraft) it with Claude, edit, save.
struct TasteProfileEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: TasteProfileEditorModel
  @Query private var profiles: [CachedTasteProfile]

  init(session: AppSession) {
    _model = State(initialValue: TasteProfileEditorModel(session: session))
  }

  var body: some View {
    @Bindable var model = model

    // Not a `Form`: a form row can't grow, and the editor should fill the screen (and
    // shrink above the keyboard) so the profile is edited without a tiny scrolling box.
    VStack(alignment: .leading, spacing: 12) {
      if model.isDrafting {
        HStack(spacing: 8) {
          ProgressView()
          Text("Drafting…")
        }
      }
      if model.isFirstDraft {
        Text("First draft — review it, then save.")
          .font(.subheadline)
      } else if !model.changes.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("Changes in this draft")
            .font(.footnote)
            .foregroundStyle(.secondary)
          ForEach(model.changes, id: \.self) { change in
            Text("• \(change)")
              .font(.subheadline)
          }
        }
      }
      TextEditor(text: $model.text)
        .disabled(model.isBusy)
        .scrollContentBackground(.hidden)
        .padding(8)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        .frame(maxHeight: .infinity)
      VStack(alignment: .leading, spacing: 4) {
        if model.isOverLimit {
          Text("\(model.length) / \(ProfileLimit.maxLength)")
            .foregroundStyle(.red)
        }
        Text("Your Notes section is kept when you redraft.")
          .foregroundStyle(.secondary)
      }
      .font(.footnote)
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(Color(.systemGroupedBackground))
    .navigationTitle("Taste profile")
    .navigationBarTitleDisplayMode(.inline)
    // With unsaved edits the system back button (and the back swipe) is replaced by one
    // that asks first.
    .navigationBarBackButtonHidden(model.isDirty)
    .toolbar {
      if model.isDirty {
        ToolbarItem(placement: .topBarLeading) {
          Button("Back", systemImage: "chevron.backward") {
            if model.requestLeave() {
              dismiss()
            }
          }
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button(model.draftTitle, action: model.requestDraft)
          .disabled(model.isBusy)
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save", action: model.save)
          .disabled(!model.canSave)
      }
    }
    .confirmationDialog(
      "Replace your unsaved edits with a new draft?", isPresented: $model.isConfirmingDraft,
      titleVisibility: .visible
    ) {
      Button("Replace", role: .destructive, action: model.confirmDraft)
      Button("Cancel", role: .cancel) {}
    }
    .confirmationDialog(
      "Discard your unsaved changes?", isPresented: $model.isConfirmingDiscard,
      titleVisibility: .visible
    ) {
      Button("Discard Changes", role: .destructive) { dismiss() }
      Button("Keep Editing", role: .cancel) {}
    }
    .alert(
      model.errorMessage ?? "",
      isPresented: Binding(
        get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    ) {
      Button("OK", role: .cancel) {}
    }
    .onChange(of: profiles.first?.content, initial: true) {
      model.cacheChanged(profiles.first?.content ?? "")
    }
  }
}
