import AppKit
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel
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

            UsageChartView(mode: chartMode, hourlySeries: model.hourlySeries, dailySeries: model.dailySeries)

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
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.title3)
                .foregroundColor(.accentColor)
            Text("VibePulse")
                .font(.headline)
            Spacer()
            if model.isRefreshing {
                ProgressView()
                    .scaleEffect(0.7)
            } else if let lastUpdated = model.lastUpdated {
                Text(lastUpdated, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
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
                    Text("\(total.tool.shortName) \(Formatters.currencyString(total.totalCost))")
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

    private var combinedTotalText: String {
        switch chartMode {
        case .today:
            return model.menuTotalText
        case .thirtyDays:
            let total = model.dailySeries.reduce(0) { $0 + $1.cost }
            return Formatters.currencyString(total)
        }
    }

    private var combinedTotalSubtitle: String {
        switch chartMode {
        case .today:
            return "Combined today"
        case .thirtyDays:
            return "Combined (last 30 days)"
        }
    }

    private var toolBreakdown: [ToolTotal] {
        switch chartMode {
        case .today:
            return model.toolTotals
        case .thirtyDays:
            var totalsByTool: [UsageTool: Double] = [:]
            for point in model.dailySeries {
                totalsByTool[point.tool, default: 0] += point.cost
            }
            return UsageTool.allCases.compactMap { tool in
                guard let total = totalsByTool[tool] else { return nil }
                return ToolTotal(tool: tool, totalCost: total)
            }
        }
    }
}
