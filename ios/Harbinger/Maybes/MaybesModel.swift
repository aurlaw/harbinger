import Foundation
import Observation

/// Promotions from the Maybes list. The requests run on `AppSession` (like every decision),
/// so they outlive this object; this holds the No confirmation and the error alert.
@Observable
final class MaybesModel {
  let session: AppSession
  /// The film whose No is waiting for confirmation.
  var noCandidate: MaybeItem?
  /// The last failure, shown in an alert until dismissed.
  var errorMessage: String?
  /// The request started by this screen, for tests and callers that want to wait.
  private(set) var task: Task<Void, Never>?

  init(session: AppSession) {
    self.session = session
  }

  /// A decision for the film is in flight (from here or from the detail screen).
  func isSaving(_ item: MaybeItem) -> Bool {
    session.pendingDecisions[item.tmdbID] != nil
  }

  /// Saves Yes; the session then opens the film on Letterboxd.
  func promoteToYes(_ item: MaybeItem) {
    promote(item, to: .yes)
  }

  /// No is permanent, so it asks first.
  func askNo(_ item: MaybeItem) {
    guard !isSaving(item) else { return }
    noCandidate = item
  }

  /// Call from the confirmation only.
  func confirmNo() {
    guard let item = noCandidate else { return }
    noCandidate = nil
    promote(item, to: .no)
  }

  private func promote(_ item: MaybeItem, to choice: Decision.Choice) {
    guard !isSaving(item) else { return }
    let session = session
    task = Task { [weak self] in
      let outcome = await session.setDecision(choice, for: item.target, current: .maybe)
      if case .failed(let failure) = outcome {
        self?.errorMessage = failure.message
      }
    }
  }
}
