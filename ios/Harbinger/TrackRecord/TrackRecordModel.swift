import Foundation
import Observation

/// What the Track record section shows.
nonisolated enum TrackRecordContent: Equatable, Sendable {
  /// The first load is in flight (or hasn't started).
  case loading
  /// The first load failed; there is no earlier value to show.
  case failed(String)
  /// Nothing has been recommended yet.
  case noPicks
  /// Picks exist, but none have been rated.
  case noneRated(recommended: Int)
  case stats(OutcomeStats)
}

/// The track record, owned by the session. Fetched, never cached: the stats are derived on the
/// server from ratings that change only on import, and are looked at only occasionally.
@Observable
final class TrackRecordModel {
  private let client: any APIClient

  /// The last loaded stats; kept while a refresh is in flight and when one fails.
  private(set) var stats: OutcomeStats?
  /// The last load's error; cleared by the next success.
  private(set) var error: String?
  private(set) var isLoading = false

  init(client: any APIClient) {
    self.client = client
  }

  var content: TrackRecordContent {
    guard let stats else { return error.map { TrackRecordContent.failed($0) } ?? .loading }
    if stats.recommended == 0 { return .noPicks }
    if stats.rated == 0 { return .noneRated(recommended: stats.recommended) }
    return .stats(stats)
  }

  /// A failed refresh, shown under the stats it couldn't replace.
  var refreshError: String? {
    stats == nil ? nil : error
  }

  /// Runs when the Watched tab or the track-record screen appears, and on their
  /// pull-to-refresh. A call made while one is in
  /// flight does nothing.
  func load() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      stats = try await client.outcomeStats()
      error = nil
    } catch {
      self.error = trackRecordErrorMessage(error)
    }
  }
}
