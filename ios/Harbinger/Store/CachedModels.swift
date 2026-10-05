import Foundation
import SwiftData

// The SwiftData read cache. Disposable: everything here is rebuilt from `/sync`.
// Models are `nonisolated` so `SyncService` (a model actor) can create and mutate them.
// Every property except the unique key has a default, so additive schema changes migrate.

@Model
nonisolated final class CachedConversation {
  @Attribute(.unique) var id: String
  var title: String?
  var model: String = ""
  var questionRounds: Int = 0
  var createdAt: Date = Date.distantPast
  var updatedAt: Date = Date.distantPast

  @Relationship(deleteRule: .cascade, inverse: \CachedMessage.conversation)
  var messages: [CachedMessage] = []

  init(id: String) {
    self.id = id
  }

  var orderedMessages: [CachedMessage] {
    messages.sorted { $0.seq < $1.seq }
  }
}

@Model
nonisolated final class CachedMessage {
  @Attribute(.unique) var id: String
  var conversationID: String = ""
  var seq: Int = 0
  /// `MessageRole` raw value — see `messageRole`.
  var role: String = MessageRole.user.rawValue
  var kind: String = "text"
  // Flattened `MessageContent` — see `content`.
  var text: String?
  var justPick: Bool = false
  var chips: [String] = []
  var dropped: Int = 0
  var createdAt: Date = Date.distantPast

  var conversation: CachedConversation?

  @Relationship(deleteRule: .cascade, inverse: \CachedRecommendation.message)
  var recommendations: [CachedRecommendation] = []

  init(id: String) {
    self.id = id
  }

  var orderedRecommendations: [CachedRecommendation] {
    recommendations.sorted { $0.position < $1.position }
  }
}

nonisolated struct CachedProvider: Codable, Sendable, Hashable {
  let name: String
  let type: String
  let logoPath: String?
}

@Model
nonisolated final class CachedRecommendation {
  @Attribute(.unique) var id: String
  var conversationID: String = ""
  var messageID: String = ""
  var position: Int = 0
  var tmdbID: Int = 0
  var title: String = ""
  var year: Int?
  var whyShort: String = ""
  var whyFull: String = ""
  var posterPath: String?
  var runtime: Int?
  var overview: String = ""
  var director: String?
  var providers: [CachedProvider] = []
  var providersLink: String?
  var trailerKey: String?
  var createdAt: Date?

  var message: CachedMessage?

  init(id: String) {
    self.id = id
  }
}

/// One per film, mirroring D1. Separate from `CachedRecommendation`: a film can be
/// recommended in several conversations, and the badge looks up by `tmdbID`.
@Model
nonisolated final class CachedDecision {
  @Attribute(.unique) var tmdbID: Int
  /// `Decision.Choice` raw value — see `choice`.
  var decision: String = ""
  var conversationID: String = ""
  var decidedAt: Date = Date.distantPast

  init(tmdbID: Int) {
    self.tmdbID = tmdbID
  }
}

/// A watched film from `GET /library/watched`. Read-only library data: replaced wholesale
/// from the server, never edited locally.
@Model
nonisolated final class CachedWatchedFilm {
  @Attribute(.unique) var letterboxdURI: String
  var tmdbID: Int?
  var title: String = ""
  var year: Int?
  var halfStars: Int?
  /// `YYYY-MM-DD` (sorts correctly as a string); empty when the export had no date.
  var loggedOn: String = ""
  var posterPath: String?
  var isHorror: Bool = false
  var harbingerPick: Bool = false
  var firstRecommendedAt: Date?

  init(letterboxdURI: String) {
    self.letterboxdURI = letterboxdURI
  }
}

/// Single row.
@Model
nonisolated final class CachedTasteProfile {
  static let key = "profile"

  @Attribute(.unique) var key: String
  var content: String = ""
  var basedOnImportID: Int?
  var updatedAt: Date = Date.distantPast

  init() {
    self.key = Self.key
  }
}

/// Single row.
@Model
nonisolated final class SyncState {
  static let key = "sync"

  @Attribute(.unique) var key: String
  /// The exact server string — never round-tripped through `Date`.
  var nextSince: String?
  var lastSyncedAt: Date?
  var lastImportAt: Date?
  /// The `last_import_at` the cached watched list was fetched for; `nil` when there is none.
  var watchedImportAt: Date?

  init() {
    self.key = Self.key
  }
}
