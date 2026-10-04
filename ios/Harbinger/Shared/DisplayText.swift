import Foundation

// Pure rendering helpers, kept out of the views so they can be tested.

// MARK: - Error text
//
// Every context shares one base for the errors that mean the same thing everywhere
// (`baseErrorMessage`); each helper then adds its own server-code cases on top.

/// The shared base: key rejected, offline, unreachable, and unreadable responses. `nil` for
/// a `.server` error, which each context words itself.
nonisolated func baseErrorMessage(_ error: APIError) -> String? {
  switch error {
  case .unauthorized: "API key rejected — update it in Settings."
  case .network(.notConnectedToInternet): "You're offline."
  case .network: "Can't reach the server."
  case .decoding, .invalidResponse: "Something went wrong."
  case .server: nil
  }
}

/// Shown instead of a plain error when a turn's request was cut off: the Worker usually
/// still commits the turn, and a follow-up sync delivers it.
nonisolated let replyMayArriveMessage =
  "This is taking longer than usual — your reply may still arrive."

/// A turn's request timed out or lost its connection after it was sent, so the reply may
/// still land on the server.
nonisolated func replyMayStillArrive(_ error: APIError) -> Bool {
  switch error {
  case .network(.timedOut), .network(.networkConnectionLost): true
  default: false
  }
}

/// `409 conversation_busy`: an earlier turn for the conversation is still running.
nonisolated func isConversationBusy(_ error: APIError) -> Bool {
  if case .server(_, "conversation_busy", _, _) = error { return true }
  return false
}

/// Error text for a failed chat turn.
nonisolated func turnErrorMessage(_ error: APIError) -> String {
  if replyMayStillArrive(error) { return replyMayArriveMessage }
  if let base = baseErrorMessage(error) { return base }
  switch error {
  case .server(_, "conversation_busy", _, _):
    return "Still working on your last message."
  case .server(503, _, _, let retryAfter):
    guard let retryAfter, retryAfter > 0 else {
      return "The service is busy — try again in a moment."
    }
    let unit = retryAfter == 1 ? "second" : "seconds"
    return "The service is busy — try again in \(retryAfter) \(unit)."
  case .server(502, "recommendation_failed", _, _):
    return "Couldn't find good picks for that — try rephrasing."
  case .server(502, "tmdb_unavailable", _, _):
    return "Movie data is unavailable right now — try again shortly."
  case .server(502, _, _, _):
    return "Couldn't get recommendations — try again."
  case .server(404, _, _, _):
    return "This conversation no longer exists."
  default:
    return "Something went wrong."
  }
}

/// Error text for a failed conversation delete. A `404` never gets here: it means the
/// conversation is already gone, which the session treats as success.
nonisolated func deleteErrorMessage(_ error: APIError) -> String {
  baseErrorMessage(error) ?? "Couldn't delete — try again."
}

/// Error text for a failed conversation rename.
nonisolated func renameErrorMessage(_ error: APIError) -> String {
  if let base = baseErrorMessage(error) { return base }
  if case .server(404, _, _, _) = error { return "This conversation no longer exists." }
  return "Couldn't rename — try again."
}

/// Error text for a failed taste-profile draft.
nonisolated func draftErrorMessage(_ error: APIError) -> String {
  if let base = baseErrorMessage(error) { return base }
  switch error {
  case .server(_, "no_ratings", _, _): return "Import your Letterboxd ratings first."
  case .server(_, "claude_unavailable", _, _):
    return "The service is busy — try again in a moment."
  default: return "Couldn't draft — try again."
  }
}

/// Error text for a failed taste-profile save.
nonisolated func profileSaveErrorMessage(_ error: APIError) -> String {
  baseErrorMessage(error) ?? "Couldn't save — try again."
}

/// The inline notice on the conversation list while the last sync has failed; `nil` when
/// there is nothing to show.
nonisolated func syncNoticeMessage(_ error: SyncError?) -> String? {
  switch error {
  case nil: nil
  case .api(.unauthorized): baseErrorMessage(.unauthorized)
  case .api(.network(.notConnectedToInternet)): "You're offline — pull to retry."
  case .api, .store: "Couldn't sync — pull to retry."
  }
}

// MARK: - Accessibility text

/// A pick card read as one element: "<Title>, <year>. <why>. Decision: <Yes>", with missing
/// parts left out.
nonisolated func pickAccessibilityLabel(
  title: String, year: Int?, whyShort: String, decision: DecisionBadge?
) -> String {
  var parts = [year.map { "\(title), \($0)" } ?? title]
  var why = whyShort.trimmingCharacters(in: .whitespacesAndNewlines)
  while why.hasSuffix(".") {
    why.removeLast()
  }
  if !why.isEmpty {
    parts.append(why)
  }
  if let decision {
    parts.append("Decision: \(decision.label)")
  }
  return parts.joined(separator: ". ")
}

/// What a decision button does, for VoiceOver.
nonisolated func decisionAccessibilityLabel(_ choice: Decision.Choice) -> String {
  switch choice {
  case .yes: "Yes — add to watchlist"
  case .maybe: "Maybe"
  case .no: "No — never recommend"
  }
}

// MARK: - Starter suggestions

/// The fixed suggestions on a new conversation, before its first message.
nonisolated struct StarterSuggestion: Hashable, Sendable {
  let title: String
  /// Sends a just-pick turn straight away instead of filling the composer.
  var sendsImmediately = false

  static let surpriseMe = StarterSuggestion(title: "Surprise me", sendsImmediately: true)

  static let all: [StarterSuggestion] = [
    StarterSuggestion(title: "Something slow and unsettling"),
    StarterSuggestion(title: "A hidden gem from the 70s or 80s"),
    StarterSuggestion(title: "Under 90 minutes, tonight"),
    StarterSuggestion(title: "Folk horror"),
    surpriseMe,
  ]
}

// MARK: - Other text

/// A user bubble's text: a just-pick turn with no text reads "Just pick for me".
nonisolated func userBubbleText(text: String?, justPick: Bool) -> String {
  if let text, !text.isEmpty { return text }
  return justPick ? "Just pick for me" : ""
}

/// Conversation list date: time for today, weekday within the last 7 days, short date otherwise.
nonisolated func listDateText(
  _ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current
) -> String {
  let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
  if calendar.isDate(date, inSameDayAs: now) {
    return date.formatted(style.hour().minute())
  }
  let start = calendar.startOfDay(for: date)
  let days = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: now)).day
  if let days, (1..<7).contains(days) {
    return date.formatted(style.weekday(.wide))
  }
  return date.formatted(style.year().month(.defaultDigits).day())
}

/// The badge on a pick card for the film's cached decision; `nil` when undecided.
nonisolated enum DecisionBadge: Equatable, Sendable {
  case yes
  case maybe
  case no

  init?(_ choice: Decision.Choice?) {
    switch choice {
    case .yes: self = .yes
    case .maybe: self = .maybe
    case .no: self = .no
    case nil: return nil
    }
  }

  var symbol: String {
    switch self {
    case .yes: "checkmark.circle.fill"
    case .maybe: "questionmark.circle.fill"
    case .no: "xmark.circle.fill"
    }
  }

  var label: String {
    switch self {
    case .yes: "Yes"
    case .maybe: "Maybe"
    case .no: "No"
    }
  }
}

/// The Worker's limit: 1–2,000 characters after trimming, counted as JavaScript
/// `string.length` (UTF-16 code units), so emoji count the same on both sides.
nonisolated enum MessageLimit {
  static let maxLength = 2000

  static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func length(_ text: String) -> Int {
    trimmed(text).utf16.count
  }
}

/// The Worker's title rule: 1–100 characters after trimming, counted as code points —
/// `unicodeScalars` here. `String.count` counts grapheme clusters and would disagree on
/// emoji.
nonisolated enum TitleLimit {
  static let maxLength = 100

  static func trimmed(_ title: String) -> String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func length(_ title: String) -> Int {
    trimmed(title).unicodeScalars.count
  }

  static func isValid(_ title: String) -> Bool {
    (1...maxLength).contains(length(title))
  }
}

/// The Worker's taste-profile rule: 1–4,000 characters after trimming, counted as JavaScript
/// `string.length` (UTF-16 code units, so an emoji counts as 2) — like `MessageLimit`, and
/// unlike titles, which the server counts in code points (`TitleLimit`).
nonisolated enum ProfileLimit {
  static let maxLength = 4000

  static func trimmed(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func length(_ text: String) -> Int {
    trimmed(text).utf16.count
  }

  static func isValid(_ text: String) -> Bool {
    (1...maxLength).contains(length(text))
  }
}

/// A taste profile predates the last import when it was saved before it. Unknown (either
/// date missing) is not stale.
nonisolated func profileIsStale(updatedAt: Date?, lastImportAt: Date?) -> Bool {
  guard let updatedAt, let lastImportAt else { return false }
  return updatedAt < lastImportAt
}
