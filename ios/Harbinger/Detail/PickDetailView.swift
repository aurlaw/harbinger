import SwiftData
import SwiftUI

/// Everything needed to decide on a pick, with the Yes / Maybe / No bar pinned below.
struct PickDetailView: View {
  @Environment(AppSession.self) private var session
  @Query private var picks: [CachedRecommendation]

  init(recommendationID: String) {
    _picks = Query(filter: #Predicate<CachedRecommendation> { $0.id == recommendationID })
  }

  var body: some View {
    if let pick = picks.first {
      PickDetailContent(pick: pick, session: session)
    } else {
      ContentUnavailableView("Pick not found", systemImage: "film")
    }
  }
}

private struct PickDetailContent: View {
  let pick: CachedRecommendation
  @State private var model: PickDetailModel
  @Query private var decisions: [CachedDecision]

  init(pick: CachedRecommendation, session: AppSession) {
    self.pick = pick
    _model = State(initialValue: PickDetailModel(session: session, target: DecisionTarget(pick)))
    let tmdbID = pick.tmdbID
    _decisions = Query(filter: #Predicate<CachedDecision> { $0.tmdbID == tmdbID })
  }

  private var current: Decision.Choice? { decisions.first?.choice }

  var body: some View {
    let info = PickDetailInfo(pick)
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Poster(path: info.posterPath, title: info.title, size: .w500)
          .aspectRatio(2 / 3, contentMode: .fit)
          .frame(maxWidth: 220)
          .frame(maxWidth: .infinity)

        VStack(alignment: .leading, spacing: 6) {
          Text(info.title)
            .font(.largeTitle.bold())
          if !info.metadata.isEmpty {
            Text(info.metadata)
              .foregroundStyle(.secondary)
          }
        }

        DetailSection("Why you'd like it") {
          Text(info.whyFull)
        }
        if let overview = info.overview {
          DetailSection("Overview") {
            Text(overview)
          }
        }
        DetailSection("Where to watch") {
          WhereToWatch(info: info)
        }
        DetailLinks(info: info)
      }
      .padding()
    }
    .navigationTitle(info.title)
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .bottom) {
      DecisionBar(model: model, current: current)
    }
    .sensoryFeedback(.success, trigger: model.savedCount)
  }
}

private struct DetailSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)
      content
    }
  }
}

private struct WhereToWatch: View {
  let info: PickDetailInfo
  @Environment(\.openURL) private var openURL

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if info.providers.isEmpty {
        Text("Not available to stream in the US right now.")
          .foregroundStyle(.secondary)
      } else {
        FlowLayout(spacing: 8) {
          ForEach(info.providers) { provider in
            Button {
              if let url = info.providersURL { openURL(url) }
            } label: {
              ProviderChip(provider: provider)
            }
            .buttonStyle(.plain)
            .disabled(info.providersURL == nil)
          }
        }
      }
      if let url = info.providersURL {
        Link("More options", destination: url)
          .font(.subheadline)
      }
      Text("Streaming availability from JustWatch.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private struct ProviderChip: View {
  let provider: PickDetailInfo.ProviderItem

  var body: some View {
    HStack(spacing: 8) {
      AsyncImage(url: provider.logoURL) { phase in
        if let image = phase.image {
          image.resizable().scaledToFit()
        } else {
          Color(.tertiarySystemFill)
        }
      }
      .frame(width: 28, height: 28)
      .clipShape(.rect(cornerRadius: 6))
      VStack(alignment: .leading, spacing: 0) {
        Text(provider.name)
          .font(.subheadline)
        if let label = provider.label {
          Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 8)
    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
  }
}

private struct DetailLinks: View {
  let info: PickDetailInfo

  var body: some View {
    HStack(spacing: 12) {
      if let url = info.trailerURL {
        Link(destination: url) {
          Label("Trailer", systemImage: "play.rectangle")
        }
        .buttonStyle(.bordered)
      }
      if let url = info.letterboxdURL {
        Link(destination: url) {
          Label("Letterboxd", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(.bordered)
      }
    }
  }
}

/// Yes / Maybe / No. The current decision is prominent; all three are disabled while a
/// decision is saving, with a spinner on the one tapped.
private struct DecisionBar: View {
  let model: PickDetailModel
  let current: Decision.Choice?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private static let choices: [Decision.Choice] = [.yes, .maybe, .no]

  var body: some View {
    VStack(spacing: 8) {
      if let failure = model.failure {
        HStack {
          Label(failure.message, systemImage: "exclamationmark.triangle")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Retry", action: model.retry)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
      }
      // Side by side normally; stacked at accessibility sizes so no label is truncated.
      let layout =
        dynamicTypeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
      layout {
        ForEach(Self.choices, id: \.self) { choice in
          DecisionButton(
            choice: choice, isSelected: choice == current,
            isSaving: model.pending?.choice == choice
          ) {
            model.choose(choice, current: current)
          }
        }
      }
      .disabled(model.isSaving)
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.bar)
  }
}

private struct DecisionButton: View {
  let choice: Decision.Choice
  let isSelected: Bool
  let isSaving: Bool
  let action: () -> Void

  var body: some View {
    let badge = DecisionBadge(choice)
    let button = Button(action: action) {
      HStack(spacing: 6) {
        if isSaving {
          ProgressView()
            .controlSize(.small)
        } else if let badge {
          Image(systemName: badge.symbol)
        }
        Text(badge?.label ?? "")
      }
      .frame(maxWidth: .infinity)
    }
    .controlSize(.large)
    .accessibilityLabel(decisionAccessibilityLabel(choice))
    .accessibilityAddTraits(isSelected ? .isSelected : [])

    if isSelected {
      button.buttonStyle(.borderedProminent)
    } else {
      button.buttonStyle(.bordered)
    }
  }
}
