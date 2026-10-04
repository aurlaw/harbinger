import Foundation
import Observation

/// Decides when to sync and exposes progress to the UI. Sync errors are non-fatal.
///
/// One instance lives as long as the root view; the service is attached with `connect`
/// once a connection exists. Views must be given the controller on their first render:
/// a `List` keeps the `.refreshable` action it was first given, so a controller that
/// starts out `nil` would leave pull-to-refresh doing nothing.
@Observable
final class SyncController {
  /// Launch / foreground syncs are skipped when the last success is newer than this.
  static let minimumInterval: TimeInterval = 30

  private(set) var isSyncing = false
  /// User-readable; cleared by the next successful sync.
  private(set) var lastError: String?

  private var service: (any SyncServicing)?
  private let now: () -> Date
  private var lastSuccess: Date?
  private var running = 0

  init(service: (any SyncServicing)? = nil, now: @escaping () -> Date = Date.init) {
    self.service = service
    self.now = now
  }

  /// Attaches the service for a (new) connection. The next `syncIfStale()` always runs.
  func connect(_ service: any SyncServicing) {
    self.service = service
    lastSuccess = nil
    lastError = nil
  }

  /// Launch and foreground: syncs unless one succeeded within `minimumInterval`.
  func syncIfStale() async {
    if let lastSuccess, now().timeIntervalSince(lastSuccess) < Self.minimumInterval {
      return
    }
    await syncNow()
  }

  /// A (new) connection's first sync. A different endpoint is a different server, so the
  /// cache is rebuilt from it instead of synced on top of the old server's rows.
  func start(endpointChanged: Bool) async {
    if endpointChanged {
      await rebuild()
    } else {
      await syncIfStale()
    }
  }

  /// Manual (pull-to-refresh): always syncs. Does nothing until a service is connected.
  func syncNow() async {
    await run(rebuild: false)
  }

  /// Clears the cache and pulls everything again (Settings, and an endpoint change).
  func rebuild() async {
    await run(rebuild: true)
  }

  private func run(rebuild: Bool) async {
    guard let service else { return }
    running += 1
    isSyncing = true
    defer {
      running -= 1
      isSyncing = running > 0
    }
    do {
      _ = rebuild ? try await service.resetAndSync() : try await service.sync()
      lastSuccess = now()
      lastError = nil
    } catch {
      lastError = Self.message(for: error)
    }
  }

  static func message(for error: SyncError) -> String {
    switch error {
    case .api(.unauthorized): "API key rejected"
    case .api(.network): "Can't reach endpoint"
    case .api(.server(_, let code, _, _)): "Server error (\(code))"
    case .api(.decoding), .api(.invalidResponse): "Unexpected response from the server"
    case .store: "Couldn't update the local cache"
    }
  }
}
