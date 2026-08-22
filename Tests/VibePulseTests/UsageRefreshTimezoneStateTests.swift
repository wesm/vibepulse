import XCTest

@testable import VibePulse

final class UsageRefreshTimezoneStateTests: XCTestCase {
  func testPartialRefreshCompletesInvalidationWithoutAdvancingSuccessfulImportMarker() throws {
    let oldTimeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
    let newTimeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let context = UsageDateContext(
      now: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-22T01:30:00Z")),
      timeZone: newTimeZone)
    var state = UsageRefreshTimezoneState(
      lastSuccessfulTimeZone: oldTimeZone.identifier,
      lastInvalidatedTimeZone: oldTimeZone.identifier,
      pendingInvalidation: true)

    XCTAssertTrue(state.shouldInvalidateCurrentDay(for: context.timeZone.identifier))

    state.completeRefresh(
      for: context.timeZone.identifier,
      invalidatedCurrentDay: true,
      hasImportErrors: true)

    XCTAssertFalse(state.pendingInvalidation)
    XCTAssertFalse(state.shouldInvalidateCurrentDay(for: context.timeZone.identifier))
    XCTAssertEqual(state.lastInvalidatedTimeZone, newTimeZone.identifier)
    XCTAssertEqual(state.lastSuccessfulTimeZone, oldTimeZone.identifier)
  }
}
