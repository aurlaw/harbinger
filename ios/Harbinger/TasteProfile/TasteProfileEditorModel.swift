import Foundation
import Observation

/// The taste profile editor: the text being edited and the last draft's changes. Drafts are
/// view state only; the cache changes when a save succeeds. The requests run on
/// `AppSession`, so they outlive this object (a draft that finishes afterwards is dropped).
@Observable
final class TasteProfileEditorModel {
  let session: AppSession
  var text = ""
  /// The cached profile's content (empty when there is none).
  private(set) var savedContent = ""
  /// A draft has been loaded into the editor and not yet saved.
  private(set) var hasDraft = false
  /// What the last draft changed; empty for a first draft.
  private(set) var changes: [String] = []
  var isConfirmingDraft = false
  var isConfirmingDiscard = false
  var errorMessage: String?
  /// The request started by this screen, for tests and callers that want to wait.
  private(set) var task: Task<Void, Never>?

  init(session: AppSession) {
    self.session = session
  }

  var hasProfile: Bool { !savedContent.isEmpty }
  var isDirty: Bool { text != savedContent }
  var isDrafting: Bool { session.isDraftingProfile }
  var isSaving: Bool { session.isSavingProfile }
  var isBusy: Bool { isDrafting || isSaving }

  var draftTitle: String { hasProfile ? "Redraft" : "Draft" }
  /// A draft made with no saved profile: there is nothing to list as changed.
  var isFirstDraft: Bool { hasDraft && !hasProfile && changes.isEmpty }

  var length: Int { ProfileLimit.length(text) }
  var isOverLimit: Bool { length > ProfileLimit.maxLength }

  var canSave: Bool {
    !isBusy && (isDirty || hasDraft) && ProfileLimit.isValid(text)
  }

  /// The view reports the cached content (on appear, and when a sync or save changes it).
  /// The editor follows it only while there is nothing unsaved to lose.
  func cacheChanged(_ content: String) {
    let follows = !isDirty && !hasDraft
    savedContent = content
    if follows {
      text = content
    }
  }

  /// The server drafts from the saved profile, so unsaved edits would be replaced: ask first.
  func requestDraft() {
    guard !isBusy else { return }
    if isDirty {
      isConfirmingDraft = true
    } else {
      startDraft()
    }
  }

  func confirmDraft() {
    guard !isBusy else { return }
    startDraft()
  }

  func save() {
    guard canSave else { return }
    let session = session
    let content = text
    task = Task { [weak self] in
      let outcome = await session.saveTasteProfile(content: content)
      self?.finish(outcome)
    }
  }

  /// Back was tapped. `true` means leave now; otherwise the discard dialog is showing.
  func requestLeave() -> Bool {
    if isDirty {
      isConfirmingDiscard = true
      return false
    }
    return true
  }

  private func startDraft() {
    let session = session
    task = Task { [weak self] in
      let outcome = await session.draftTasteProfile()
      self?.finish(outcome)
    }
  }

  private func finish(_ outcome: ProfileDraftOutcome) {
    switch outcome {
    case .drafted(let draft):
      text = draft.content
      changes = draft.changes
      hasDraft = true
    case .failed(let message):
      errorMessage = message
    case .rejected:
      break
    }
  }

  private func finish(_ outcome: ProfileSaveOutcome) {
    switch outcome {
    case .saved(let profile):
      // The server's copy (trimmed) is now both the saved and the edited text.
      savedContent = profile.content
      text = profile.content
      hasDraft = false
      changes = []
    case .failed(let message):
      errorMessage = message
    case .invalid, .rejected:
      break
    }
  }
}
