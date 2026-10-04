# CLAUDE.md — harbinger/ios

Native Swift/SwiftUI iOS app (iPhone only, iOS 26, Swift 6). Talks only to the Worker at `harbinger-api.aurlaw.dev`. Read the repo-root `CLAUDE.md` first. Its working agreement applies here.

## Layout

- `Harbinger/HarbingerApp.swift`: app entry; creates the one `ModelContainer` (skipped when hosting unit tests), the live `AppConfiguration`, and the enlarged `URLCache.shared`
- `Harbinger/RootView.swift`: shows the first-launch sheet until an endpoint + key are saved; owns the `SyncController`; once a connection exists builds the `SyncService` and `AppSession`, injects the session, and syncs on launch / foreground
- `Harbinger/Session/AppSession.swift`: the connected session (client, `SyncService`, `SyncController`, models and the saved default model, turns, decisions, deletes, renames, and taste-profile draft / save in flight, the external-link opener); `TurnTarget`, `TurnRequest`, `PendingTurn`, `TurnFailure`, `TurnOutcome`; `DecisionTarget`, `DecisionRequest`, `DecisionFailure`, `DecisionOutcome`; `DeleteOutcome`, `RenameOutcome`; `ProfileDraftOutcome`, `ProfileSaveOutcome`
- `Harbinger/Conversations/ConversationListView.swift`: the root screen (swipe / long-press delete and rename); `Route` and the stack's `navigationDestination`
- `Harbinger/Conversations/ConversationActions.swift`: delete / rename for a screen (`canDelete`, the error alert text); `RenameAlert.swift`: `RenameTarget`, the shared `renameAlert` and `actionErrorAlert` modifiers
- `Harbinger/Settings/`: `SettingsView` (the one `Form` behind the gear), `SettingsModel` (default-model picker, sync / rebuild, connection form), `ConnectionEditor` + the `connectionEditor` environment value, `profileStatusText`, `appVersionText`
- `Harbinger/TasteProfile/`: `TasteProfileEditorView`, `TasteProfileEditorModel` (text, dirty tracking, draft changes, the confirmations)
- `Harbinger/Chat/`: `ChatView` (transcript, bubbles, chips, typing indicator, error row), `ChatModel` (draft, model choice, send / just pick / chip / retry), `Composer`, `PickCard` + `Poster` (`w185` cards, `w500` detail)
- `Harbinger/Detail/`: `PickDetailView` (poster, title + metadata, why, overview, where to watch, links, decision bar), `PickDetailModel` (decision bar state), `DetailText.swift` (link builders, runtime / metadata text, provider labels, decision error text, `PickDetailInfo`)
- `Harbinger/Shared/`: `tmdbImageURL` + `TMDBImageSize`; `DisplayText.swift` (turn / delete / rename error text, bubble text, list dates, `DecisionBadge`, `MessageLimit`, `TitleLimit`, `ProfileLimit`, draft / profile-save error text, `profileIsStale`); `FlowLayout` (wrapping chips)
- `Harbinger/Config/Endpoint.swift`: `normalizeEndpoint` (https only; http for `localhost` / `127.0.0.1`), `defaultEndpoint`
- `Harbinger/Config/CredentialStore.swift`: `CredentialStore` protocol + `KeychainCredentialStore` (service `com.aurlaw.harbinger`, account `api-key`, `AfterFirstUnlockThisDeviceOnly`)
- `Harbinger/Config/AppConfiguration.swift`: `EndpointStore` (UserDefaults `endpointURL`), `ModelPreferenceStore` (UserDefaults `defaultModel`), `resolveModel`, `Connection`, `isDifferentServer`, `AppConfiguration` (stores + client factory)
- `Harbinger/API/APIClient.swift`: `APIClient` protocol (one method per app endpoint), `URLSessionAPIClient`, `RequestTimeout`
- `Harbinger/API/Models.swift`: DTOs matching `api-surface` and the Worker's mappers (`worker/src/conversations/store.ts`, `worker/src/sync/handlers.ts`)
- `Harbinger/API/APIError.swift`: `APIError` + the Worker's error envelope
- `Harbinger/API/JSONCoding.swift`: snake_case coders; fractional-second timestamp parsing/formatting
- `Harbinger/Setup/`: first-launch sheet (`SetupView`) + `SetupViewModel`; `ConnectionCheck.swift`: `verifyAndSave` (normalize → `/health` → save) and its error text, shared with Settings
- `Harbinger/Store/CachedModels.swift`: the six SwiftData models (`CachedConversation`, `CachedMessage`, `CachedRecommendation`, `CachedDecision`, `CachedTasteProfile`, `SyncState`) + `CachedProvider`
- `Harbinger/Store/CacheMapping.swift`: DTO → cache mapping (`apply`) and typed accessors (`content`, `messageRole`, `choice`). The only place DTO names (`tmdbId`) become cache names (`tmdbID`)
- `Harbinger/Store/CacheStore.swift`: schema, store URL, `openOrRebuild`, `inMemory()` for tests
- `Harbinger/Sync/SyncService.swift`: the model actor: `sync()`, `resetAndSync()`, `ingest(_:)`, `removeConversation(id:)`; `SyncError`, `SyncResult`, `SyncServicing`
- `Harbinger/Sync/SyncService+Apply.swift`: `CacheBatch` + the shared upsert logic
- `Harbinger/Sync/SyncController.swift`: main-actor `@Observable`; decides when to sync (`syncIfStale`, `syncNow`, `rebuild`, `start(endpointChanged:)`), exposes `isSyncing` / `lastError`
- `HarbingerTests/`: Swift Testing. `TestSupport.swift` has `StubURLProtocol`, `InMemoryCredentialStore`, `FakeAPIClient` (scripted `health()` and `sync(since:)` via `SyncRecorder`); `SyncTestSupport.swift` has DTO builders, `CacheReader`, `FakeSyncService`; `RootViewTests.swift` hosts the real root view in the test host's window; `AppSessionTests.swift` has `SessionHarness` (fake Worker + in-memory cache + real `SyncService`) and `eventually`; `ScreenSmokeTests.swift` renders each screen so its `@Query` predicates run; `DecisionScript`, `ManagementScript`, `ProfileScript`, and `OpenRecorder` (in `TestSupport.swift`) script decisions, rename / delete, taste-profile draft / save, and capture opened links; `SessionHarness` gives each session a throwaway `ModelPreferenceStore` suite; `SettingsTests.swift` covers I5; `ConversationManagementTests.swift` covers I4b (its client tests extend `APIClientTests`, so they share that suite's `.serialized`); `Fixtures.swift` has real-shaped response bodies

## Commands

Use `make build`, `make test`, `make lint` (run from `ios/`). Never run raw `xcodebuild`, and never edit `Harbinger.xcodeproj` / `project.pbxproj`. The project uses folder-synchronized groups, so new files under `Harbinger/` or `HarbingerTests/` are picked up automatically. If something can only be done in the project file, stop and list it as a manual step for Michael.

- `SIMULATOR` (default `iPhone 17`) and `OS` (default `latest`) are overridable: `make test SIMULATOR="iPhone 17 Pro"`
- `make test` runs `HarbingerTests` only (UI tests are skipped)
- `make lint` is `swift-format lint --strict` with the default configuration (2-space indent, 100-column lines)

No signing changes, device builds, git, or requests to the real Worker.

## Concurrency (Swift 6, default MainActor isolation)

The app target defaults every unannotated declaration to `@MainActor`. That's right for views and view models. The API and config layers must be usable from the sync model actor (I2):

- DTOs: `nonisolated struct … : Codable, Sendable, Equatable`
- `APIClient` is `Sendable`; `URLSessionAPIClient` is a `nonisolated final class` with only immutable stored properties
- Keychain, endpoint store, and pure helpers (`normalizeEndpoint`, timestamp parsing, coders) are `nonisolated`
- Views and view models stay main-actor (the default)
- SwiftData models are `@Model nonisolated final class`. A model actor can't create or mutate main-actor-isolated models, so this is required. Their extensions are `nonisolated extension`
- No `@unchecked Sendable`. `nonisolated(unsafe)` is allowed only in test stubs (`StubURLProtocol`'s shared handler), and suites using the stub must be `@Suite(.serialized)`

## API client rules

- Every failure is an `APIError`, thrown with typed throws. `401` → `.unauthorized`; enveloped non-2xx → `.server` (with `Retry-After`); `URLError` → `.network`; a 2xx that doesn't match the DTO → `.decoding`; non-HTTP or an error response without the envelope → `.invalidResponse`
- Timeouts are set per request (`RequestTimeout`). Conversation turns and taste-profile drafts get 180 s
- **No-content responses:** `DELETE /conversations/{id}` answers `204` with an empty body, so it goes through `sendNoContent`, which maps statuses and errors exactly like `send` (both run `perform`) but doesn't decode a `2xx`. Don't loosen `send` to tolerate empty bodies
- `Conversation.deletedAt` is optional: responses without `deleted_at` still decode. `renameConversation` returns the bare `Conversation`, not a `ConversationResponse`
- Build paths with `URL.append(component:)` / query items. Never concatenate user input into a URL string
- No retries in the client
- The sync cursor (`next_since` / `server_time`) stays the exact server `String`. Never round-trip it through `Date`
- Server timestamps have fractional seconds, which `.iso8601` rejects. Use `makeDecoder()` / `makeEncoder()`, never a bare `JSONDecoder`

## Cache and sync

The SwiftData store is a **disposable read cache**. The Worker is the source of truth and everything is rebuilt from `/sync`.

- **Naming:** DTOs own the plain names (`Conversation`, `Message`, …). SwiftData models take a `Cached` prefix. Don't rename the DTOs
- **Models:** enum-like fields (`role`, `kind`, `decision`) are stored as raw `String`s for simple `#Predicate`s, with typed accessors. Message content is flattened into `text` / `justPick` / `chips` / `dropped`; `CachedMessage.content` rebuilds the `MessageContent` enum. Every property except the unique key has a default value, so additive changes migrate
- **Decisions** are one row per `tmdbID`, separate from recommendations (a film can appear in several conversations)
- **Container:** one `ModelContainer`, created once in `HarbingerApp` and shared by `.modelContainer(_:)` and `SyncService`. Store at `Application Support/Harbinger.store`. If it can't be opened, `CacheStore.openOrRebuild` deletes the store files and retries once; a second failure is a `fatalError`. No `VersionedSchema` or migration plan. Tests use `CacheStore.inMemory()`
- **One writer:** `SyncService` is the only code that writes to the cache. Views read with `@Query`. It conforms to `ModelActor` by hand because the `@ModelActor` macro's initializer can't take the API client; create it with `SyncService.make` so it's built off the main actor
- **Upsert by id:** one fetch per model for the incoming ids, then update in place or insert. Never rely on `@Attribute(.unique)` insert collisions. Order: conversations → messages → recommendations → decisions → profile. A child whose parent is neither in the batch nor cached is skipped and logged
- **Delta semantics:** empty arrays mean no changes. **`taste_profile: null` means unchanged. Never delete the cached profile because of it.**
- **Tombstones are the only delete path in `apply`:** a conversation DTO with `deletedAt != nil` deletes the cached conversation with its messages and recommendations; if it isn't cached it is ignored (a tombstone is never inserted), and content in the same batch for a tombstoned conversation is skipped. `SyncResult.conversationsDeleted` counts them. **`CachedDecision` rows are never deleted or modified because of a conversation delete, in any path** — a No stays a No. Otherwise rows are only deleted by `removeConversation(id:)`, `resetAndSync()`, and the container-rebuild path
- **Deleting a conversation's rows:** fetch its recommendations and messages by `conversationID` and delete them explicitly, then the conversation (`delete(_:)` in `SyncService+Apply.swift`). Don't rely on the cascade rule or walk `conversation.messages`: after either, `rollback()` on a failed save trips a SwiftData assertion and crashes (found on iOS 26.5; `failedDeletesRollBack` covers it)
- **Idempotent:** the Worker's 120 s overlap re-sends rows, so applying a response twice must leave identical state
- **The cursor advances only with the data it covers:** the apply and the `SyncState` update are one `modelContext.save()`. An API error applies nothing; an apply or save error calls `rollback()`. Either way `nextSince` is unchanged
- **No overlapping syncs:** a `sync()` call made while one is running awaits the same in-flight task. The task clears itself when it finishes
- **Model-actor executor gotchas** (verified on iOS 26.5): a `Task { }` created inside the actor starts running immediately, before the creating code continues, so never assume "the line after `Task { }` runs first". And a service built on the main actor does its work on the main thread, which is why `SyncService.make` is `@concurrent`
- **Logging:** each sync logs its cursor, row counts, and failures to `Logger` category `sync` (subsystem `com.aurlaw.harbinger`). Never log the API key
- **Ingest helpers** (`ingest(ConversationResponse)`, `ingest(Conversation)`, `ingest(Decision)`, `ingest(TasteProfile)`) put write responses straight into the cache through the same upsert path. One save each, and they never move the cursor; the next `/sync` re-delivers those rows harmlessly. `ingest(Conversation)` (a rename response) upserts the conversation row only; one with `deletedAt` set is a tombstone. `removeConversation(id:)` drops a conversation after a successful `DELETE` (or a `404`): one save, no cursor change, decisions kept, unknown id is not an error
- **One long-lived `SyncController`:** `RootView` creates it up front and attaches the service with `connect(_:)` once a connection exists. Give views the controller non-optionally from their first render. A `List` keeps the `.refreshable` action it was first given, so a controller that starts as `nil` leaves pull-to-refresh doing nothing (`RootViewTests` covers this)
- **Triggers:** `SyncController.syncIfStale()` on launch and when the scene becomes active, skipped if a sync succeeded in the last 30 s. `syncNow()` (pull-to-refresh) always runs. Sync errors are non-fatal and never block the UI
- **Test host:** `make test` launches the app as the test host. `isHostingTests` makes it skip the live store and sync, so a simulator with a saved key never calls the real Worker. Keep that guard

## Session, navigation, and chat

- **`AppSession`** is created by `RootView` once a connection exists and injected with `.environment(_:)`. Views get the client, sync, and models from it, with no singletons. A new session (new connection) re-creates the screens (`.id(ObjectIdentifier(session))`), because lists keep their first refresh action
- **Sending lives on the session, not in views.** `send(_:)` runs the request and `ingest` in a task the session owns, so a turn survives leaving (and releasing) the chat screen. One turn in flight per `TurnTarget` (each conversation, plus one `.new` slot); a second send is `.rejected` with no request. `pending` and `failures` are keyed by target, so returning to a chat shows its typing indicator or error row. `retry(_:)` resends the identical `TurnRequest`. No client-side reconciliation: if a request is cut off, the next sync delivers whatever the Worker committed. If ingest fails after a successful response, the session runs a sync instead
- **Models:** `loadModels()` runs once per session. On failure `defaultModel` / `allowedModels` stay `nil`: the picker is hidden and new conversations omit `model`. The model is sent only when creating a conversation
- **Default-model resolution** (`resolveModel`, `AppSession.preferredModel`): the saved default (`UserDefaults` key `defaultModel`) **if it is still in `allowed`** → else the server default → `nil` when models didn't load (the server chooses). A saved model that leaves `allowed` is ignored, never deleted. New-conversation preselection (`ChatModel.model`: the on-screen choice, else `preferredModel`) and taste-profile drafts both use it
- **The cache only holds server data.** The pending bubble is session state, never a cached row; the transcript renders from `@Query`, and the pending entry is cleared only after ingest
- **Routes** (`Route`, value-based `NavigationLink` + one `navigationDestination` on the list): `.conversation(id)`, `.newConversation`, `.recommendation(id)` (`PickDetailView`), `.settings` (`SettingsView`), `.tasteProfile` (`TasteProfileEditorView`, pushed from Settings)
- **New conversations** switch to the returned id in place (`ChatModel.conversationID`; the transcript is re-created with `.id`), with no extra push
- **Composer rules:** text is trimmed; 1–2,000 characters counted as UTF-16 (`MessageLimit`, matching the Worker's JS `length`); over the limit disables Send and Just pick and shows a count. Just pick works with or without text on an existing conversation, but **a new conversation needs text**: `POST /conversations` requires it even with `just_pick`. Chips are live only on the latest message while nothing is sending. A failed send restores its text to the composer
- **Posters:** TMDB returns only a path; build URLs with `tmdbImageURL(path:size:)` (single slash, `nil` for a missing path). Sizes: `w185` cards, `w500` detail (I4), `w92` provider logos (I4). `HarbingerApp` sets `URLCache.shared` to 50 MB memory / 300 MB disk so seen posters load offline; `AsyncImage` uses it. No custom image loader
- **Turn error text** (`turnErrorMessage`; I6 refines):

| Error | Text |
|---|---|
| `409 conversation_busy` | "Still working on the last message." |
| `503 claude_unavailable` / `tmdb_rate_limited` | "The service is busy — try again in a moment." |
| any `502` (`claude_error`, `tmdb_unavailable`, `recommendation_failed`) | "Couldn't get recommendations — try again." |
| `.network` | "Can't reach the server." |
| `.unauthorized` | "API key rejected." |
| anything else | "Something went wrong." |

## Conversation management (delete + rename)

- **Server first, always.** The cache only changes from a server response: no optimistic removal, no local-only titles. Both requests run in session-owned tasks (like turns and decisions), so they finish and update the cache even if the screen that started them is released
- **Delete** (`AppSession.deleteConversation(id:)`): **refused while a turn is in flight for that conversation** (`.blocked`, no request); a second delete while one is in flight is `.rejected`. Success **or `404`** (already gone) → `removeConversation(id:)` → `.deleted`. Any other failure leaves the cache unchanged
- **Rename** (`AppSession.renameConversation(id:title:)`): trimmed, then **1–100 characters counted as Unicode scalars** (`TitleLimit`, `unicodeScalars.count`) to match the Worker's code-point count; `String.count` counts grapheme clusters and disagrees on emoji. Invalid → `.invalid`, no request. One rename in flight per conversation. Success → `ingest(conversation)`. `404` → the conversation is gone: removed from the cache and reported as "This conversation no longer exists.". Allowed while a turn is in flight (the server's turn save doesn't touch the title)
- **Error text** (`deleteErrorMessage` / `renameErrorMessage`): `.network` → "Can't reach the server."; `.unauthorized` → "API key rejected."; `.server` → "Couldn't delete — try again." / "Couldn't rename — try again." (rename `404` → "This conversation no longer exists."; delete `404` is success); `.decoding` / `.invalidResponse` → "Something went wrong."
- **List:** trailing swipe (Delete) and a long-press menu (Rename, Delete). Delete always asks first (`confirmationDialog`). The swipe button is tinted red rather than `role: .destructive`, so the row stays until the server confirms. While a turn is in flight the swipe isn't offered and the menu's Delete is disabled (`ConversationActions.canDelete`); while a delete is in flight the row is dimmed with a spinner. Failures show an alert. No Edit mode, multi-select, undo, or bulk delete
- **Rename alert** (`renameAlert`): shared by the list and the chat title; text field prefilled with the current title (empty for "Untitled"); Save disabled unless `TitleLimit.isValid`
- **Chat:** the title is a `.principal` toolbar button (existing conversations only) that opens the rename alert. If the open conversation leaves the cache (a sync tombstone, or a rename `404`) the screen pops back: the transcript reports `conversationIsCached(_:)`, and `ChatModel.shouldDismiss` is set only once the conversation had been seen (an empty query while loading, or a new unsaved conversation, never pops). A pending error alert is shown before the pop

## Settings and taste profile

Secondary, rarely used screens built from standard controls (`Form`, `Picker`, `LabeledContent`, `TextEditor`), no Markdown rendering. Settings is one `Form`. The editor is deliberately **not** a `Form`: a form row can't grow, so it is a `VStack` whose `TextEditor` fills the screen (`maxHeight: .infinity`) and shrinks above the keyboard.

- **Settings sections, in order:** Taste profile → Recommendations → Sync → Connection → About
- **Taste profile row:** "Not set" or "Updated <relative date>"; plus "Predates your last import" when the cached profile's `updatedAt` is earlier than `SyncState.lastImportAt` (`profileIsStale`; hidden when either date is missing)
- **Recommendations:** the default-model picker — "Server default (<name>)" (stores no value) plus each allowed model. If models didn't load, the saved value is shown read-only with "Couldn't load models"
- **Sync:** Sync Now, last sync / last import, `SyncController.lastError` in red, and Rebuild Cache (destructive; runs `SyncController.rebuild()` → `resetAndSync()` only from its confirmation dialog)
- **Connection:** endpoint field + an empty API-key `SecureField` — **the saved key is never displayed**. Save Connection is enabled when the normalized URL differs from the saved one or a new key was typed. It runs `ConnectionCheck.verifyAndSave` (the first-launch rules and error text; the health check uses the new key if entered, else the saved one), saves only on success, and hands the `Connection` to `RootView` through the `connectionEditor` environment value, whose `.task(id: connection)` rebuilds the session
- **Endpoint change → `resetAndSync()`, never a normal sync:** a different normalized base URL is a different server (`isDifferentServer`), and one server's cached rows must never mix with another's. `RootView` flags it and the new session's first sync is `SyncController.start(endpointChanged: true)`. A key-only change (and the first connection) keeps the cache and syncs normally
- **About:** version + build, and the attributions as text + links (no logo assets): "This product uses the TMDB API but is not endorsed or certified by TMDB." (`https://www.themoviedb.org`) and "Streaming availability provided by JustWatch." (`https://www.justwatch.com`)
- **Taste profile editor:** the text starts from the cached content and follows the cache only while nothing is unsaved. Dirty = text ≠ cached content. Draft / Redraft is session-owned (`AppSession.draftTasteProfile`), uses the default-model resolution, and asks first when dirty (the server drafts from the **saved** profile). **A draft is view state: nothing is cached until Save**, and a draft that completes after the editor is gone is dropped. A first draft (no saved profile, empty `changes`) shows "First draft — review it, then save."; otherwise the draft's `changes` are listed until saved
- **Profile length is counted in UTF-16** (`ProfileLimit`: 1–4,000 after trimming, `utf16.count`, an emoji is 2) because the Worker counts JS `string.length` — the same rule as `MessageLimit`, and unlike titles, which the Worker counts in code points (`TitleLimit`, Unicode scalars). Match each server rule; don't unify them
- **Save** (`AppSession.saveTasteProfile`): trimmed text → `PUT /taste-profile` → `ingest(profile)`; the editor then shows the server's copy and clears the changes. Enabled when dirty or a draft is pending, and the length is valid; over the limit shows a count
- **Leaving with unsaved edits:** the system back button (and back swipe) is hidden while dirty and replaced by one that asks: Discard Changes / Keep Editing
- **Error text:** draft (`draftErrorMessage`) — `422 no_ratings` → "Import your Letterboxd ratings first."; `claude_unavailable` → "The service is busy — try again in a moment."; `.network` → "Can't reach the server."; `.unauthorized` → "API key rejected."; else "Couldn't draft — try again.". Save (`profileSaveErrorMessage`) — `.network` → "Can't reach the server."; `.unauthorized` → "API key rejected."; else "Couldn't save — try again."

## Pick detail and decisions

- **Detail screen** (`PickDetailView`, top to bottom): poster (`w500`, 2:3, width-capped), title, metadata line (`year · 1h 38m · Directed by …`, missing parts dropped with no stray separators), "Why you'd like it" (`whyFull`), Overview (hidden when empty), Where to watch, then Trailer (only with a `trailerKey`) and Letterboxd (always) links. The Yes / Maybe / No bar is pinned with `safeAreaInset(edge: .bottom)`. The pick and its `CachedDecision` come from `@Query`, so the bar and every card badge update live. Everything shown is derived in `PickDetailInfo`, which is where to test content
- **Where to watch:** providers in the Worker's order (stream → free → ads → rent → buy) in a `FlowLayout`: logo (`w92`), name, type label (`Stream`, `Free`, `With ads`, `Rent`, `Buy`; none for unknown types). Any provider and "More options" open `providersLink` when present. With no providers: "Not available to stream in the US right now." (the link still shows if present). Always captioned "Streaming availability from JustWatch." (the TMDB and JustWatch credits are in Settings → About)
- **Decision flow:** `AppSession.setDecision(_:for:current:)` sends `PUT /decisions/{tmdb_id}` with the **recommendation's own `conversationID`** (the server only accepts decisions on films recommended in that conversation), ingests the returned `Decision`, and **after a Yes is saved** opens `https://letterboxd.com/tmdb/{id}`. The request runs in a session-owned task, like chat turns, so leaving the screen doesn't cancel it. A success haptic fires on save
- **Decision rules:** re-choosing the current decision makes no request; re-choosing Yes re-opens Letterboxd. Changing a decision is a normal request (the server upserts). One decision in flight per film: the bar is disabled with a spinner on the tapped button, and a second tap is `.rejected`. On failure nothing is cached and Letterboxd is not opened; an inline error shows above the bar with Retry, which resends the identical `DecisionRequest`. There is no "undecided" (v1 can't clear a decision), and no optimistic `CachedDecision` writes
- **Decision error text** (`decisionErrorMessage`): `.network` → "Can't reach the server."; `.unauthorized` → "API key rejected."; any `.server` → "Couldn't save that — try again."; `.decoding` / `.invalidResponse` → "Something went wrong."
- **Link builders** are pure `nonisolated` helpers built with `URLComponents`: `letterboxdURL(tmdbID:)`, `trailerURL(key:)` (`https://www.youtube.com/watch?v=…`, key query-encoded; `nil` without a key), `tmdbImageURL(path:size:)`. Links open the YouTube / Letterboxd apps through universal links when installed, otherwise Safari. No embedded video (no `WKWebView` or AVKit)
- **External opens are injected:** views use the `openURL` environment action (`Link`, provider buttons). The session takes an `open: (URL) -> Void` closure, which `RootView` fills with `openURL`; tests pass an `OpenRecorder`

## Dependencies and secrets

- **No third-party packages**, including test helpers and formatters. Apple frameworks and the toolchain's `swift-format` only
- The API key is never logged, printed, or included in an error
- **Test credentials:** never write key-shaped literals. Build them at runtime (`testAPIKey = String(repeating: "k", count: 32)`), because GitHub push protection blocks realistic secrets
- Keychain tests use a throwaway account (`api-key-test-<uuid>`), never the real `api-key`
