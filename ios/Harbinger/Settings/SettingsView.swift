import SwiftData
import SwiftUI

/// Settings: one plain form. The taste profile editor is the only screen pushed from it.
struct SettingsView: View {
  @State private var model: SettingsModel
  @State private var trackRecord: TrackRecordModel
  @Query private var profiles: [CachedTasteProfile]
  @Query private var states: [SyncState]

  init(session: AppSession, editor: ConnectionEditor?) {
    _model = State(initialValue: SettingsModel(session: session, editor: editor))
    _trackRecord = State(initialValue: TrackRecordModel(client: session.client))
  }

  var body: some View {
    @Bindable var model = model
    let sync = model.session.sync

    Form {
      Section {
        NavigationLink(value: Route.tasteProfile) {
          LabeledContent(
            "Taste profile", value: profileStatusText(updatedAt: profiles.first?.updatedAt))
        }
        if profileIsStale(
          updatedAt: profiles.first?.updatedAt, lastImportAt: states.first?.lastImportAt)
        {
          Text("Predates your last import")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }

      TrackRecordSection(model: trackRecord)

      Section("Recommendations") {
        if let allowed = model.session.allowedModels {
          Picker("Default model", selection: $model.modelSelection) {
            Text(model.serverDefaultLabel).tag(String?.none)
            ForEach(allowed, id: \.self) { name in
              Text(modelDisplayName(name)).tag(Optional(name))
            }
          }
        } else {
          LabeledContent(
            "Default model",
            value: model.session.savedModel.map(modelDisplayName) ?? "Server default")
          Text("Couldn't load models")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }

      Section("Sync") {
        Button(action: model.syncNow) {
          HStack {
            Text("Sync Now")
            Spacer()
            if sync.isSyncing {
              ProgressView()
            }
          }
        }
        .disabled(sync.isSyncing)
        LabeledContent("Last sync", value: formatted(states.first?.lastSyncedAt))
        LabeledContent("Last import", value: formatted(states.first?.lastImportAt))
        if let error = sync.lastError {
          Text(error)
            .foregroundStyle(.red)
        }
        Button("Rebuild Cache", role: .destructive) { model.isConfirmingRebuild = true }
          .disabled(sync.isSyncing)
      }

      if model.canEditConnection {
        Section("Connection") {
          TextField("Endpoint URL", text: $model.endpoint)
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          SecureField("API Key Saved — enter to replace", text: $model.apiKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          if let message = model.connectionError {
            Text(message)
              .foregroundStyle(.red)
          }
          Button {
            Task { await model.saveConnection() }
          } label: {
            if model.isChecking {
              ProgressView()
            } else {
              Text("Save Connection")
            }
          }
          .disabled(!model.canSaveConnection)
        }
      }

      Section("About") {
        LabeledContent("Version", value: appVersionText(Bundle.main.infoDictionary))
        VStack(alignment: .leading, spacing: 4) {
          Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
          if let url = URL(string: "https://www.themoviedb.org") {
            Link("themoviedb.org", destination: url)
          }
        }
        .font(.footnote)
        VStack(alignment: .leading, spacing: 4) {
          Text("Streaming availability provided by JustWatch.")
          if let url = URL(string: "https://www.justwatch.com") {
            Link("justwatch.com", destination: url)
          }
        }
        .font(.footnote)
      }
    }
    .navigationTitle("Settings")
    // Stats are fetched, not cached: load them each time Settings appears, and on pull.
    .task { await trackRecord.load() }
    .refreshable { await trackRecord.load() }
    .confirmationDialog(
      "Rebuild the cache?", isPresented: $model.isConfirmingRebuild, titleVisibility: .visible
    ) {
      Button("Rebuild Cache", role: .destructive, action: model.confirmRebuild)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Clears the local cache and downloads everything again.")
    }
  }

  private func formatted(_ date: Date?) -> String {
    date?.formatted(date: .abbreviated, time: .standard) ?? "Never"
  }
}
