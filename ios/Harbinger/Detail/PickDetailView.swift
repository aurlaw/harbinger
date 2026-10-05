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
    Group {
      if let pick = picks.first {
        PickDetailContent(pick: pick, session: session)
      } else {
        ContentUnavailableView("Pick not found", systemImage: "film")
      }
    }
    // The decision bar gets the full screen.
    .toolbar(.hidden, for: .tabBar)
  }
}

private struct PickDetailContent: View {
  let pick: CachedRecommendation
  @State private var model: PickDetailModel
  @Query private var decisions: [CachedDecision]
  /// From the poster; `nil` (the system background) until it loads, or without a poster.
  @State private var palette: DetailPalette?
  @Environment(\.colorScheme) private var systemScheme

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
              .foregroundStyle(.detailSecondary)
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
    .background(palette.map { Color($0.background) } ?? Color(.systemBackground))
    .navigationTitle(info.title)
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .bottom) {
      DecisionBar(model: model, current: current)
    }
    // On the poster's color the text switches to whichever appearance reads on it; the
    // accent-colored links and buttons take the text color (the accent has no guaranteed
    // contrast against an arbitrary background); and secondary text (`.detailSecondary`) is
    // a stronger shade than the system's, which the palette's contrast check assumes.
    .tint(palette == nil ? nil : Color.primary)
    .environment(\.detailPalette, palette)
    .environment(\.colorScheme, palette?.colorScheme ?? systemScheme)
    .toolbarColorScheme(palette?.colorScheme, for: .navigationBar)
    .animation(.easeInOut(duration: 0.25), value: palette)
    .task(id: info.posterPath) {
      palette = await loadPosterPalette(path: info.posterPath)
    }
    .sensoryFeedback(.success, trigger: model.savedCount)
  }
}

nonisolated extension EnvironmentValues {
  /// The poster palette the detail screen is drawn on; `nil` on the system background.
  @Entry var detailPalette: DetailPalette?
}

/// Secondary text on the detail screen: the system's secondary label normally, and the text
/// color at `DetailPalette.secondaryOpacity` on a poster-colored background (where the
/// system's is too faint).
nonisolated struct DetailSecondaryStyle: ShapeStyle {
  func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
    environment.detailPalette == nil
      ? AnyShapeStyle(.secondary)
      : AnyShapeStyle(Color.primary.opacity(DetailPalette.secondaryOpacity))
  }
}

extension ShapeStyle where Self == DetailSecondaryStyle {
  nonisolated static var detailSecondary: DetailSecondaryStyle { DetailSecondaryStyle() }
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
          .foregroundStyle(.detailSecondary)
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
        .foregroundStyle(.detailSecondary)
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
            .foregroundStyle(.detailSecondary)
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
            .foregroundStyle(.detailSecondary)
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
  @Environment(\.detailPalette) private var palette

  /// On a poster-colored screen the selected button is filled with the text color, so its
  /// label takes the background color — the pair the palette guarantees contrast for.
  /// `nil` leaves the button style's own label color.
  private var selectedLabel: Color? {
    guard isSelected, let palette else { return nil }
    return Color(palette.background)
  }

  var body: some View {
    let badge = DecisionBadge(choice)
    let button = Button(action: action) {
      // Only overridden when needed: otherwise the button style colors its own label.
      if let selectedLabel {
        label(badge)
          .foregroundStyle(selectedLabel)
      } else {
        label(badge)
      }
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

  private func label(_ badge: DecisionBadge?) -> some View {
    HStack(spacing: 6) {
      if isSaving {
        ProgressView()
          .controlSize(.small)
          .tint(selectedLabel)
      } else if let badge {
        Image(systemName: badge.symbol)
      }
      Text(badge?.label ?? "")
    }
    .frame(maxWidth: .infinity)
  }
}
