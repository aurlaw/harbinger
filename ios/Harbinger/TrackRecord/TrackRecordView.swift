import SwiftUI

/// The full track record, pushed from the Watched tab's summary row.
struct TrackRecordView: View {
  let model: TrackRecordModel

  var body: some View {
    Form {
      TrackRecordSection(model: model)
    }
    .navigationTitle("Track record")
    .task { await model.load() }
    .refreshable { await model.load() }
  }
}
