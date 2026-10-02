import Foundation
import SwiftData
import Testing

@testable import Harbinger

struct CacheStoreTests {
  struct OpenFailed: Error {}

  let directory = FileManager.default.temporaryDirectory
    .appending(path: "CacheStoreTests-\(UUID().uuidString)")
  var url: URL { directory.appending(path: "Harbinger.store") }
  var files: [URL] {
    ["", "-wal", "-shm"].map { URL(fileURLWithPath: url.path(percentEncoded: false) + $0) }
  }

  func writeStaleStore() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for file in files {
      try Data("stale".utf8).write(to: file)
    }
  }

  func existing() -> [URL] {
    files.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
  }

  @Test func failedOpenDeletesTheStoreAndRetriesOnce() throws {
    try writeStaleStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    var attempts: [[URL]] = []

    let container = try CacheStore.openOrRebuild(at: url) { _ in
      attempts.append(existing())
      if attempts.count == 1 { throw OpenFailed() }
      return try CacheStore.inMemory()
    }

    // First attempt saw the stale files; the retry saw none.
    #expect(attempts == [files, []])
    #expect(try ModelContext(container).fetch(FetchDescriptor<CachedConversation>()).isEmpty)
  }

  @Test func secondFailureIsThrown() throws {
    try writeStaleStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    var attempts = 0

    #expect(throws: OpenFailed.self) {
      try CacheStore.openOrRebuild(at: url) { _ in
        attempts += 1
        throw OpenFailed()
      }
    }
    #expect(attempts == 2)
    #expect(existing().isEmpty)
  }

  @Test func healthyStoreIsNotDeleted() throws {
    defer { try? FileManager.default.removeItem(at: directory) }

    do {
      let container = try CacheStore.openOrRebuild(at: url)
      let context = ModelContext(container)
      context.insert(CachedConversation(id: "conv-1"))
      try context.save()
    }
    let reopened = try CacheStore.openOrRebuild(at: url)

    let rows = try ModelContext(reopened).fetch(FetchDescriptor<CachedConversation>())
    #expect(rows.map(\.id) == ["conv-1"])
  }

  @Test func unreadableStoreIsRebuilt() throws {
    try writeStaleStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let container = try CacheStore.openOrRebuild(at: url)

    #expect(try ModelContext(container).fetch(FetchDescriptor<CachedConversation>()).isEmpty)
  }

  /// The host app must not open the live store or sync while tests run.
  @Test func hostAppKnowsItIsHostingTests() {
    #expect(isHostingTests)
  }

  @Test func defaultStoreLivesInApplicationSupport() {
    let url = CacheStore.defaultURL()
    #expect(url.lastPathComponent == "Harbinger.store")
    #expect(url.deletingLastPathComponent() == URL.applicationSupportDirectory)
  }
}
