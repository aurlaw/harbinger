import Foundation
import SwiftData

/// What the cache held just before a turn was sent, to tell later whether its reply has
/// arrived by sync.
nonisolated enum TurnBaseline: Sendable, Equatable {
  /// An existing conversation: how many messages it had.
  case messages(Int)
  /// A new conversation: the conversations that already existed.
  case conversations(Set<String>)
}

// Read-only helpers for turns whose request was cut off. Nothing here writes to the cache.
extension SyncService {
  func turnBaseline(for target: TurnTarget) throws -> TurnBaseline {
    switch target {
    case .conversation(let id):
      return .messages(try messageCount(conversationID: id))
    case .new:
      let rows = try modelContext.fetch(FetchDescriptor<CachedConversation>())
      return .conversations(Set(rows.map(\.id)))
    }
  }

  /// The conversation the turn landed in, once the cache shows it: more messages than the
  /// baseline for an existing conversation, or — for a new one — a conversation that wasn't
  /// there before and starts with the turn's text. `nil` while it hasn't arrived.
  func arrivedConversation(for request: TurnRequest, since baseline: TurnBaseline) throws
    -> String?
  {
    switch (request.target, baseline) {
    case (.conversation(let id), .messages(let before)):
      return try messageCount(conversationID: id) > before ? id : nil
    case (.new, .conversations(let before)):
      let text = request.text
      let firstMessages = try modelContext.fetch(
        FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.seq == 1 && $0.text == text }))
      return
        firstMessages
        .filter { !before.contains($0.conversationID) }
        .max { $0.createdAt < $1.createdAt }?
        .conversationID
    default:
      return nil
    }
  }

  private func messageCount(conversationID: String) throws -> Int {
    try modelContext.fetchCount(
      FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.conversationID == conversationID }))
  }
}
