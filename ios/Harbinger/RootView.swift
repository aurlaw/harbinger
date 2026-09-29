import SwiftUI

/// Presents the first-launch sheet until an endpoint + key are saved.
/// The connected screen is a placeholder until I3.
struct RootView: View {
  let configuration: AppConfiguration
  @State private var connection: Connection?

  init(configuration: AppConfiguration) {
    self.configuration = configuration
    _connection = State(initialValue: configuration.connection())
  }

  var body: some View {
    VStack(spacing: 8) {
      Text("Harbinger")
        .font(.largeTitle)
      if let host = connection?.baseURL.host() {
        Text("Connected to \(host)")
          .foregroundStyle(.secondary)
      }
    }
    .sheet(isPresented: .constant(connection == nil)) {
      SetupView(model: SetupViewModel(configuration: configuration)) { connection = $0 }
        .interactiveDismissDisabled()
    }
  }
}
