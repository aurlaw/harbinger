import SwiftData
import SwiftUI

/// Every film marked Maybe, newest first: open the pick, or promote it to Yes or No.
struct MaybesView: View {
  @Environment(AppSession.self) private var session

  var body: some View {
    MaybesList(session: session)
  }
}

private struct MaybesList: View {
  @Query private var decisions: [CachedDecision]
  @Query private var recommendations: [CachedRecommendation]
  @State private var model: MaybesModel

  init(session: AppSession) {
    let maybe = Decision.Choice.maybe.rawValue
    _decisions = Query(filter: #Predicate<CachedDecision> { $0.decision == maybe })
    _model = State(initialValue: MaybesModel(session: session))
  }

  var body: some View {
    @Bindable var model = model
    // Recomputed whenever either query changes, so a promotion from anywhere (here, the
    // detail screen, a sync) updates the list.
    let items = maybes(decisions: decisions, recommendations: recommendations)

    List(items) { item in
      let isSaving = model.isSaving(item)
      NavigationLink(value: Route.recommendation(item.recommendationID)) {
        MaybeRow(item: item, isSaving: isSaving)
      }
      .disabled(isSaving)
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        if !isSaving {
          // Tinted rather than `role: .destructive`: the row must stay until the user
          // confirms and the server has saved the No.
          Button("No", systemImage: "xmark") { model.askNo(item) }
            .tint(.red)
          Button("Yes", systemImage: "checkmark") { model.promoteToYes(item) }
            .tint(.green)
        }
      }
    }
    .confirmationDialog(
      "Never recommend this film?",
      isPresented: Binding(
        get: { model.noCandidate != nil }, set: { if !$0 { model.noCandidate = nil } }),
      titleVisibility: .visible
    ) {
      Button("No — Never Recommend", role: .destructive, action: model.confirmNo)
      Button("Cancel", role: .cancel) {}
    }
    .alert(
      model.errorMessage ?? "",
      isPresented: Binding(
        get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    ) {
      Button("OK", role: .cancel) {}
    }
    .overlay {
      if items.isEmpty {
        ContentUnavailableView(
          "No Maybes", systemImage: "questionmark.circle",
          description: Text("Tap Maybe on a pick to save it for later."))
      }
    }
    .navigationTitle("Maybes")
  }
}

/// A compact pick card: poster, title + year, the short reason, and when it was saved.
private struct MaybeRow: View {
  let item: MaybeItem
  let isSaving: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Poster(path: item.posterPath, title: item.title)
        .frame(width: 50, height: 75)
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline) {
          Text(item.title)
            .font(.headline)
          if let year = item.year {
            Text(String(year))
              .foregroundStyle(.secondary)
          }
        }
        Text(item.whyShort)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Text(maybeSavedText(decidedAt: item.decidedAt))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if isSaving {
        ProgressView()
          .controlSize(.small)
      }
    }
    .opacity(isSaving ? 0.5 : 1)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(maybeAccessibilityLabel(item))
    .accessibilityHint("Shows details")
  }
}
