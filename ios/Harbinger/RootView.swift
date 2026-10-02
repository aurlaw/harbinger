import SwiftData
import SwiftUI

/// Presents the first-launch sheet until an endpoint + key are saved, then keeps the
/// cache synced. The connected screen is a placeholder until I3.
struct RootView: View {
  let configuration: AppConfiguration
  let container: ModelContainer

  @Environment(\.scenePhase) private var scenePhase
  @State private var connection: Connection?
  @State private var sync = SyncController()

  init(configuration: AppConfiguration, container: ModelContainer) {
    self.configuration = configuration
    self.container = container
    _connection = State(initialValue: configuration.connection())
  }

  var body: some View {
    NavigationStack {
      SyncStatusView(host: connection?.baseURL.host(), sync: sync)
        .navigationTitle("Harbinger")
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
      await sync.syncIfStale()
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      Task { await sync.syncIfStale() }
    }
  }
}
