import SwiftUI

/// The most recent rated picks, in the server's order. Read-only: a row opens the film on
/// Letterboxd.
struct RecentOutcomesView: View {
  let outcomes: [Outcome]
  @Environment(\.openURL) private var openURL

  var body: some View {
    List(outcomes, id: \.tmdbId) { outcome in
      Button {
        openLetterboxd(for: outcome) { openURL($0) }
      } label: {
        OutcomeRow(info: OutcomeRowInfo(outcome))
      }
      .foregroundStyle(.primary)
    }
    .navigationTitle("Recent outcomes")
  }
}

private struct OutcomeRow: View {
  let info: OutcomeRowInfo

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(info.title)
        Text(info.subtitle)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Text(info.rating)
      Image(systemName: info.markerSymbol)
        .foregroundStyle(.secondary)
        .accessibilityLabel(info.markerLabel)
    }
  }
}
