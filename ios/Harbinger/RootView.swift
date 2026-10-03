import SwiftData
import SwiftUI

/// Presents the first-launch sheet until an endpoint + key are saved, then shows the
/// conversation list and keeps the cache synced.
struct RootView: View {
  let configuration: AppConfiguration
  let container: ModelContainer

  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openURL) private var openURL
  @State private var connection: Connection?
  @State private var sync = SyncController()
  @State private var session: AppSession?

  init(configuration: AppConfiguration, container: ModelContainer) {
    self.configuration = configuration
    self.container = container
    _connection = State(initialValue: configuration.connection())
  }

  var body: some View {
    Group {
      if let session {
        NavigationStack {
          ConversationListView()
        }
        .environment(session)
        // A new session (new connection) gets fresh screens: lists keep the refresh action
        // they were first given.
        .id(ObjectIdentifier(session))
      } else {
        Color(.systemBackground)
      }
    }
    .sheet(isPresented: .constant(connection == nil)) {
      SetupView(model: SetupViewModel(configuration: configuration)) { connection = $0 }
        .interactiveDismissDisabled()
    }
    // Launch, and again whenever a connection is saved.
    .task(id: connection) {
      guard let connection else { return }
      let service = await SyncService.make(
        modelContainer: container, client: configuration.makeClient(connection))
      sync.connect(service)
      let session = AppSession(
        connection: connection, client: configuration.makeClient(connection),
        syncService: service, sync: sync, open: { [openURL] in openURL($0) })
      self.session = session
      async let synced: Void = sync.syncIfStale()
      async let models: Void = session.loadModels()
      _ = await (synced, models)
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      Task { await sync.syncIfStale() }
    }
  }
}
