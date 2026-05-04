import XCTest

@testable import VibePulse

final class ChartModeTests: XCTestCase {
  func testChartModesIncludeSevenDayViewInDisplayOrder() {
    XCTAssertEqual(
      ChartMode.allCases.map(\.rawValue),
      ["today", "sevenDays", "thirtyDays"])
    XCTAssertEqual(
      ChartMode.allCases.map(\.title),
      ["Today", "7 Days", "30 Days"])
  }

  func testDailyWindowDaysOnlyAppliesToDailyModes() {
    XCTAssertNil(ChartMode.today.dailyWindowDays)
    XCTAssertEqual(ChartMode.sevenDays.dailyWindowDays, 7)
    XCTAssertEqual(ChartMode.thirtyDays.dailyWindowDays, 30)
  }

  func testSevenDayViewUsesGroupedDailyBars() {
    XCTAssertFalse(ChartMode.today.usesGroupedDailyBars)
    XCTAssertTrue(ChartMode.sevenDays.usesGroupedDailyBars)
    XCTAssertFalse(ChartMode.thirtyDays.usesGroupedDailyBars)
  }
}
