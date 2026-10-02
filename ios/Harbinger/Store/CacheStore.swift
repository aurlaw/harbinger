import Foundation
import SwiftData

/// The one `ModelContainer` for the cache: created once at app start and shared by the
/// views and `SyncService`.
nonisolated enum CacheStore {
  static func schema() -> Schema {
    Schema([
      CachedConversation.self, CachedMessage.self, CachedRecommendation.self,
      CachedDecision.self, CachedTasteProfile.self, SyncState.self,
    ])
  }

  static func defaultURL() -> URL {
    URL.applicationSupportDirectory.appending(path: "Harbinger.store")
  }

  static func open(at url: URL) throws -> ModelContainer {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let schema = schema()
    let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
    return try ModelContainer(for: schema, configurations: configuration)
  }

  static func inMemory() throws -> ModelContainer {
    let schema = schema()
    let configuration = ModelConfiguration(
      UUID().uuidString, schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    return try ModelContainer(for: schema, configurations: configuration)
  }

  /// The cache is disposable: if the store can't be opened (e.g. an incompatible schema
  /// change), delete it and try **once** more. It refills from a full `/sync`.
  static func openOrRebuild(
    at url: URL, open: (URL) throws -> ModelContainer = CacheStore.open
  ) throws -> ModelContainer {
    do {
      return try open(url)
    } catch {
      deleteStore(at: url)
      return try open(url)
    }
  }

  /// The SQLite file plus its write-ahead log and shared-memory siblings.
  static func deleteStore(at url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      let file = URL(fileURLWithPath: url.path(percentEncoded: false) + suffix)
      try? FileManager.default.removeItem(at: file)
    }
  }

  static func live() -> ModelContainer {
    do {
      return try openOrRebuild(at: defaultURL())
    } catch {
      fatalError("Couldn't create the cache store, even after deleting it: \(error)")
    }
  }
}
