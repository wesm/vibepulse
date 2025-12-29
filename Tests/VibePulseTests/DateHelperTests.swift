import XCTest
@testable import VibePulse

final class DateHelperTests: XCTestCase {
    func testDateKeyRoundTrip() {
        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: 2024, month: 1, day: 15, hour: 12, minute: 34))!
        let key = DateHelper.dateKey(for: date)
        let parsed = DateHelper.date(fromKey: key)
        XCTAssertNotNil(parsed)
        if let parsed {
            XCTAssertEqual(DateHelper.dateKey(for: parsed), key)
        }
    }
}
