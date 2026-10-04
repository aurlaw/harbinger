import Foundation
import Testing

@testable import Harbinger

struct DisplayTextTests {
  // MARK: - TMDB images

  @Test(
    "TMDB image URLs",
    arguments: [
      (
        "/4zqCKJVHUolGs6C5AZwAZqLWixW.jpg", TMDBImageSize.w185,
        "https://image.tmdb.org/t/p/w185/4zqCKJVHUolGs6C5AZwAZqLWixW.jpg"
      ),
      (
        "4zqCKJVHUolGs6C5AZwAZqLWixW.jpg", .w185,
        "https://image.tmdb.org/t/p/w185/4zqCKJVHUolGs6C5AZwAZqLWixW.jpg"
      ),
      ("/poster.jpg", .w500, "https://image.tmdb.org/t/p/w500/poster.jpg"),
      ("/logo.png", .w92, "https://image.tmdb.org/t/p/w92/logo.png"),
    ])
  func imageURL(path: String, size: TMDBImageSize, expected: String) {
    #expect(tmdbImageURL(path: path, size: size)?.absoluteString == expected)
  }

  @Test(arguments: [nil, "", "  "])
  func missingImagePath(path: String?) {
    #expect(tmdbImageURL(path: path, size: .w185) == nil)
  }

  // MARK: - Decision badge

  @Test func decisionBadge() {
    #expect(DecisionBadge(.yes) == .yes)
    #expect(DecisionBadge(.maybe) == .maybe)
    #expect(DecisionBadge(.no) == .no)
    #expect(DecisionBadge(nil) == nil)
    #expect(DecisionBadge.yes.symbol == "checkmark.circle.fill")
    #expect(DecisionBadge.maybe.symbol == "questionmark.circle.fill")
    #expect(DecisionBadge.no.symbol == "xmark.circle.fill")
  }

  // MARK: - List dates

  /// Saturday 3 October 2026, 15:00 UTC.
  let now = timestamp("2026-10-03T15:00:00.000Z")
  var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }
  let locale = Locale(identifier: "en_US")

  func listDate(_ string: String) -> String {
    listDateText(timestamp(string), now: now, calendar: calendar, locale: locale)
  }

  @Test func todayShowsTheTime() {
    #expect(listDate("2026-10-03T09:30:00.000Z").contains("9:30"))
    #expect(listDate("2026-10-03T00:00:00.000Z").contains("12:00"))
  }

  @Test func lastSevenDaysShowTheWeekday() {
    #expect(listDate("2026-10-02T23:59:00.000Z") == "Friday")
    #expect(listDate("2026-09-27T08:00:00.000Z") == "Sunday")
  }

  @Test func olderShowsAShortDate() {
    #expect(listDate("2026-09-26T20:00:00.000Z") == "9/26/2026")
    #expect(listDate("2025-12-25T12:00:00.000Z") == "12/25/2025")
  }

  // MARK: - Bubbles and errors

  @Test func userBubbleText() {
    #expect(Harbinger.userBubbleText(text: nil, justPick: true) == "Just pick for me")
    #expect(Harbinger.userBubbleText(text: "", justPick: true) == "Just pick for me")
    #expect(Harbinger.userBubbleText(text: "Folk horror", justPick: true) == "Folk horror")
    #expect(Harbinger.userBubbleText(text: "Folk horror", justPick: false) == "Folk horror")
  }

  @Test(
    "Turn error text",
    arguments: [
      (
        APIError.server(status: 409, code: "conversation_busy", message: "", retryAfter: nil),
        "Still working on your last message."
      ),
      (
        .server(status: 503, code: "claude_unavailable", message: "", retryAfter: 7),
        "The service is busy — try again in 7 seconds."
      ),
      (
        .server(status: 503, code: "tmdb_rate_limited", message: "", retryAfter: 1),
        "The service is busy — try again in 1 second."
      ),
      (
        .server(status: 503, code: "claude_unavailable", message: "", retryAfter: nil),
        "The service is busy — try again in a moment."
      ),
      (
        .server(status: 503, code: "tmdb_rate_limited", message: "", retryAfter: nil),
        "The service is busy — try again in a moment."
      ),
      (
        .server(status: 502, code: "recommendation_failed", message: "", retryAfter: nil),
        "Couldn't find good picks for that — try rephrasing."
      ),
      (
        .server(status: 502, code: "tmdb_unavailable", message: "", retryAfter: nil),
        "Movie data is unavailable right now — try again shortly."
      ),
      (
        .server(status: 502, code: "claude_error", message: "", retryAfter: nil),
        "Couldn't get recommendations — try again."
      ),
      (
        .server(status: 502, code: "something_else", message: "", retryAfter: nil),
        "Couldn't get recommendations — try again."
      ),
      (
        .server(status: 404, code: "not_found", message: "", retryAfter: nil),
        "This conversation no longer exists."
      ),
      (.network(.notConnectedToInternet), "You're offline."),
      (.network(.cannotConnectToHost), "Can't reach the server."),
      (
        .network(.timedOut),
        "This is taking longer than usual — your reply may still arrive."
      ),
      (
        .network(.networkConnectionLost),
        "This is taking longer than usual — your reply may still arrive."
      ),
      (.unauthorized, "API key rejected — update it in Settings."),
      (
        .server(status: 400, code: "invalid_request", message: "", retryAfter: nil),
        "Something went wrong."
      ),
      (.decoding("bad"), "Something went wrong."),
      (.invalidResponse, "Something went wrong."),
    ])
  func turnError(error: APIError, expected: String) {
    #expect(turnErrorMessage(error) == expected)
  }
}
