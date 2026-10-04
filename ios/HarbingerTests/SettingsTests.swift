import Foundation
import SwiftData
import SwiftUI
import Testing

@testable import Harbinger

// I5: Settings (default model, sync, connection) and the taste profile editor.

/// Connections that Settings handed to "RootView".
@MainActor
final class AppliedConnections {
  var connections: [Connection] = []
}

@MainActor
struct SettingsTests {
  let day = timestamp("2026-10-01T12:00:00.000Z")
  let allowedModels = TurnScript(models: .success(testModels))

  // MARK: - Taste profile row

  @Test func profileIsStaleOnlyWhenSavedBeforeTheLastImport() {
    let later = day.addingTimeInterval(60)
    #expect(profileIsStale(updatedAt: day, lastImportAt: later))
    #expect(!profileIsStale(updatedAt: later, lastImportAt: day))
    #expect(!profileIsStale(updatedAt: day, lastImportAt: day))
    #expect(!profileIsStale(updatedAt: nil, lastImportAt: day))
    #expect(!profileIsStale(updatedAt: day, lastImportAt: nil))
    #expect(!profileIsStale(updatedAt: nil, lastImportAt: nil))
  }

  @Test func profileStatus() {
    #expect(profileStatusText(updatedAt: nil) == "Not set")
    #expect(profileStatusText(updatedAt: day, now: day) == "Updated just now")
    let text = profileStatusText(updatedAt: day, now: day.addingTimeInterval(3 * 86_400))
    #expect(text.hasPrefix("Updated "))
    #expect(text != "Updated just now")
  }

  @Test func versionText() {
    #expect(
      appVersionText(["CFBundleShortVersionString": "1.0", "CFBundleVersion": "2"]) == "1.0 (2)")
    #expect(appVersionText(["CFBundleShortVersionString": "1.0"]) == "1.0")
    #expect(appVersionText(nil) == "Unknown")
  }

  // MARK: - Default model

  @Test(arguments: [
    ("claude-opus-5-5", "claude-opus-5-5"),  // saved and allowed
    ("claude-retired-1", "claude-sonnet-5"),  // saved but no longer allowed
    (nil, "claude-sonnet-5"),  // none saved
  ])
  func defaultModelResolution(saved: String?, expected: String) async throws {
    let harness = try SessionHarness(turns: allowedModels, savedModel: saved)
    await harness.session.loadModels()

    #expect(harness.session.preferredModel == expected)
    // A new conversation's picker preselects the same model.
    #expect(ChatModel(session: harness.session, conversationID: nil).model == expected)
    // A saved model the server dropped is ignored, not deleted.
    #expect(harness.modelPreference.model() == saved)
  }

  @Test func withoutLoadedModelsTheServerChooses() async throws {
    let harness = try SessionHarness(savedModel: "claude-opus-5-5")
    await harness.session.loadModels()

    #expect(harness.session.allowedModels == nil)
    #expect(harness.session.preferredModel == nil)
    #expect(harness.session.savedModel == "claude-opus-5-5")
  }

  @Test func pickerSelectionSavesAndServerDefaultClears() async throws {
    let harness = try SessionHarness(turns: allowedModels, savedModel: "claude-retired-1")
    await harness.session.loadModels()
    let model = SettingsModel(session: harness.session, editor: nil)
    #expect(model.serverDefaultLabel == "Server default (claude-sonnet-5)")
    // Not allowed any more: the picker falls back to "Server default".
    #expect(model.modelSelection == nil)

    model.modelSelection = "claude-haiku-4-5-20251001"
    #expect(model.modelSelection == "claude-haiku-4-5-20251001")
    #expect(harness.modelPreference.model() == "claude-haiku-4-5-20251001")
    #expect(harness.session.preferredModel == "claude-haiku-4-5-20251001")
    #expect(
      ChatModel(session: harness.session, conversationID: nil).model
        == "claude-haiku-4-5-20251001")

    model.modelSelection = nil
    #expect(harness.modelPreference.model() == nil)
    #expect(harness.modelPreference.defaults.object(forKey: "defaultModel") == nil)
    #expect(harness.session.preferredModel == "claude-sonnet-5")
  }

  @Test func theChoiceOnTheChatScreenStillWins() async throws {
    let harness = try SessionHarness(turns: allowedModels, savedModel: "claude-opus-5-5")
    await harness.session.loadModels()
    let chat = ChatModel(session: harness.session, conversationID: nil)

    chat.selectedModel = "claude-haiku-4-5-20251001"

    #expect(chat.model == "claude-haiku-4-5-20251001")
  }

  // MARK: - Sync

  @Test func rebuildClearsTheCacheAndPullsInFull() async throws {
    let syncs = SyncRecorder([
      .success(makeSync(nextSince: Fixtures.nextSince, conversations: [makeConversation()])),
      .success(makeSync(conversations: [makeConversation(id: "conv-2", title: "Second")])),
      .success(makeSync(conversations: [makeConversation(id: "conv-3", title: "Third")])),
    ])
    let harness = try SessionHarness(syncs: syncs)
    let model = SettingsModel(session: harness.session, editor: nil)

    model.syncNow()
    await model.task?.value
    #expect(syncs.sinces == [nil])

    // Asking is not doing: nothing runs until the dialog confirms.
    model.isConfirmingRebuild = true
    #expect(syncs.sinces == [nil])

    model.confirmRebuild()
    await model.task?.value
    // A full pull (no cursor), and the old rows are gone.
    #expect(syncs.sinces == [nil, nil])
    let ids = try CacheReader(harness.container).all(CachedConversation.self).map(\.id)
    #expect(ids == ["conv-2"])

    // Sync Now is a normal delta.
    model.syncNow()
    await model.task?.value
    #expect(syncs.sinces == [nil, nil, "2026-09-29T19:00:00.000Z"])
    #expect(try CacheReader(harness.container).all(CachedConversation.self).count == 2)
  }

  @Test func aNewEndpointRebuildsAndAKeyChangeSyncs() async {
    let old = Connection(baseURL: testBaseURL, apiKey: testAPIKey)
    let moved = Connection(baseURL: URL(string: "http://localhost:8787")!, apiKey: testAPIKey)
    let rekeyed = Connection(baseURL: testBaseURL, apiKey: String(repeating: "n", count: 32))
    #expect(isDifferentServer(from: old, to: moved))
    #expect(!isDifferentServer(from: old, to: rekeyed))
    #expect(!isDifferentServer(from: nil, to: old))

    let service = FakeSyncService()
    let controller = SyncController(service: service)
    await controller.start(endpointChanged: true)
    #expect((service.calls, service.resets) == (0, 1))

    controller.connect(service)
    await controller.start(endpointChanged: false)
    #expect((service.calls, service.resets) == (1, 1))
  }

  @Test func rebuildErrorsShowLikeSyncErrors() async {
    let service = FakeSyncService(result: .failure(.api(.network(.timedOut))))
    let controller = SyncController(service: service)

    await controller.rebuild()

    #expect(controller.lastError == "Can't reach endpoint")
    #expect(!controller.isSyncing)
  }

  // MARK: - Connection

  struct ConnectionForm {
    let model: SettingsModel
    let configuration: AppConfiguration
    let recorder: HealthRecorder
    let applied: AppliedConnections
  }

  /// Settings over a saved connection (`testBaseURL` + `testAPIKey`).
  func connectionForm(health: Result<HealthResponse, APIError>) throws -> ConnectionForm {
    let harness = try SessionHarness()
    let recorder = HealthRecorder(result: health)
    let suite = "SettingsTests-\(UUID().uuidString)"
    let configuration = AppConfiguration(
      endpoints: EndpointStore(defaults: try #require(UserDefaults(suiteName: suite))),
      credentials: InMemoryCredentialStore(key: testAPIKey),
      makeClient: { recorder.makeClient($0) })
    configuration.endpoints.save(testBaseURL)
    let applied = AppliedConnections()
    let editor = ConnectionEditor(
      configuration: configuration, apply: { applied.connections.append($0) })
    return ConnectionForm(
      model: SettingsModel(session: harness.session, editor: editor),
      configuration: configuration, recorder: recorder, applied: applied)
  }

  let saved = Connection(baseURL: testBaseURL, apiKey: testAPIKey)
  let healthy = Result<HealthResponse, APIError>.success(HealthResponse(status: "ok"))

  @Test func saveConnectionIsEnabledOnlyByAChange() throws {
    let form = try connectionForm(health: healthy)
    let model = form.model
    #expect(model.endpoint == "https://api.example.test")
    #expect(model.apiKey.isEmpty)
    #expect(!model.canSaveConnection)

    // The same endpoint written differently is not a change.
    model.endpoint = " https://API.example.test/ "
    #expect(!model.canSaveConnection)
    model.endpoint = "http://localhost:8787"
    #expect(model.canSaveConnection)
    model.endpoint = "https://api.example.test"
    model.apiKey = "  "
    #expect(!model.canSaveConnection)
    model.apiKey = "new"
    #expect(model.canSaveConnection)
  }

  @Test func invalidURLMakesNoRequest() async throws {
    let form = try connectionForm(health: healthy)
    form.model.endpoint = "http://api.example.test"

    #expect(await form.model.saveConnection() == nil)

    #expect(form.model.connectionError == SetupViewModel.invalidURLMessage)
    #expect(form.recorder.connections.isEmpty)
    #expect(form.applied.connections.isEmpty)
    #expect(form.configuration.connection() == saved)
  }

  @Test func rejectedKeySavesNothing() async throws {
    let form = try connectionForm(health: .failure(.unauthorized))
    form.model.apiKey = String(repeating: "n", count: 32)

    #expect(await form.model.saveConnection() == nil)

    #expect(form.model.connectionError == "Key rejected")
    #expect(form.applied.connections.isEmpty)
    #expect(form.configuration.connection() == saved)
    #expect(!form.model.isChecking)
  }

  @Test func unreachableEndpointSavesNothing() async throws {
    let form = try connectionForm(health: .failure(.network(.cannotConnectToHost)))
    form.model.endpoint = "http://localhost:8787"

    #expect(await form.model.saveConnection() == nil)

    #expect(form.model.connectionError == "Can't reach endpoint")
    #expect(form.configuration.connection() == saved)
    #expect(form.applied.connections.isEmpty)
  }

  @Test func newEndpointIsCheckedWithTheSavedKeyThenHandedOff() async throws {
    let form = try connectionForm(health: healthy)
    form.model.endpoint = " http://localhost:8787/ "
    let moved = Connection(baseURL: URL(string: "http://localhost:8787")!, apiKey: testAPIKey)

    #expect(await form.model.saveConnection() == moved)

    // No new key was entered: the health check used the saved one.
    #expect(form.recorder.connections == [moved])
    #expect(form.configuration.connection() == moved)
    #expect(form.applied.connections == [moved])
    #expect(form.model.connectionError == nil)
    // A different server: the session that follows rebuilds the cache.
    #expect(isDifferentServer(from: saved, to: moved))
  }

  @Test func newKeyOnlyKeepsTheServer() async throws {
    let form = try connectionForm(health: healthy)
    let newKey = String(repeating: "n", count: 32)
    form.model.apiKey = " \(newKey) "
    let rekeyed = Connection(baseURL: testBaseURL, apiKey: newKey)

    #expect(await form.model.saveConnection() == rekeyed)

    #expect(form.recorder.connections == [rekeyed])
    #expect(form.configuration.connection() == rekeyed)
    #expect(form.applied.connections == [rekeyed])
    // The typed key is cleared, never left on screen.
    #expect(form.model.apiKey.isEmpty)
    #expect(!isDifferentServer(from: saved, to: rekeyed))
  }
}

// MARK: - Taste profile editor

@MainActor
struct TasteProfileEditorTests {
  let savedProfile = makeProfile("## Loves\nSlow dread.\n\n## Notes\nNo clowns.")
  let draft = TasteProfileDraft(
    content: "## Loves\nSlow dread, folk horror.\n\n## Notes\nNo clowns.",
    changes: ["Added folk horror to Loves"])

  func harness(
    drafts: [Result<TasteProfileDraft, APIError>] = [],
    saves: [Result<TasteProfile, APIError>] = [], delay: Duration? = nil,
    cached: Bool = true, turns: TurnScript = TurnScript(), savedModel: String? = nil
  ) async throws -> SessionHarness {
    let harness = try SessionHarness(
      turns: turns, profiles: ProfileScript(drafts: drafts, saves: saves, delay: delay),
      savedModel: savedModel)
    if cached {
      try await harness.session.syncService.ingest(savedProfile)
    }
    return harness
  }

  /// An editor that has been told the cached content, as the view does on appear.
  func editor(_ harness: SessionHarness) throws -> TasteProfileEditorModel {
    let model = TasteProfileEditorModel(session: harness.session)
    model.cacheChanged(try cachedContent(harness) ?? "")
    return model
  }

  func cachedContent(_ harness: SessionHarness) throws -> String? {
    try CacheReader(harness.container).all(CachedTasteProfile.self).first?.content
  }

  // MARK: State

  @Test func startsFromTheCachedProfile() async throws {
    let model = try editor(try await harness())
    #expect(model.text == savedProfile.content)
    #expect(!model.isDirty)
    #expect(model.draftTitle == "Redraft")
    #expect(!model.canSave)

    let empty = try editor(try await harness(cached: false))
    #expect(empty.text.isEmpty)
    #expect(!empty.isDirty)
    #expect(empty.draftTitle == "Draft")
    #expect(!empty.canSave)
  }

  @Test func saveNeedsAChangeAndAValidLength() async throws {
    let model = try editor(try await harness())
    let ghost = "\u{1F47B}"  // two UTF-16 units

    model.text = savedProfile.content + " More."
    #expect(model.isDirty)
    #expect(model.canSave)

    model.text = " \n "
    #expect(model.isDirty)
    #expect(!model.canSave)

    model.text = String(repeating: ghost, count: 2000)
    #expect(model.length == 4000)
    #expect(model.canSave)
    #expect(!model.isOverLimit)

    model.text = String(repeating: ghost, count: 2000) + "x"
    #expect(model.length == 4001)
    #expect(model.isOverLimit)
    #expect(!model.canSave)

    // Surrounding whitespace doesn't count: the server trims.
    model.text = "  " + String(repeating: "x", count: 4000) + "\n"
    #expect(model.canSave)

    model.text = savedProfile.content
    #expect(!model.isDirty)
    #expect(!model.canSave)
  }

  @Test func theEditorFollowsTheCacheOnlyWhileNothingIsUnsaved() async throws {
    let model = try editor(try await harness())

    model.cacheChanged("Synced from elsewhere.")
    #expect(model.text == "Synced from elsewhere.")
    #expect(!model.isDirty)

    model.text = "My edits."
    model.cacheChanged("Synced again.")
    #expect(model.text == "My edits.")
    #expect(model.isDirty)
  }

  // MARK: Draft

  @Test func draftReplacesTheTextAndShowsChangesWithoutSaving() async throws {
    let harness = try await harness(
      drafts: [.success(draft)], turns: TurnScript(models: .success(testModels)),
      savedModel: "claude-opus-5-5")
    await harness.session.loadModels()
    let model = try editor(harness)

    model.requestDraft()
    #expect(!model.isConfirmingDraft)
    await model.task?.value

    #expect(model.text == draft.content)
    #expect(model.changes == ["Added folk horror to Loves"])
    #expect(!model.isFirstDraft)
    #expect(model.canSave)
    #expect(!model.isDrafting)
    // Same model resolution as new conversations; nothing was saved or cached.
    #expect(harness.profiles.calls == [.draft(model: "claude-opus-5-5")])
    #expect(try cachedContent(harness) == savedProfile.content)
  }

  @Test func firstDraftHasNoChangesToList() async throws {
    let first = TasteProfileDraft(content: "## Loves\nSlow dread.", changes: [])
    let harness = try await harness(drafts: [.success(first)], cached: false)
    let model = try editor(harness)

    model.requestDraft()
    await model.task?.value

    #expect(model.isFirstDraft)
    #expect(model.text == first.content)
    #expect(model.canSave)
    // Models never loaded: the server picks the model.
    #expect(harness.profiles.calls == [.draft(model: nil)])
    #expect(try cachedContent(harness) == nil)
  }

  @Test func draftingOverUnsavedEditsAsksFirst() async throws {
    let harness = try await harness(drafts: [.success(draft)])
    let model = try editor(harness)
    model.text = "My unsaved edits."

    model.requestDraft()
    #expect(model.isConfirmingDraft)
    #expect(model.task == nil)
    #expect(harness.profiles.calls.isEmpty)
    #expect(model.text == "My unsaved edits.")

    model.confirmDraft()
    await model.task?.value
    #expect(model.text == draft.content)
    #expect(harness.profiles.calls.count == 1)
  }

  @Test(arguments: [
    (
      APIError.server(status: 422, code: "no_ratings", message: "x", retryAfter: nil),
      "Import your Letterboxd ratings first."
    ),
    (
      .server(status: 503, code: "claude_unavailable", message: "x", retryAfter: 5),
      "The service is busy — try again in a moment."
    ),
    (.network(.timedOut), "Can't reach the server."),
    (.unauthorized, "API key rejected — update it in Settings."),
    (serverError(502), "Couldn't draft — try again."),
    (.decoding("x"), "Something went wrong."),
  ])
  func draftFailureKeepsTheText(error: APIError, text: String) async throws {
    let model = try editor(try await harness(drafts: [.failure(error)]))

    model.requestDraft()
    await model.task?.value

    #expect(model.errorMessage == text)
    #expect(model.text == savedProfile.content)
    #expect(model.changes.isEmpty)
    #expect(!model.canSave)
  }

  @Test func editingAndSavingAreOffWhileDrafting() async throws {
    let harness = try await harness(drafts: [.success(draft)], delay: .milliseconds(300))
    let model = try editor(harness)
    model.text = "Edited."
    model.confirmDraft()
    await eventually { model.isDrafting }

    #expect(model.isBusy)
    #expect(!model.canSave)
    // A second draft while one is in flight makes no request.
    model.requestDraft()
    #expect(await harness.session.draftTasteProfile() == .rejected)

    await model.task?.value
    #expect(harness.profiles.calls.count == 1)
    #expect(!model.isBusy)
  }

  // MARK: Save

  @Test func saveSendsTheTrimmedTextAndUpdatesTheCache() async throws {
    let edited = "## Loves\nSlow dread, folk horror.\n\n## Notes\nNo clowns."
    let updated = TasteProfile(
      content: edited, basedOnImportId: 3, updatedAt: timestamp("2026-10-04T12:00:00.000Z"))
    let harness = try await harness(drafts: [.success(draft)], saves: [.success(updated)])
    let model = try editor(harness)
    model.requestDraft()
    await model.task?.value
    model.text = "  \(edited)\n\n"

    model.save()
    await model.task?.value

    #expect(harness.profiles.calls.last == .save(content: edited))
    #expect(try cachedContent(harness) == edited)
    #expect(try CacheReader(harness.container).all(CachedTasteProfile.self).count == 1)
    #expect(model.text == edited)
    #expect(!model.isDirty)
    #expect(model.changes.isEmpty)
    #expect(!model.isFirstDraft)
    #expect(!model.canSave)
    #expect(model.errorMessage == nil)
  }

  @Test(arguments: [
    (APIError.network(.notConnectedToInternet), "You're offline."),
    (serverError(500), "Couldn't save — try again."),
    (.invalidResponse, "Something went wrong."),
  ])
  func saveFailureLeavesTheCacheUnchanged(error: APIError, text: String) async throws {
    let harness = try await harness(saves: [.failure(error)])
    let model = try editor(harness)
    model.text = "Edited."

    model.save()
    await model.task?.value

    #expect(model.errorMessage == text)
    #expect(try cachedContent(harness) == savedProfile.content)
    // The edits are still there to retry.
    #expect(model.text == "Edited.")
    #expect(model.canSave)
  }

  @Test func invalidContentMakesNoRequest() async throws {
    let harness = try await harness()

    #expect(await harness.session.saveTasteProfile(content: " \n ") == .invalid)
    let tooLong = String(repeating: "x", count: 4001)
    #expect(await harness.session.saveTasteProfile(content: tooLong) == .invalid)
    #expect(harness.profiles.calls.isEmpty)
  }

  // MARK: Leaving

  @Test func leavingWithUnsavedEditsAsksFirst() async throws {
    let model = try editor(try await harness())
    #expect(model.requestLeave())
    #expect(!model.isConfirmingDiscard)

    model.text = "Edited."
    #expect(!model.requestLeave())
    #expect(model.isConfirmingDiscard)
  }

  @Test func requestsFinishAfterTheEditorIsReleased() async throws {
    let updated = TasteProfile(
      content: "Edited.", basedOnImportId: 3, updatedAt: timestamp("2026-10-04T12:00:00.000Z"))
    let harness = try await harness(
      drafts: [.success(draft)], saves: [.success(updated)], delay: .milliseconds(300))
    let session = harness.session

    // A save still lands in the cache.
    var model: TasteProfileEditorModel? = try editor(harness)
    weak let released = model
    model?.text = "Edited."
    model?.save()
    await eventually { session.isSavingProfile }
    model = nil
    #expect(released == nil)
    try await eventually { try cachedContent(harness) == "Edited." && !session.isSavingProfile }
    #expect(try cachedContent(harness) == "Edited.")

    // A draft is simply dropped: drafts are never saved.
    model = try editor(harness)
    weak let releasedAgain = model
    model?.requestDraft()
    await eventually { session.isDraftingProfile }
    model = nil
    #expect(releasedAgain == nil)
    await eventually { !session.isDraftingProfile }
    #expect(!session.isDraftingProfile)
    #expect(try cachedContent(harness) == "Edited.")
  }
}

// MARK: - Screens

extension ScreenSmokeTests {
  @Test func settingsRenders() async throws {
    let harness = try SessionHarness(turns: TurnScript(models: .success(testModels)))
    await harness.session.loadModels()
    try await harness.session.syncService.ingest(makeProfile("## Loves\nSlow dread."))
    let editor = ConnectionEditor(
      configuration: AppConfiguration(credentials: InMemoryCredentialStore()), apply: { _ in })
    try await render(
      NavigationStack { SettingsView(session: harness.session, editor: editor) }
        .environment(harness.session)
        .modelContainer(harness.container))
  }

  @Test func settingsRendersWithoutModelsOrAProfile() async throws {
    let harness = try SessionHarness()
    try await render(
      NavigationStack { SettingsView(session: harness.session, editor: nil) }
        .environment(harness.session)
        .modelContainer(harness.container))
  }

  @Test func tasteProfileEditorRenders() async throws {
    let harness = try SessionHarness()
    try await harness.session.syncService.ingest(makeProfile("## Loves\nSlow dread."))
    try await render(
      NavigationStack { TasteProfileEditorView(session: harness.session) }
        .environment(harness.session)
        .modelContainer(harness.container))
  }
}
