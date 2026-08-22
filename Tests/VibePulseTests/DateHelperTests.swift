import Darwin
import XCTest

@testable import VibePulse

final class DateHelperTests: XCTestCase {
  func testUsageDateContextKeepsDateKeyAndDayBoundsInOneTimezone() throws {
    let timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    let now = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-08-22T01:30:00Z"))
    let context = UsageDateContext(now: now, timeZone: timeZone)

    XCTAssertEqual(context.todayKey, "2026-08-21")
    XCTAssertEqual(DateHelper.dateKey(for: now, in: timeZone), context.todayKey)
    XCTAssertEqual(
      DateHelper.dateKey(for: context.startOfToday, in: timeZone),
      context.todayKey)
    XCTAssertEqual(
      DateHelper.dateKey(for: context.startOfNextDay, in: timeZone),
      "2026-08-22")
    XCTAssertEqual(
      context.startOfNextDay.timeIntervalSince(context.startOfToday),
      24 * 60 * 60,
      accuracy: 0.001)
  }

  func testDateKeyTracksSystemTimezoneChangesAfterFormatterInitialization() throws {
    let originalTimeZone = getenv("TZ").map { String(cString: $0) }
    defer {
      if let originalTimeZone {
        setenv("TZ", originalTimeZone, 1)
      } else {
        unsetenv("TZ")
      }
      tzset()
      NSTimeZone.resetSystemTimeZone()
    }

    let instant = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-08-22T01:30:00Z"))
    let beforeChange = DateHelper.dateKey(for: instant)
    let targetIdentifier = try XCTUnwrap(
      ["America/Los_Angeles", "Asia/Tokyo", "UTC", "America/New_York"].first { identifier in
        guard let timeZone = TimeZone(identifier: identifier) else { return false }
        return DateHelper.dateKey(for: instant, in: timeZone) != beforeChange
      })
    let targetTimeZone = try XCTUnwrap(TimeZone(identifier: targetIdentifier))
    let capturedContext = UsageDateContext(now: instant)
    let capturedIdentifier = capturedContext.timeZone.identifier

    setenv("TZ", targetIdentifier, 1)
    tzset()
    NSTimeZone.resetSystemTimeZone()

    let expectedKey = DateHelper.dateKey(for: instant, in: targetTimeZone)
    XCTAssertEqual(DateHelper.dateKey(for: instant), expectedKey)
    XCTAssertEqual(
      DateHelper.dateKey(for: instant, in: targetTimeZone),
      expectedKey)
    XCTAssertNotEqual(beforeChange, DateHelper.dateKey(for: instant))
    XCTAssertEqual(capturedContext.timeZone.identifier, capturedIdentifier)
  }

  func testDateKeyRoundTrip() {
    let calendar = Calendar.current
    let date = calendar.date(
      from: DateComponents(year: 2024, month: 1, day: 15, hour: 12, minute: 34))!
    let key = DateHelper.dateKey(for: date)
    let parsed = DateHelper.date(fromKey: key)
    XCTAssertNotNil(parsed)
    if let parsed {
      XCTAssertEqual(DateHelper.dateKey(for: parsed), key)
    }
  }

  func testNormalizedDateKeyAcceptsCanonicalAndTextualDates() {
    XCTAssertEqual(DateHelper.normalizedDateKey(from: "2026-07-15"), "2026-07-15")
    XCTAssertEqual(DateHelper.normalizedDateKey(from: "2024-02-29"), "2024-02-29")
    XCTAssertEqual(DateHelper.normalizedDateKey(from: "July 2, 2026"), "2026-07-02")
    XCTAssertEqual(DateHelper.normalizedDateKey(from: "2026/07/15"), "2026-07-15")
  }

  func testNormalizedDateKeyRejectsInvalidCalendarDates() {
    // February never has a 30th, and 2026 is not a leap year.
    XCTAssertNil(DateHelper.normalizedDateKey(from: "2026-02-30"))
    XCTAssertNil(DateHelper.normalizedDateKey(from: "2026-02-29"))
    XCTAssertNil(DateHelper.normalizedDateKey(from: "2026-13-01"))
  }
}
