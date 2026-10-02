import Foundation
import Testing

@testable import Harbinger

@MainActor
final class TestClock {
  var now = Date(timeIntervalSince1970: 1_790_000_000)

  func advance(_ seconds: TimeInterval) {
    now.addTimeInterval(seconds)
  }
}

@MainActor
struct SyncControllerTests {
  let service = FakeSyncService()
  let clock = TestClock()

  func makeController() -> SyncController {
    SyncController(service: service, now: { [clock] in clock.now })
  }

  @Test func launchSyncs() async {
    let controller = makeController()

    await controller.syncIfStale()

    #expect(service.calls == 1)
    #expect(controller.lastError == nil)
    #expect(!controller.isSyncing)
  }

  @Test func foregroundWithinThirtySecondsIsSkipped() async {
    let controller = makeController()
    await controller.syncIfStale()

    clock.advance(29)
    await controller.syncIfStale()
    #expect(service.calls == 1)

    clock.advance(1)
    await controller.syncIfStale()
    #expect(service.calls == 2)
  }

  @Test func manualRefreshAlwaysSyncs() async {
    let controller = makeController()
    await controller.syncIfStale()

    await controller.syncNow()
    await controller.syncNow()

    #expect(service.calls == 3)
  }

  @Test func failedSyncDoesNotCountAsRecent() async {
    let controller = makeController()
    service.set(.failure(.api(.network(.timedOut))))
    await controller.syncIfStale()
    #expect(controller.lastError == "Can't reach endpoint")

    service.set(.success(SyncResult()))
    await controller.syncIfStale()

    #expect(service.calls == 2)
    #expect(controller.lastError == nil)
  }

  @Test func nothingHappensBeforeAServiceIsConnected() async {
    let controller = SyncController(now: { [clock] in clock.now })

    await controller.syncNow()
    await controller.syncIfStale()

    #expect(service.calls == 0)
    #expect(!controller.isSyncing)
    #expect(controller.lastError == nil)

    controller.connect(service)
    await controller.syncIfStale()
    #expect(service.calls == 1)
  }

  @Test func connectingANewServiceSyncsStraightAway() async {
    let controller = makeController()
    await controller.syncIfStale()

    let other = FakeSyncService(result: .failure(.api(.unauthorized)))
    controller.connect(other)
    await controller.syncIfStale()

    #expect(service.calls == 1)
    #expect(other.calls == 1)
    #expect(controller.lastError == "API key rejected")
  }

  @Test func unauthorizedIsReadable() async {
    let controller = makeController()
    service.set(.failure(.api(.unauthorized)))

    await controller.syncNow()

    #expect(controller.lastError == "API key rejected")
    #expect(!controller.isSyncing)
  }

  @Test(
    "Errors are user-readable",
    arguments: [
      (SyncError.api(.unauthorized), "API key rejected"),
      (.api(.network(.notConnectedToInternet)), "Can't reach endpoint"),
      (
        .api(.server(status: 503, code: "db_unavailable", message: "down", retryAfter: nil)),
        "Server error (db_unavailable)"
      ),
      (.api(.decoding("bad")), "Unexpected response from the server"),
      (.api(.invalidResponse), "Unexpected response from the server"),
      (.store("save failed"), "Couldn't update the local cache"),
    ])
  func messages(error: SyncError, expected: String) {
    #expect(SyncController.message(for: error) == expected)
  }
}
