import SwiftData
import SwiftUI

/// One recommendation in the chat: poster, title, year, short reason, decision badge.
struct PickCard: View {
  let pick: CachedRecommendation
  let badge: DecisionBadge?

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Poster(path: pick.posterPath, title: pick.title)
        .frame(width: 60, height: 90)
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline) {
          Text(pick.title)
            .font(.headline)
          if let year = pick.year {
            Text(String(year))
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
          if let badge {
            Image(systemName: badge.symbol)
              .foregroundStyle(badge.color)
              .accessibilityLabel(badge.label)
          }
        }
        Text(pick.whyShort)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
    .contentShape(.rect)
  }
}

extension DecisionBadge {
  var color: Color {
    switch self {
    case .yes: .green
    case .maybe: .orange
    case .no: .secondary
    }
  }
}

/// TMDB poster at `w185`; a neutral shape with the title's initial while loading or missing.
struct Poster: View {
  let path: String?
  let title: String

  var body: some View {
    AsyncImage(url: tmdbImageURL(path: path, size: .w185)) { phase in
      if let image = phase.image {
        image
          .resizable()
          .scaledToFill()
      } else {
        placeholder
      }
    }
    .clipShape(.rect(cornerRadius: 6))
  }

  private var placeholder: some View {
    RoundedRectangle(cornerRadius: 6)
      .fill(Color(.tertiarySystemFill))
      .overlay {
        Text(title.first.map(String.init) ?? "")
          .font(.title2)
          .foregroundStyle(.secondary)
      }
  }
}

/// I3 stand-in for the pick detail screen (I4).
struct RecommendationPlaceholderView: View {
  @Query private var picks: [CachedRecommendation]

  init(recommendationID: String) {
    _picks = Query(filter: #Predicate<CachedRecommendation> { $0.id == recommendationID })
  }

  var body: some View {
    VStack(spacing: 8) {
      Text(picks.first?.title ?? "")
        .font(.title2)
      Text("Details coming in I4")
        .foregroundStyle(.secondary)
    }
    .navigationBarTitleDisplayMode(.inline)
  }
}
