import UIKit

/// Asks iOS for extra running time around a request, so one started just before the app is
/// backgrounded can still finish and be cached. Injected into `AppSession`; tests record
/// the calls instead.
struct BackgroundTime {
  /// Starts a background task and returns its identifier. `onExpiration` runs if iOS runs
  /// out of patience first.
  var begin: (_ name: String, _ onExpiration: @escaping @MainActor @Sendable () -> Void) -> Int
  var end: (_ identifier: Int) -> Void

  static let live = BackgroundTime(
    begin: { name, onExpiration in
      UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: onExpiration)
        .rawValue
    },
    end: { UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: $0)) })

  /// Runs `work` inside a background task that is always ended exactly once: when the work
  /// finishes (success or failure) or when the task expires, whichever comes first.
  func run<Value>(_ name: String, _ work: () async -> Value) async -> Value {
    let task = RunningTask(end: end)
    task.start(begin(name) { task.finish() })
    defer { task.finish() }
    return await work()
  }

  private final class RunningTask {
    private let end: (Int) -> Void
    private var identifier: Int?
    private var isFinished = false
    /// Expired before `begin` returned its identifier.
    private var finishWhenStarted = false

    init(end: @escaping (Int) -> Void) {
      self.end = end
    }

    func start(_ identifier: Int) {
      self.identifier = identifier
      if finishWhenStarted {
        finish()
      }
    }

    func finish() {
      guard !isFinished else { return }
      guard let identifier else {
        finishWhenStarted = true
        return
      }
      isFinished = true
      end(identifier)
    }
  }
}
