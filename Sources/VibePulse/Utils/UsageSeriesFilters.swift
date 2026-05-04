import Foundation

enum UsageSeriesFilters {
  static let minimumVisibleCost = 0.0001

  static func visibleDailySeries(_ points: [UsageSeriesPoint], mode: ChartMode)
    -> [UsageSeriesPoint]
  {
    let dateFiltered: [UsageSeriesPoint]
    if let days = mode.dailyWindowDays {
      let startKey = DateHelper.dateKeyDaysAgo(days - 1)
      dateFiltered = points.filter { point in
        DateHelper.dateKey(for: point.date) >= startKey
      }
    } else {
      dateFiltered = points
    }

    return dateFiltered.filter { $0.cost > minimumVisibleCost }
  }
}
