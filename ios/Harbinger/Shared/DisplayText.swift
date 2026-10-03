import Foundation

// Pure rendering helpers, kept out of the views so they can be tested.

/// Error text for a failed chat turn. Basic copy; I6 refines it.
nonisolated func turnErrorMessage(_ error: APIError) -> String {
  switch error {
  case .unauthorized:
    return "API key rejected."
  case .network:
    return "Can't reach the server."
  case .server(_, "conversation_busy", _, _):
    return "Still working on the last message."
  case .server(_, "claude_unavailable", _, _), .server(_, "tmdb_rate_limited", _, _):
    return "The service is busy — try again in a moment."
  case .server(502, _, _, _):
    return "Couldn't get recommendations — try again."
  case .server, .decoding, .invalidResponse:
    return "Something went wrong."
  }
}

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
