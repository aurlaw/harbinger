import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit

@testable import Harbinger

/// Hosts the real root view in the test host's window, with a fake Worker.
@MainActor
struct RootViewTests {
  func wait(_ seconds: Double = 5, until done: () -> Bool) async {
    let deadline = Date().addingTimeInterval(seconds)
    while !done(), Date() < deadline {
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  func find<Target: UIView>(_ type: Target.Type, in view: UIView) -> Target? {
    if let match = view as? Target { return match }
    for subview in view.subviews {
      if let match = find(type, in: subview) { return match }
    }
    return nil
  }

  /// Regression: the sync controller used to be created after the first render, and the
  /// list kept the refresh action it was first given, so pull-to-refresh did nothing.
  @Test func pullToRefreshSyncsAfterLaunch() async throws {
    let suite = "RootViewTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let recorder = SyncRecorder([
      .success(
        makeSync(nextSince: "2026-09-29T19:00:00.000Z", conversations: [makeConversation()])),
      .success(
        makeSync(
          nextSince: "2026-09-29T20:00:00.000Z",
          conversations: [makeConversation(id: "conv-2", title: "Second")])),
    ])
    let configuration = AppConfiguration(
      endpoints: EndpointStore(defaults: defaults),
      credentials: InMemoryCredentialStore(key: testAPIKey),
      makeClient: { _ in FakeAPIClient(syncs: recorder) })
    configuration.endpoints.save(testBaseURL)
    let container = try CacheStore.inMemory()

    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    defer { window.isHidden = true }
    window.rootViewController = UIHostingController(
      rootView: RootView(configuration: configuration, container: container)
        .modelContainer(container))
    window.makeKeyAndVisible()

    // Launch sync: a full pull.
    await wait { recorder.sinces.count >= 1 }
    #expect(recorder.sinces == [nil])
    await wait {
      (try? container.mainContext.fetchCount(FetchDescriptor<CachedConversation>())) == 1
    }

    // Pull to refresh.
    let root = try #require(window.rootViewController?.view)
    let scroll = try #require(find(UIScrollView.self, in: root))
    let control = try #require(scroll.refreshControl)
    control.beginRefreshing()
    control.sendActions(for: .valueChanged)

    await wait { recorder.sinces.count >= 2 }
    #expect(recorder.sinces == [nil, "2026-09-29T19:00:00.000Z"])
    await wait {
      (try? container.mainContext.fetchCount(FetchDescriptor<CachedConversation>())) == 2
    }
    #expect(try container.mainContext.fetchCount(FetchDescriptor<CachedConversation>()) == 2)
  }
}
