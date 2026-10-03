import Foundation
import Observation

/// The decision bar's state for one pick. The request itself runs on `AppSession`, so it
/// outlives this object.
@Observable
final class PickDetailModel {
  let session: AppSession
  let target: DecisionTarget
  /// Bumped on each saved decision; drives the success haptic.
  private(set) var savedCount = 0
  /// The request started by this screen, for tests and callers that want to wait.
  private(set) var decisionTask: Task<Void, Never>?

  init(session: AppSession, target: DecisionTarget) {
    self.session = session
    self.target = target
  }

  var pending: DecisionRequest? { session.pendingDecisions[target.tmdbID] }
  var isSaving: Bool { pending != nil }
  var failure: DecisionFailure? { session.decisionFailures[target.tmdbID] }

  /// `current` is the cached decision (from the view's `@Query`).
  func choose(_ choice: Decision.Choice, current: Decision.Choice?) {
    guard !isSaving else { return }
    let session = session
    let target = target
    decisionTask = Task { [weak self] in
      let outcome = await session.setDecision(choice, for: target, current: current)
      self?.finish(outcome)
    }
  }

  func retry() {
    guard !isSaving, failure != nil else { return }
    let session = session
    let tmdbID = target.tmdbID
    decisionTask = Task { [weak self] in
      let outcome = await session.retryDecision(tmdbID: tmdbID)
      self?.finish(outcome)
    }
  }

  private func finish(_ outcome: DecisionOutcome) {
    if case .saved = outcome {
      savedCount += 1
    }
  }
}
