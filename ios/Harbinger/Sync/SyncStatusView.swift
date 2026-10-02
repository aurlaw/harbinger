import SwiftData
import SwiftUI

/// Placeholder until I3: cache counts and sync status, with pull-to-refresh.
struct SyncStatusView: View {
  let host: String?
  let sync: SyncController

  @Query private var conversations: [CachedConversation]
  @Query private var messages: [CachedMessage]
  @Query private var recommendations: [CachedRecommendation]
  @Query private var decisions: [CachedDecision]
  @Query private var profiles: [CachedTasteProfile]
  @Query private var states: [SyncState]

  var body: some View {
    List {
      if let host {
        Section {
          LabeledContent("Connected to", value: host)
        }
      }
      Section("Cache") {
        LabeledContent("Conversations", value: "\(conversations.count)")
        LabeledContent("Messages", value: "\(messages.count)")
        LabeledContent("Recommendations", value: "\(recommendations.count)")
        LabeledContent("Decisions", value: "\(decisions.count)")
        LabeledContent("Taste profile", value: profiles.isEmpty ? "No" : "Yes")
      }
      Section("Sync") {
        LabeledContent("Last sync", value: formatted(states.first?.lastSyncedAt))
        LabeledContent("Last import", value: formatted(states.first?.lastImportAt))
        if sync.isSyncing {
          ProgressView()
        }
        if let error = sync.lastError {
          Text(error)
            .foregroundStyle(.red)
        }
      }
    }
    .refreshable {
      await sync.syncNow()
    }
  }

  private func formatted(_ date: Date?) -> String {
    date?.formatted(date: .abbreviated, time: .standard) ?? "Never"
  }
}
