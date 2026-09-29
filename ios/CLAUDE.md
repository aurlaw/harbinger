# CLAUDE.md — harbinger/ios

Native Swift/SwiftUI iOS app (iPhone only, iOS 26, Swift 6). Talks only to the Worker at `harbinger-api.aurlaw.dev`. Read the repo-root `CLAUDE.md` first. Its working agreement applies here.

## Layout

- `Harbinger/HarbingerApp.swift`: app entry; builds the live `AppConfiguration`
- `Harbinger/RootView.swift`: shows the first-launch sheet until an endpoint + key are saved. The connected screen is a placeholder until I3
- `Harbinger/Config/Endpoint.swift`: `normalizeEndpoint` (https only; http for `localhost` / `127.0.0.1`), `defaultEndpoint`
- `Harbinger/Config/CredentialStore.swift`: `CredentialStore` protocol + `KeychainCredentialStore` (service `com.aurlaw.harbinger`, account `api-key`, `AfterFirstUnlockThisDeviceOnly`)
- `Harbinger/Config/AppConfiguration.swift`: `EndpointStore` (UserDefaults `endpointURL`), `Connection`, `AppConfiguration` (stores + client factory)
- `Harbinger/API/APIClient.swift`: `APIClient` protocol (one method per app endpoint), `URLSessionAPIClient`, `RequestTimeout`
- `Harbinger/API/Models.swift`: DTOs matching `api-surface` and the Worker's mappers (`worker/src/conversations/store.ts`, `worker/src/sync/handlers.ts`)
- `Harbinger/API/APIError.swift`: `APIError` + the Worker's error envelope
- `Harbinger/API/JSONCoding.swift`: snake_case coders; fractional-second timestamp parsing/formatting
- `Harbinger/Setup/`: first-launch sheet (`SetupView`) + `SetupViewModel`
- `HarbingerTests/`: Swift Testing. `TestSupport.swift` has `StubURLProtocol`, `InMemoryCredentialStore`, `FakeAPIClient`; `Fixtures.swift` has real-shaped response bodies

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
- No `@unchecked Sendable`. `nonisolated(unsafe)` is allowed only in test stubs (`StubURLProtocol`'s shared handler), and suites using the stub must be `@Suite(.serialized)`

## API client rules

- Every failure is an `APIError`, thrown with typed throws. `401` → `.unauthorized`; enveloped non-2xx → `.server` (with `Retry-After`); `URLError` → `.network`; a 2xx that doesn't match the DTO → `.decoding`; non-HTTP or an error response without the envelope → `.invalidResponse`
- Timeouts are set per request (`RequestTimeout`). Conversation turns and taste-profile drafts get 180 s
- Build paths with `URL.append(component:)` / query items. Never concatenate user input into a URL string
- No retries in the client
- The sync cursor (`next_since` / `server_time`) stays the exact server `String`. Never round-trip it through `Date`
- Server timestamps have fractional seconds, which `.iso8601` rejects. Use `makeDecoder()` / `makeEncoder()`, never a bare `JSONDecoder`

## Dependencies and secrets

- **No third-party packages**, including test helpers and formatters. Apple frameworks and the toolchain's `swift-format` only
- The API key is never logged, printed, or included in an error
- **Test credentials:** never write key-shaped literals. Build them at runtime (`testAPIKey = String(repeating: "k", count: 32)`), because GitHub push protection blocks realistic secrets
- Keychain tests use a throwaway account (`api-key-test-<uuid>`), never the real `api-key`
