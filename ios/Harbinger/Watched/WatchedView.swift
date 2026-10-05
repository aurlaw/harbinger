import SwiftData
import SwiftUI

/// The Watched tab: every watched film from the cache, with the track record as its header.
struct WatchedView: View {
  @Environment(AppSession.self) private var session

  var body: some View {
    WatchedList(session: session)
  }
}

private struct WatchedList: View {
  let session: AppSession
  @Query private var films: [CachedWatchedFilm]
  @Query private var states: [SyncState]
  @Environment(\.openURL) private var openURL

  // Genre, picks-only, and sort persist; search doesn't.
  @AppStorage("watchedGenre") private var genre = WatchedGenre.all
  @AppStorage("watchedPicksOnly") private var picksOnly = false
  @AppStorage("watchedSort") private var sort = WatchedSort.logged
  @State private var search = ""

  var body: some View {
    let options = WatchedOptions(genre: genre, picksOnly: picksOnly, sort: sort, search: search)
    let rows = watchedRows(films.map { WatchedRowInput($0) }, options: options)

    List {
      Section {
        NavigationLink(value: Route.trackRecord) {
          TrackRecordSummaryRow(content: session.trackRecord.content)
        }
      }

      Section {
        Picker("Genre", selection: $genre) {
          ForEach(WatchedGenre.allCases, id: \.self) { genre in
            Text(genre.title).tag(genre)
          }
        }
        .pickerStyle(.segmented)

        if films.isEmpty {
          ContentUnavailableView(
            "No watched films", systemImage: "film.stack",
            description: Text(
              states.first?.lastImportAt == nil
                ? "Import your Letterboxd export to see them here."
                : "Pull down to load them."))
        } else if rows.isEmpty {
          if options.trimmedSearch.isEmpty {
            ContentUnavailableView(
              "No films match", systemImage: "line.3.horizontal.decrease.circle",
              description: Text("Try changing the filters."))
          } else {
            ContentUnavailableView.search(text: options.trimmedSearch)
          }
        } else {
          ForEach(rows) { film in
            Button {
              if let url = watchedURL(film.letterboxdURI) {
                openURL(url)
              }
            } label: {
              WatchedRow(film: film)
            }
            .foregroundStyle(.primary)
          }
        }
      } header: {
        // How many films the list below is showing, after the filters and search.
        if !films.isEmpty {
          Text(watchedCountText(rows.count))
            .textCase(nil)
        }
      }
    }
    .searchable(text: $search)
    // A failed refresh keeps the cached list: a small notice until the next one succeeds.
    .safeAreaInset(edge: .top, spacing: 0) {
      if let notice = syncNoticeMessage(session.sync.watchedFailure) {
        Label(notice, systemImage: "exclamationmark.icloud")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal)
          .padding(.vertical, 6)
          .background(.bar)
      }
    }
    .refreshable {
      async let watched: Void = session.sync.refreshWatched()
      async let record: Void = session.trackRecord.load()
      _ = await (watched, record)
    }
    .task { await session.trackRecord.load() }
    .navigationTitle("Watched")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Picker("Sort", selection: $sort) {
            ForEach(WatchedSort.allCases, id: \.self) { sort in
              Text(sort.title).tag(sort)
            }
          }
          Toggle("Harbinger picks only", isOn: $picksOnly)
        } label: {
          Label("Sort and filter", systemImage: "line.3.horizontal.decrease.circle")
        }
      }
    }
  }
}

/// The track record in one line; opens the full track record.
private struct TrackRecordSummaryRow: View {
  let content: TrackRecordContent

  var body: some View {
    switch content {
    case .loading:
      HStack(spacing: 8) {
        Text("Track record")
        Spacer()
        ProgressView()
      }
    case .stats(let stats):
      if let percent = percentText(stats.hitRate) {
        Text("Hit rate \(Text(percent).bold()) · \(ratedPicksText(stats))")
          .accessibilityLabel(trackRecordSummaryText(content) ?? "")
      } else {
        Text(ratedPicksText(stats))
      }
    case .failed, .noPicks, .noneRated:
      Text(trackRecordSummaryText(content) ?? "")
        .foregroundStyle(.secondary)
    }
  }
}

private struct WatchedRow: View {
  let film: WatchedRowInput

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Poster(path: film.posterPath, title: film.title, size: .w92)
        .frame(width: 40, height: 60)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(film.title)
          if let year = film.year {
            Text(String(year))
              .foregroundStyle(.secondary)
          }
          if film.harbingerPick {
            Image(systemName: "sparkles")
              .foregroundStyle(.tint)
          }
        }
        Text(watchedRatingText(halfStars: film.halfStars))
          .font(.subheadline)
          .foregroundStyle(film.halfStars == nil ? .secondary : .primary)
        if let logged = loggedText(film.loggedOn) {
          Text(logged)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .contentShape(.rect)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(watchedAccessibilityLabel(film))
    .accessibilityHint("Opens Letterboxd")
    .accessibilityAddTraits(.isButton)
  }
}
