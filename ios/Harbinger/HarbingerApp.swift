import SwiftData
import SwiftUI

@main
struct HarbingerApp: App {
  /// Created once; shared by the views and `SyncService`.
  /// `nil` when the app is only hosting unit tests: no store on disk, and no sync —
  /// a simulator with a saved key must never call the real Worker from `make test`.
  private let container: ModelContainer? = isHostingTests ? nil : CacheStore.live()

  var body: some Scene {
    WindowGroup {
      if let container {
        RootView(configuration: AppConfiguration(), container: container)
          .modelContainer(container)
      }
    }
  }
}

/// Xcode sets this in the app process when it injects a test bundle.
nonisolated var isHostingTests: Bool {
  ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
