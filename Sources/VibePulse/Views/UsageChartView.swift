import AppKit
import Charts
import SwiftUI

struct UsageChartView: View {
  let mode: ChartMode
  let cumulativeSeries: [UsageSeriesPoint]
  let dailySeries: [UsageSeriesPoint]
  let palette: UsageSeriesPalette

  @State private var dailyHoverDate: Date?
  @State private var dailyTooltipPosition: CGPoint?

  var body: some View {
    switch mode {
    case .today:
      todayChart
    case .sevenDays:
      dailyChart
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
          .lineStyle(StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
          .foregroundStyle(by: .value("Series", point.series.chartIdentity))
        }
        .chartLegend(.hidden)
        .chartForegroundStyleScale(domain: colorDomain, range: colorRange)
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
            if mode.usesGroupedDailyBars {
              BarMark(
                x: .value("Date", point.date, unit: .day),
                y: .value("Cost", point.cost)
              )
              .foregroundStyle(by: .value("Series", point.series.chartIdentity))
              .position(by: .value("Series", point.series.chartIdentity))
            } else {
              BarMark(
                x: .value("Date", point.date, unit: .day),
                y: .value("Cost", point.cost)
              )
              .foregroundStyle(by: .value("Series", point.series.chartIdentity))
            }
          }

          if let dailyHoverDate, !dailyHoverPoints.isEmpty {
            RuleMark(x: .value("Date", dailyHoverDate, unit: .day))
              .foregroundStyle(.secondary.opacity(0.5))
              .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
          }
        }
        .chartLegend(.hidden)
        .chartForegroundStyleScale(domain: colorDomain, range: colorRange)
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
            DailyTooltipView(
              date: dailyHoverDate,
              points: dailyHoverPoints,
              palette: palette
            )
            .offset(x: dailyTooltipPosition.x, y: dailyTooltipPosition.y)
          }
        }
        .frame(height: 160)
      }
    }
  }

  private var dailyHoverPoints: [UsageSeriesPoint] {
    guard let dailyHoverDate else { return [] }
    let calendar = Calendar.autoupdatingCurrent
    return
      dailySeries
      .filter { calendar.isDate($0.date, inSameDayAs: dailyHoverDate) }
      .sorted { $0.series.sortKey < $1.series.sortKey }
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

    let calendar = Calendar.autoupdatingCurrent
    let day = calendar.startOfDay(for: date)
    if dailySeries.contains(where: { calendar.isDate($0.date, inSameDayAs: day) }) {
      dailyHoverDate = day
      dailyTooltipPosition = CGPoint(x: plotFrame.minX + 8, y: plotFrame.minY + 8)
    } else {
      dailyHoverDate = nil
      dailyTooltipPosition = nil
    }
  }

  private var chartSeries: [UsageSeriesKey] {
    let series = (cumulativeSeries + dailySeries).map(\.series)
    return Array(Set(series)).sorted { $0.sortKey < $1.sortKey }
  }

  private var colorDomain: [String] {
    chartSeries.map(\.chartIdentity)
  }

  private var colorRange: [Color] {
    chartSeries.map(palette.color(for:))
  }
}

private struct DailyTooltipView: View {
  let date: Date
  let points: [UsageSeriesPoint]
  let palette: UsageSeriesPalette

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(date, format: .dateTime.month().day())
        .font(.caption)
        .foregroundColor(.secondary)

      if points.count > 8 {
        ScrollView(.vertical) {
          LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(points) { point in
              pointRow(point)
            }
          }
        }
        .frame(height: 150)
      } else {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(points) { point in
            pointRow(point)
          }
        }
      }
    }
    .frame(minWidth: 180, maxWidth: 260, alignment: .leading)
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
  }

  private func pointRow(_ point: UsageSeriesPoint) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(palette.color(for: point.series))
        .frame(width: 8, height: 8)
      Text(point.series.displayName)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      Text(Formatters.currencyString(point.cost))
        .fixedSize()
    }
    .font(.caption)
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
