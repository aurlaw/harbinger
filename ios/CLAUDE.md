# CLAUDE.md — harbinger/ios

Native Swift/SwiftUI iOS app (iPhone only, iOS 26, Swift 6). Talks only to the Worker at `harbinger-api.aurlaw.dev`. Read the repo-root `CLAUDE.md` first. Its working agreement applies here.

## Layout

- `Harbinger/HarbingerApp.swift`: app entry; creates the one `ModelContainer` (skipped when hosting unit tests), the live `AppConfiguration`, and the enlarged `URLCache.shared`
- `Harbinger/RootView.swift`: shows the first-launch sheet until an endpoint + key are saved; owns the `SyncController`; once a connection exists builds the `SyncService` and `AppSession`, injects the session, and syncs on launch / foreground
- `Harbinger/Session/AppSession.swift`: the connected session (client, `SyncService`, `SyncController`, models, turns in flight); `TurnTarget`, `TurnRequest`, `PendingTurn`, `TurnFailure`, `TurnOutcome`
- `Harbinger/Conversations/ConversationListView.swift`: the root screen; `Route` and the stack's `navigationDestination`
- `Harbinger/Chat/`: `ChatView` (transcript, bubbles, chips, typing indicator, error row), `ChatModel` (draft, model choice, send / just pick / chip / retry), `Composer`, `PickCard` + `Poster` + `RecommendationPlaceholderView` (I4 replaces the placeholder)
- `Harbinger/Shared/`: `tmdbImageURL` + `TMDBImageSize`; `DisplayText.swift` (turn error text, bubble text, list dates, `DecisionBadge`, `MessageLimit`); `FlowLayout` (wrapping chips)
- `Harbinger/Config/Endpoint.swift`: `normalizeEndpoint` (https only; http for `localhost` / `127.0.0.1`), `defaultEndpoint`
- `Harbinger/Config/CredentialStore.swift`: `CredentialStore` protocol + `KeychainCredentialStore` (service `com.aurlaw.harbinger`, account `api-key`, `AfterFirstUnlockThisDeviceOnly`)
- `Harbinger/Config/AppConfiguration.swift`: `EndpointStore` (UserDefaults `endpointURL`), `Connection`, `AppConfiguration` (stores + client factory)
- `Harbinger/API/APIClient.swift`: `APIClient` protocol (one method per app endpoint), `URLSessionAPIClient`, `RequestTimeout`
- `Harbinger/API/Models.swift`: DTOs matching `api-surface` and the Worker's mappers (`worker/src/conversations/store.ts`, `worker/src/sync/handlers.ts`)
- `Harbinger/API/APIError.swift`: `APIError` + the Worker's error envelope
- `Harbinger/API/JSONCoding.swift`: snake_case coders; fractional-second timestamp parsing/formatting
- `Harbinger/Setup/`: first-launch sheet (`SetupView`) + `SetupViewModel`
- `Harbinger/Store/CachedModels.swift`: the six SwiftData models (`CachedConversation`, `CachedMessage`, `CachedRecommendation`, `CachedDecision`, `CachedTasteProfile`, `SyncState`) + `CachedProvider`
- `Harbinger/Store/CacheMapping.swift`: DTO → cache mapping (`apply`) and typed accessors (`content`, `messageRole`, `choice`). The only place DTO names (`tmdbId`) become cache names (`tmdbID`)
- `Harbinger/Store/CacheStore.swift`: schema, store URL, `openOrRebuild`, `inMemory()` for tests
- `Harbinger/Sync/SyncService.swift`: the model actor: `sync()`, `resetAndSync()`, `ingest(_:)`; `SyncError`, `SyncResult`, `SyncServicing`
- `Harbinger/Sync/SyncService+Apply.swift`: `CacheBatch` + the shared upsert logic
- `Harbinger/Sync/SyncController.swift`: main-actor `@Observable`; decides when to sync, exposes `isSyncing` / `lastError`
- `Harbinger/Sync/SyncStatusView.swift`: cache counts + sync status; the interim Settings screen (gear) until I5
- `HarbingerTests/`: Swift Testing. `TestSupport.swift` has `StubURLProtocol`, `InMemoryCredentialStore`, `FakeAPIClient` (scripted `health()` and `sync(since:)` via `SyncRecorder`); `SyncTestSupport.swift` has DTO builders, `CacheReader`, `FakeSyncService`; `RootViewTests.swift` hosts the real root view in the test host's window; `AppSessionTests.swift` has `SessionHarness` (fake Worker + in-memory cache + real `SyncService`) and `eventually`; `ScreenSmokeTests.swift` renders each screen so its `@Query` predicates run; `Fixtures.swift` has real-shaped response bodies

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
- **Delta semantics:** empty arrays mean no changes. **`taste_profile: null` means unchanged. Never delete the cached profile because of it.** Sync never deletes anything; rows are only deleted by `resetAndSync()` and the container-rebuild path
- **Idempotent:** the Worker's 120 s overlap re-sends rows, so applying a response twice must leave identical state
- **The cursor advances only with the data it covers:** the apply and the `SyncState` update are one `modelContext.save()`. An API error applies nothing; an apply or save error calls `rollback()`. Either way `nextSince` is unchanged
- **No overlapping syncs:** a `sync()` call made while one is running awaits the same in-flight task. The task clears itself when it finishes
- **Model-actor executor gotchas** (verified on iOS 26.5): a `Task { }` created inside the actor starts running immediately, before the creating code continues, so never assume "the line after `Task { }` runs first". And a service built on the main actor does its work on the main thread, which is why `SyncService.make` is `@concurrent`
- **Logging:** each sync logs its cursor, row counts, and failures to `Logger` category `sync` (subsystem `com.aurlaw.harbinger`). Never log the API key
- **Ingest helpers** (`ingest(ConversationResponse)`, `ingest(Decision)`, `ingest(TasteProfile)`) put write responses straight into the cache through the same upsert path. One save each, and they never move the cursor; the next `/sync` re-delivers those rows harmlessly
- **One long-lived `SyncController`:** `RootView` creates it up front and attaches the service with `connect(_:)` once a connection exists. Give views the controller non-optionally from their first render. A `List` keeps the `.refreshable` action it was first given, so a controller that starts as `nil` leaves pull-to-refresh doing nothing (`RootViewTests` covers this)
- **Triggers:** `SyncController.syncIfStale()` on launch and when the scene becomes active, skipped if a sync succeeded in the last 30 s. `syncNow()` (pull-to-refresh) always runs. Sync errors are non-fatal and never block the UI
- **Test host:** `make test` launches the app as the test host. `isHostingTests` makes it skip the live store and sync, so a simulator with a saved key never calls the real Worker. Keep that guard

## Session, navigation, and chat

- **`AppSession`** is created by `RootView` once a connection exists and injected with `.environment(_:)`. Views get the client, sync, and models from it, with no singletons. A new session (new connection) re-creates the screens (`.id(ObjectIdentifier(session))`), because lists keep their first refresh action
- **Sending lives on the session, not in views.** `send(_:)` runs the request and `ingest` in a task the session owns, so a turn survives leaving (and releasing) the chat screen. One turn in flight per `TurnTarget` (each conversation, plus one `.new` slot); a second send is `.rejected` with no request. `pending` and `failures` are keyed by target, so returning to a chat shows its typing indicator or error row. `retry(_:)` resends the identical `TurnRequest`. No client-side reconciliation: if a request is cut off, the next sync delivers whatever the Worker committed. If ingest fails after a successful response, the session runs a sync instead
- **Models:** `loadModels()` runs once per session. On failure `defaultModel` / `allowedModels` stay `nil`: the picker is hidden and new conversations omit `model`. The model is sent only when creating a conversation
- **The cache only holds server data.** The pending bubble is session state, never a cached row; the transcript renders from `@Query`, and the pending entry is cleared only after ingest
- **Routes** (`Route`, value-based `NavigationLink` + one `navigationDestination` on the list): `.conversation(id)`, `.newConversation`, `.recommendation(id)` (placeholder until I4), `.settings` (`SyncStatusView` until I5)
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

## Dependencies and secrets

- **No third-party packages**, including test helpers and formatters. Apple frameworks and the toolchain's `swift-format` only
- The API key is never logged, printed, or included in an error
- **Test credentials:** never write key-shaped literals. Build them at runtime (`testAPIKey = String(repeating: "k", count: 32)`), because GitHub push protection blocks realistic secrets
- Keychain tests use a throwaway account (`api-key-test-<uuid>`), never the real `api-key`
