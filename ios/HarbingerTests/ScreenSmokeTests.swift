import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit

@testable import Harbinger

/// Renders the I3 screens over a cached conversation in the test host's window, so their
/// `@Query` predicates and layout run for real (a bad predicate fails at runtime, not build).
@MainActor
struct ScreenSmokeTests {
  func render(_ view: some View, for seconds: Double = 0.5) async throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    defer { window.isHidden = true }
    window.rootViewController = UIHostingController(rootView: view)
    window.makeKeyAndVisible()
    try await Task.sleep(for: .seconds(seconds))
    window.rootViewController?.view.layoutIfNeeded()
  }

  func cachedHarness() async throws -> SessionHarness {
    let harness = try SessionHarness()
    try await harness.session.syncService.ingest(try turnResponse(Fixtures.conversationResponse))
    try await harness.session.syncService.ingest(
      try turnResponse(Fixtures.recommendationsResponse))
    try await harness.session.syncService.ingest(makeDecision(.yes))
    #expect(try harness.counts() == [1, 4, 2])
    return harness
  }

  @Test func conversationListRenders() async throws {
    let harness = try await cachedHarness()
    try await render(
      NavigationStack { ConversationListView() }
        .environment(harness.session)
        .modelContainer(harness.container))
  }

  @Test func existingChatRenders() async throws {
    let harness = try await cachedHarness()
    try await render(
      NavigationStack { ChatView(session: harness.session, conversationID: "conv-1") }
        .environment(harness.session)
        .modelContainer(harness.container))
  }

  @Test func newChatRendersWithModelsAndAPendingTurn() async throws {
    let harness = try SessionHarness(
      turns: TurnScript(
        [.failure(.network(.notConnectedToInternet))], models: .success(testModels),
        delay: .milliseconds(400)))
    await harness.session.loadModels()
    let view = NavigationStack { ChatView(session: harness.session, conversationID: nil) }
      .environment(harness.session)
      .modelContainer(harness.container)
    let send = Task {
      await harness.session.send(
        TurnRequest(target: .new, text: "Something slow", justPick: false, model: nil))
    }
    try await render(view, for: 0.2)
    _ = await send.value
    try await render(view, for: 0.2)
    #expect(harness.session.failures[.new] != nil)
  }

  @Test func pickDetailRenders() async throws {
    let harness = try await cachedHarness()
    try await render(
      NavigationStack { PickDetailView(recommendationID: "rec-1") }
        .environment(harness.session)
        .modelContainer(harness.container))
  }

  /// A W4a-era row: no director, providers, providers link, or trailer.
  @Test func bareRecommendationDetailRenders() async throws {
    let harness = try await cachedHarness()
    try await render(
      NavigationStack { PickDetailView(recommendationID: "rec-2") }
        .environment(harness.session)
        .modelContainer(harness.container))
  }

  @Test func missingPickRenders() async throws {
    let harness = try await cachedHarness()
    try await render(
      NavigationStack { PickDetailView(recommendationID: "missing") }
        .environment(harness.session)
        .modelContainer(harness.container))
  }
}
