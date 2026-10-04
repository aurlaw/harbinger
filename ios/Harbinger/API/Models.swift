import Foundation

// DTOs for the Worker's app endpoints — see `api-surface` in the vault.
// Keys are snake_case on the wire (converted by `makeDecoder` / `makeEncoder`).
// Timestamps decode to `Date`, except the sync cursor, which stays the exact server string.

nonisolated struct HealthResponse: Codable, Sendable, Equatable {
  let status: String
}

nonisolated struct ModelsResponse: Codable, Sendable, Equatable {
  let defaultModel: String
  let allowed: [String]

  enum CodingKeys: String, CodingKey {
    case defaultModel = "default"
    case allowed
  }
}

nonisolated struct Conversation: Codable, Sendable, Equatable {
  let id: String
  let title: String?
  let model: String
  let questionRounds: Int
  let createdAt: Date
  let updatedAt: Date
  /// Set on a tombstone (a deleted conversation in a `/sync` delta); absent or `null` when live.
  var deletedAt: Date?
}

/// `POST /conversations`, `POST /conversations/{id}/messages`, `GET /conversations/{id}`.
nonisolated struct ConversationResponse: Codable, Sendable, Equatable {
  let conversation: Conversation
  let messages: [Message]
}

nonisolated enum MessageRole: String, Codable, Sendable, Equatable {
  case user
  case assistant
}

/// A message's `content`, keyed by `role` + `kind` on the wire.
nonisolated enum MessageContent: Sendable, Equatable {
  case user(text: String?, justPick: Bool)
  case question(text: String, chips: [String])
  case recommendations(dropped: Int)
}

nonisolated struct Message: Codable, Sendable, Equatable {
  let id: String
  let seq: Int
  let content: MessageContent
  let createdAt: Date
  /// Present in `/sync` (flat), absent when nested in a conversation response.
  let conversationId: String?
  /// Present on nested recommendations messages; `/sync` sends recommendations flat.
  let recommendations: [Recommendation]?

  var role: MessageRole {
    if case .user = content { return .user }
    return .assistant
  }

  var kind: String {
    switch content {
    case .user: "text"
    case .question: "question"
    case .recommendations: "recommendations"
    }
  }

  enum CodingKeys: String, CodingKey {
    case id, seq, role, kind, content, createdAt, conversationId, recommendations
  }

  private struct UserBody: Codable {
    let text: String?
    let justPick: Bool?
  }

  private struct QuestionBody: Codable {
    let text: String
    let chips: [String]
  }

  private struct RecommendationsBody: Codable {
    let dropped: Int?
  }

  init(
    id: String, seq: Int, content: MessageContent, createdAt: Date,
    conversationId: String? = nil, recommendations: [Recommendation]? = nil
  ) {
    self.id = id
    self.seq = seq
    self.content = content
    self.createdAt = createdAt
    self.conversationId = conversationId
    self.recommendations = recommendations
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    seq = try container.decode(Int.self, forKey: .seq)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId)
    recommendations = try container.decodeIfPresent(
      [Recommendation].self, forKey: .recommendations)

    let role = try container.decode(MessageRole.self, forKey: .role)
    let kind = try container.decode(String.self, forKey: .kind)
    switch (role, kind) {
    case (.user, _):
      let body = try container.decode(UserBody.self, forKey: .content)
      content = .user(text: body.text, justPick: body.justPick ?? false)
    case (.assistant, "question"):
      let body = try container.decode(QuestionBody.self, forKey: .content)
      content = .question(text: body.text, chips: body.chips)
    case (.assistant, "recommendations"):
      let body = try container.decode(RecommendationsBody.self, forKey: .content)
      content = .recommendations(dropped: body.dropped ?? 0)
    case (.assistant, _):
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: container, debugDescription: "Unknown assistant message kind: \(kind)")
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(seq, forKey: .seq)
    try container.encode(role, forKey: .role)
    try container.encode(kind, forKey: .kind)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encodeIfPresent(conversationId, forKey: .conversationId)
    try container.encodeIfPresent(recommendations, forKey: .recommendations)
    switch content {
    case .user(let text, let justPick):
      try container.encode(UserBody(text: text, justPick: justPick), forKey: .content)
    case .question(let text, let chips):
      try container.encode(QuestionBody(text: text, chips: chips), forKey: .content)
    case .recommendations(let dropped):
      try container.encode(RecommendationsBody(dropped: dropped), forKey: .content)
    }
  }
}

nonisolated struct Provider: Codable, Sendable, Equatable {
  let name: String
  /// `flatrate`, `free`, `ads`, `rent`, or `buy` — kept as a string for forward compatibility.
  let type: String
  let logoPath: String?
}

nonisolated struct Recommendation: Codable, Sendable, Equatable {
  let id: String
  let position: Int
  let tmdbId: Int
  let title: String
  let year: Int?
  let whyShort: String
  let whyFull: String
  let posterPath: String?
  let runtime: Int?
  let overview: String
  let director: String?
  let providers: [Provider]
  let providersLink: String?
  let trailerKey: String?
  /// Present in `/sync` (flat), absent when nested in a message.
  let conversationId: String?
  let messageId: String?
  let createdAt: Date?

  init(
    id: String, position: Int, tmdbId: Int, title: String, year: Int?, whyShort: String,
    whyFull: String, posterPath: String? = nil, runtime: Int? = nil, overview: String = "",
    director: String? = nil, providers: [Provider] = [], providersLink: String? = nil,
    trailerKey: String? = nil, conversationId: String? = nil, messageId: String? = nil,
    createdAt: Date? = nil
  ) {
    self.id = id
    self.position = position
    self.tmdbId = tmdbId
    self.title = title
    self.year = year
    self.whyShort = whyShort
    self.whyFull = whyFull
    self.posterPath = posterPath
    self.runtime = runtime
    self.overview = overview
    self.director = director
    self.providers = providers
    self.providersLink = providersLink
    self.trailerKey = trailerKey
    self.conversationId = conversationId
    self.messageId = messageId
    self.createdAt = createdAt
  }

  // Enrichment fields may be null or absent on older rows.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    position = try container.decode(Int.self, forKey: .position)
    tmdbId = try container.decode(Int.self, forKey: .tmdbId)
    title = try container.decode(String.self, forKey: .title)
    year = try container.decodeIfPresent(Int.self, forKey: .year)
    whyShort = try container.decode(String.self, forKey: .whyShort)
    whyFull = try container.decode(String.self, forKey: .whyFull)
    posterPath = try container.decodeIfPresent(String.self, forKey: .posterPath)
    runtime = try container.decodeIfPresent(Int.self, forKey: .runtime)
    overview = try container.decodeIfPresent(String.self, forKey: .overview) ?? ""
    director = try container.decodeIfPresent(String.self, forKey: .director)
    providers = try container.decodeIfPresent([Provider].self, forKey: .providers) ?? []
    providersLink = try container.decodeIfPresent(String.self, forKey: .providersLink)
    trailerKey = try container.decodeIfPresent(String.self, forKey: .trailerKey)
    conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId)
    messageId = try container.decodeIfPresent(String.self, forKey: .messageId)
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
  }
}

nonisolated struct Decision: Codable, Sendable, Equatable {
  nonisolated enum Choice: String, Codable, Sendable, Equatable {
    case yes
    case maybe
    case no
  }

  let tmdbId: Int
  let decision: Choice
  let conversationId: String
  let decidedAt: Date
}

nonisolated struct TasteProfile: Codable, Sendable, Equatable {
  let content: String
  let basedOnImportId: Int?
  let updatedAt: Date
}

/// `POST /taste-profile/draft` — not saved until `PUT /taste-profile`.
nonisolated struct TasteProfileDraft: Codable, Sendable, Equatable {
  let content: String
  let changes: [String]
}

/// `GET /sync` — flat collections; messages and recommendations carry their parent ids.
nonisolated struct SyncResponse: Codable, Sendable, Equatable {
  /// Exact server string — never round-tripped through `Date`.
  let serverTime: String
  /// Exact server string; send back unchanged as the next `since`.
  let nextSince: String
  let conversations: [Conversation]
  let messages: [Message]
  let recommendations: [Recommendation]
  let decisions: [Decision]
  let tasteProfile: TasteProfile?
  let lastImportAt: Date?
}

// MARK: - Request bodies

nonisolated struct CreateConversationBody: Codable, Sendable, Equatable {
  let model: String?
  let text: String
  let justPick: Bool
}

nonisolated struct SendMessageBody: Codable, Sendable, Equatable {
  let text: String?
  let justPick: Bool
}

nonisolated struct DecisionBody: Codable, Sendable, Equatable {
  let decision: Decision.Choice
  let conversationId: String
}

nonisolated struct RenameConversationBody: Codable, Sendable, Equatable {
  let title: String
}

nonisolated struct TasteProfileBody: Codable, Sendable, Equatable {
  let content: String
}

nonisolated struct DraftTasteProfileBody: Codable, Sendable, Equatable {
  let model: String?
}
