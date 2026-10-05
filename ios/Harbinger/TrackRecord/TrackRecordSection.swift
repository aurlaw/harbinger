import SwiftUI

/// The track record's rows (in `TrackRecordView`'s form): how past picks landed.
struct TrackRecordSection: View {
  let model: TrackRecordModel

  var body: some View {
    Section("Track record") {
      switch model.content {
      case .loading:
        HStack {
          Spacer()
          ProgressView()
          Spacer()
        }
      case .failed(let message):
        Text(message)
          .foregroundStyle(.secondary)
      case .noPicks:
        Text("No picks yet.")
          .foregroundStyle(.secondary)
      case .noneRated(let recommended):
        Text("\(Text(String(recommended)).bold()) \(picksSoFarSuffix(recommended))")
          .accessibilityLabel(picksSoFarText(recommended))
        Text(rateToSeeOutcomesText)
          .font(.footnote)
          .foregroundStyle(.secondary)
      case .stats(let stats):
        StatsRows(stats: stats)
      }
      if let error = model.refreshError {
        Text(error)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct StatsRows: View {
  let stats: OutcomeStats

  var body: some View {
    if let percent = percentText(stats.hitRate) {
      LabeledContent("Hit rate", value: percent)
    }
    Text(hitRateCaption(stats))
      .font(.footnote)
      .foregroundStyle(.secondary)
    if let average = averageText(stats.averageHalfStars) {
      LabeledContent("Average rating", value: average)
    }
    LabeledContent("Picks shown", value: String(stats.recommended))
    ForEach(stats.byModel, id: \.model) { outcome in
      LabeledContent(modelDisplayName(outcome.model), value: modelOutcomeText(outcome))
    }
    if stats.hasRecentOutcomes {
      NavigationLink("Recent outcomes", value: Route.recentOutcomes(stats.recent))
    }
  }
}
