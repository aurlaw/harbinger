import Foundation
import Testing

@testable import Harbinger

@MainActor
struct SetupViewModelTests {
  let suite = "SetupViewModelTests-\(UUID().uuidString)"

  func makeModel(
    result: Result<HealthResponse, APIError>,
    credentials: InMemoryCredentialStore = InMemoryCredentialStore()
  ) throws -> (SetupViewModel, AppConfiguration, HealthRecorder) {
    let recorder = HealthRecorder(result: result)
    let defaults = try #require(UserDefaults(suiteName: suite))
    let configuration = AppConfiguration(
      endpoints: EndpointStore(defaults: defaults),
      credentials: credentials,
      makeClient: { recorder.makeClient($0) })
    let model = SetupViewModel(configuration: configuration)
    model.apiKey = testAPIKey
    return (model, configuration, recorder)
  }

  @Test func healthyCheckSavesBoth() async throws {
    let (model, configuration, recorder) = try makeModel(result: .success(.init(status: "ok")))
    model.endpoint = " https://harbinger-api.aurlaw.dev/ "

    let saved = await model.save()

    let expected = Connection(
      baseURL: URL(string: "https://harbinger-api.aurlaw.dev")!, apiKey: testAPIKey)
    #expect(saved == expected)
    #expect(recorder.connections == [expected])
    #expect(configuration.connection() == expected)
    #expect(model.errorMessage == nil)
    #expect(!model.isChecking)
  }

  @Test func rejectedKeySavesNothing() async throws {
    let (model, configuration, _) = try makeModel(result: .failure(.unauthorized))

    #expect(await model.save() == nil)
    #expect(model.errorMessage == "Key rejected")
    #expect(configuration.connection() == nil)
    #expect(try configuration.credentials.apiKey() == nil)
    #expect(configuration.endpoints.url() == nil)
  }

  @Test func networkFailureSavesNothing() async throws {
    let (model, configuration, _) = try makeModel(result: .failure(.network(.cannotConnectToHost)))

    #expect(await model.save() == nil)
    #expect(model.errorMessage == "Can't reach endpoint")
    #expect(try configuration.credentials.apiKey() == nil)
    #expect(configuration.endpoints.url() == nil)
  }

  @Test func unexpectedResponseShowsCode() async throws {
    let (model, configuration, _) = try makeModel(
      result: .failure(
        .server(status: 503, code: "db_unavailable", message: "down", retryAfter: nil)))

    #expect(await model.save() == nil)
    #expect(model.errorMessage == "Unexpected response (db_unavailable)")
    #expect(configuration.connection() == nil)
  }

  @Test func invalidURLMakesNoRequest() async throws {
    let (model, configuration, recorder) = try makeModel(result: .success(.init(status: "ok")))
    model.endpoint = "http://harbinger-api.aurlaw.dev"

    #expect(await model.save() == nil)
    #expect(model.errorMessage == SetupViewModel.invalidURLMessage)
    #expect(recorder.connections.isEmpty)
    #expect(configuration.connection() == nil)
  }

  @Test func keychainFailureSavesNothing() async throws {
    let (model, configuration, _) = try makeModel(
      result: .success(.init(status: "ok")),
      credentials: InMemoryCredentialStore(saveError: .status(-25_308)))

    #expect(await model.save() == nil)
    #expect(model.errorMessage != nil)
    #expect(configuration.endpoints.url() == nil)
  }

  @Test func saveDisabledUntilBothFieldsFilled() throws {
    let (model, _, _) = try makeModel(result: .success(.init(status: "ok")))
    #expect(model.canSave)
    model.apiKey = "  "
    #expect(!model.canSave)
    model.apiKey = testAPIKey
    model.endpoint = ""
    #expect(!model.canSave)
  }
}
