import XCTest

@testable import VibePulse

final class UsageSeriesFiltersTests: XCTestCase {
  func testVisibleDailySeriesDropsZeroCostPointsThatWouldReserveGroupedBarSlots() {
    let today = DateHelper.date(fromKey: DateHelper.dateKey(for: Date()))!
    let points = [
      UsageSeriesPoint(tool: .codex, date: today, cost: 12),
      UsageSeriesPoint(tool: .pi, date: today, cost: 0),
      UsageSeriesPoint(tool: .openCode, date: today, cost: 0.00001),
    ]

    let visible = UsageSeriesFilters.visibleDailySeries(points, mode: .sevenDays)

    XCTAssertEqual(visible.map(\.tool), [.codex])
  }
}
