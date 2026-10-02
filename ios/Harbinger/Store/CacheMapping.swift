import Foundation

// DTO → cache mapping, all in one place (`tmdbId` → `tmdbID` etc.), plus the typed
// accessors over the raw-string columns. The server is truth: `apply` overwrites every field.

nonisolated extension CachedConversation {
  func apply(_ dto: Conversation) {
    title = dto.title
    model = dto.model
    questionRounds = dto.questionRounds
    createdAt = dto.createdAt
    updatedAt = dto.updatedAt
  }
}

nonisolated extension CachedMessage {
  func apply(_ dto: Message, conversationID: String) {
    self.conversationID = conversationID
    seq = dto.seq
    content = dto.content
    createdAt = dto.createdAt
  }

  var messageRole: MessageRole {
    MessageRole(rawValue: role) ?? .assistant
  }

  /// The I1 enum, rebuilt from (and flattened into) the stored columns.
  var content: MessageContent {
    get {
      if messageRole == .user { return .user(text: text, justPick: justPick) }
      if kind == "question" { return .question(text: text ?? "", chips: chips) }
      return .recommendations(dropped: dropped)
    }
    set {
      text = nil
      justPick = false
      chips = []
      dropped = 0
      switch newValue {
      case .user(let text, let justPick):
        role = MessageRole.user.rawValue
        kind = "text"
        self.text = text
        self.justPick = justPick
      case .question(let text, let chips):
        role = MessageRole.assistant.rawValue
        kind = "question"
        self.text = text
        self.chips = chips
      case .recommendations(let dropped):
        role = MessageRole.assistant.rawValue
        kind = "recommendations"
        self.dropped = dropped
      }
    }
  }
}

nonisolated extension CachedRecommendation {
  func apply(_ dto: Recommendation, conversationID: String, messageID: String) {
    self.conversationID = conversationID
    self.messageID = messageID
    position = dto.position
    tmdbID = dto.tmdbId
    title = dto.title
    year = dto.year
    whyShort = dto.whyShort
    whyFull = dto.whyFull
    posterPath = dto.posterPath
    runtime = dto.runtime
    overview = dto.overview
    director = dto.director
    providers = dto.providers.map {
      CachedProvider(name: $0.name, type: $0.type, logoPath: $0.logoPath)
    }
    providersLink = dto.providersLink
    trailerKey = dto.trailerKey
    // Nested recommendations (write responses) carry no timestamp; keep the synced one.
    if let createdAt = dto.createdAt {
      self.createdAt = createdAt
    }
  }
}

nonisolated extension CachedDecision {
  func apply(_ dto: Decision) {
    decision = dto.decision.rawValue
    conversationID = dto.conversationId
    decidedAt = dto.decidedAt
  }

  var choice: Decision.Choice? {
    Decision.Choice(rawValue: decision)
  }
}

nonisolated extension CachedTasteProfile {
  func apply(_ dto: TasteProfile) {
    content = dto.content
    basedOnImportID = dto.basedOnImportId
    updatedAt = dto.updatedAt
  }
}
