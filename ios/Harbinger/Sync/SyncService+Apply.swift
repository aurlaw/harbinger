import Foundation
import OSLog
import SwiftData

/// Rows to upsert, normalized so `/sync` (flat) and write responses (nested) share one path.
nonisolated struct CacheBatch: Sendable {
  nonisolated struct MessageItem: Sendable {
    let conversationID: String?
    let message: Message
  }

  nonisolated struct RecommendationItem: Sendable {
    let conversationID: String?
    let messageID: String?
    let recommendation: Recommendation
  }

  var conversations: [Conversation] = []
  var messages: [MessageItem] = []
  var recommendations: [RecommendationItem] = []
  var decisions: [Decision] = []
  /// `nil` means unchanged, never "delete".
  var profile: TasteProfile?

  init(decisions: [Decision] = [], profile: TasteProfile? = nil) {
    self.decisions = decisions
    self.profile = profile
  }

  /// `/sync`: flat collections; children carry their parent ids.
  init(_ response: SyncResponse) {
    conversations = response.conversations
    decisions = response.decisions
    profile = response.tasteProfile
    for message in response.messages {
      add(message, conversationID: message.conversationId)
    }
    for recommendation in response.recommendations {
      recommendations.append(
        RecommendationItem(
          conversationID: recommendation.conversationId, messageID: recommendation.messageId,
          recommendation: recommendation))
    }
  }

  /// A conversation response: messages belong to its conversation, recommendations are nested.
  init(_ response: ConversationResponse) {
    conversations = [response.conversation]
    for message in response.messages {
      add(message, conversationID: response.conversation.id)
    }
  }

  private mutating func add(_ message: Message, conversationID: String?) {
    messages.append(MessageItem(conversationID: conversationID, message: message))
    for recommendation in message.recommendations ?? [] {
      recommendations.append(
        RecommendationItem(
          conversationID: conversationID, messageID: message.id, recommendation: recommendation))
    }
  }
}

// Upsert rules, shared by `sync()` and the ingest helpers:
// - one fetch per model for the incoming ids, then update in place or insert
//   (never rely on `@Attribute(.unique)` insert collisions)
// - order: conversations → messages → recommendations → decisions → profile
// - a child whose parent is neither in the batch nor cached is skipped and logged
// - empty arrays and a nil profile mean "no change"; nothing is ever deleted here
// - applying the same batch twice leaves identical state
extension SyncService {
  /// Applies `batch` to the context **without saving**. The caller saves or rolls back.
  func apply(_ batch: CacheBatch) throws -> SyncResult {
    var result = SyncResult()

    var conversations = try cachedConversations(ids: batch.conversations.map(\.id))
    for dto in batch.conversations {
      let row = conversations[dto.id] ?? inserted(CachedConversation(id: dto.id))
      conversations[dto.id] = row
      row.apply(dto)
      result.conversations += 1
    }

    // Parents that aren't in this batch may already be cached (ingest, or a later delta).
    let otherConversations = Set(batch.messages.compactMap(\.conversationID))
      .subtracting(conversations.keys)
    if !otherConversations.isEmpty {
      conversations.merge(try cachedConversations(ids: Array(otherConversations))) { old, _ in old }
    }

    var messages = try cachedMessages(ids: batch.messages.map(\.message.id))
    for item in batch.messages {
      guard let conversationID = item.conversationID, let parent = conversations[conversationID]
      else {
        log.error(
          "Skipped message \(item.message.id, privacy: .public): its conversation isn't cached")
        continue
      }
      let row = messages[item.message.id] ?? inserted(CachedMessage(id: item.message.id))
      messages[item.message.id] = row
      row.apply(item.message, conversationID: conversationID)
      row.conversation = parent
      result.messages += 1
    }

    let otherMessages = Set(batch.recommendations.compactMap(\.messageID))
      .subtracting(messages.keys)
    if !otherMessages.isEmpty {
      messages.merge(try cachedMessages(ids: Array(otherMessages))) { old, _ in old }
    }

    var recommendations = try cachedRecommendations(
      ids: batch.recommendations.map(\.recommendation.id))
    for item in batch.recommendations {
      let dto = item.recommendation
      guard let messageID = item.messageID, let parent = messages[messageID] else {
        log.error("Skipped recommendation \(dto.id, privacy: .public): its message isn't cached")
        continue
      }
      let row = recommendations[dto.id] ?? inserted(CachedRecommendation(id: dto.id))
      recommendations[dto.id] = row
      row.apply(
        dto, conversationID: item.conversationID ?? parent.conversationID, messageID: messageID)
      row.message = parent
      result.recommendations += 1
    }

    var decisions = try cachedDecisions(tmdbIDs: batch.decisions.map(\.tmdbId))
    for dto in batch.decisions {
      let row = decisions[dto.tmdbId] ?? inserted(CachedDecision(tmdbID: dto.tmdbId))
      decisions[dto.tmdbId] = row
      row.apply(dto)
      result.decisions += 1
    }

    if let profile = batch.profile {
      let cached = try modelContext.fetch(FetchDescriptor<CachedTasteProfile>()).first
      (cached ?? inserted(CachedTasteProfile())).apply(profile)
      result.profileUpdated = true
    }

    return result
  }

  private func inserted<Model: PersistentModel>(_ row: Model) -> Model {
    modelContext.insert(row)
    return row
  }

  private func cachedConversations(ids: [String]) throws -> [String: CachedConversation] {
    guard !ids.isEmpty else { return [:] }
    let rows = try modelContext.fetch(
      FetchDescriptor<CachedConversation>(predicate: #Predicate { ids.contains($0.id) }))
    return Dictionary(rows.map { ($0.id, $0) }) { first, _ in first }
  }

  private func cachedMessages(ids: [String]) throws -> [String: CachedMessage] {
    guard !ids.isEmpty else { return [:] }
    let rows = try modelContext.fetch(
      FetchDescriptor<CachedMessage>(predicate: #Predicate { ids.contains($0.id) }))
    return Dictionary(rows.map { ($0.id, $0) }) { first, _ in first }
  }

  private func cachedRecommendations(ids: [String]) throws -> [String: CachedRecommendation] {
    guard !ids.isEmpty else { return [:] }
    let rows = try modelContext.fetch(
      FetchDescriptor<CachedRecommendation>(predicate: #Predicate { ids.contains($0.id) }))
    return Dictionary(rows.map { ($0.id, $0) }) { first, _ in first }
  }

  private func cachedDecisions(tmdbIDs: [Int]) throws -> [Int: CachedDecision] {
    guard !tmdbIDs.isEmpty else { return [:] }
    let rows = try modelContext.fetch(
      FetchDescriptor<CachedDecision>(predicate: #Predicate { tmdbIDs.contains($0.tmdbID) }))
    return Dictionary(rows.map { ($0.tmdbID, $0) }) { first, _ in first }
  }
}
