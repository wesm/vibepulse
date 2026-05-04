import AppKit
import SwiftUI

struct MenuContentView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var updaterController: UpdaterController
  @State private var chartMode: ChartMode = .today

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      totalSection
      Picker("View", selection: $chartMode) {
        ForEach(ChartMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      Text(chartMode == .today ? "Cumulative" : "By Day")
        .font(.caption)
        .foregroundColor(.secondary)

      UsageChartView(
        mode: chartMode, cumulativeSeries: model.cumulativeSeries, dailySeries: visibleDailySeries)

      totalsBreakdown

      if let status = model.statusMessage {
        Text(status)
          .font(.caption)
          .foregroundColor(.red)
      }

      Divider()

      controls
    }
    .padding(12)
    .frame(width: 360)
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear {
      disableWindowResizing()
      model.refreshNow()
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "waveform.path.ecg")
        .font(.title3)
        .foregroundColor(.accentColor)
      Text("VibePulse")
        .font(.headline)
      Spacer()
      statusIndicator
    }
  }

  private var statusIndicator: some View {
    ZStack(alignment: .trailing) {
      if let lastUpdated = model.lastUpdated {
        Text(lastUpdated, format: .dateTime.hour().minute())
          .font(.caption)
          .foregroundColor(.secondary)
          .opacity(model.isRefreshing ? 0 : 1)
          .monospacedDigit()
      } else {
        Text(" ")
          .font(.caption)
          .foregroundColor(.secondary)
          .opacity(0)
      }

      if model.isRefreshing {
        ProgressView()
          .scaleEffect(0.7)
      }
    }
    .frame(width: 70, height: 16, alignment: .trailing)
    .animation(.none, value: model.isRefreshing)
  }

  private var totalSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(combinedTotalText)
        .font(.system(size: 28, weight: .semibold, design: .rounded))
        .monospacedDigit()
      Text(combinedTotalSubtitle)
        .font(.caption)
        .foregroundColor(.secondary)
    }
  }

  private var totalsBreakdown: some View {
    LazyVGrid(columns: legendColumns, alignment: .leading, spacing: 8) {
      ForEach(toolBreakdown) { total in
        ToolTotalLegendItem(total: total)
      }
    }
  }

  private var legendColumns: [GridItem] {
    [
      GridItem(.flexible(minimum: 120), alignment: .leading),
      GridItem(.flexible(minimum: 120), alignment: .leading),
    ]
  }

  private var controls: some View {
    HStack {
      Button("Refresh") {
        model.refreshNow()
      }
      .disabled(model.isRefreshing)

      Button("Settings") {
        model.openSettings()
      }

      Button("Check for Updates\u{2026}") {
        updaterController.checkForUpdates()
      }

      Spacer()

      Button("Quit") {
        NSApp.terminate(nil)
      }
    }
    .buttonStyle(.borderless)
    .font(.caption)
  }

  private func disableWindowResizing() {
    if let window = NSApp.keyWindow {
      window.styleMask.remove(.resizable)
    }
  }

  private var combinedTotalText: String {
    switch chartMode {
    case .today:
      return model.menuTotalText
    case .sevenDays, .thirtyDays:
      let total = visibleDailySeries.reduce(0) { $0 + $1.cost }
      return Formatters.currencyString(total)
    }
  }

  private var combinedTotalSubtitle: String {
    switch chartMode {
    case .today:
      return "Combined today via agentsview"
    case .sevenDays:
      return "Combined (last 7 days) via agentsview"
    case .thirtyDays:
      return "Combined (last 30 days) via agentsview"
    }
  }

  private var toolBreakdown: [ToolTotal] {
    switch chartMode {
    case .today:
      return model.toolTotals.filter { $0.totalCost > 0.0001 }
    case .sevenDays, .thirtyDays:
      var totalsByTool: [UsageTool: Double] = [:]
      for point in visibleDailySeries {
        totalsByTool[point.tool, default: 0] += point.cost
      }
      return UsageTool.allCases.compactMap { tool in
        guard let total = totalsByTool[tool], total > 0.0001 else { return nil }
        return ToolTotal(tool: tool, totalCost: total)
      }
    }
  }

  private var visibleDailySeries: [UsageSeriesPoint] {
    UsageSeriesFilters.visibleDailySeries(model.dailySeries, mode: chartMode)
  }
}

private struct ToolTotalLegendItem: View {
  let total: ToolTotal

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      Circle()
        .fill(total.tool.color)
        .frame(width: 8, height: 8)
        .padding(.top, 4)

      VStack(alignment: .leading, spacing: 1) {
        Text(total.tool.displayName)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
        Text(Formatters.currencyString(total.totalCost))
          .monospacedDigit()
      }
      .font(.caption)
      .foregroundColor(.secondary)
    }
  }
}
