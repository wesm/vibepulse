import AppKit
import Charts
import SwiftUI

struct UsageChartView: View {
    let mode: ChartMode
    let cumulativeSeries: [UsageSeriesPoint]
    let dailySeries: [UsageSeriesPoint]

    @State private var dailyHoverDate: Date?
    @State private var dailyTooltipPosition: CGPoint?

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
                Chart {
                    ForEach(dailySeries) { point in
                        BarMark(
                            x: .value("Date", point.date, unit: .day),
                            y: .value("Cost", point.cost)
                        )
                        .foregroundStyle(by: .value("Tool", point.tool.displayName))
                        .position(by: .value("Tool", point.tool.displayName))
                    }

                    if let dailyHoverDate, !dailyHoverPoints.isEmpty {
                        RuleMark(x: .value("Date", dailyHoverDate, unit: .day))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                    }
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
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        HoverTrackingView { location in
                            updateDailyHover(location, proxy: proxy, geo: geo)
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let dailyHoverDate, !dailyHoverPoints.isEmpty, let dailyTooltipPosition {
                        DailyTooltipView(date: dailyHoverDate, points: dailyHoverPoints)
                            .offset(x: dailyTooltipPosition.x, y: dailyTooltipPosition.y)
                    }
                }
                .frame(height: 160)
            }
        }
    }

    private var dailyHoverPoints: [UsageSeriesPoint] {
        guard let dailyHoverDate else { return [] }
        let calendar = Calendar.current
        return dailySeries
            .filter { calendar.isDate($0.date, inSameDayAs: dailyHoverDate) }
            .sorted { toolOrder($0.tool) < toolOrder($1.tool) }
    }

    private func toolOrder(_ tool: UsageTool) -> Int {
        UsageTool.allCases.firstIndex(of: tool) ?? 0
    }

    private func updateDailyHover(_ location: CGPoint?, proxy: ChartProxy, geo: GeometryProxy) {
        guard let location else {
            dailyHoverDate = nil
            dailyTooltipPosition = nil
            return
        }

        let plotFrame = geo[proxy.plotAreaFrame]
        guard plotFrame.contains(location) else {
            dailyHoverDate = nil
            dailyTooltipPosition = nil
            return
        }

        let relativeX = location.x - plotFrame.origin.x
        guard let date: Date = proxy.value(atX: relativeX) else {
            dailyHoverDate = nil
            dailyTooltipPosition = nil
            return
        }

        let day = Calendar.current.startOfDay(for: date)
        if dailySeries.contains(where: { Calendar.current.isDate($0.date, inSameDayAs: day) }) {
            dailyHoverDate = day
            dailyTooltipPosition = CGPoint(x: plotFrame.minX + 8, y: plotFrame.minY + 8)
        } else {
            dailyHoverDate = nil
            dailyTooltipPosition = nil
        }
    }

    private var colorScale: KeyValuePairs<String, Color> {
        [
            UsageTool.claude.displayName: UsageTool.claude.color,
            UsageTool.codex.displayName: UsageTool.codex.color,
        ]
    }
}

private struct DailyTooltipView: View {
    let date: Date
    let points: [UsageSeriesPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(date, format: .dateTime.month().day())
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(points) { point in
                HStack(spacing: 6) {
                    Circle()
                        .fill(point.tool.color)
                        .frame(width: 8, height: 8)
                    Text(point.tool.displayName)
                    Spacer(minLength: 8)
                    Text(Formatters.currencyString(point.cost))
                }
                .font(.caption)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 3)
        .fixedSize()
    }
}

private struct HoverTrackingView: NSViewRepresentable {
    var onMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onMove = onMove
    }

    final class TrackingView: NSView {
        var onMove: ((CGPoint?) -> Void)?
        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }

            let options: NSTrackingArea.Options = [
                .activeAlways,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
            ]
            let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
            super.updateTrackingAreas()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }

        override func mouseEntered(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            onMove?(point)
        }

        override func mouseMoved(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            onMove?(point)
        }

        override func mouseExited(with event: NSEvent) {
            onMove?(nil)
        }
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
