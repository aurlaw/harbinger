// Response bodies in the Worker's real shapes (api-surface.md + worker/src mappers).

enum Fixtures {
  static let health = #"{ "status": "ok" }"#

  static let models = """
    { "default": "claude-sonnet-5",
      "allowed": ["claude-haiku-4-5-20251001", "claude-sonnet-5", "claude-opus-5-5"] }
    """

  static let conversation = """
    { "id": "conv-1", "title": "Something slow and unsettling", "model": "claude-sonnet-5",
      "question_rounds": 1, "created_at": "2026-09-29T18:00:00.000Z",
      "updated_at": "2026-09-29T18:01:30.456Z" }
    """

  static let userMessage = """
    { "id": "msg-1", "seq": 1, "role": "user", "kind": "text",
      "content": { "text": "Something slow and unsettling", "just_pick": false },
      "created_at": "2026-09-29T18:00:00.000Z" }
    """

  static let questionMessage = """
    { "id": "msg-2", "seq": 2, "role": "assistant", "kind": "question",
      "content": { "text": "How much time do you have?",
                   "chips": ["Under 90 min", "Around 2 hours", "Doesn't matter"] },
      "created_at": "2026-09-29T18:00:12.345Z" }
    """

  static let fullRecommendation = """
    { "id": "rec-1", "position": 1, "tmdb_id": 12345, "title": "The Witch", "year": 2015,
      "why_short": "Slow dread.", "why_full": "A slow, bleak folk horror.",
      "poster_path": "/abc.jpg", "runtime": 92, "overview": "A family in 1630s New England.",
      "director": "Robert Eggers",
      "providers": [ { "name": "Shudder", "type": "flatrate", "logo_path": "/x.jpg" } ],
      "providers_link": "https://www.themoviedb.org/movie/12345/watch?locale=US",
      "trailer_key": "abc123" }
    """

  /// A W4a-era row: no enrichment stored.
  static let bareRecommendation = """
    { "id": "rec-2", "position": 2, "tmdb_id": 67890, "title": "Lake Mungo", "year": null,
      "why_short": "Grief.", "why_full": "Quiet mockumentary grief.",
      "poster_path": null, "runtime": null, "overview": "", "director": null,
      "providers": [], "providers_link": null, "trailer_key": null }
    """

  static let recommendationsMessage = """
    { "id": "msg-4", "seq": 4, "role": "assistant", "kind": "recommendations",
      "content": { "dropped": 1 }, "created_at": "2026-09-29T18:01:30.456Z",
      "recommendations": [\(fullRecommendation), \(bareRecommendation)] }
    """

  static let justPickMessage = """
    { "id": "msg-3", "seq": 3, "role": "user", "kind": "text",
      "content": { "text": null, "just_pick": true }, "created_at": "2026-09-29T18:01:00.000Z" }
    """

  static let conversationResponse = """
    { "conversation": \(conversation), "messages": [\(userMessage), \(questionMessage)] }
    """

  static let recommendationsResponse = """
    { "conversation": \(conversation), "messages": [\(justPickMessage), \(recommendationsMessage)] }
    """

  static let decision = """
    { "tmdb_id": 12345, "decision": "maybe", "conversation_id": "conv-1",
      "decided_at": "2026-09-29T18:05:00.789Z" }
    """

  static let tasteProfile = """
    { "content": "## Enjoys\\n- Folk horror", "based_on_import_id": 3,
      "updated_at": "2026-09-28T12:00:00.000Z" }
    """

  static let draft = """
    { "content": "## Enjoys\\n- Folk horror",
      "changes": ["Moved found footage from Mixed to Enjoys — 6 recent 4+ ratings"] }
    """

  static let nextSince = "2026-09-29T18:08:00.123Z"

  static let sync = """
    { "server_time": "2026-09-29T18:10:00.123Z",
      "next_since": "\(nextSince)",
      "conversations": [\(conversation)],
      "messages": [
        { "id": "msg-1", "conversation_id": "conv-1", "seq": 1, "role": "user", "kind": "text",
          "content": { "text": "Something slow", "just_pick": false },
          "created_at": "2026-09-29T18:00:00.000Z" },
        { "id": "msg-2", "conversation_id": "conv-1", "seq": 2, "role": "assistant",
          "kind": "question", "content": { "text": "How long?", "chips": ["Short", "Long"] },
          "created_at": "2026-09-29T18:00:12.345Z" },
        { "id": "msg-4", "conversation_id": "conv-1", "seq": 4, "role": "assistant",
          "kind": "recommendations", "content": { "dropped": 0 },
          "created_at": "2026-09-29T18:01:30.456Z" }
      ],
      "recommendations": [
        { "id": "rec-2", "conversation_id": "conv-1", "message_id": "msg-4", "position": 1,
          "tmdb_id": 67890, "title": "Lake Mungo", "year": 2008,
          "why_short": "Grief.", "why_full": "Quiet mockumentary grief.",
          "poster_path": null, "runtime": 87, "overview": "", "director": null,
          "providers": [], "providers_link": null, "trailer_key": null,
          "created_at": "2026-09-29T18:01:30.456Z" }
      ],
      "decisions": [\(decision)],
      "taste_profile": null,
      "last_import_at": "2026-09-24T21:54:00.000Z" }
    """

  /// `GET /stats/outcomes` in the Worker's shape (`worker/src/outcomes/handlers.ts`).
  static let outcomeStats = """
    { "hit_threshold_half_stars": 7, "recommended": 41, "rated": 12, "hits": 9,
      "hit_rate": 0.75, "average_half_stars": 7.4,
      "by_model": [
        { "model": "claude-sonnet-5", "recommended": 30, "rated": 9, "hits": 7,
          "hit_rate": 0.778 },
        { "model": "claude-opus-5-5", "recommended": 11, "rated": 3, "hits": 2,
          "hit_rate": 0.667 }
      ],
      "recent": [
        { "tmdb_id": 12345, "title": "Noroi: The Curse", "year": 2005, "half_stars": 9,
          "hit": true, "model": "claude-sonnet-5",
          "first_recommended_at": "2026-09-29T18:01:30.456Z" },
        { "tmdb_id": 67890, "title": "Lake Mungo", "year": null, "half_stars": 4,
          "hit": false, "model": "claude-opus-5-5",
          "first_recommended_at": "2026-09-20T09:00:00.000Z" }
      ] }
    """

  static let emptyOutcomeStats = """
    { "hit_threshold_half_stars": 7, "recommended": 0, "rated": 0, "hits": 0,
      "hit_rate": null, "average_half_stars": null, "by_model": [], "recent": [] }
    """

  static func error(_ code: String, _ message: String = "Something went wrong") -> String {
    #"{ "error": { "code": "\#(code)", "message": "\#(message)" } }"#
  }
}
