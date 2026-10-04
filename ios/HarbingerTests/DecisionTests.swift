import Foundation
import SwiftData
import Testing

@testable import Harbinger

@MainActor
struct DecisionTests {
  let pick = DecisionTarget(tmdbID: 12345, conversationID: "conv-1")
  let letterboxd = URL(string: "https://letterboxd.com/tmdb/12345")!

  func harness(
    _ results: [Result<Decision, APIError>], delay: Duration? = nil
  ) throws -> SessionHarness {
    try SessionHarness(decisions: DecisionScript(results, delay: delay))
  }

  func cachedDecisions(_ harness: SessionHarness) throws -> [CachedDecision] {
    try CacheReader(harness.container).all(CachedDecision.self)
  }

  // MARK: - Request

  @Test func sendsThePicksOwnConversation() async throws {
    // A pick cached from conv-2: the decision must name conv-2, not some other conversation.
    let cached = CachedRecommendation(id: "rec-9")
    cached.apply(
      Recommendation(
        id: "rec-9", position: 1, tmdbId: 777, title: "The Witch", year: 2015, whyShort: "",
        whyFull: ""),
      conversationID: "conv-2", messageID: "msg-9")
    let target = DecisionTarget(cached)
    #expect(target == DecisionTarget(tmdbID: 777, conversationID: "conv-2"))

    let harness = try harness([
      .success(
        Decision(
          tmdbId: 777, decision: .maybe, conversationId: "conv-2",
          decidedAt: timestamp("2026-10-03T18:00:00.000Z")))
    ])
    let outcome = await harness.session.setDecision(.maybe, for: target, current: nil)

    #expect(outcome == .saved(.maybe))
    #expect(
      harness.decisions.calls
        == [DecisionScript.Call(tmdbID: 777, decision: .maybe, conversationID: "conv-2")])
  }

  @Test func successIsCachedAndChangingItKeepsOneRow() async throws {
    let harness = try harness([.success(makeDecision(.maybe)), .success(makeDecision(.yes))])

    await harness.session.setDecision(.maybe, for: pick, current: nil)
    #expect(try cachedDecisions(harness).map(\.choice) == [.maybe])

    await harness.session.setDecision(.yes, for: pick, current: .maybe)
    let rows = try cachedDecisions(harness)
    #expect(rows.count == 1)
    #expect(rows.first?.choice == .yes)
    #expect(harness.decisions.calls.map(\.decision) == [.maybe, .yes])
  }

  // MARK: - Letterboxd hand-off

  @Test func yesOpensLetterboxdAfterSaving() async throws {
    let harness = try harness([.success(makeDecision(.yes))])

    #expect(await harness.session.setDecision(.yes, for: pick, current: nil) == .saved(.yes))

    #expect(harness.opener.opened == [letterboxd])
    #expect(try cachedDecisions(harness).first?.choice == .yes)
  }

  @Test(arguments: [Decision.Choice.maybe, .no])
  func maybeAndNoDoNotOpenAnything(_ choice: Decision.Choice) async throws {
    let harness = try harness([.success(makeDecision(choice))])

    #expect(await harness.session.setDecision(choice, for: pick, current: nil) == .saved(choice))

    #expect(harness.opener.opened.isEmpty)
  }

  // MARK: - Re-tapping

  @Test(arguments: [Decision.Choice.maybe, .no])
  func retappingTheCurrentChoiceMakesNoRequest(_ choice: Decision.Choice) async throws {
    let harness = try harness([])

    #expect(await harness.session.setDecision(choice, for: pick, current: choice) == .unchanged)

    #expect(harness.decisions.calls.isEmpty)
    #expect(harness.opener.opened.isEmpty)
  }

  @Test func retappingYesReopensLetterboxdWithoutARequest() async throws {
    let harness = try harness([])

    #expect(await harness.session.setDecision(.yes, for: pick, current: .yes) == .unchanged)

    #expect(harness.decisions.calls.isEmpty)
    #expect(harness.opener.opened == [letterboxd])
  }

  // MARK: - Failure

  @Test(
    "Failure caches nothing and opens nothing",
    arguments: [
      (APIError.network(.notConnectedToInternet), "You're offline."),
      (.unauthorized, "API key rejected — update it in Settings."),
      (
        .server(status: 422, code: "not_recommended", message: "", retryAfter: nil),
        "Couldn't save that — try again."
      ),
      (.decoding("bad"), "Something went wrong."),
    ])
  func failure(error: APIError, message: String) async throws {
    let harness = try harness([.failure(error)])

    let outcome = await harness.session.setDecision(.yes, for: pick, current: nil)

    let request = DecisionRequest(tmdbID: 12345, choice: .yes, conversationID: "conv-1")
    let failure = DecisionFailure(request: request, message: message)
    #expect(outcome == .failed(failure))
    #expect(harness.session.decisionFailures[12345] == failure)
    #expect(harness.session.pendingDecisions.isEmpty)
    #expect(try cachedDecisions(harness).isEmpty)
    #expect(harness.opener.opened.isEmpty)
  }

  @Test func retryResendsTheSameDecision() async throws {
    let harness = try harness([
      .failure(.network(.timedOut)), .success(makeDecision(.yes)),
    ])
    await harness.session.setDecision(.yes, for: pick, current: nil)

    let outcome = await harness.session.retryDecision(tmdbID: 12345)

    let call = DecisionScript.Call(tmdbID: 12345, decision: .yes, conversationID: "conv-1")
    #expect(harness.decisions.calls == [call, call])
    #expect(outcome == .saved(.yes))
    #expect(harness.session.decisionFailures.isEmpty)
    #expect(harness.opener.opened == [letterboxd])
  }

  // MARK: - Concurrency

  @Test func secondTapWhileInFlightIsRejected() async throws {
    let harness = try harness([.success(makeDecision(.maybe))], delay: .milliseconds(300))
    let session = harness.session
    let pick = pick

    let first = Task { await session.setDecision(.maybe, for: pick, current: nil) }
    await eventually { session.pendingDecisions[12345] != nil }
    let second = await session.setDecision(.no, for: pick, current: nil)

    #expect(second == .rejected)
    #expect(await first.value == .saved(.maybe))
    #expect(harness.decisions.calls.count == 1)
  }

  @Test func decisionCompletesAfterTheDetailScreenIsReleased() async throws {
    let harness = try harness([.success(makeDecision(.yes))], delay: .milliseconds(300))
    var model: PickDetailModel? = PickDetailModel(session: harness.session, target: pick)
    weak let released = model
    model?.choose(.yes, current: nil)
    await eventually { harness.session.pendingDecisions[12345] != nil }

    model = nil
    #expect(released == nil)

    try await eventually {
      try cachedDecisions(harness).count == 1 && harness.session.pendingDecisions.isEmpty
    }
    #expect(try cachedDecisions(harness).first?.choice == .yes)
    #expect(harness.opener.opened == [letterboxd])
  }

  // MARK: - View model

  @Test func modelTracksSavingAndSuccess() async throws {
    let harness = try harness([.success(makeDecision(.maybe))], delay: .milliseconds(200))
    let model = PickDetailModel(session: harness.session, target: pick)

    model.choose(.maybe, current: nil)
    await eventually { model.isSaving }
    #expect(model.pending?.choice == .maybe)

    // Taps while saving are ignored.
    model.choose(.no, current: nil)
    await model.decisionTask?.value

    #expect(!model.isSaving)
    #expect(model.savedCount == 1)
    #expect(harness.decisions.calls.count == 1)
  }

  @Test func modelRetryAfterFailure() async throws {
    let harness = try harness([
      .failure(.network(.timedOut)), .success(makeDecision(.no)),
    ])
    let model = PickDetailModel(session: harness.session, target: pick)

    model.choose(.no, current: nil)
    await model.decisionTask?.value
    #expect(model.failure?.message == "Can't reach the server.")
    #expect(model.savedCount == 0)

    model.retry()
    await model.decisionTask?.value
    #expect(model.failure == nil)
    #expect(model.savedCount == 1)
    #expect(harness.decisions.calls.map(\.decision) == [.no, .no])
  }
}
