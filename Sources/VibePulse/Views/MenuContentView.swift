import AppKit
import SwiftUI

struct MenuContentView: View {
  @EnvironmentObject private var model: AppModel
  @State private var chartMode: ChartMode = .today

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if chartMode != .limits {
        totalSection
      }
      Picker("View", selection: $chartMode) {
        ForEach(ChartMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      if chartMode != .limits {
        Text(chartMode == .today ? "Cumulative" : "By Day")
          .font(.caption)
          .foregroundColor(.secondary)

        UsageChartView(
          mode: chartMode, cumulativeSeries: model.cumulativeSeries, dailySeries: model.dailySeries)

        totalsBreakdown
      } else {
        LimitsView(
          claudeLimits: claudeLimits,
          codexLimits: codexLimits,
          claudeError: claudeLimitError,
          codexError: codexLimitError,
          showClaude: model.includeClaude,
          showCodex: model.includeCodex
        )
      }

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
    HStack(spacing: 12) {
      ForEach(toolBreakdown) { total in
        HStack(spacing: 6) {
          Circle()
            .fill(total.tool.color)
            .frame(width: 8, height: 8)
          Text("\(total.tool.displayName) \(Formatters.currencyString(total.totalCost))")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
    }
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
    case .thirtyDays:
      let total = model.dailySeries.reduce(0) { $0 + $1.cost }
      return Formatters.currencyString(total)
    case .limits:
      return ""
    }
  }

  private var combinedTotalSubtitle: String {
    switch chartMode {
    case .today:
      return "Combined today via ccusage"
    case .thirtyDays:
      return "Combined (last 30 days) via ccusage"
    case .limits:
      return ""
    }
  }

  private var toolBreakdown: [ToolTotal] {
    switch chartMode {
    case .today:
      return model.toolTotals.filter { $0.totalCost > 0.0001 }
    case .thirtyDays:
      var totalsByTool: [UsageTool: Double] = [:]
      for point in model.dailySeries {
        totalsByTool[point.tool, default: 0] += point.cost
      }
      return UsageTool.allCases.compactMap { tool in
        guard let total = totalsByTool[tool], total > 0.0001 else { return nil }
        return ToolTotal(tool: tool, totalCost: total)
      }
    case .limits:
      return []
    }
  }

  private var claudeLimits: [UsageLimit] {
    model.limits.filter { $0.tool == .claude }
  }

  private var codexLimits: [UsageLimit] {
    model.limits.filter { $0.tool == .codex }
  }

  private var claudeLimitError: String? {
    model.limitErrors[.claude]
  }

  private var codexLimitError: String? {
    model.limitErrors[.codex]
  }
}
