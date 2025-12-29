import Charts
import SwiftUI

struct UsageChartView: View {
    let mode: ChartMode
    let cumulativeSeries: [UsageSeriesPoint]
    let dailySeries: [UsageSeriesPoint]

    var body: some View {
        switch mode {
        case .today:
            todayChart
        case .thirtyDays:
            dailyChart
        }
    }

    private var todayChart: some View {
        Group {
            if cumulativeSeries.isEmpty {
                EmptyStateView(message: "Collecting samples for today.")
            } else {
                Chart(cumulativeSeries) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Cost", point.cost)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(by: .value("Tool", point.tool.displayName))

                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("Cost", point.cost)
                    )
                    .foregroundStyle(by: .value("Tool", point.tool.displayName))
                    .opacity(0.6)
                }
                .chartLegend(.hidden)
                .chartForegroundStyleScale(colorScale)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let cost = value.as(Double.self) {
                                Text(Formatters.currencyString(cost))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date, format: .dateTime.hour())
                            }
                        }
                    }
                }
                .frame(height: 140)
            }
        }
    }

    private var dailyChart: some View {
        Group {
            if dailySeries.isEmpty {
                EmptyStateView(message: "No daily totals yet.")
            } else {
                Chart(dailySeries) { point in
                    BarMark(
                        x: .value("Date", point.date, unit: .day),
                        y: .value("Cost", point.cost)
                    )
                    .foregroundStyle(by: .value("Tool", point.tool.displayName))
                    .position(by: .value("Tool", point.tool.displayName))
                }
                .chartLegend(.hidden)
                .chartForegroundStyleScale(colorScale)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let cost = value.as(Double.self) {
                                Text(Formatters.currencyString(cost))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 5)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date, format: .dateTime.month().day())
                            }
                        }
                    }
                }
                .frame(height: 160)
            }
        }
    }

    private var colorScale: KeyValuePairs<String, Color> {
        [
            UsageTool.claude.displayName: UsageTool.claude.color,
            UsageTool.codex.displayName: UsageTool.codex.color,
        ]
    }
}

private struct EmptyStateView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .padding(.vertical, 8)
    }
}
